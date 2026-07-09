using System.Drawing;
using System.Globalization;

namespace ClaudeQuota;

/// <summary>
/// Pure derivations over stats.json used by the Resumen / Modelos tabs.
/// Ports streaks{}, heatmapCells(), maxDayTokens and modelColor() from
/// QuotaModel.swift / main.qml so all three surfaces agree.
/// </summary>
public static class StatsCompute
{
    public static Color ModelColor(Stats? stats, string? name)
    {
        var models = stats?.Models;
        if (models == null || name == null) return Fmt.Hex(Fmt.ModelPalette[0]);
        for (int i = 0; i < models.Count; i++)
            if (models[i].Model == name)
                return Fmt.Hex(Fmt.ModelPalette[i % Fmt.ModelPalette.Length]);
        return Fmt.Hex(Fmt.ModelPalette[0]);
    }

    public static Color ProjectColor(Stats? stats, string? name)
    {
        var projects = stats?.Projects;
        if (projects == null || name == null) return Fmt.Hex(Fmt.ModelPalette[0]);
        for (int i = 0; i < projects.Count; i++)
            if (projects[i].Project == name)
                return Fmt.Hex(Fmt.ModelPalette[i % Fmt.ModelPalette.Length]);
        return Fmt.Hex(Fmt.ModelPalette[0]);
    }

    public static double MaxDayTokens(Stats? stats)
    {
        var days = stats?.Days;
        if (days == null || days.Count == 0) return 1;
        return Math.Max(1, days.Max(d => d.Tokens));
    }

    // Máximo de la SUMA de proyectos por día — normaliza la gráfica de Proyectos con su propio eje.
    // Los tokens por-modelo (con caché) y por-proyecto (in+out crudos) difieren, así que un día puede
    // sumar más en proyectos que MaxDayTokens y la barra se saldría del viewport si se usa ese.
    public static double MaxDayProjectTokens(Stats? stats)
    {
        var days = stats?.Days;
        if (days == null || days.Count == 0) return 1;
        return Math.Max(1, days.Max(d => (d.Projects ?? new List<DayProject>()).Sum(p => p.Tokens)));
    }

    /// rachas (días consecutivos con uso).
    public static (int cur, int max) Streaks(Stats? stats)
    {
        var days = stats?.Days;
        if (days == null || days.Count == 0) return (0, 0);

        var active = new HashSet<string>();
        foreach (var d in days)
            if (d.Date != null && d.Tokens > 0) active.Add(d.Date);
        if (active.Count == 0) return (0, 0);

        var dates = active.Select(ParseDay).Where(d => d != null)
            .Select(d => d!.Value).OrderBy(d => d).ToList();

        int longest = 0, run = 0;
        DateTime? prev = null;
        foreach (var t in dates)
        {
            if (prev is DateTime p && (t - p).Days == 1) run++;
            else run = 1;
            longest = Math.Max(longest, run);
            prev = t;
        }

        int cur = 0;
        var day = DateTime.UtcNow.Date;
        if (!active.Contains(Key(day))) day = day.AddDays(-1);
        while (active.Contains(Key(day))) { cur++; day = day.AddDays(-1); }

        return (cur, longest);
    }

    /// GitHub-style heatmap: continuous range from the first day with data,
    /// week-aligned starting on the Sunday of that first week. Column-major
    /// (7 rows). Returns per-cell token counts.
    public static List<double> HeatmapCells(Stats? stats)
    {
        var days = stats?.Days;
        if (days == null || days.Count == 0) return new();

        var m = new Dictionary<string, double>();
        DateTime? minD = null, maxD = null;
        foreach (var d in days)
        {
            if (d.Date == null || ParseDay(d.Date) is not DateTime dt) continue;
            m[d.Date] = d.Tokens;
            if (minD == null || dt < minD) minD = dt;
            if (maxD == null || dt > maxD) maxD = dt;
        }
        if (minD is not DateTime min || maxD is not DateTime max) return new();

        // retroceder al domingo de la semana del primer día (Sunday = 0)
        int weekday = (int)min.DayOfWeek; // Sunday=0
        var cur = min.AddDays(-weekday);
        var cells = new List<double>();
        while (cur <= max)
        {
            cells.Add(m.GetValueOrDefault(Key(cur)));
            cur = cur.AddDays(1);
        }
        return cells;
    }

    private static string Key(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static DateTime? ParseDay(string s) =>
        DateTime.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture,
            DateTimeStyles.None, out var d) ? d : null;
}
