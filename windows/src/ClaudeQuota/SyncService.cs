using System.Text.Json;

namespace ClaudeQuota;

/// <summary>
/// (e) Sync entre máquinas vía carpeta de nube — el análogo C# del bloque "(e) Sync entre máquinas"
/// del script bash src/bin/claude-brain-fetch (mac/linux).
///
/// OPT-IN: se activa solo si CLAUDE_QUOTA_SYNC_DIR (env) o el archivo de config `sync-dir` está puesto,
/// así ninguna máquina sube nada sin que lo actives. El valor "auto" autodetecta Google Drive en Windows.
/// Cada máquina escribe su snapshot &lt;host&gt;.json en la carpeta (que tu nube ya replica), lee los de
/// TODAS las de la MISMA cuenta y fusiona -> stats-global.json (lo consume el toggle "todas" del widget).
/// Fail-open en cada paso: cualquier fallo deja el estado anterior intacto y devuelve null.
/// </summary>
public static class SyncService
{
    private const string SyncSubfolder = "claude-brain-sync";

    /// <summary>
    /// Produce el sync: escribe el snapshot propio y fusiona los de la misma cuenta.
    /// Devuelve la vista global recién fusionada (o null si el sync está apagado o algo falló).
    /// </summary>
    public static Stats? Produce(Stats localStats, string account, string nowIso,
                                 string cacheDir, string statsGlobalFile, JsonSerializerOptions jsonOpts)
    {
        try
        {
            string? syncDir = ResolveSyncDir(cacheDir);
            if (string.IsNullOrEmpty(syncDir)) return null;   // no configurado -> off

            Directory.CreateDirectory(syncDir);

            // snapshot propio: nombrado por un machine-id ESTABLE (no por el hostname, que puede cambiar
            // -> una misma maquina generaria varios snapshots y el merge multiplicaria). El nombre bonito
            // (Environment.MachineName) viaja como dato aparte para la lista "Maquinas".
            string machineId = MachineId(cacheDir);
            var snapshot = new SyncSnapshot
            {
                MachineId = machineId,
                Machine = SafeHost(),
                UpdatedAt = nowIso,
                Account = account,
                Stats = localStats,
            };
            try
            {
                WriteAtomic(Path.Combine(syncDir, machineId + ".json"),
                            JsonSerializer.Serialize(snapshot, jsonOpts));
            }
            catch { /* fail-open: no se pudo subir el snapshot; seguimos e intentamos fusionar */ }

            // merge de todos los snapshots de la MISMA cuenta -> stats-global.json.
            var global = Merge(syncDir, account, nowIso);
            if (global == null) return null;

            WriteAtomic(statsGlobalFile, JsonSerializer.Serialize(global, jsonOpts));
            return global;
        }
        catch { return null; }
    }

    // ---- resolución de SYNC_DIR (espeja resolve_sync_dir del bash) ---------

    /// <summary>
    /// env CLAUDE_QUOTA_SYNC_DIR gana; si no, el archivo de config `sync-dir` (texto plano) en cacheDir.
    /// Vacío/ausente = off (null). Valor "auto" autodetecta Google Drive en Windows; cualquier otro valor
    /// se usa TAL CUAL (sin subcarpeta, igual que el bash). En "auto" se agrega la subcarpeta claude-brain-sync.
    /// </summary>
    public static string? ResolveSyncDir(string cacheDir)
    {
        string v = Environment.GetEnvironmentVariable("CLAUDE_QUOTA_SYNC_DIR") ?? "";
        if (string.IsNullOrWhiteSpace(v))
        {
            try
            {
                string cfg = Path.Combine(cacheDir, "sync-dir");
                if (File.Exists(cfg)) v = File.ReadAllText(cfg).Trim();
            }
            catch { }
        }
        v = v.Trim();
        if (string.IsNullOrEmpty(v)) return null;                 // no configurado -> off
        if (!string.Equals(v, "auto", StringComparison.OrdinalIgnoreCase))
            return v;                                             // valor explícito, tal cual (sin subcarpeta)

        // auto: autodetecta Google Drive en Windows probando ubicaciones conocidas.
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string[] candidates =
        {
            Path.Combine(home, "My Drive"),
            Path.Combine(home, "Google Drive"),
            Path.Combine(home, "Mi unidad"),
            @"G:\My Drive",
            @"G:\Mi unidad",
            @"G:\",
        };
        foreach (var d in candidates)
        {
            try { if (Directory.Exists(d)) return Path.Combine(d, SyncSubfolder); }
            catch { }
        }
        return null;   // "auto" pero no se halló Google Drive -> off
    }

    // ---- merge (espeja el jq -s del bash) ----------------------------------

    /// <summary>Lee todos los *.json de syncDir, filtra por cuenta y fusiona a una vista Stats global.</summary>
    private static Stats? Merge(string syncDir, string account, string nowIso)
    {
        // 1. leer y deserializar cada snapshot (fail-open por archivo), filtrar por cuenta.
        var snaps = new List<SyncSnapshot>();
        string[] files;
        try { files = Directory.GetFiles(syncDir, "*.json"); }
        catch { return null; }
        foreach (var f in files)
        {
            try
            {
                var snap = JsonSerializer.Deserialize<SyncSnapshot>(File.ReadAllText(f));
                if (snap?.Stats != null && string.Equals(snap.Account, account, StringComparison.Ordinal))
                    snaps.Add(snap);
            }
            catch { /* snapshot roto o parcial: se ignora */ }
        }
        if (snaps.Count == 0) return null;

        // 2. days[]: agrupa todos los stats.days[] por fecha, sumando por día y por modelo/proyecto.
        var allDays = snaps.SelectMany(s => s.Stats!.Days ?? new List<StatsDay>());
        var days = allDays
            .Where(d => d.Date != null)
            .GroupBy(d => d.Date!)
            .OrderBy(g => g.Key, StringComparer.Ordinal)
            .Select(g => new StatsDay
            {
                Date = g.Key,
                InTok = g.Sum(d => d.InTok),
                OutTok = g.Sum(d => d.OutTok),
                Tokens = g.Sum(d => d.Tokens),
                Cost = g.Sum(d => d.Cost ?? 0),
                Messages = g.Sum(d => d.Messages),
                Models = g.SelectMany(d => d.Models ?? new List<DayModel>())
                    .GroupBy(m => m.Model ?? "unknown")
                    .Select(mg => new DayModel
                    {
                        Model = mg.Key,
                        InTok = mg.Sum(m => m.InTok),
                        OutTok = mg.Sum(m => m.OutTok),
                        Tokens = mg.Sum(m => m.Tokens),
                    }).ToList(),
                Projects = g.SelectMany(d => d.Projects ?? new List<DayProject>())
                    .GroupBy(p => p.Project ?? "?")
                    .Select(pg => new DayProject
                    {
                        Project = pg.Key,
                        InTok = pg.Sum(p => p.InTok),
                        OutTok = pg.Sum(p => p.OutTok),
                        Tokens = pg.Sum(p => p.Tokens),
                    }).ToList(),
            })
            .ToList();

        // 3. models[]: agrega los models[] de todos los días, tot = in+out, orden desc, pct sobre el gran total.
        var models = days.SelectMany(d => d.Models ?? new List<DayModel>())
            .GroupBy(m => m.Model ?? "unknown")
            .Select(g =>
            {
                double inTok = g.Sum(m => m.InTok), outTok = g.Sum(m => m.OutTok);
                return new StatsModel { Model = g.Key, InTok = inTok, OutTok = outTok, Tot = inTok + outTok };
            })
            .OrderByDescending(m => m.Tot)
            .ToList();
        double grand = models.Sum(m => m.Tot);
        foreach (var m in models) m.Pct = grand > 0 ? m.Tot * 100 / grand : 0;

        // 4. projects[]: idem por proyecto.
        var projects = days.SelectMany(d => d.Projects ?? new List<DayProject>())
            .GroupBy(p => p.Project ?? "?")
            .Select(g =>
            {
                double inTok = g.Sum(p => p.InTok), outTok = g.Sum(p => p.OutTok);
                return new StatsProject { Project = g.Key, InTok = inTok, OutTok = outTok, Tot = inTok + outTok };
            })
            .OrderByDescending(p => p.Tot)
            .ToList();
        foreach (var p in projects) p.Pct = grand > 0 ? p.Tot * 100 / grand : 0;

        // 5. machines[]: qué máquina aportó y cuánto (por total_tokens de su summary), orden desc.
        var machines = snaps
            .Select(s => new MachineStat
            {
                Name = s.Machine,
                UpdatedAt = s.UpdatedAt,
                Tokens = s.Stats!.Summary?.TotalTokens ?? 0,
            })
            .OrderByDescending(m => m.Tokens)
            .ToList();

        return new Stats
        {
            UpdatedAt = nowIso,
            Machines = machines,
            Days = days,
            Models = models,
            Projects = projects,
            Summary = new StatsSummary
            {
                TotalTokens = grand,
                TotalCost = days.Sum(d => d.Cost ?? 0),
                ActiveDays = days.Count(d => d.Tokens > 0),
                FavoriteModel = models.FirstOrDefault()?.Model,
                Sessions = snaps.Sum(s => s.Stats!.Summary?.Sessions ?? 0),
                Messages = days.Sum(d => d.Messages),
                PeakHour = null,   // combinar la hora pico de varias máquinas no tiene sentido
            },
        };
    }

    // ---- utilidades --------------------------------------------------------

    /// Nombre bonito de la máquina (para mostrar). Environment.MachineName es el NetBIOS name.
    private static string SafeHost()
    {
        try
        {
            string h = Environment.MachineName;
            return string.IsNullOrWhiteSpace(h) ? "host" : h;
        }
        catch { return "host"; }
    }

    /// Machine-id ESTABLE (nombra el snapshot). Se persiste en cacheDir\machine-id la 1a vez; se siembra
    /// del MachineGuid del registro (muy estable) o de un Guid nuevo. Sobrevive a cambios de hostname.
    private static string MachineId(string cacheDir)
    {
        string file = Path.Combine(cacheDir, "machine-id");
        try
        {
            if (File.Exists(file))
            {
                string existing = File.ReadAllText(file).Trim();
                if (!string.IsNullOrEmpty(existing)) return existing;
            }
        }
        catch { }
        string id = "";
        try
        {
            id = Microsoft.Win32.Registry.GetValue(
                @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography", "MachineGuid", null) as string ?? "";
        }
        catch { }
        if (string.IsNullOrWhiteSpace(id)) id = Guid.NewGuid().ToString();
        id = id.Trim().ToLowerInvariant();
        try { Directory.CreateDirectory(cacheDir); File.WriteAllText(file, id); } catch { }
        return id;
    }

    private static void WriteAtomic(string path, string content)
    {
        string tmp = path + ".tmp";
        File.WriteAllText(tmp, content);
        File.Move(tmp, path, overwrite: true);
    }
}
