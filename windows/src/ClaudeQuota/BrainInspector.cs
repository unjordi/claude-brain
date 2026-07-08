using System.Text.Json;
using System.Text.RegularExpressions;

namespace ClaudeQuota;

/// <summary>
/// Estado de instalación de una pieza del cerebro, leído de la realidad (`~/.claude`).
/// Espejo 1:1 del enum `BrainStatus` de la GUI macOS (BrainInspector.swift).
/// </summary>
public enum BrainStatus
{
    Installed,        // global: script presente + cableado, o norma/skill presente
    PresentNotWired,  // global: el script existe pero NO está cableado en settings.json
    Absent,           // global: se esperaba y no está
    RepoScoped,       // viaja por repo (no verificable desde el ~/.claude global)
}

/// <summary>
/// Evidencia real leída de `~/.claude` en un instante dado. Puro I/O de lectura, tolerante a
/// fallos. Espejo del struct `BrainState` de Swift.
/// </summary>
public sealed class BrainState
{
    public HashSet<string> PresentHooks { get; } = new();   // basenames sin .sh en ~/.claude/hooks
    public HashSet<string> WiredHooks { get; } = new();     // basenames referenciados en settings.json
    public bool HasNorms { get; set; }                      // ~/.claude/CLAUDE.md trae marcador/normas
    public HashSet<string> Skills { get; } = new();         // subcarpetas de ~/.claude/skills con SKILL.md
    public List<string> Extras { get; set; } = new();       // hooks cableados fuera del catálogo
    public DateTime ScannedAt { get; set; } = DateTime.Now;

    /// Los 8 hooks de tier global que instala install-brain.sh.
    public static readonly HashSet<string> KnownGlobalHooks = new()
    {
        "git-branch-guard", "merge-squash-guard", "recordar-dashboard",
        "secret-scan", "rama-vieja", "limite-gasto",
        "delegacion-gate", "delegacion-registrar",
    };

    /// Los hooks repo-scoped (fuente en brain/hooks, no globales) — pueden aparecer cableados en un repo.
    public static readonly HashSet<string> KnownRepoHooks = new()
    {
        "sesion-inicio", "precompact-volcar-estado", "dod-verificar", "confirmar-merge-develop",
    };

    /// Estado real de una pieza (por nombre) contra la evidencia leída. Espejo de `status(_:_:)` de Swift.
    public BrainStatus StatusOf(string name)
    {
        if (KnownGlobalHooks.Contains(name))
        {
            bool p = PresentHooks.Contains(name), w = WiredHooks.Contains(name);
            return p && w ? BrainStatus.Installed : (p ? BrainStatus.PresentNotWired : BrainStatus.Absent);
        }
        if (KnownRepoHooks.Contains(name)) return BrainStatus.RepoScoped;
        return name switch
        {
            "cerrar-slice" => Skills.Contains("cerrar-slice") ? BrainStatus.Installed : BrainStatus.Absent,
            "Definition of Done" or "Doc <= realidad" or "Flujo de git" or "Costo de delegación"
                => HasNorms ? BrainStatus.Installed : BrainStatus.Absent,
            _ => BrainStatus.Absent,
        };
    }
}

/// <summary>
/// Lee `~/.claude` y arma un `BrainState`. Todo el I/O es de LECTURA y fail-safe (si algo falta,
/// esa pieza queda como ausente en vez de romper). Así la pestaña Cerebro refleja la realidad.
/// Réplica en .NET de `BrainInspector.inspect()` (Swift). En Windows el ~/.claude vive en el HOME
/// del usuario (UserProfile), así que usamos esa carpeta.
/// </summary>
public static class BrainInspector
{
    // Regex: basenames referenciados como /hooks/<nombre>.sh en los comandos de settings.json.
    private static readonly Regex HookRefRx =
        new(@"/hooks/([A-Za-z0-9._-]+)\.sh", RegexOptions.Compiled);

    public static BrainState Inspect()
    {
        var st = new BrainState();
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string claude = Path.Combine(home, ".claude");

        // (1) Hooks presentes: *.sh en ~/.claude/hooks
        try
        {
            string hooksDir = Path.Combine(claude, "hooks");
            if (Directory.Exists(hooksDir))
                foreach (var f in Directory.EnumerateFiles(hooksDir, "*.sh"))
                    st.PresentHooks.Add(Path.GetFileNameWithoutExtension(f));
        }
        catch { /* fail-safe: sin hooks presentes */ }

        // (2) Hooks cableados: basenames referenciados en los comandos de settings.json
        try
        {
            string settings = Path.Combine(claude, "settings.json");
            if (File.Exists(settings))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(settings));
                if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                    doc.RootElement.TryGetProperty("hooks", out var hooks) &&
                    hooks.ValueKind == JsonValueKind.Object)
                {
                    foreach (var evt in hooks.EnumerateObject())
                    {
                        if (evt.Value.ValueKind != JsonValueKind.Array) continue;
                        foreach (var entry in evt.Value.EnumerateArray())
                        {
                            if (entry.ValueKind != JsonValueKind.Object ||
                                !entry.TryGetProperty("hooks", out var hs) ||
                                hs.ValueKind != JsonValueKind.Array) continue;
                            foreach (var h in hs.EnumerateArray())
                            {
                                if (h.ValueKind == JsonValueKind.Object &&
                                    h.TryGetProperty("command", out var cmd) &&
                                    cmd.ValueKind == JsonValueKind.String)
                                {
                                    foreach (Match m in HookRefRx.Matches(cmd.GetString() ?? ""))
                                        st.WiredHooks.Add(m.Groups[1].Value);
                                }
                            }
                        }
                    }
                }
            }
        }
        catch { /* fail-safe: sin cableado */ }

        // (3) Normas: instaladas por marcador de inyección, O presentes por contenido (escritas a
        //     mano). Ambas gobiernan de verdad → cuentan como activas (doc=realidad).
        try
        {
            string claudeMd = Path.Combine(claude, "CLAUDE.md");
            if (File.Exists(claudeMd))
            {
                string txt = File.ReadAllText(claudeMd);
                st.HasNorms = txt.Contains("BEGIN claude-brain")
                    || txt.Contains("Definición de \"LISTO\"")
                    || txt.Contains("reflejo de la realidad");
            }
        }
        catch { /* fail-safe: sin normas */ }

        // (4) Skills: subcarpetas de ~/.claude/skills con un SKILL.md
        try
        {
            string skillsDir = Path.Combine(claude, "skills");
            if (Directory.Exists(skillsDir))
                foreach (var d in Directory.EnumerateDirectories(skillsDir))
                    if (File.Exists(Path.Combine(d, "SKILL.md")))
                        st.Skills.Add(Path.GetFileName(d));
        }
        catch { /* fail-safe: sin skills */ }

        // (5) Extras: hooks cableados que no reconocemos (ni global ni repo-scoped del catálogo)
        var known = new HashSet<string>(BrainState.KnownGlobalHooks);
        known.UnionWith(BrainState.KnownRepoHooks);
        st.Extras = st.WiredHooks.Where(h => !known.Contains(h)).OrderBy(h => h).ToList();

        st.ScannedAt = DateTime.Now;
        return st;
    }

    // ── Presentación de cada estado (glifo + etiqueta). El color lo resuelve PopupForm. ──
    //
    // De cara al usuario el glifo COLAPSA a binario (espejo de `BrainStatus.symbol` en macOS):
    // ✓ verde = bien; ! rojo = falta algo (sin cablear y ausente se ven igual → "cúralo");
    // ○ azul discreto = por-repo (no cuenta). El matiz fino de los 4 estados sigue en `Label`.

    /// Glifo binario de punto de estado. ✓ instalado · ! atención (sin cablear/ausente) · ○ por-repo.
    public static string Glyph(BrainStatus s) => s switch
    {
        BrainStatus.Installed => "✓",
        BrainStatus.PresentNotWired => "!",
        BrainStatus.Absent => "!",
        BrainStatus.RepoScoped => "○",
        _ => "!",
    };

    /// Texto de ayuda al expandir la pieza (espejo de `label` en Swift).
    public static string Label(BrainStatus s) => s switch
    {
        BrainStatus.Installed => "instalado + cableado en tu ~/.claude",
        BrainStatus.PresentNotWired => "el script existe pero NO está cableado en settings.json",
        BrainStatus.Absent => "no instalado en tu ~/.claude",
        BrainStatus.RepoScoped => "viaja por repo: se copia al .claude/ de cada proyecto",
        _ => "",
    };
}
