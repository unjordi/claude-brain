using System.Drawing;
using Microsoft.Win32;

namespace ClaudeQuota;

/// <summary>
/// Entry point + tray host — the Windows analogue of macOS AppDelegate.
/// Polls the cache every 10s and redraws the two-row tray icon; the in-process
/// fetch runs on a 5.5-min stale floor (and on demand from the popup / menu).
/// </summary>
internal static class Program
{
    private const string AppName = "ClaudeBrain";   // exe + nombre del valor de autostart
    private const string OldAppName = "ClaudeQuota"; // migración: limpiar el autostart viejo
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const double StaleThreshold = 330; // 5.5 min, matches the mac port

    [STAThread]
    private static void Main(string[] args)
    {
        // Dev/verify hook: `--shot <dir>` fetches once, renders every popup tab
        // to PNGs in <dir>, and exits. Lets the UI be checked headlessly.
        var shot = args.FirstOrDefault(a => a.StartsWith("--shot"));
        if (shot != null)
        {
            string dir = args.SkipWhile(a => a != shot).Skip(1).FirstOrDefault() ?? ".";
            ApplicationConfiguration.Initialize();
            ShotMode(dir);
            return;
        }

        // Single instance.
        using var mutex = new Mutex(true, "io.github.unjordi.claude-quota", out bool isNew);
        if (!isNew) return;

        ApplicationConfiguration.Initialize();
        Application.Run(new TrayContext());
    }

    private static void ShotMode(string dir)
    {
        Directory.CreateDirectory(dir);
        var svc = new QuotaService();
        svc.FetchAsync().GetAwaiter().GetResult();
        using var popup = new PopupForm(svc, () => { }) { ShotMode = true };
        popup.StartPosition = FormStartPosition.Manual;
        popup.Location = new Point(0, 0);
        popup.Show();
        Application.DoEvents();
        string[] names = { "limites", "resumen", "modelos", "proyectos", "chats", "cerebro" };
        for (int t = 0; t < names.Length; t++)
        {
            popup.SelectTab(t);
            popup.Refresh();
            Application.DoEvents();
            using var bmp = new Bitmap(popup.Width, popup.Height);
            popup.DrawToBitmap(bmp, new Rectangle(0, 0, popup.Width, popup.Height));
            bmp.Save(Path.Combine(dir, $"popup-{names[t]}.png"),
                System.Drawing.Imaging.ImageFormat.Png);
        }
        popup.Close();

        // Tray icon at a few sizes (blown up 8x so the two rows are inspectable).
        foreach (int sz in new[] { 16, 24, 32 })
        {
            var (icon, handle) = TrayIconRenderer.Render(
                new TrayIconRenderer.Row(svc.FivePct),
                new TrayIconRenderer.Row(svc.WeekPct),
                svc.StatusKey == "error", sz);
            using (var src = icon.ToBitmap())
            using (var big = new Bitmap(sz * 8, sz * 8))
            {
                using (var g = Graphics.FromImage(big))
                {
                    g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
                    g.Clear(Color.FromArgb(0x30, 0x30, 0x30));
                    g.DrawImage(src, 0, 0, sz * 8, sz * 8);
                }
                big.Save(Path.Combine(dir, $"tray-{sz}.png"), System.Drawing.Imaging.ImageFormat.Png);
            }
            icon.Dispose();
            TrayIconRenderer.Release(handle);
        }
    }

    private sealed class TrayContext : ApplicationContext
    {
        private readonly QuotaService _svc = new();
        private readonly NotifyIcon _tray;
        private readonly System.Windows.Forms.Timer _timer;
        private readonly PopupForm _popup;
        private IntPtr _iconHandle = IntPtr.Zero;
        private bool _fetching;

        public TrayContext()
        {
            _popup = new PopupForm(_svc, () => RunFetch(force: true));

            _tray = new NotifyIcon
            {
                Visible = true,
                Text = "Claude Brain Widget",
                ContextMenuStrip = BuildMenu(),
            };
            _tray.MouseClick += OnTrayClick;

            _svc.Reload();
            RedrawIcon();

            // First real fetch shortly after launch (off the UI thread).
            RunFetch(force: true);

            _timer = new System.Windows.Forms.Timer { Interval = 10_000 };
            _timer.Tick += (_, _) => Poll();
            _timer.Start();
        }

        private void Poll()
        {
            _svc.Reload();
            RedrawIcon();
            if (ShouldRefetch) RunFetch(force: true);
        }

        // Refresca si el caché superó el piso de 5.5 min, O si una ventana YA pasó su reset (el %
        // cacheado quedó viejo) y el caché tiene >60s — así el 100% no se queda pegado tras el reset.
        // El >60s acota el disparo por-reset (no cada tick de 10s); el guard `_fetching` de RunFetch
        // evita fetches solapados.
        private bool ShouldRefetch =>
            _svc.AgeSeconds is double age &&
            (age > StaleThreshold || (_svc.AnyResetPassed && age > 60));

        private async void RunFetch(bool force)
        {
            if (_fetching) return;
            if (!force && _svc.AgeSeconds is double age && age <= StaleThreshold) return;
            _fetching = true;
            try { await Task.Run(() => _svc.FetchAsync()); }
            catch { /* keep last good snapshot */ }
            finally
            {
                _fetching = false;
                _svc.Reload();
                RedrawIcon();
                if (_popup.Visible) _popup.RefreshData();
            }
        }

        private void RedrawIcon()
        {
            int size = Math.Max(16, SystemInformation.SmallIconSize.Width);
            var (icon, handle) = TrayIconRenderer.Render(
                new TrayIconRenderer.Row(_svc.FivePct),
                new TrayIconRenderer.Row(_svc.WeekPct),
                _svc.StatusKey == "error", size);

            var oldHandle = _iconHandle;
            var oldIcon = _tray.Icon;
            _tray.Icon = icon;
            _iconHandle = handle;
            oldIcon?.Dispose();
            TrayIconRenderer.Release(oldHandle);

            _tray.Text = Truncate(_svc.Tooltip, 63);
        }

        private static string Truncate(string s, int n) => s.Length <= n ? s : s[..n];

        private void OnTrayClick(object? sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            if (_popup.Visible) { _popup.Hide(); return; }

            _svc.Reload();
            if (ShouldRefetch) RunFetch(force: true);
            _popup.RefreshData();
            PositionPopup();
            _popup.Show();
            _popup.Activate();
        }

        /// Anchor the popup to the bottom-right, above the taskbar.
        private void PositionPopup()
        {
            var wa = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 720);
            int margin = 4;
            int x = wa.Right - _popup.Width - margin;
            int y = wa.Bottom - _popup.Height - margin;
            _popup.Location = new Point(Math.Max(wa.Left, x), Math.Max(wa.Top, y));
        }

        private ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("Actualizar ahora", null, (_, _) => RunFetch(force: true));

            var auto = new ToolStripMenuItem("Iniciar con Windows")
            {
                Checked = IsAutostart(),
                CheckOnClick = true,
            };
            auto.Click += (_, _) => SetAutostart(auto.Checked);
            menu.Items.Add(auto);

            menu.Items.Add(new ToolStripSeparator());

            // Account guard: pin the active account so a silent flip (the shared
            // credential slot switching identities) shows a ⚠ instead of wrong data.
            var pin = new ToolStripMenuItem("Fijar esta cuenta");
            pin.Click += (_, _) => { PinCurrentAccount(); RunFetch(force: true); };
            menu.Items.Add(pin);
            var unpin = new ToolStripMenuItem("Quitar cuenta fijada");
            unpin.Click += (_, _) => { UnpinAccount(); RunFetch(force: true); };
            menu.Items.Add(unpin);
            menu.Opening += (_, _) =>
            {
                bool pinned = QuotaService.ReadAccountPin() != null;
                pin.Enabled = !pinned;
                unpin.Enabled = pinned;
                pin.Text = _svc.Snapshot?.AccountEmail is string e && !pinned
                    ? $"Fijar esta cuenta ({e})" : "Fijar esta cuenta";
            };

            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Salir", null, (_, _) => ExitApp());
            return menu;
        }

        private void ExitApp()
        {
            _timer.Stop();
            _tray.Visible = false;
            _tray.Icon?.Dispose();
            TrayIconRenderer.Release(_iconHandle);
            _tray.Dispose();
            ExitThread();
        }

        // ---- account guard (pin file) ----

        private void PinCurrentAccount()
        {
            // Prefer the stable uuid; fall back to email; last resort no-op.
            string? id = _svc.Snapshot?.AccountUuid ?? _svc.Snapshot?.AccountEmail;
            if (string.IsNullOrEmpty(id)) return;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(QuotaService.AccountPinFile)!);
                File.WriteAllText(QuotaService.AccountPinFile, id);
            }
            catch { }
        }

        private static void UnpinAccount()
        {
            try { if (File.Exists(QuotaService.AccountPinFile)) File.Delete(QuotaService.AccountPinFile); }
            catch { }
        }

        // ---- autostart (registry Run key) ----

        private static bool IsAutostart()
        {
            try
            {
                using var k = Registry.CurrentUser.OpenSubKey(RunKey);
                return k?.GetValue(AppName) != null;
            }
            catch { return false; }
        }

        private static void SetAutostart(bool on)
        {
            try
            {
                using var k = Registry.CurrentUser.CreateSubKey(RunKey);
                if (k == null) return;
                // Migración: borra el valor viejo "ClaudeQuota" (si un install previo lo dejó) para
                // no quedar con dos entradas de autostart tras el rename a ClaudeBrain.
                k.DeleteValue(OldAppName, throwOnMissingValue: false);
                if (on) k.SetValue(AppName, $"\"{Application.ExecutablePath}\"");
                else k.DeleteValue(AppName, throwOnMissingValue: false);
            }
            catch { }
        }
    }
}
