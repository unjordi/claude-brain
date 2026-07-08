using System.Drawing;
using System.Globalization;
using System.Text.RegularExpressions;

namespace ClaudeQuota;

/// <summary>
/// Formatting / color helpers, ported 1:1 from the plasmoid (main.qml) and the
/// macOS QuotaModel.swift so the three surfaces render identically.
/// </summary>
public static partial class Fmt
{
    // Look FelixDes: naranja acento; rojo throttle solo >90%.
    public const string Accent = "#e8884a";
    public const string Danger = "#dc3545";

    /// <summary>Palette assigned by index into the (tot-desc-sorted) models list.</summary>
    public static readonly string[] ModelPalette =
        { "#e8884a", "#5b9bd5", "#9b6dd6", "#5fb98e", "#d6a15b", "#c96daa" };

    /// pctColor: null → gris; >90 → rojo (throttle); resto → naranja acento.
    public static string PctHex(double? p) =>
        p is null ? "#777777" : (p > 90 ? Danger : Accent);

    public static Color PctColor(double? p) => Hex(PctHex(p));

    /// <summary>Parse "#rrggbb" into a Color.</summary>
    public static Color Hex(string hex)
    {
        var s = hex.TrimStart('#');
        int v = int.Parse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        return Color.FromArgb((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
    }

    /// fmtTok: 1.2M / 3.4k / entero.
    public static string Tok(double? n)
    {
        if (n is null) return "—";
        double v = n.Value;
        if (v >= 1e6) return (v / 1e6).ToString("0.0", CultureInfo.InvariantCulture) + "M";
        if (v >= 1e3) return (v / 1e3).ToString("0.0", CultureInfo.InvariantCulture) + "k";
        return ((long)Math.Round(v)).ToString(CultureInfo.InvariantCulture);
    }

    /// fmtInt: separador de miles con coma.
    public static string Int(double? n)
    {
        if (n is null) return "—";
        return ((long)Math.Round(n.Value)).ToString("#,0", CultureInfo.InvariantCulture);
    }

    /// fmtHour: "9 p.m.", 12 → "12 a.m." / "12 p.m." (-1 → "—").
    public static string Hour(int? h)
    {
        if (h is null || h < 0) return "—";
        string ampm = h < 12 ? "a.m." : "p.m.";
        int hh = h.Value % 12;
        if (hh == 0) hh = 12;
        return $"{hh} {ampm}";
    }

    [GeneratedRegex("^claude-")] private static partial Regex ClaudePrefix();
    [GeneratedRegex(@"^[0-9]+\.[0-9]+$")] private static partial Regex Dotted();
    private static readonly HashSet<string> Noise = new() { "preview", "exp", "latest" };

    /// prettyModel: quita "claude-", capitaliza familia, junta versiones con "."
    /// descartando sellos de fecha (≥6 dígitos). "claude-opus-4-8" → "Opus 4.8".
    public static string PrettyModel(string? id)
    {
        if (string.IsNullOrEmpty(id)) return "—";
        var parts = ClaudePrefix().Replace(id, "").Split('-');
        if (parts.Length == 0 || parts[0].Length == 0) return "—";
        string fam = char.ToUpperInvariant(parts[0][0]) + parts[0][1..];

        var tokens = new List<string>();
        var nums = new List<string>();
        void Flush()
        {
            if (nums.Count > 0) { tokens.Add(string.Join('.', nums)); nums.Clear(); }
        }
        for (int i = 1; i < parts.Length; i++)
        {
            string p = parts[i];
            if (p.Length > 0 && p.All(char.IsDigit))
            {
                if (p.Length >= 6) break;         // sello de fecha tipo 20251001
                nums.Add(p);
            }
            else if (Dotted().IsMatch(p))
            {
                Flush(); tokens.Add(p);           // versión ya punteada, p.ej. 3.1
            }
            else if (p.Length > 0 && !Noise.Contains(p.ToLowerInvariant()))
            {
                Flush(); tokens.Add(char.ToUpperInvariant(p[0]) + p[1..]);
            }
        }
        Flush();
        return tokens.Count == 0 ? fam : $"{fam} {string.Join(' ', tokens)}";
    }
}

/// <summary>
/// ISO-8601 → texto relativo en español. relative(): "hace 2min" / "en 3h";
/// compactReset(): solo magnitud ("5min"/"3h"/"2d"). Redondea (Math.round) como el QML.
/// </summary>
public static class Rel
{
    public static DateTimeOffset? Parse(string? iso)
    {
        if (string.IsNullOrEmpty(iso)) return null;
        return DateTimeOffset.TryParse(iso, CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d)
            ? d : null;
    }

    public static string Relative(string? iso)
    {
        if (string.IsNullOrEmpty(iso)) return "";
        var date = Parse(iso);
        if (date is null) return iso;
        int diff = (int)Math.Round((date.Value - DateTimeOffset.UtcNow).TotalSeconds);
        int a = Math.Abs(diff);
        var (val, unit) = Magnitude(a);
        return diff < 0 ? $"hace {val}{unit}" : $"en {val}{unit}";
    }

    /// ¿El instante ya pasó? (resets_at en el pasado → la ventana ya se reinició y el % cacheado es viejo).
    public static bool IsPast(string? iso)
    {
        var date = Parse(iso);
        return date is DateTimeOffset d && d < DateTimeOffset.UtcNow;
    }

    public static string CompactReset(string? iso)
    {
        var date = Parse(iso);
        if (date is null) return "";
        int a = Math.Abs((int)Math.Round((date.Value - DateTimeOffset.UtcNow).TotalSeconds));
        if (a < 3600)  return $"{(int)Math.Round(a / 60.0)}min";
        if (a < 86400) return $"{(int)Math.Round(a / 3600.0)}h";
        return $"{(int)Math.Round(a / 86400.0)}d";
    }

    private static (int, string) Magnitude(int a)
    {
        if (a < 60)    return (a, "s");
        if (a < 3600)  return ((int)Math.Round(a / 60.0), "min");
        if (a < 86400) return ((int)Math.Round(a / 3600.0), "h");
        return ((int)Math.Round(a / 86400.0), "d");
    }
}
