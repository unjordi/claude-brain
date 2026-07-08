using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace ClaudeQuota;

/// <summary>
/// The click-to-open breakdown, a borderless transient form. Mirrors the
/// plasmoid's fullRepresentation and the mac popover: a vertical tab rail on the
/// left (Límites / Resumen / Modelos / Proyectos / Cerebro), a 1px separator, and
/// the tab content on the right. Everything is owner-drawn with GDI+ so it stays a
/// single control tree and honors the FelixDes look (orange accent, red past 90%).
/// </summary>
public sealed class PopupForm : Form
{
    private readonly QuotaService _svc;
    private readonly Action _onRefresh;
    private int _tab;
    private int _hoverRail = -1;

    // Scroll vertical SOLO de la pestaña Cerebro (owner-draw): desplazamiento
    // actual y altura total dibujada en el último paint (para acotar el scroll).
    private int _cerebroScroll;
    private int _cerebroContentH;

    // ── Cerebro VIVO (interactividad + auto-reflejo + curita) ──
    // Estado REAL leído de ~/.claude (se recarga al abrir la pestaña); nil hasta la 1ª lectura.
    private BrainState? _brainState;
    // Hoja del Cerebro actualmente expandida ("<tier>-<idx>"), o null. Solo una abierta a la vez.
    private string? _expandedKey;
    // El botón-curita está corriendo el instalador del cerebro.
    private bool _healing;
    // Mensaje transitorio tras curar/actualizar el cerebro.
    private string? _healMsg;
    // Zonas clicables recolectadas en el último PaintCerebro (coords LÓGICAS pre-scroll):
    // cada hoja (clave→rect de su fila) y el botón-curita. El hit-testing suma _cerebroScroll.
    private readonly List<(string key, Rectangle rect)> _leafHits = new();
    private Rectangle _healHit = Rectangle.Empty;
    // Banner de AUTOUPDATE (winturbo-style): zona clicable (coords lógicas pre-scroll) + timer de
    // respaldo que resetea el estado si el update no completó (p. ej. ff abortado → app sigue viva).
    private Rectangle _updateHit = Rectangle.Empty;
    private System.Windows.Forms.Timer? _updateFallback;

    // logical → device scale (PerMonitorV2); all metrics below are in logical px.
    private float S => DeviceDpi / 96f;

    private const int WLogical = 520, HLogical = 420, RailWLogical = 132;

    // theme
    private Color _bg, _fg;
    // Paleta compartida con macOS (PopoverView.swift): acento naranja + verde/rojo/azul de estado.
    private readonly Color _accent = Fmt.Hex(Fmt.Accent);
    private readonly Color _green = Fmt.Hex("#3aa76d");
    private readonly Color _red = Fmt.Hex("#dc3545");
    private readonly Color _blue = Fmt.Hex("#4a90d9");

    private readonly Panel _rail = new();
    private readonly Panel _content = new();

    private static readonly string[] TabNames = { "Límites", "Resumen", "Modelos", "Proyectos", "Cerebro" };

    public PopupForm(QuotaService svc, Action onRefresh)
    {
        _svc = svc;
        _onRefresh = onRefresh;

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.Dpi;
        DoubleBuffered = true;
        KeyPreview = true;
        // 1px hairline frame around the popover: the form's own BackColor (a subtle
        // fg-tinted line, set in ApplyTheme) peeks through the padding while the docked
        // panels fill the interior. Gives the popup an edge against the desktop.
        Padding = new Padding(1);

        ApplyTheme();

        _rail.Dock = DockStyle.Left;
        _rail.Width = Sc(RailWLogical);
        _rail.BackColor = Blend(_bg, _fg, 0.03);
        _rail.Paint += RailPaint;
        _rail.MouseDown += RailMouseDown;
        _rail.MouseMove += RailMouseMove;
        _rail.MouseLeave += (_, _) => { _hoverRail = -1; _rail.Invalidate(); };

        _content.Dock = DockStyle.Fill;
        _content.BackColor = _bg;
        _content.Paint += ContentPaint;
        _content.MouseDown += ContentMouseDown;

        // 1px separator between rail and content.
        var sep = new Panel { Dock = DockStyle.Left, Width = 1, BackColor = Blend(_bg, _fg, 0.12) };

        Controls.Add(_content);
        Controls.Add(sep);
        Controls.Add(_rail);

        ClientSize = new Size(Sc(WLogical), Sc(HLogical));

        foreach (Control c in new Control[] { _rail, _content })
            EnableDoubleBuffer(c);
    }

    /// When set (dev `--shot` mode) the popup stays visible so its real paint
    /// path can be captured; normal runtime leaves it false.
    public bool ShotMode;

    // Close when focus leaves (transient popover behavior).
    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        if (!ShotMode) Hide();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape) Hide();
        base.OnKeyDown(e);
    }

    /// <summary>Refresh in-memory data and repaint (called before showing).</summary>
    public void RefreshData()
    {
        ApplyTheme();
        _rail.BackColor = Blend(_bg, _fg, 0.03);
        _content.BackColor = _bg;
        Invalidate(true);
        _rail.Invalidate();
        _content.Invalidate();
    }

    public void SelectTab(int t)
    {
        _tab = t;
        _cerebroScroll = 0;
        // Al mostrar la pestaña Cerebro, re-lee el estado REAL de ~/.claude (doc=realidad) y dispara
        // el chequeo de autoupdate (throttled 1×/15min, fail-open). Espeja `.task { checkIfStale() }`
        // de la vista macOS: al resolver (si cambió), re-pinta el popup para mostrar/ocultar el banner.
        if (t == 4)
        {
            _brainState = BrainInspector.Inspect();
            _expandedKey = null;
            _healMsg = null;
            Updater.Shared.CheckIfStale(() =>
            {
                try { BeginInvoke(new Action(() => _content.Invalidate())); } catch { }
            });
        }
        _rail.Invalidate();
        _content.Invalidate();
    }

    // Rueda del ratón: solo scrollea la pestaña Cerebro (las demás caben en el
    // alto fijo del popup). El form tiene el foco mientras el popover está
    // visible, así que recibe WM_MOUSEWHEEL aquí.
    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        if (_tab != 4) return;
        int max = Math.Max(0, _cerebroContentH - _content.Height);
        if (max <= 0) return;
        int step = (e.Delta / 120) * Sc(48);
        _cerebroScroll = Math.Clamp(_cerebroScroll - step, 0, max);
        _content.Invalidate();
    }

    // ================= Rail =================

    // Rect (device px) del i-ésimo botón del riel. Centralizado para que paint y
    // hit-testing no se desincronicen si cambia el espaciado.
    private Rectangle RailBtnRect(int i)
    {
        int pad = Sc(6), btnH = Sc(36), gap = Sc(5);
        return new Rectangle(pad, pad + Sc(2) + i * (btnH + gap), _rail.Width - pad * 2, btnH);
    }

    private void RailPaint(object? sender, PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        using var font = Px(12.5f, FontStyle.Regular);
        using var fontB = Px(12.5f, FontStyle.Bold);

        for (int i = 0; i < TabNames.Length; i++)
        {
            var r = RailBtnRect(i);
            bool active = _tab == i;
            if (active)
            {
                // Píldora acento ~16% (como macOS) + barra-indicador acento a la izquierda.
                using (var b = new SolidBrush(Color.FromArgb(41, _accent)))
                    FillRounded(g, b, r, Sc(8));
                int barH = r.Height - Sc(14);
                using (var ib = new SolidBrush(_accent))
                    FillRounded(g, ib, new Rectangle(r.X + Sc(2), r.Y + (r.Height - barH) / 2, Sc(3), barH), Sc(1.5f));
            }
            else if (_hoverRail == i)
            {
                using (var b = new SolidBrush(Blend(_bg, _fg, 0.06)))
                    FillRounded(g, b, r, Sc(8));
            }

            var col = active ? _accent : Blend(_bg, _fg, 0.82);
            using var brush = new SolidBrush(col);
            var sf = new StringFormat { LineAlignment = StringAlignment.Center, Alignment = StringAlignment.Near };
            g.DrawString(TabNames[i], active ? fontB : font, brush,
                new RectangleF(r.X + Sc(14), r.Y, r.Width - Sc(16), r.Height), sf);
        }

        // bottom row: refresh + quit (fondos redondeados sutiles al hover-less, glifos tenues)
        var (refreshR, quitR) = BottomButtons();
        using (var b1 = new SolidBrush(Blend(_bg, _fg, 0.7)))
            g.DrawString("⟳", Px(15f, FontStyle.Regular), b1, refreshR, Center());
        using (var b2 = new SolidBrush(Blend(_bg, _fg, 0.45)))
            g.DrawString("⏻", Px(13f, FontStyle.Regular), b2, quitR, Center());
    }

    private (RectangleF refresh, RectangleF quit) BottomButtons()
    {
        int sz = Sc(30);
        int y = _rail.Height - sz - Sc(6);
        var refresh = new RectangleF(Sc(8), y, sz, sz);
        var quit = new RectangleF(Sc(8) + sz + Sc(6), y, sz, sz);
        return (refresh, quit);
    }

    private void RailMouseDown(object? sender, MouseEventArgs e)
    {
        for (int i = 0; i < TabNames.Length; i++)
            if (RailBtnRect(i).Contains(e.Location)) { SelectTab(i); return; }
        var (refreshR, quitR) = BottomButtons();
        if (refreshR.Contains(e.Location)) { _onRefresh(); return; }
        if (quitR.Contains(e.Location)) { Application.Exit(); }
    }

    private void RailMouseMove(object? sender, MouseEventArgs e)
    {
        int was = _hoverRail;
        _hoverRail = -1;
        for (int i = 0; i < TabNames.Length; i++)
            if (RailBtnRect(i).Contains(e.Location)) { _hoverRail = i; break; }
        if (was != _hoverRail) _rail.Invalidate();
    }

    // ================= Content =================

    private void ContentPaint(object? sender, PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        int pad = Sc(16);
        switch (_tab)
        {
            case 0: PaintLimites(g, pad); break;
            case 1: PaintResumen(g, pad); break;
            case 2: PaintModelos(g, pad); break;
            case 3: PaintProyectos(g, pad); break;
            default:
                // Cerebro: contenido alto y scrolleable → se dibuja bajo un
                // desplazamiento; lo que queda fuera del panel lo recorta el clip.
                var state = g.Save();
                g.TranslateTransform(0, -_cerebroScroll);
                _cerebroContentH = PaintCerebro(g, pad);
                g.Restore(state);
                break;
        }
    }

    // ----- Tab 0: Límites -----

    private void PaintLimites(Graphics g, int pad)
    {
        int y = SectionTitle(g, pad, pad, "Límites de uso");

        y = UsageSection(g, pad, y, "Sesión (5 h)", _svc.Snapshot?.FiveHour);
        y += Sc(14);
        y = UsageSection(g, pad, y, "Semanal (7 d)", _svc.Snapshot?.Weekly);

        // footer at the bottom (red when the pinned account doesn't match)
        bool mismatch = _svc.Snapshot?.AccountMismatch == true;
        using var fFont = Px(10f, mismatch ? FontStyle.Bold : FontStyle.Regular);
        using var fBrush = new SolidBrush(mismatch ? Fmt.Hex(Fmt.Danger) : Blend(_bg, _fg, 0.5));
        var fr = new RectangleF(pad, _content.Height - Sc(24), _content.Width - pad * 2, Sc(20));
        g.DrawString(_svc.FooterText, fFont, fBrush, fr);
    }

    private int UsageSection(Graphics g, int pad, int y, string title, Bucket? bucket)
    {
        int w = _content.Width - pad * 2;
        double? pct = bucket?.Percent;

        using (var tFont = Px(12.5f, FontStyle.Bold))
        using (var tBrush = new SolidBrush(_fg))
            g.DrawString(title, tFont, tBrush, pad, y);

        string pctTxt = pct is double p ? p.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + "%" : "—";
        using (var pFont = Px(12.5f, FontStyle.Bold))
        using (var pBrush = new SolidBrush(Fmt.PctColor(pct)))
        {
            var sz = g.MeasureString(pctTxt, pFont);
            g.DrawString(pctTxt, pFont, pBrush, pad + w - sz.Width, y);
        }
        y += Sc(24);

        // progress bar (cápsula con sutil brillo vertical en el relleno)
        int barH = Sc(10);
        using (var track = new SolidBrush(Blend(_bg, _fg, 0.12)))
            FillRounded(g, track, new Rectangle(pad, y, w, barH), barH / 2f);
        if (pct is double pv)
        {
            int fw = (int)(w * Math.Clamp(pv / 100.0, 0, 1));
            if (fw > 1)
            {
                var c = Fmt.PctColor(pct);
                using var fill = new LinearGradientBrush(
                    new Rectangle(pad, y - 1, fw, barH + 2), Lighten(c, 0.18), c, LinearGradientMode.Vertical);
                FillRounded(g, fill, new Rectangle(pad, y, fw, barH), barH / 2f);
            }
        }
        y += barH + Sc(9);

        // caption
        using (var cFont = Px(10f, FontStyle.Regular))
        using (var cBrush = new SolidBrush(Blend(_bg, _fg, 0.65)))
            g.DrawString(Caption(bucket), cFont, cBrush, pad, y);
        return y + Sc(20);
    }

    private static string Caption(Bucket? bucket)
    {
        if (bucket == null) return "";
        string s = ResetLine(bucket.ResetsAt);
        if (bucket.CostUsd is double c)
            s += $" · ≈ ${c.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture)} (API equiv local)";
        return s;
    }

    /// "Se restablece en Nmin" (futuro) o "Se restableció hace Nmin · actualizando…" (ya pasó → el %
    /// cacheado quedó viejo y el fetch disparado por el reset lo está poniendo al día).
    private static string ResetLine(string? iso)
    {
        // Pasado → "Se restableció hace Nmin · actualizando…"; futuro → detalle útil "en 4h36m" / "mié@7:59".
        return Rel.IsPast(iso)
            ? $"Se restableció {Rel.Relative(iso)} · actualizando…"
            : $"Se restablece {Rel.ResetDetail(iso)}";
    }

    // ----- Tab 1: Resumen -----

    private void PaintResumen(Graphics g, int pad)
    {
        var s = _svc.Stats?.Summary;
        var streaks = StatsCompute.Streaks(_svc.Stats);
        int y = SectionTitle(g, pad, pad, "Resumen");

        (string, string)[] cards =
        {
            ("Sesiones",        s != null ? Fmt.Int(s.Sessions) : "—"),
            ("Mensajes",        s != null ? Fmt.Int(s.Messages) : "—"),
            ("Tokens totales",  s != null ? Fmt.Tok(s.TotalTokens) : "—"),
            ("Días activos",    s != null ? s.ActiveDays.ToString() : "—"),
            ("Racha actual",    $"{streaks.cur}d"),
            ("Racha más larga", $"{streaks.max}d"),
            ("Hora pico",       s != null ? Fmt.Hour(s.PeakHour) : "—"),
            ("Modelo favorito", s != null ? Fmt.PrettyModel(s.FavoriteModel) : "—"),
            ("Costo API-equiv", s?.TotalCost is double tc ? "$" + ((long)Math.Round(tc)) : "—"),
        };

        int cols = 3, gapc = Sc(6);
        int cardW = (_content.Width - pad * 2 - gapc * (cols - 1)) / cols;
        int cardH = Sc(50);
        for (int i = 0; i < cards.Length; i++)
        {
            int cx = pad + (i % cols) * (cardW + gapc);
            int cy = y + (i / cols) * (cardH + gapc);
            StatCard(g, new Rectangle(cx, cy, cardW, cardH), cards[i].Item1, cards[i].Item2);
        }
        y += 3 * (cardH + gapc) + Sc(6);

        using (var cFont = Px(10f, FontStyle.Regular))
        using (var cBrush = new SolidBrush(Blend(_bg, _fg, 0.6)))
            g.DrawString("Actividad diaria (local)", cFont, cBrush, pad, y);
        y += Sc(18);

        Heatmap(g, pad, y);
    }

    private void StatCard(Graphics g, Rectangle r, string label, string value)
    {
        using (var bg = new SolidBrush(Blend(_bg, _fg, 0.06)))
            FillRounded(g, bg, r, Sc(8));
        using (var pen = new Pen(Blend(_bg, _fg, 0.10)))
            DrawRounded(g, pen, r, Sc(8));
        int ipad = Sc(8);
        using (var lFont = Px(9f, FontStyle.Regular))
        using (var lBrush = new SolidBrush(Blend(_bg, _fg, 0.6)))
            g.DrawString(label, lFont, lBrush, r.X + ipad, r.Y + Sc(6));
        using (var vFont = Px(13.5f, FontStyle.Bold))
        using (var vBrush = new SolidBrush(_fg))
        {
            var sf = new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap };
            g.DrawString(value, vFont, vBrush,
                new RectangleF(r.X + ipad, r.Y + Sc(24), r.Width - ipad * 2, Sc(20)), sf);
        }
    }

    private void Heatmap(Graphics g, int pad, int y)
    {
        var cells = StatsCompute.HeatmapCells(_svc.Stats);
        if (cells.Count == 0) return;
        double maxTok = StatsCompute.MaxDayTokens(_svc.Stats);
        int cell = Sc(12), gap = Sc(3);
        var empty = Blend(_bg, _fg, 0.08);
        for (int i = 0; i < cells.Count; i++)
        {
            int col = i / 7, row = i % 7;
            int x = pad + col * (cell + gap);
            int cy = y + row * (cell + gap);
            if (x + cell > _content.Width - pad) break; // clip overflow columns
            Color c;
            if (cells[i] <= 0) c = empty;
            else
            {
                double a = 0.25 + 0.75 * Math.Min(1, cells[i] / maxTok);
                c = Color.FromArgb((int)(a * 255), _accent);
            }
            using var b = new SolidBrush(c);
            FillRounded(g, b, new Rectangle(x, cy, cell, cell), Sc(3));
        }
    }

    // ----- Tab 2: Modelos -----

    private void PaintModelos(Graphics g, int pad)
    {
        int y = SectionTitle(g, pad, pad, "Uso por modelo");

        int chartH = Sc(110);
        ChartPanel(g, new Rectangle(pad, y, _content.Width - pad * 2, chartH), StackedChart);
        y += chartH + Sc(14);

        var models = _svc.Stats?.Models ?? new List<StatsModel>();
        using var nameFont = Px(11.5f, FontStyle.Bold);
        using var subFont = Px(10.5f, FontStyle.Regular);
        int rowH = Sc(22);
        foreach (var m in models)
        {
            if (y + rowH > _content.Height - pad) break;
            var col = StatsCompute.ModelColor(_svc.Stats, m.Model);
            using (var sw = new SolidBrush(col))
                FillRounded(g, sw, new Rectangle(pad, y + Sc(4), Sc(10), Sc(10)), Sc(2));
            using (var nb = new SolidBrush(_fg))
                g.DrawString(Fmt.PrettyModel(m.Model), nameFont, nb, pad + Sc(16), y);

            string sub = $"{Fmt.Tok(m.InTok)} in · {Fmt.Tok(m.OutTok)} out";
            string pctT = m.Pct.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + "%";
            using (var pb = new SolidBrush(col))
            {
                var pf = new StringFormat { Alignment = StringAlignment.Far };
                g.DrawString(pctT, nameFont, pb,
                    new RectangleF(pad, y, _content.Width - pad * 2, rowH), pf);
            }
            using (var sb = new SolidBrush(Blend(_bg, _fg, 0.7)))
            {
                var sf = new StringFormat { Alignment = StringAlignment.Far };
                g.DrawString(sub, subFont, sb,
                    new RectangleF(pad, y, _content.Width - pad * 2 - Sc(52), rowH), sf);
            }
            y += rowH;
        }
    }

    /// Frame a stacked chart inside a subtle rounded card (labelColor ~4%) with an
    /// inset drawing area — mirrors the grouped-card look of macOS.
    private void ChartPanel(Graphics g, Rectangle outer, Action<Graphics, Rectangle> draw)
    {
        using (var bg = new SolidBrush(Blend(_bg, _fg, 0.04)))
            FillRounded(g, bg, outer, Sc(8));
        int ins = Sc(8);
        draw(g, new Rectangle(outer.X + ins, outer.Y + ins, outer.Width - ins * 2, outer.Height - ins * 2));
    }

    private void StackedChart(Graphics g, Rectangle area)
    {
        var days = _svc.Stats?.Days ?? new List<StatsDay>();
        if (days.Count == 0) return;
        double maxTok = StatsCompute.MaxDayTokens(_svc.Stats);
        int gap = Sc(2);
        float barW = Math.Max(1f, (area.Width - gap * (days.Count - 1f)) / days.Count);
        for (int i = 0; i < days.Count; i++)
        {
            float x = area.X + i * (barW + gap);
            float yTop = area.Bottom;
            foreach (var seg in days[i].Models ?? new List<DayModel>())
            {
                float h = (float)(area.Height * (seg.Tokens / maxTok));
                if (h <= 0) continue;
                yTop -= h;
                using var b = new SolidBrush(StatsCompute.ModelColor(_svc.Stats, seg.Model));
                g.FillRectangle(b, x, yTop, barW, h);
            }
        }
    }

    // ----- Tab 3: Proyectos -----

    private void PaintProyectos(Graphics g, int pad)
    {
        int y = SectionTitle(g, pad, pad, "Uso por proyecto");

        int chartH = Sc(110);
        ChartPanel(g, new Rectangle(pad, y, _content.Width - pad * 2, chartH), StackedProjectChart);
        y += chartH + Sc(14);

        var projects = _svc.Stats?.Projects ?? new List<StatsProject>();
        using var nameFont = Px(11.5f, FontStyle.Bold);
        using var subFont = Px(10.5f, FontStyle.Regular);
        int rowH = Sc(22);
        foreach (var p in projects)
        {
            if (y + rowH > _content.Height - pad) break;
            var col = StatsCompute.ProjectColor(_svc.Stats, p.Project);
            using (var sw = new SolidBrush(col))
                FillRounded(g, sw, new Rectangle(pad, y + Sc(4), Sc(10), Sc(10)), Sc(2));
            using (var nb = new SolidBrush(_fg))
            {
                var nf = new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap };
                g.DrawString(p.Project ?? "—", nameFont, nb,
                    new RectangleF(pad + Sc(16), y, _content.Width - pad * 2 - Sc(180), rowH), nf);
            }

            string sub = $"{Fmt.Tok(p.InTok)} in · {Fmt.Tok(p.OutTok)} out";
            string pctT = p.Pct.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + "%";
            using (var pb = new SolidBrush(col))
            {
                var pf = new StringFormat { Alignment = StringAlignment.Far };
                g.DrawString(pctT, nameFont, pb,
                    new RectangleF(pad, y, _content.Width - pad * 2, rowH), pf);
            }
            using (var sb = new SolidBrush(Blend(_bg, _fg, 0.7)))
            {
                var sf = new StringFormat { Alignment = StringAlignment.Far };
                g.DrawString(sub, subFont, sb,
                    new RectangleF(pad, y, _content.Width - pad * 2 - Sc(52), rowH), sf);
            }
            y += rowH;
        }
    }

    private void StackedProjectChart(Graphics g, Rectangle area)
    {
        var days = _svc.Stats?.Days ?? new List<StatsDay>();
        if (days.Count == 0) return;
        double maxTok = StatsCompute.MaxDayTokens(_svc.Stats);
        int gap = Sc(2);
        float barW = Math.Max(1f, (area.Width - gap * (days.Count - 1f)) / days.Count);
        for (int i = 0; i < days.Count; i++)
        {
            float x = area.X + i * (barW + gap);
            float yTop = area.Bottom;
            foreach (var seg in days[i].Projects ?? new List<DayProject>())
            {
                float h = (float)(area.Height * (seg.Tokens / maxTok));
                if (h <= 0) continue;
                yTop -= h;
                using var b = new SolidBrush(StatsCompute.ProjectColor(_svc.Stats, seg.Project));
                g.FillRectangle(b, x, yTop, barW, h);
            }
        }
    }

    // ----- Tab 4: Cerebro (VIVO) -----
    //
    // Infografía del cerebro global de Claude Code, réplica de la pestaña macOS
    // (PopoverView.swift, `cerebroTab`). La ESTRUCTURA (qué piezas hay y su explicación)
    // es curada; el ESTADO de instalación de cada pieza se LEE de la realidad (`~/.claude`)
    // vía `_brainState` (auto-reflejo). Además cada hoja es CLICABLE (se expande su evento +
    // detalle) y un recuadro de salud arriba trae el botón-curita self-healing.
    // Jerarquía de más DURO (arriba) a más LEVE (abajo). Devuelve la altura total dibujada,
    // que ContentPaint usa para acotar el scroll.
    private int PaintCerebro(Graphics g, int pad)
    {
        int right = _content.Width - pad;      // borde derecho útil del contenido
        int y = pad;

        // Recolectar de cero las zonas clicables de este paint (hit-testing).
        _leafHits.Clear();
        _healHit = Rectangle.Empty;
        // Salvaguarda: si nunca se leyó el estado (p. ej. paint directo en tab 4), léelo ahora.
        _brainState ??= BrainInspector.Inspect();

        // Encabezado de marca: destello acento + 🧠 Cerebro global.
        using (var spFont = Px(12f, FontStyle.Bold))
        using (var spBrush = new SolidBrush(_accent))
            g.DrawString("✦", spFont, spBrush, pad, y + Sc(1));
        int hx = pad + Sc(16);
        using (var emj = PxFont("Segoe UI Emoji", 13f, FontStyle.Regular))
        using (var b = new SolidBrush(_fg))
            g.DrawString("🧠", emj, b, hx, y);
        hx += Sc(22);
        using (var h = Px(13.5f, FontStyle.Bold))
        using (var b = new SolidBrush(_fg))
            g.DrawString("Cerebro global", h, b, hx, y + Sc(1));
        y += Sc(24);

        // Subtítulo tenue (envuelve a varias líneas).
        const string subtitle =
            "Guardarraíles + gobernanza + normas de Claude Code. Viaja por git, aplica en " +
            "toda máquina. De más duro (arriba) a más leve (abajo). Toca una pieza para ver " +
            "su evento y un ejemplo.";
        using (var sf = Px(9.5f, FontStyle.Regular))
        using (var b = new SolidBrush(Blend(_bg, _fg, 0.6)))
        {
            var sz = g.MeasureString(subtitle, sf, right - pad);
            g.DrawString(subtitle, sf, b, new RectangleF(pad, y, right - pad, sz.Height + Sc(2)));
            y += (int)Math.Ceiling(sz.Height) + Sc(10);
        }

        // Banner de AUTOUPDATE (solo si el repo avanzó respecto al build actual).
        y = PaintUpdateBanner(g, pad, right, y);

        // Recuadro de salud (auto-reflejo + curita).
        y = PaintBrainHealth(g, pad, right, y);

        for (int t = 0; t < BrainTiers.Length; t++)
            y = PaintTier(g, pad, right, y, BrainTiers[t], t);

        y = PaintExtras(g, pad, right, y);

        // Pie tenue.
        const string footer =
            "Instalado por install-brain.sh · probado por test-brain.sh · sin jq " +
            "los hooks fallan ABIERTO (no bloquean).";
        using (var ff = Px(9.5f, FontStyle.Regular))
        using (var b = new SolidBrush(Blend(_bg, _fg, 0.45)))
        {
            var sz = g.MeasureString(footer, ff, right - pad);
            g.DrawString(footer, ff, b, new RectangleF(pad, y + Sc(2), right - pad, sz.Height + Sc(2)));
            y += (int)Math.Ceiling(sz.Height) + Sc(4);
        }
        return y + pad;
    }

    /// Banner de AUTOUPDATE (winturbo-style), espejo de `updateBanner` en PopoverView.swift: solo
    /// aparece si el repo avanzó respecto al build actual. Pastilla naranja acento ~16% con un ⬆ y
    /// "Actualizar widget (local → remoto)". Toda la pastilla es CLICABLE (owner-draw, como el
    /// botón-curita): al pulsarla corre el update detachado. Si no hay clon, invita a hacerlo a mano.
    private int PaintUpdateBanner(Graphics g, int pad, int right, int y)
    {
        var up = Updater.Shared;
        _updateHit = Rectangle.Empty;
        if (!up.UpdateAvailable) return y;

        int inner = Sc(9), lineH = Sc(18), iconW = Sc(20);
        int boxW = right - pad;
        int boxH = inner + lineH + inner;
        var box = new Rectangle(pad, y, boxW, boxH);

        // Fondo pastilla acento ~16%.
        using (var bx = new SolidBrush(Color.FromArgb(41, _accent)))
            FillRounded(g, bx, box, Sc(8));

        int cx = pad + inner, cy = y + inner;

        // Ícono (⬆ en reposo, ⏳ mientras actualiza) en acento.
        string icon = up.Updating ? "⏳" : "⬆";
        using (var icF = PxFont("Segoe UI Emoji", 10.5f, FontStyle.Regular))
        using (var icB = new SolidBrush(_accent))
            g.DrawString(icon, icF, icB, cx, cy - Sc(1));

        // Texto: espeja los tres estados del banner macOS.
        string text = up.Updating
            ? "Actualizando… (se relanza sola)"
            : up.CanSelfUpdate
                ? $"Actualizar widget ({up.LocalShort} → {up.RemoteShort})"
                : $"Hay versión nueva ({up.RemoteShort}) — actualiza a mano";
        using (var tf = Px(10f, FontStyle.Bold))
        using (var tb = new SolidBrush(_accent))
            g.DrawString(text, tf, tb, cx + iconW, cy);

        // Mensaje transitorio del updater (p. ej. fallback tras un ff abortado), a la derecha.
        if (!string.IsNullOrEmpty(up.Message))
            using (var mf = Px(8.5f, FontStyle.Regular))
            using (var mb = new SolidBrush(Blend(_bg, _fg, 0.6)))
            {
                var sf = new StringFormat { Alignment = StringAlignment.Far };
                g.DrawString(up.Message, mf, mb, new RectangleF(pad, cy + lineH, boxW - inner, Sc(14)), sf);
            }

        // Zona clicable: toda la pastilla (deshabilitada mientras actualiza).
        _updateHit = up.Updating ? Rectangle.Empty : box;
        return y + boxH + Sc(12);
    }

    /// Arranca el update desde el banner (espeja `runUpdate` del Swift): lanza el script detachado y,
    /// si logró lanzarlo, marca `Updating` y arma un respaldo a 60 s que resetea el estado si no
    /// completó (caso ff abortado → la app sigue viva). En éxito, install.ps1 mata esta app y abre la
    /// nueva, así que el respaldo nunca llega a dispararse.
    private void StartUpdate()
    {
        var up = Updater.Shared;
        if (up.Updating) return;
        if (!up.CanSelfUpdate)
        {
            up.TryLaunchUpdate();   // solo setea Message ("actualiza a mano") para pintarlo
            _content.Invalidate();
            return;
        }
        up.Updating = true;
        up.Message = null;
        _content.Invalidate();

        bool launched = up.TryLaunchUpdate();
        if (!launched)
        {
            up.Updating = false;    // no arrancó → Message ya trae el motivo
            _content.Invalidate();
            return;
        }

        _updateFallback?.Stop();
        _updateFallback?.Dispose();
        _updateFallback = new System.Windows.Forms.Timer { Interval = 60_000 };
        _updateFallback.Tick += (_, _) =>
        {
            _updateFallback!.Stop();
            if (up.Updating)
            {
                up.Updating = false;
                up.Message = "el update no completó (¿árbol sucio o sin git?)";
                _content.Invalidate();
            }
        };
        _updateFallback.Start();
    }

    /// Recuadro de SALUD leído de la realidad, BINARIO (espejo de `brainHealth` en macOS): un sello
    /// verde "Cerebro global completo y activo" o un curita rojo "Tu cerebro global está incompleto",
    /// + la hora de lectura + (si falta algo) el botón-curita. SIN leyenda de 4 estados — el matiz
    /// fino vive en el detalle al tocar cada pieza. Alturas fijas para pintar el fondo antes del texto.
    private int PaintBrainHealth(Graphics g, int pad, int right, int y)
    {
        var st = _brainState!;
        // Globales = piezas del catálogo cuyo estado NO es por-repo (los 8 hooks globales + 4 normas
        // + 1 skill = 13). Los 4 hooks repo-scoped se excluyen del conteo.
        int active = 0, total = 0;
        foreach (var tier in BrainTiers)
            foreach (var it in tier.Items)
            {
                var s = st.StatusOf(it.Name);
                if (s == BrainStatus.RepoScoped) continue;
                total++;
                if (s == BrainStatus.Installed) active++;
            }
        int missing = total - active;
        bool allGood = missing == 0;

        // El botón-curita SOLO aparece si hay algo que curar; sano → sin botón ni mensaje
        // (el sello verde ya lo dice todo). Así no reservamos su alto cuando no se muestra.
        bool showHeal = missing > 0;
        int inner = Sc(10), line1H = Sc(17), gap = Sc(7), healH = Sc(26);
        int boxW = right - pad;
        int boxH = inner + line1H + (showHeal ? gap + healH : 0) + inner;

        // Fondo del recuadro (primero, para que el texto quede encima).
        using (var bx = new SolidBrush(Blend(_bg, _fg, 0.05)))
            FillRounded(g, bx, new Rectangle(pad, y, boxW, boxH), Sc(8));

        int cx = pad + inner, cy = y + inner;

        // Línea 1 (BINARIA): sello ✓ verde / curita 🩹 + mensaje + hora a la derecha.
        string hIcon = allGood ? "✓" : "🩹";
        var hCol = allGood ? _green : _red;
        using (var hf = PxFont("Segoe UI Emoji", 10.5f, FontStyle.Bold))
        using (var hb = new SolidBrush(hCol))
            g.DrawString(hIcon, hf, hb, cx, cy - Sc(1));
        string msg = allGood ? "Cerebro global completo y activo" : "Tu cerebro global está incompleto";
        using (var tf = Px(10f, FontStyle.Bold))
        using (var tb = new SolidBrush(allGood ? _fg : _red))
            g.DrawString(msg, tf, tb, cx + Sc(20), cy);
        using (var clf = Px(8.5f, FontStyle.Regular))
        using (var clb = new SolidBrush(Blend(_bg, _fg, 0.4)))
        {
            string clock = "leído " + st.ScannedAt.ToString("HH:mm");
            var sf = new StringFormat { Alignment = StringAlignment.Far };
            g.DrawString(clock, clf, clb, new RectangleF(pad, cy, boxW - inner, line1H), sf);
        }
        cy += line1H + gap;

        // Línea 2: botón-curita 🩹 (rojo cruz-roja). Solo si hay algo que curar.
        if (showHeal)
        {
            string label = _healing ? "Curando…" : $"Curar cerebro global ({missing})";
            string bIcon = _healing ? "⏳" : "🩹";
            var bCol = Fmt.Hex("#dc3545");
            int btnPadX = Sc(9), iconW = Sc(16);
            using (var lblF = Px(9.5f, FontStyle.Bold))
            {
                int labW = (int)Math.Ceiling(g.MeasureString(label, lblF).Width);
                int btnW = btnPadX + iconW + labW + btnPadX;
                var btnR = new Rectangle(cx, cy, btnW, healH - Sc(2));
                using (var bg = new SolidBrush(Color.FromArgb(41, bCol)))  // ~16% alpha
                    FillRounded(g, bg, btnR, Sc(6));
                using (var icF = PxFont("Segoe UI Emoji", 9.5f, FontStyle.Regular))
                using (var icB = new SolidBrush(bCol))
                    g.DrawString(bIcon, icF, icB, btnR.X + btnPadX, btnR.Y + Sc(4));
                using (var lblB = new SolidBrush(bCol))
                    g.DrawString(label, lblF, lblB, btnR.X + btnPadX + iconW, btnR.Y + Sc(5));
                _healHit = btnR;   // zona clicable (coords lógicas pre-scroll)

                // Mensaje transitorio (p. ej. "✗ error") a la derecha del botón.
                if (!string.IsNullOrEmpty(_healMsg))
                    using (var mf = Px(8.5f, FontStyle.Regular))
                    using (var mb = new SolidBrush(Blend(_bg, _fg, 0.6)))
                        g.DrawString(_healMsg, mf, mb, btnR.Right + Sc(8), btnR.Y + Sc(5));
            }
        }
        else
        {
            _healHit = Rectangle.Empty;   // sano → sin zona clicable
        }

        return y + boxH + Sc(12);
    }

    /// Sección "➕ OTROS": hooks cableados en settings.json fuera del catálogo del cerebro
    /// (doc=realidad completa). Espejo de `extrasSection` (Swift). Solo si hay extras.
    private int PaintExtras(Graphics g, int pad, int right, int y)
    {
        var st = _brainState;
        if (st == null || st.Extras.Count == 0) return y;

        int spineW = Sc(3), spineGap = Sc(10);
        int tx = pad + spineW + spineGap;
        int top = y;

        using (var emj = PxFont("Segoe UI Emoji", 12.5f, FontStyle.Regular))
        using (var b = new SolidBrush(_fg))
            g.DrawString("➕", emj, b, tx, y);
        using (var tf = Px(12f, FontStyle.Bold))
        using (var tb = new SolidBrush(Blend(_bg, _fg, 0.5)))
            g.DrawString("OTROS", tf, tb, tx + Sc(22), y + Sc(1));
        y += Sc(20);

        const string sub = "hooks cableados en tu settings.json, fuera del catálogo del cerebro";
        using (var subF = Px(9.5f, FontStyle.Regular))
        using (var subB = new SolidBrush(Blend(_bg, _fg, 0.6)))
        {
            var sz = g.MeasureString(sub, subF, right - tx);
            g.DrawString(sub, subF, subB, new RectangleF(tx, y, right - tx, sz.Height + Sc(2)));
            y += (int)Math.Ceiling(sz.Height) + Sc(5);
        }

        foreach (var name in st.Extras)
        {
            using (var dotF = Px(9f, FontStyle.Regular))
            using (var dotB = new SolidBrush(Blend(_bg, _fg, 0.5)))
                g.DrawString("●", dotF, dotB, tx, y);
            using (var nf = PxFont("Consolas", 10f, FontStyle.Regular))
            using (var nb = new SolidBrush(_fg))
                g.DrawString(name, nf, nb, tx + Sc(14), y);
            y += Sc(16);
        }

        int bottom = y - Sc(3);
        using (var sp = new SolidBrush(Blend(_bg, _fg, 0.3)))
            FillRounded(g, sp, new Rectangle(pad, top, spineW, Math.Max(spineW, bottom - top)), spineW / 2f);
        return y + Sc(12);
    }

    /// Un nivel del cerebro: espina de color a la izquierda + encabezado
    /// (emoji + TÍTULO en el color del nivel + subtítulo tenue) + hojas con
    /// conectores de árbol monoespaciados. Devuelve la nueva `y`.
    private int PaintTier(Graphics g, int pad, int right, int y, BrainTier tier, int tierIndex)
    {
        int spineW = Sc(3), spineGap = Sc(10);
        int tx = pad + spineW + spineGap;   // x del texto del nivel
        int top = y;

        // Encabezado del nivel.
        using (var emj = PxFont("Segoe UI Emoji", 12.5f, FontStyle.Regular))
        using (var b = new SolidBrush(_fg))
            g.DrawString(tier.Emoji, emj, b, tx, y);
        using (var tf = Px(12f, FontStyle.Bold))
        using (var tb = new SolidBrush(tier.Color))
            g.DrawString(tier.Title, tf, tb, tx + Sc(22), y + Sc(1));
        y += Sc(20);

        using (var subF = Px(9.5f, FontStyle.Regular))
        using (var subB = new SolidBrush(Blend(_bg, _fg, 0.6)))
        {
            var sz = g.MeasureString(tier.Subtitle, subF, right - tx);
            g.DrawString(tier.Subtitle, subF, subB, new RectangleF(tx, y, right - tx, sz.Height + Sc(2)));
            y += (int)Math.Ceiling(sz.Height) + Sc(5);
        }

        // Hojas: conector ├─ salvo la última, que lleva └─.
        for (int i = 0; i < tier.Items.Length; i++)
            y = PaintLeaf(g, tx, right, y, tier.Items[i], i == tier.Items.Length - 1, tier.Color, tierIndex, i);

        // Espina de color: se dibuja al final, cuando ya se conoce el alto del nivel.
        int bottom = y - Sc(3);
        using (var sp = new SolidBrush(tier.Color))
            FillRounded(g, sp, new Rectangle(pad, top, spineW, Math.Max(spineW, bottom - top)), spineW / 2f);

        return y + Sc(12); // separación entre niveles
    }

    /// Una hoja del árbol: conector monoespaciado (color del nivel, tenue) + punto de ESTADO
    /// (leído de ~/.claude) + emoji + nombre en mono; la descripción tenue envuelve debajo del
    /// nombre; un chevron ▸/▾ a la derecha. La fila completa es CLICABLE (se registra en
    /// `_leafHits`): al tocarla se expande abajo su evento (chip color del nivel) + un párrafo de
    /// detalle + la etiqueta del estado real. Solo una hoja abierta a la vez (`_expandedKey`).
    private int PaintLeaf(Graphics g, int tx, int right, int y, BrainItem item, bool last, Color color,
                          int tierIndex, int idx)
    {
        string key = $"{tierIndex}-{idx}";
        bool isOpen = _expandedKey == key;
        var status = _brainState?.StatusOf(item.Name);
        int headerTop = y;

        using (var cf = PxFont("Consolas", 10.5f, FontStyle.Regular))
        using (var cb = new SolidBrush(Blend(_bg, color, 0.55)))
            g.DrawString(last ? "└─" : "├─", cf, cb, tx, y);

        int dotX = tx + Sc(19);             // punto de estado tras el conector
        if (status is BrainStatus s)
            using (var dotF = Px(8.5f, FontStyle.Regular))
            using (var dotB = new SolidBrush(StatusColor(s)))
                g.DrawString(BrainInspector.Glyph(s), dotF, dotB, dotX, y + Sc(1));

        int ex = tx + Sc(33);               // emoji de la pieza
        using (var emj = PxFont("Segoe UI Emoji", 10f, FontStyle.Regular))
        using (var b = new SolidBrush(_fg))
            g.DrawString(item.Emoji, emj, b, ex, y);

        int nx = ex + Sc(18);               // nombre (mono)
        using (var nf = PxFont("Consolas", 10.5f, FontStyle.Bold))
        using (var nb = new SolidBrush(_fg))
            g.DrawString(item.Name, nf, nb, nx, y);

        // Chevron ▸ (cerrado) / ▾ (abierto) a la derecha.
        int chevX = right - Sc(12);
        using (var chf = Px(9f, FontStyle.Bold))
        using (var chb = new SolidBrush(Blend(_bg, _fg, 0.35)))
            g.DrawString(isOpen ? "▾" : "▸", chf, chb, chevX, y);

        // Descripción tenue, envuelta bajo el nombre (dejando margen al chevron en la 1ª línea).
        using var df = Px(9f, FontStyle.Regular);
        using var db = new SolidBrush(Blend(_bg, _fg, 0.62));
        int descY = y + Sc(15);
        var descSz = g.MeasureString(item.Desc, df, right - nx);
        g.DrawString(item.Desc, df, db, new RectangleF(nx, descY, right - nx, descSz.Height + Sc(2)));
        int headerBottom = descY + (int)Math.Ceiling(descSz.Height) + Sc(4);

        // Registrar la zona clicable de la CABECERA (coords lógicas pre-scroll).
        _leafHits.Add((key, new Rectangle(tx, headerTop - Sc(2), right - tx, headerBottom - (headerTop - Sc(2)))));

        y = headerBottom;

        if (isOpen)
        {
            int inx = ex;   // sangría de la expansión, alineada con el emoji
            // Chip del evento (fondo color del nivel al 15%, texto mono en el color del nivel).
            using (var evF = PxFont("Consolas", 9f, FontStyle.Bold))
            {
                var evSz = g.MeasureString(item.Event, evF);
                int chipW = (int)Math.Ceiling(evSz.Width) + Sc(10);
                int chipH = (int)Math.Ceiling(evSz.Height) + Sc(4);
                var chipR = new Rectangle(inx, y, chipW, chipH);
                using (var chBg = new SolidBrush(Color.FromArgb(38, color)))  // ~15% alpha
                    FillRounded(g, chBg, chipR, Sc(3));
                using (var evB = new SolidBrush(color))
                    g.DrawString(item.Event, evF, evB, chipR.X + Sc(5), chipR.Y + Sc(2));
                y += chipH + Sc(4);
            }

            // Párrafo de detalle.
            using (var detF = Px(9f, FontStyle.Regular))
            using (var detB = new SolidBrush(Blend(_bg, _fg, 0.75)))
            {
                var sz = g.MeasureString(item.Detail, detF, right - inx);
                g.DrawString(item.Detail, detF, detB, new RectangleF(inx, y, right - inx, sz.Height + Sc(2)));
                y += (int)Math.Ceiling(sz.Height) + Sc(4);
            }

            // Etiqueta del estado real (punto + texto, en el color del estado).
            if (status is BrainStatus s2)
            {
                using (var dotF = Px(8.5f, FontStyle.Regular))
                using (var dotB = new SolidBrush(StatusColor(s2)))
                    g.DrawString(BrainInspector.Glyph(s2), dotF, dotB, inx, y);
                using (var slF = Px(8.5f, FontStyle.Regular))
                using (var slB = new SolidBrush(StatusColor(s2)))
                    g.DrawString(BrainInspector.Label(s2), slF, slB, inx + Sc(12), y);
                y += Sc(15);
            }
            y += Sc(4);
        }

        return y + Sc(6);
    }

    /// Color BINARIO del punto de estado (espejo de `BrainStatus.color` en macOS): verde=bien,
    /// rojo=falta algo (sin cablear Y ausente comparten rojo), azul discreto=por-repo. El matiz
    /// fino de los 4 estados sigue en la etiqueta al expandir (BrainInspector.Label).
    private Color StatusColor(BrainStatus s) => s switch
    {
        BrainStatus.Installed => _green,
        BrainStatus.PresentNotWired => _red,
        BrainStatus.Absent => _red,
        BrainStatus.RepoScoped => Blend(_bg, _blue, 0.6),
        _ => _red,
    };

    // ── Interactividad + self-healing ──

    /// Clic en la pestaña Cerebro: convierte la Y a coords lógicas (suma el scroll) y prueba
    /// primero el botón-curita, luego cada hoja. Toggle de la hoja tocada (una sola abierta).
    private void ContentMouseDown(object? sender, MouseEventArgs e)
    {
        if (_tab != 4) return;
        int ly = e.Y + _cerebroScroll;   // el paint aplica TranslateTransform(0, -_cerebroScroll)
        if (!_updateHit.IsEmpty && _updateHit.Contains(e.X, ly)) { StartUpdate(); return; }
        if (!_healing && !_healHit.IsEmpty && _healHit.Contains(e.X, ly)) { StartHeal(); return; }
        foreach (var (key, rect) in _leafHits)
            if (rect.Contains(e.X, ly))
            {
                _expandedKey = _expandedKey == key ? null : key;
                _content.Invalidate();
                return;
            }
    }

    /// Botón-curita: corre el instalador del cerebro EMPAQUETADO junto al exe
    /// (`<AppDir>/brain/install-brain.ps1`, que a su vez delega en bash install-brain.sh).
    /// Async (Task) para no congelar la UI; al terminar re-lee el estado y muestra ✓/✗.
    private void StartHeal()
    {
        if (_healing) return;
        string script = Path.Combine(AppContext.BaseDirectory, "brain", "install-brain.ps1");
        if (!File.Exists(script))
        {
            _healMsg = "no encontré el instalador junto al app";
            _content.Invalidate();
            return;
        }
        _healing = true;
        _healMsg = null;
        _content.Invalidate();

        Task.Run(() =>
        {
            bool ok = false;
            try { ok = RunBrainInstaller(script) == 0; }
            catch { ok = false; }
            // Volver al hilo de UI para releer el estado y repintar.
            try
            {
                BeginInvoke(new Action(() =>
                {
                    _brainState = BrainInspector.Inspect();
                    _healing = false;
                    _healMsg = ok ? "✓ curado" : "✗ error (¿Git Bash + jq?)";
                    _content.Invalidate();
                }));
            }
            catch { /* el form pudo cerrarse mientras curaba */ }
        });
    }

    /// Corre install-brain.ps1 con pwsh (fallback a powershell), sin ventana, drenando salida.
    /// Devuelve el exit code; lanza si no hay ningún PowerShell disponible.
    private static int RunBrainInstaller(string script)
    {
        foreach (var shell in new[] { "pwsh", "powershell" })
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = shell,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                psi.ArgumentList.Add("-NoProfile");
                psi.ArgumentList.Add("-ExecutionPolicy");
                psi.ArgumentList.Add("Bypass");
                psi.ArgumentList.Add("-File");
                psi.ArgumentList.Add(script);
                using var p = Process.Start(psi);
                if (p == null) continue;
                // Drenar ambos flujos en paralelo para no bloquear el pipe.
                var _o = p.StandardOutput.ReadToEndAsync();
                var _e = p.StandardError.ReadToEndAsync();
                p.WaitForExit();
                return p.ExitCode;
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // Este PowerShell no está en el PATH → probar el siguiente.
            }
        }
        throw new FileNotFoundException("ni pwsh ni powershell disponibles en el PATH");
    }

    /// Datos del cerebro. La ESTRUCTURA (qué piezas y su explicación + evento + detalle) es curada;
    /// el ESTADO de instalación se LEE de la realidad (`~/.claude`) vía `_brainState`. Espejo 1:1
    /// del array `brainTiers` de la GUI macOS (event/detail copiados literales, en español).
    private BrainTier[] BrainTiers =>
    [
        new("🔒", "INVIOLABLE", Fmt.Hex("#dc3545"), "hooks que BLOQUEAN (deny) — no negociables",
        [
            new("🚧", "git-branch-guard", "push/merge a develop·main → denegado, te redirige a ramita→MR",
                "PreToolUse · Bash",
                "Escanea cada comando: si ve un `git push` o un merge que apunte a develop/main, lo deniega y te recuerda el flujo ramita→MR. Sin jq falla ABIERTO (no bloquea)."),
            new("🔗", "merge-squash-guard", "MR a develop sin --squash → denegado (1 commit limpio)",
                "PreToolUse · Bash",
                "Un `gh pr merge`/`glab mr merge` a develop sin --squash se deniega, para que la ramita colapse a un commit curado. Los releases a main quedan exentos (conservan historia)."),
            new("🕵️", "secret-scan", "commit/push con un secreto → denegado",
                "PreToolUse · Bash",
                "Escanea lo que ENTRA al repo (staged en commit, saliente en push) buscando llaves/tokens/claves privadas de formato inconfundible (AWS, PEM, Anthropic, OpenAI, GitHub, GitLab, Slack, Google). Si aparece uno → bloquea: una credencial pusheada queda comprometida aunque la borres. Escape: --no-verify."),
            new("✋", "confirmar-merge-develop", "merge a develop sin tu OK → denegado; a main exige OK súper-explícito",
                "PreToolUse · Bash",
                "Antes de integrar por MR busca tu OK explícito en el chat reciente; a main exige lenguaje de release ('hasta main', 'libera'). Un 'sigue/avanza' NO cuenta como autorización."),
            new("✅", "dod-verificar", "Def. of Done (ver Norma 🎯 DoD) sin build+tests+memoria → denegado",
                "Stop",
                "Al cerrar el turno, si dijiste 'listo/en producción' tras tocar código fuente, exige evidencia de build+tests verdes y memoria al día, o bloquea el cierre."),
            new("💸", "delegacion-gate", "reclutar agente con costo → pide tu consentimiento (puede negar)",
                "PreToolUse · Task",
                "Al reclutar un agente calcula su nivel de costo (gratis/incluido/con costo, según tu ventana de 5h) y pide consentimiento mostrando tu cuota real. Puedes negar y el agente no corre."),
            new("🛑", "limite-gasto", "reclutar agente con el gasto pasado del techo → denegado",
                "PreToolUse · Task",
                "Freno DURO (distinto del gate que pregunta): si el gasto real ya rebasó un techo configurable (sobreuso o ventana 5h), bloquea reclutar más agentes para que un workflow desbocado no siga quemando dinero. Techo por env (LIMITE_GASTO_OVERAGE_PCT / LIMITE_GASTO_5H_PCT)."),
        ]),
        new("🔔", "AUTOMÁTICO", _accent, "hooks que inyectan / recuerdan — no bloquean",
        [
            new("🧭", "sesion-inicio", "al abrir/retomar reinyecta rama + norma de git + orden de leer memoria",
                "SessionStart",
                "Al abrir/retomar sesión o tras compactar, reinyecta la rama actual, la norma de git y la orden de leer MEMORY/estado. Antídoto a 'se me va la onda al cambiar de sesión o compu'."),
            new("💾", "precompact-volcar-estado", "antes de compactar, vuelca avance/decisiones/pendientes a memoria",
                "PreCompact",
                "Justo antes de que el contexto se compacte, te obliga a volcar avance/decisiones/pendientes a la memoria, para no perder el hilo en un sprint largo."),
            new("📊", "recordar-dashboard", "antes de un push, recuerda actualizar el dashboard del cerebro",
                "PreToolUse · Bash",
                "Antes de un `git push` recuerda (no bloquea) actualizar el dashboard del cerebro: una línea a la bitácora + ajustar el mapa si cambió el layout de repos/proyectos."),
            new("🕰️", "rama-vieja", "push de ramita muy atrás de develop → aviso (no bloquea)",
                "PreToolUse · Bash",
                "Antes de un push, si la ramita está muchos commits detrás de origin/develop (base vieja → el MR trae ruido/conflictos), avisa —no bloquea— y sugiere rebasar. Umbral configurable (RAMA_VIEJA_UMBRAL, def 40)."),
            new("📝", "delegacion-registrar", "registra el consentimiento (materializa el “pregunta 1×”)",
                "PostToolUse · Task",
                "Tras un consentimiento aprobado lo registra para no volver a preguntar (1× por máquina o por workflow, según el nivel de costo). Materializa el 'pregunta una sola vez'."),
        ]),
        new("📜", "NORMAS", Fmt.Hex("#4a90d9"), "reglas que Claude se autoimpone (CLAUDE.md)",
        [
            new("🎯", "Definition of Done", "verde técnico ≠ Done/Listo/Ya Quedó; exige QA o un OK explícito",
                "CLAUDE.md · norma",
                "Algo es LISTO solo si tú lo validaste (QA) o autorizaste el cierre. 'Verde técnico' es necesario pero insuficiente; la autorización es acotada y NO transitiva."),
            new("🪞", "Doc <= realidad", "cambió algo → actualiza su doc en la misma tanda, sin preguntar",
                "CLAUDE.md · norma",
                "Cuando cambia algo (config, ruta, comportamiento) se actualiza su doc en la misma tanda, sin preguntar. Primero revisar el estado real, luego editar: una doc que miente es peor que nada. Y con iniciativa: ¿vive en MÁS de un lugar (un README y su UI, varias plataformas, un ejemplo)? rastréalas (grep del valor viejo) y actualízalas todas — una copia desincronizada ya miente."),
            new("🌿", "Flujo de git", "ramita → MR → develop (squash); main es release-only",
                "CLAUDE.md · norma",
                "Todo push va a ramitas; se integra por MR a develop con squash; main es release-only (decisión humana deliberada). 1–3 devs → auto-merge; ≥4 devs → se revisa."),
            new("💰", "Costo de delegación", "gratis / incluido / con costo — window-aware, lee tu cuota",
                "CLAUDE.md · norma",
                "Reclutar agentes cuesta según nivel: gratis (local), incluido (Claude dentro de la ventana 5h) o con costo (overage / API externa / desconocido). La cadencia del permiso depende del nivel."),
        ]),
        new("💡", "SKILLS", Fmt.Hex("#3aa76d"), "herramientas opt-in — las invocas tú",
        [
            new("📦", "cerrar-slice", "build+tests+memoria al día + MR con resumen curado por slice",
                "skill · opt-in",
                "Ritual de cierre de un slice: build+tests verdes, memoria al día (bitácora), MR con resumen curado en prosa, y el Paso 5 de cosechar lo genérico de vuelta al cerebro global."),
        ]),
    ];

    /// Un nivel del cerebro (tier) con sus hojas — la ESTRUCTURA es curada.
    private sealed record BrainTier(string Emoji, string Title, Color Color, string Subtitle, BrainItem[] Items);

    /// Una hoja del árbol del cerebro (un hook / norma / skill). `Event` y `Detail` se muestran
    /// al expandir la hoja (chip + párrafo).
    private sealed record BrainItem(string Emoji, string Name, string Desc, string Event, string Detail);

    // ================= helpers =================

    private int Sc(float logical) => (int)Math.Round(logical * S);
    private Font Px(float logicalPt, FontStyle style) =>
        new("Segoe UI", logicalPt * S, style, GraphicsUnit.Pixel);
    // Como Px pero con una familia explícita (Consolas para mono/conectores,
    // Segoe UI Emoji para que los emojis rendericen a color en GDI+).
    private Font PxFont(string family, float logicalPt, FontStyle style) =>
        new(family, logicalPt * S, style, GraphicsUnit.Pixel);
    private static StringFormat Center() =>
        new() { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };

    private void ApplyTheme()
    {
        bool light = IsLightTheme();
        _bg = light ? Color.FromArgb(0xFA, 0xFA, 0xFA) : Color.FromArgb(0x1E, 0x1E, 0x20);
        _fg = light ? Color.FromArgb(0x1A, 0x1A, 0x1A) : Color.FromArgb(0xE8, 0xE8, 0xEA);
        // El form solo se ve por el borde de 1px (Padding): tono tenue del fg sobre el fondo.
        BackColor = Blend(_bg, _fg, 0.16);
    }

    private static bool IsLightTheme()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (k?.GetValue("AppsUseLightTheme") is int v) return v != 0;
        }
        catch { }
        return false; // default dark
    }

    /// Blend `over` onto `baseC` at the given alpha (0..1); GDI+ alpha over an
    /// opaque surface, matching SwiftUI's Color.opacity() usage.
    private static Color Blend(Color baseC, Color over, double a)
    {
        a = Math.Clamp(a, 0, 1);
        return Color.FromArgb(
            (int)(baseC.R + (over.R - baseC.R) * a),
            (int)(baseC.G + (over.G - baseC.G) * a),
            (int)(baseC.B + (over.B - baseC.B) * a));
    }

    /// Lighten a color toward white by `a` (0..1) — used for the subtle sheen on progress fills.
    private static Color Lighten(Color c, double a) => Blend(c, Color.White, a);

    /// Section title with a short accent underline, so every tab opens with the same
    /// branded header (mirrors macOS `.headline`). Returns the y below the header.
    private int SectionTitle(Graphics g, int pad, int y, string text)
    {
        using (var h = Px(15.5f, FontStyle.Bold))
        using (var b = new SolidBrush(_fg))
            g.DrawString(text, h, b, pad, y);
        using (var ab = new SolidBrush(_accent))
            FillRounded(g, ab, new Rectangle(pad, y + Sc(24), Sc(22), Sc(3)), Sc(1.5f));
        return y + Sc(38);
    }

    private static GraphicsPath RoundedPath(RectangleF r, float radius)
    {
        float rad = Math.Min(radius, Math.Min(r.Width, r.Height) / 2f);
        var path = new GraphicsPath();
        float d = rad * 2f;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    /// Stroke a rounded rectangle (1px hairline borders around cards).
    private static void DrawRounded(Graphics g, Pen p, Rectangle r, float radius)
    {
        if (r.Width <= 0 || r.Height <= 0) return;
        using var path = RoundedPath(new RectangleF(r.X, r.Y, r.Width, r.Height), radius);
        g.DrawPath(p, path);
    }

    private static void FillRounded(Graphics g, Brush b, Rectangle r, float radius) =>
        FillRounded(g, b, new RectangleF(r.X, r.Y, r.Width, r.Height), radius);

    private static void FillRounded(Graphics g, Brush b, RectangleF r, float radius)
    {
        if (r.Width <= 0 || r.Height <= 0) return;
        using var path = RoundedPath(r, radius);
        g.FillPath(b, path);
    }

    private static void EnableDoubleBuffer(Control c)
    {
        typeof(Control).GetProperty("DoubleBuffered",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
            ?.SetValue(c, true, null);
    }
}
