using System.Diagnostics;
using System.Text.Json;

namespace ClaudeQuota;

/// <summary>
/// The Windows data pipeline — the C# analogue of src/bin/claude-brain-fetch.
///
/// Unlike the Linux/mac ports (which run a bash script on a systemd/launchd
/// timer and let the UI only read the cache), the always-running tray app does
/// the fetch itself in-process every 5 minutes. It still writes the same
/// state.json / stats.json cache files under %LOCALAPPDATA%\claude-brain so the
/// snapshot stays inspectable and cross-platform-compatible.
///
/// Sources, in order of authority:
///   1. Anthropic OAuth /usage endpoint  → exact % + reset times (needs only
///      the token in %USERPROFILE%\.claude\.credentials.json; no cost).
///   2. Local transcripts (~/.claude/projects/**/*.jsonl) → tokens by day/model,
///      sessions, messages, peak hour. Pure C#, no external tools.
///   3. ccusage (if Node is installed) → API-equivalent $ cost enrichment.
/// </summary>
public sealed class QuotaService
{
    public Snapshot? Snapshot { get; private set; }
    public Stats? Stats { get; private set; }
    /// Vista fusionada de TODAS las máquinas de la misma cuenta (stats-global.json), producida por el
    /// sync (e). null si el sync no está activo o aún no hay snapshot; su presencia activa el toggle 🖥/☁️.
    public Stats? StatsGlobal { get; private set; }
    /// Conversaciones del app de escritorio (chats.json) y sesiones de Claude Code (sessions.json),
    /// producidas por los extractores de node. Best-effort: si no hay node/script quedan vacías.
    public List<Chat> Chats { get; private set; } = new();
    public List<Session> Sessions { get; private set; } = new();
    public string? LoadError { get; private set; }

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    private static string Home =>
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    private static string CacheDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                     "claude-brain");
    public static string StateFile => Path.Combine(CacheDir, "state.json");
    public static string StatsFile => Path.Combine(CacheDir, "stats.json");
    /// stats-global.json — vista fusionada de todas las máquinas (sync (e)); mismo dir del cache.
    public static string StatsGlobalFile => Path.Combine(CacheDir, "stats-global.json");
    /// Config del sync (e): ruta de la carpeta de nube. Texto plano (como el archivo `account`), o
    /// "auto" para autodetectar Google Drive. El env CLAUDE_QUOTA_SYNC_DIR gana sobre este archivo.
    public static string SyncDirConfigFile => Path.Combine(CacheDir, "sync-dir");
    /// chats.json / sessions.json — mismo dir del cache que state/stats (los emite node).
    public static string ChatsFile => Path.Combine(CacheDir, "chats.json");
    public static string SessionsFile => Path.Combine(CacheDir, "sessions.json");
    /// Optional pinned account (uuid or email) — the account-guard config.
    /// If present and the active account differs, the UI warns of a mismatch.
    public static string AccountPinFile => Path.Combine(CacheDir, "account");
    /// Config dir: CLAUDE_CONFIG_DIR if set (Claude Code honors it), else ~/.claude.
    /// Público: es la base donde el widget ESCRIBE los mapas de alias (proyectos/sesiones).
    public static string ClaudeDir
    {
        get
        {
            var cfg = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            return string.IsNullOrEmpty(cfg) ? Path.Combine(Home, ".claude") : cfg;
        }
    }
    private static string CredentialsFile => Path.Combine(ClaudeDir, ".credentials.json");
    private static string ProjectsDir => Path.Combine(ClaudeDir, "projects");
    /// ~/.claude.json (account + project names). Under CLAUDE_CONFIG_DIR if it lives there.
    private static string ClaudeJsonFile
    {
        get
        {
            var cfg = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            if (!string.IsNullOrEmpty(cfg))
            {
                var p = Path.Combine(cfg, ".claude.json");
                if (File.Exists(p)) return p;
            }
            return Path.Combine(Home, ".claude.json");
        }
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.Never,
        WriteIndented = true,
    };

    // ---- (c/d) alias de proyectos/sesiones (renombrar por clic-secundario) ----
    // Espeja QuotaModel.swift (renameProject/renameSession/aliasMap/writeMap/projectAliased/
    // sessionAliased). Los mapas { "<clave>": "<valor>" } viven en la base de Claude (ClaudeDir).
    // El fetch (proyectos) y sessions-extract vía QuotaService (sesiones) los RELEEN: tras escribir
    // hay que disparar un refetch para que la lista muestre el nombre nuevo.
    /// ~/.claude/proyectos-alias.json — { "<nombre canónico>": "<alias>" }.
    public static string ProjectAliasFile => Path.Combine(ClaudeDir, "proyectos-alias.json");
    /// ~/.claude/sesiones-alias.json — { "<id de sesión>": "<etiqueta>" }.
    public static string SessionAliasFile => Path.Combine(ClaudeDir, "sesiones-alias.json");

    private static Dictionary<string, string> AliasMap(string file)
    {
        // Fail-open: ausente/ilegible → mapa vacío (nunca rompe el rename por un JSON torcido).
        try
        {
            if (!File.Exists(file)) return new();
            return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(file)) ?? new();
        }
        catch { return new(); }
    }

    private static void WriteMap(string file, Dictionary<string, string> map)
    {
        Directory.CreateDirectory(ClaudeDir);
        // Llaves ordenadas (como el .sortedKeys de macOS) → diff limpio si el archivo se versiona/sincroniza.
        var sorted = new SortedDictionary<string, string>(map, StringComparer.Ordinal);
        WriteAtomic(file, JsonSerializer.Serialize(sorted, JsonOpts));
    }

    /// (c) Renombra un proyecto. La lista muestra el nombre YA aliaseado, así que la llave canónica
    /// (la que el fetch usa) es la entrada cuyo VALOR == mostrado; si no hay, el mostrado es el canónico.
    /// Nombre nuevo vacío (o == canónico) BORRA el alias → revierte. Requiere refetch después.
    public static void RenameProject(string shown, string newName)
    {
        var map = AliasMap(ProjectAliasFile);
        string canonical = map.FirstOrDefault(kv => kv.Value == shown).Key ?? shown;
        string v = (newName ?? "").Trim();
        if (v.Length == 0 || v == canonical) map.Remove(canonical); else map[canonical] = v;
        WriteMap(ProjectAliasFile, map);
    }

    /// (d) Renombra una sesión por su id (nombre del .jsonl, estable). Vacío revierte a la etiqueta derivada.
    public static void RenameSession(string id, string newName)
    {
        var map = AliasMap(SessionAliasFile);
        string v = (newName ?? "").Trim();
        if (v.Length == 0) map.Remove(id); else map[id] = v;
        WriteMap(SessionAliasFile, map);
    }

    /// ¿El proyecto mostrado tiene un alias activo? (es llave o valor del mapa) — para "Restaurar original".
    public static bool ProjectAliased(string shown)
    {
        var m = AliasMap(ProjectAliasFile);
        return m.ContainsKey(shown) || m.ContainsValue(shown);
    }
    /// ¿La sesión tiene un alias activo? (su id es llave del mapa) — para "Restaurar original".
    public static bool SessionAliased(string id) => AliasMap(SessionAliasFile).ContainsKey(id);

    // ---- derived, mirrors QuotaModel.swift ---------------------------------

    public string StatusKey
    {
        get
        {
            if (LoadError != null && Snapshot == null) return "error";
            if (Snapshot == null) return "error";
            if (Snapshot.Error != null) return "error";
            return Snapshot.Status ?? "error";
        }
    }

    public double? FivePct => Snapshot?.FiveHour?.Percent;
    public double? WeekPct => Snapshot?.Weekly?.Percent;

    public string Tooltip
    {
        get
        {
            if (StatusKey == "error") return "Claude Limits — sin datos";
            string five = FivePct is double f ? $"{(int)Math.Round(f)}%" : "—";
            string wk = WeekPct is double w ? $"{(int)Math.Round(w)}%" : "—";
            string warn = Snapshot?.AccountMismatch == true ? " ⚠ otra cuenta" : "";
            return $"Claude: 5h {five} · 7d {wk}{warn}";
        }
    }

    /// ¿Alguna ventana (5h / semanal) YA pasó su reset? Si sí, el % cacheado es viejo (debería
    /// haber bajado) → conviene refrescar aunque el caché no haya llegado al piso de 5.5 min.
    public bool AnyResetPassed =>
        Rel.IsPast(Snapshot?.FiveHour?.ResetsAt) || Rel.IsPast(Snapshot?.Weekly?.ResetsAt);

    public double? AgeSeconds
    {
        get
        {
            var d = Rel.Parse(Snapshot?.UpdatedAt);
            return d is null ? null : (DateTimeOffset.UtcNow - d.Value).TotalSeconds;
        }
    }

    public string FooterText
    {
        get
        {
            if (LoadError is string err && Snapshot == null) return $"error: {err}";
            if (Snapshot == null) return "cargando…";
            if (Snapshot.Error is string e) return $"error: {e}";
            string account = Snapshot.AccountEmail
                ?? (Snapshot.Basis == "oauth" ? "datos reales" : "estimado local");
            if (Snapshot.AccountMismatch)
                return $"⚠ {account} no es la cuenta fijada · ⟳ 5 min + al reset 5h · act. hace: {Rel.CompactReset(Snapshot.UpdatedAt)}";
            return $"{account} · ⟳ 5 min + al reset 5h · últ. act. hace: {Rel.CompactReset(Snapshot.UpdatedAt)}";
        }
    }

    // ---- read cached files (fast path used on every UI tick) ---------------

    public void Reload()
    {
        try
        {
            if (File.Exists(StateFile))
            {
                Snapshot = JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(StateFile));
                LoadError = null;
            }
        }
        catch (Exception ex) { LoadError = ex.Message; }

        try
        {
            if (File.Exists(StatsFile))
                Stats = JsonSerializer.Deserialize<Stats>(File.ReadAllText(StatsFile));
        }
        catch { /* stats are best-effort */ }

        // stats-global.json (sync (e)): presente solo si el sync está activo. Ausente -> StatsGlobal null
        // (el toggle 🖥/☁️ no aparece). Best-effort: roto deja el valor anterior intacto.
        try
        {
            StatsGlobal = File.Exists(StatsGlobalFile)
                ? JsonSerializer.Deserialize<Stats>(File.ReadAllText(StatsGlobalFile))
                : null;
        }
        catch { }

        // chats.json / sessions.json son best-effort: ausente/roto deja la lista anterior intacta.
        try
        {
            if (File.Exists(ChatsFile) &&
                JsonSerializer.Deserialize<List<Chat>>(File.ReadAllText(ChatsFile)) is { } c)
                Chats = c;
        }
        catch { }
        try
        {
            if (File.Exists(SessionsFile) &&
                JsonSerializer.Deserialize<List<Session>>(File.ReadAllText(SessionsFile)) is { } s)
                Sessions = s;
        }
        catch { }
    }

    // ---- the actual fetch (off the UI thread) ------------------------------

    /// <summary>Fetch fresh data, write the caches, and update in-memory state.</summary>
    public async Task FetchAsync()
    {
        Directory.CreateDirectory(CacheDir);

        OAuthUsage? usage = await TryOAuthAsync();
        var (uuid, email) = ReadAccount();
        bool mismatch = ComputeMismatch(uuid, email);
        Stats stats = BuildLocalStats();      // transcripts → tokens/models/projects
        await EnrichCostAsync(stats);         // ccusage (best-effort) → $

        var now = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");

        // stats.json is local-only, so always refresh it regardless of OAuth.
        WriteAtomic(StatsFile, JsonSerializer.Serialize(stats, JsonOpts));
        Stats = stats;

        // (e) Sync entre máquinas (opt-in): sube el snapshot de ESTA máquina a la carpeta de nube y
        // fusiona los de todas las de la misma cuenta -> stats-global.json. Fail-open (null si off/falla).
        // account = uuid preferido, luego email, luego "default" (espeja el jq del fetch mac/linux).
        string account = !string.IsNullOrEmpty(uuid) ? uuid!
                       : !string.IsNullOrEmpty(email) ? email! : "default";
        StatsGlobal = SyncService.Produce(stats, account, now, CacheDir, StatsGlobalFile, JsonOpts);

        // chats.json / sessions.json via los extractores de node (fail-open).
        await RunExtractorsAsync();

        if (usage != null)
        {
            double five = usage.FiveHour?.Utilization ?? 0;
            double week = usage.SevenDay?.Utilization ?? 0;
            var snap = new Snapshot
            {
                UpdatedAt = now,
                Status = StatusFor(Math.Max(five, week)),
                Basis = "oauth",
                AccountEmail = email,
                AccountUuid = uuid,
                AccountMismatch = mismatch,
                Error = null,
                FiveHour = new Bucket
                {
                    Percent = Round1(five),
                    CostUsd = stats.Summary?.FiveHourCost,
                    ResetsAt = Isoz(usage.FiveHour?.ResetsAt),
                },
                Weekly = new Bucket
                {
                    Percent = Round1(week),
                    CostUsd = stats.Summary?.WeeklyCost,
                    ResetsAt = Isoz(usage.SevenDay?.ResetsAt) ?? NextMondayUtc(),
                },
            };
            WriteAtomic(StateFile, JsonSerializer.Serialize(snap, JsonOpts));
            Snapshot = snap;
            LoadError = null;
        }
        else if (File.Exists(StateFile))
        {
            // OAuth unreachable this run — keep the last good state.json (its
            // real %/resets, now aging) rather than blanking the UI. Still
            // refresh the account fields (read locally, so the mismatch guard
            // stays live even while the % ages).
            Reload();
            if (Snapshot != null)
            {
                Snapshot.AccountEmail = email;
                Snapshot.AccountUuid = uuid;
                Snapshot.AccountMismatch = mismatch;
                WriteAtomic(StateFile, JsonSerializer.Serialize(Snapshot, JsonOpts));
            }
        }
        else
        {
            var snap = new Snapshot
            {
                UpdatedAt = now,
                Status = "error",
                Basis = "cost",
                AccountEmail = email,
                AccountUuid = uuid,
                AccountMismatch = mismatch,
                Error = "sin credenciales OAuth o endpoint /usage inalcanzable",
                FiveHour = null,
                Weekly = null,
            };
            WriteAtomic(StateFile, JsonSerializer.Serialize(snap, JsonOpts));
            Snapshot = snap;
            LoadError = null;
        }
    }

    private static string StatusFor(double maxPct) =>
        maxPct >= 85 ? "crit" : maxPct >= 60 ? "warn" : "ok";

    private static double Round1(double x) => Math.Floor(x * 10) / 10;

    /// "2026-06-10T00:00:00.070837+00:00" → "2026-06-10T00:00:00Z"
    private static string? Isoz(string? iso)
    {
        var d = Rel.Parse(iso);
        return d?.ToString("yyyy-MM-ddTHH:mm:ssZ");
    }

    private static string NextMondayUtc()
    {
        var today = DateTimeOffset.UtcNow.Date;
        int delta = ((int)DayOfWeek.Monday - (int)today.DayOfWeek + 7) % 7;
        if (delta == 0) delta = 7;
        return new DateTimeOffset(today.AddDays(delta), TimeSpan.Zero)
            .ToString("yyyy-MM-ddTHH:mm:ssZ");
    }

    // ---- 1. OAuth /usage ---------------------------------------------------

    private static async Task<OAuthUsage?> TryOAuthAsync()
    {
        string? token = ReadOAuthToken();
        if (token == null) return null;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get,
                "https://api.anthropic.com/api/oauth/usage");
            req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");
            req.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");
            using var res = await Http.SendAsync(req);
            if (!res.IsSuccessStatusCode) return null;
            var json = await res.Content.ReadAsStringAsync();
            var usage = JsonSerializer.Deserialize<OAuthUsage>(json);
            // Sanity: must carry the 5-hour utilization.
            return usage?.FiveHour?.Utilization != null ? usage : null;
        }
        catch { return null; }
    }

    private static string? ReadOAuthToken()
    {
        // CLAUDE_CODE_OAUTH_TOKEN (long-lived token de `claude setup-token`) gana si está presente:
        // deja al widget leer /usage sin un .credentials.json de sesión iniciada.
        var envTok = Environment.GetEnvironmentVariable("CLAUDE_CODE_OAUTH_TOKEN");
        if (!string.IsNullOrEmpty(envTok)) return envTok;
        try
        {
            if (!File.Exists(CredentialsFile)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(CredentialsFile));
            if (doc.RootElement.TryGetProperty("claudeAiOauth", out var oauth) &&
                oauth.TryGetProperty("accessToken", out var tok) &&
                tok.ValueKind == JsonValueKind.String)
            {
                var s = tok.GetString();
                return string.IsNullOrEmpty(s) ? null : s;
            }
        }
        catch { }
        return null;
    }

    /// Active account (uuid + email) from Claude Code's own config — not in the
    /// OAuth token, so read separately and best-effort. Shown in the footer and
    /// used by the account-mismatch guard.
    private static (string? uuid, string? email) ReadAccount()
    {
        try
        {
            string path = ClaudeJsonFile;
            if (!File.Exists(path)) return (null, null);
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (doc.RootElement.TryGetProperty("oauthAccount", out var acc) &&
                acc.ValueKind == JsonValueKind.Object)
            {
                string? uuid = Str(acc, "accountUuid");
                string? email = Str(acc, "emailAddress");
                return (uuid, email);
            }
        }
        catch { }
        return (null, null);

        static string? Str(JsonElement o, string k) =>
            o.TryGetProperty(k, out var e) && e.ValueKind == JsonValueKind.String &&
            !string.IsNullOrEmpty(e.GetString()) ? e.GetString() : null;
    }

    /// The pinned account (uuid or email) the user expects, or null if unset.
    public static string? ReadAccountPin()
    {
        try
        {
            if (!File.Exists(AccountPinFile)) return null;
            var s = File.ReadAllText(AccountPinFile).Trim();
            return string.IsNullOrEmpty(s) ? null : s;
        }
        catch { return null; }
    }

    /// True iff an account is pinned and neither the active uuid nor email matches.
    private static bool ComputeMismatch(string? uuid, string? email)
    {
        string? pin = ReadAccountPin();
        if (string.IsNullOrEmpty(pin)) return false;
        bool matches =
            (uuid != null && string.Equals(uuid, pin, StringComparison.OrdinalIgnoreCase)) ||
            (email != null && string.Equals(email, pin, StringComparison.OrdinalIgnoreCase));
        return !matches;
    }

    // ---- 2. transcripts → local stats -------------------------------------
    // Pure C#: mirrors both ccusage's per-model token tallies and the fetch
    // script's grep/awk pass (sessions, messages, peak hour). No Node needed.

    private static Stats BuildLocalStats()
    {
        var nameMap = LoadProjectNameMap();

        // Deduped tallies keyed by (day, model, project). Each project is a
        // subdirectory of ~/.claude/projects (slug = cwd with non-alnum → '-').
        var agg = new Dictionary<(string day, string model, string project), (double inTok, double outTok)>();
        var seenIds = new HashSet<string>();
        int sessions = 0;
        long messages = 0;
        // Mensajes (user/assistant) por DÍA local — alimenta la suma por rango del Resumen (b1b).
        // El total all-time (`messages`) queda intacto; los días solo cuentan líneas con timestamp.
        var dayMsg = new Dictionary<string, long>();
        var hourHist = new int[24];

        if (Directory.Exists(ProjectsDir))
        {
            foreach (var projDir in Directory.EnumerateDirectories(ProjectsDir))
            {
                string slug = Path.GetFileName(projDir);
                string projName = nameMap.TryGetValue(slug, out var nm) ? nm : PrettySlug(slug);

                foreach (var file in Directory.EnumerateFiles(projDir, "*.jsonl",
                             SearchOption.AllDirectories))
                {
                    sessions++;
                    foreach (var line in ReadLinesSafe(file))
                    {
                        if (line.Length < 8) continue;
                        JsonDocument doc;
                        try { doc = JsonDocument.Parse(line); }
                        catch { continue; }
                        using (doc)
                        {
                            var root = doc.RootElement;
                            if (root.ValueKind != JsonValueKind.Object) continue;

                            // Timestamp de la línea (si trae), reusado para hora pico y día del mensaje.
                            DateTimeOffset? lineTs =
                                root.TryGetProperty("timestamp", out var tsAny) &&
                                tsAny.ValueKind == JsonValueKind.String
                                    ? Rel.Parse(tsAny.GetString())
                                    : null;

                            // Peak-hour histogram over any line carrying a
                            // timestamp (matches the fetch script's grep).
                            if (lineTs is DateTimeOffset tsa)
                                hourHist[tsa.ToLocalTime().Hour]++;

                            if (!root.TryGetProperty("type", out var typeEl) ||
                                typeEl.ValueKind != JsonValueKind.String) continue;
                            string type = typeEl.GetString()!;
                            if (type is not ("assistant" or "user")) continue;
                            messages++;   // raw line count (not deduped, matches fetch)
                            // Bucket del mensaje por día LOCAL (solo si la línea trae timestamp), espejo
                            // del pase awk del fetch mac/linux. El all-time `messages` no se toca.
                            if (lineTs is DateTimeOffset mts)
                            {
                                string mday = mts.ToLocalTime().ToString("yyyy-MM-dd");
                                dayMsg[mday] = dayMsg.GetValueOrDefault(mday) + 1;
                            }

                            if (type != "assistant") continue;
                            if (!root.TryGetProperty("message", out var msg) ||
                                msg.ValueKind != JsonValueKind.Object) continue;

                            // Dedupe by message.id: Claude Code writes one jsonl
                            // line per content block, each repeating the same id
                            // and the same cumulative usage — summing every line
                            // multiplies the token count (~2-3×).
                            if (!msg.TryGetProperty("id", out var idEl) ||
                                idEl.ValueKind != JsonValueKind.String) continue;
                            if (!seenIds.Add(idEl.GetString()!)) continue;

                            if (!root.TryGetProperty("timestamp", out var tsEl) ||
                                tsEl.ValueKind != JsonValueKind.String ||
                                Rel.Parse(tsEl.GetString()) is not DateTimeOffset ts) continue;
                            string day = ts.ToLocalTime().ToString("yyyy-MM-dd");

                            string model = msg.TryGetProperty("model", out var mEl) &&
                                           mEl.ValueKind == JsonValueKind.String
                                ? mEl.GetString()! : "unknown";

                            double inTok = 0, outTok = 0;
                            if (msg.TryGetProperty("usage", out var u) &&
                                u.ValueKind == JsonValueKind.Object)
                            {
                                inTok = NumProp(u, "input_tokens");
                                outTok = NumProp(u, "output_tokens");
                            }
                            if (inTok == 0 && outTok == 0) continue;

                            var key = (day, model, projName);
                            agg.TryGetValue(key, out var cur);
                            agg[key] = (cur.inTok + inTok, cur.outTok + outTok);
                        }
                    }
                }
            }
        }

        return Aggregate(agg, sessions, messages, dayMsg, hourHist);
    }

    // Slug used by Claude Code for a project folder: the cwd with every
    // non-alphanumeric char replaced by '-'  (e.g. C:\Users\x → C--Users-x).
    private static readonly System.Text.RegularExpressions.Regex NonAlnum =
        new("[^a-zA-Z0-9]", System.Text.RegularExpressions.RegexOptions.Compiled);

    /// Map slug → human name from ~/.claude.json `.projects` (keyed by real cwd).
    private static Dictionary<string, string> LoadProjectNameMap()
    {
        var map = new Dictionary<string, string>();
        try
        {
            string path = ClaudeJsonFile;
            if (!File.Exists(path)) return map;
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (doc.RootElement.TryGetProperty("projects", out var projs) &&
                projs.ValueKind == JsonValueKind.Object)
            {
                foreach (var p in projs.EnumerateObject())
                {
                    string slug = NonAlnum.Replace(p.Name, "-");
                    map[slug] = BaseName(p.Name);
                }
            }
        }
        catch { }
        return map;
    }

    private static string BaseName(string path)
    {
        var parts = path.Split('/', '\\');
        for (int i = parts.Length - 1; i >= 0; i--)
            if (parts[i].Length > 0) return parts[i];
        return path;
    }

    /// Fallback when a slug isn't in the name map: strip leading '-', '-' → space.
    private static string PrettySlug(string slug) => slug.TrimStart('-').Replace('-', ' ');

    private static double NumProp(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var el) && el.ValueKind == JsonValueKind.Number
            ? el.GetDouble() : 0;

    /// Reads a possibly-large file line by line, tolerant of locks / partial writes.
    private static IEnumerable<string> ReadLinesSafe(string path)
    {
        StreamReader? reader = null;
        try
        {
            reader = new StreamReader(new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite));
        }
        catch { yield break; }
        using (reader)
        {
            string? line;
            while ((line = reader.ReadLine()) != null) yield return line;
        }
    }

    private static Stats Aggregate(
        Dictionary<(string day, string model, string project), (double inTok, double outTok)> agg,
        int sessions, long messages, Dictionary<string, long> dayMsg, int[] hourHist)
    {
        static double Tot((double inTok, double outTok) v) => v.inTok + v.outTok;

        // days[] — grouped by date, with per-model and per-project in/out/token segments.
        var days = agg
            .GroupBy(kv => kv.Key.day)
            .OrderBy(g => g.Key, StringComparer.Ordinal)
            .Select(g =>
            {
                double inTok = g.Sum(x => x.Value.inTok);
                double outTok = g.Sum(x => x.Value.outTok);
                return new StatsDay
                {
                    Date = g.Key,
                    InTok = inTok,
                    OutTok = outTok,
                    Tokens = inTok + outTok,
                    Cost = null,
                    Messages = dayMsg.GetValueOrDefault(g.Key),
                    Models = g.GroupBy(x => x.Key.model)
                        .Select(mg => new DayModel
                        {
                            Model = mg.Key,
                            InTok = mg.Sum(x => x.Value.inTok),
                            OutTok = mg.Sum(x => x.Value.outTok),
                            Tokens = mg.Sum(x => Tot(x.Value)),
                        })
                        .OrderByDescending(m => m.Tokens).ToList(),
                    Projects = g.GroupBy(x => x.Key.project)
                        .Select(pg => new DayProject
                        {
                            Project = pg.Key,
                            InTok = pg.Sum(x => x.Value.inTok),
                            OutTok = pg.Sum(x => x.Value.outTok),
                            Tokens = pg.Sum(x => Tot(x.Value)),
                        })
                        .OrderByDescending(p => p.Tokens).ToList(),
                };
            })
            .ToList();

        // models[] — aggregated across all days, sorted by total tokens desc.
        var models = agg
            .GroupBy(kv => kv.Key.model)
            .Select(g =>
            {
                double inTok = g.Sum(x => x.Value.inTok);
                double outTok = g.Sum(x => x.Value.outTok);
                return new StatsModel { Model = g.Key, InTok = inTok, OutTok = outTok, Cost = null, Tot = inTok + outTok };
            })
            .OrderByDescending(m => m.Tot)
            .ToList();
        double grand = models.Sum(m => m.Tot);
        foreach (var m in models) m.Pct = grand > 0 ? m.Tot * 100 / grand : 0;

        // projects[] — same, grouped by project folder (Claude Code only).
        var projects = agg
            .GroupBy(kv => kv.Key.project)
            .Select(g =>
            {
                double inTok = g.Sum(x => x.Value.inTok);
                double outTok = g.Sum(x => x.Value.outTok);
                return new StatsProject { Project = g.Key, InTok = inTok, OutTok = outTok, Tot = inTok + outTok };
            })
            .OrderByDescending(p => p.Tot)
            .ToList();
        double pgrand = projects.Sum(p => p.Tot);
        foreach (var p in projects) p.Pct = pgrand > 0 ? p.Tot * 100 / pgrand : 0;

        int peak = -1, peakCount = -1;
        for (int h = 0; h < 24; h++)
            if (hourHist[h] > peakCount) { peakCount = hourHist[h]; peak = h; }
        if (hourHist.All(c => c == 0)) peak = -1;

        return new Stats
        {
            UpdatedAt = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            Days = days,
            Models = models,
            Projects = projects,
            Summary = new StatsSummary
            {
                TotalTokens = grand,
                TotalCost = null,   // set by EnrichCostAsync when ccusage is present
                ActiveDays = days.Count(d => d.Tokens > 0),
                FavoriteModel = models.FirstOrDefault()?.Model,
                Sessions = sessions,
                Messages = messages,
                PeakHour = peak,
            },
        };
    }

    // ---- 2b. chats.json / sessions.json via node extractors (optional) -----
    //
    // Windows QuotaService es C# puro y NO sabe leer el IndexedDB del app de
    // escritorio ni listar sesiones tan cómodamente como los scripts empaquetados.
    // La vía consistente con mac/linux: si `node` está en el PATH, corre los
    // extractores empaquetados junto al exe (<AppDir>\bin\*.js) y escribe la salida
    // en el cache. Fail-open: sin node / sin el script / si truena → no se genera
    // el archivo (la pestaña Chats / el dropdown de sesiones quedan vacíos).

    /// <summary>Corre los extractores de node (si están) y refresca las listas en memoria.</summary>
    private async Task RunExtractorsAsync()
    {
        if (!OnPath("node")) return;   // sin node no hay chats/sessions (igual que mac/linux sin node)

        await RunExtractorAsync("chats-extract.js", ChatsFile);
        await RunExtractorAsync("sessions-extract.js", SessionsFile);

        // Cargar lo recién escrito a memoria (ShotMode no llama Reload tras el fetch).
        try
        {
            if (File.Exists(ChatsFile) &&
                JsonSerializer.Deserialize<List<Chat>>(File.ReadAllText(ChatsFile)) is { } c)
                Chats = c;
        }
        catch { }
        try
        {
            if (File.Exists(SessionsFile) &&
                JsonSerializer.Deserialize<List<Session>>(File.ReadAllText(SessionsFile)) is { } s)
                Sessions = s;
        }
        catch { }
    }

    /// <summary>Corre `node &lt;AppDir&gt;\bin\&lt;script&gt;`; si su stdout es un array JSON, lo escribe
    /// atómico en <paramref name="outFile"/>. No toca el archivo si falla o no es un array.</summary>
    private static async Task RunExtractorAsync(string script, string outFile)
    {
        try
        {
            string path = Path.Combine(AppContext.BaseDirectory, "bin", script);
            if (!File.Exists(path)) return;
            string? outp = await RunAsync("node", $"\"{path}\"");
            if (string.IsNullOrWhiteSpace(outp)) return;
            using var doc = JsonDocument.Parse(outp);      // valida que sea JSON…
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return;   // …y un array
            WriteAtomic(outFile, outp);
        }
        catch { /* fail-open: deja el archivo previo (o ninguno) */ }
    }

    // ---- 2c. (Feature B) mover una sesión a otro proyecto/slug ---------------
    //
    // La foundation ya sabe reubicar el transcript: `node <AppDir>\bin\session-move.js
    // <id> --to-cwd <cwdDestino>` imprime en stdout `{"ok":true,...}` (exit 0) o
    // `{"ok":false,"error":...}` (exit 1). Reusamos el mismo patrón que RunExtractorAsync
    // (node + <AppDir>\bin), pero capturamos stdout AUNQUE el exit sea ≠0 para poder
    // mostrar el `error` de la foundation. Tras un ok, quien llama debe refrescar.

    /// <summary>Resultado de MoveSessionAsync: éxito, o el mensaje de error a mostrar.</summary>
    public sealed record MoveResult(bool Ok, string? Error);

    /// <summary>Mueve la sesión <paramref name="id"/> al cwd destino corriendo session-move.js.
    /// Devuelve ok/error parseado del JSON que imprime la foundation.</summary>
    public async Task<MoveResult> MoveSessionAsync(string id, string toCwd)
    {
        if (string.IsNullOrWhiteSpace(id)) return new MoveResult(false, "sesión inválida");
        if (string.IsNullOrWhiteSpace(toCwd)) return new MoveResult(false, "destino inválido");
        if (!OnPath("node")) return new MoveResult(false, "node no está en el PATH (necesario para mover)");

        string script = Path.Combine(AppContext.BaseDirectory, "bin", "session-move.js");
        if (!File.Exists(script)) return new MoveResult(false, "falta bin\\session-move.js junto al app");

        string outp;
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "node",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add(script);
            psi.ArgumentList.Add(id);
            psi.ArgumentList.Add("--to-cwd");
            psi.ArgumentList.Add(toCwd);
            using var proc = Process.Start(psi);
            if (proc == null) return new MoveResult(false, "no se pudo ejecutar node");
            outp = await proc.StandardOutput.ReadToEndAsync();   // JSON tanto en ok como en error
            await proc.WaitForExitAsync();
        }
        catch (Exception ex) { return new MoveResult(false, ex.Message); }

        try
        {
            using var doc = JsonDocument.Parse(outp);
            var root = doc.RootElement;
            bool ok = root.TryGetProperty("ok", out var okEl) && okEl.ValueKind == JsonValueKind.True;
            if (ok) return new MoveResult(true, null);
            string? err = root.TryGetProperty("error", out var eEl) && eEl.ValueKind == JsonValueKind.String
                ? eEl.GetString() : null;
            return new MoveResult(false, err ?? "no se pudo mover la sesión");
        }
        catch { return new MoveResult(false, "respuesta inesperada de session-move.js"); }
    }

    /// <summary>Regenera la lista de sesiones YA: corre SOLO `sessions-extract.js` (rápido, sin red),
    /// reescribe sessions.json y publica el resultado en <see cref="Sessions"/>. Úsalo tras mover o
    /// renombrar una sesión para que la lista refleje el cambio AL INSTANTE, sin esperar al fetch
    /// completo (lento, con red, y que solo regenera sessions.json de pasada → por eso mover/renombrar
    /// no se reflejaba). El fetch periódico reconcilia stats/tokens después. Fail-safe: si no hay JSON
    /// parseable (sin node / sin el helper / error), deja la lista anterior intacta.</summary>
    public async Task RefreshSessionsAsync()
    {
        if (!OnPath("node")) return;   // sin node no se puede regenerar (igual que el fetch)
        await RunExtractorAsync("sessions-extract.js", SessionsFile);
        try
        {
            if (File.Exists(SessionsFile) &&
                JsonSerializer.Deserialize<List<Session>>(File.ReadAllText(SessionsFile)) is { } s)
                Sessions = s;
        }
        catch { /* fail-safe: deja la lista anterior */ }
    }

    // ---- 2d. (Feature A) sugerir un nombre para la sesión vía `claude -p` -----
    //
    // Barato: manda SOLO el contexto (summary) y pide un nombre corto. Fail-open:
    // sin CLI `claude` o si truena → null (el diálogo lo reporta sin romperse).

    /// <summary>Corre `claude -p` con el contexto de la sesión y devuelve un nombre corto
    /// (3-6 palabras, español, sin comillas) o null si no hay CLI / falla.</summary>
    public static async Task<string?> SuggestSessionNameAsync(string? summary)
    {
        if (string.IsNullOrWhiteSpace(summary)) return null;
        if (!OnPath("claude")) return null;

        string prompt =
            "A partir del siguiente contexto de una sesión de trabajo, propón un nombre corto de 3 a 6 " +
            "palabras en español, sin comillas ni puntuación final. Devuelve SOLO el nombre.\n\n" +
            "Contexto:\n" + summary;

        string? outp = await RunClaudeAsync(prompt);
        if (string.IsNullOrWhiteSpace(outp)) return null;

        // Primera línea no vacía, sin comillas envolventes.
        string name = outp.Trim()
            .Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? "";
        name = name.Trim('"', '\'', '“', '”', '`').Trim();
        return name.Length == 0 ? null : name;
    }

    /// <summary>`claude -p "&lt;prompt&gt;"` capturando stdout. ArgumentList (no string) para no depender
    /// del quoting del shell — el prompt trae saltos de línea y posibles comillas.</summary>
    private static async Task<string?> RunClaudeAsync(string prompt)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "claude",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-p");
            // --no-session-persistence: `claude -p` ES una sesión de Claude Code y por defecto la
            // guarda en disco (cwd=/ al lanzarla desde la GUI → aparecía un proyecto fantasma "/" que
            // consumía cuota). Con esta bandera la sugerencia NO deja rastro. (Solo aplica con --print.)
            psi.ArgumentList.Add("--no-session-persistence");
            psi.ArgumentList.Add(prompt);
            using var proc = Process.Start(psi);
            if (proc == null) return null;
            string stdout = await proc.StandardOutput.ReadToEndAsync();
            await proc.WaitForExitAsync();
            return proc.ExitCode == 0 ? stdout : null;
        }
        catch { return null; }
    }

    // ---- 3. ccusage cost enrichment (optional) -----------------------------

    /// <summary>
    /// If Node/ccusage is available, layer API-equivalent $ onto the stats
    /// (total, per-model, and the 5h/weekly bucket costs). No-op otherwise —
    /// tokens/percentages already come from the sources above.
    /// </summary>
    private static async Task EnrichCostAsync(Stats stats)
    {
        string? ccusage = ResolveCcusage();
        if (ccusage == null) return;

        // daily --breakdown → per-model cost + total
        var daily = await RunCcusageJsonAsync(ccusage, "daily --json --breakdown");
        if (daily is JsonElement dj && dj.TryGetProperty("daily", out var dEl) &&
            dEl.ValueKind == JsonValueKind.Array)
        {
            var costByModel = new Dictionary<string, double>();
            double total = 0;
            foreach (var day in dEl.EnumerateArray())
            {
                if (day.TryGetProperty("modelBreakdowns", out var mbs) &&
                    mbs.ValueKind == JsonValueKind.Array)
                {
                    foreach (var mb in mbs.EnumerateArray())
                    {
                        string name = mb.TryGetProperty("modelName", out var n) &&
                                      n.ValueKind == JsonValueKind.String ? n.GetString()! : "unknown";
                        double c = NumProp(mb, "cost");
                        costByModel[name] = costByModel.GetValueOrDefault(name) + c;
                        total += c;
                    }
                }
            }
            if (stats.Models != null)
                foreach (var m in stats.Models)
                    if (m.Model != null && costByModel.TryGetValue(m.Model, out var c))
                        m.Cost = Math.Round(c, 2);
            if (stats.Summary != null && total > 0)
                stats.Summary.TotalCost = Math.Round(total, 2);
        }

        // active block → 5-hour cost
        var blocks = await RunCcusageJsonAsync(ccusage, "blocks --json --active");
        if (blocks is JsonElement bj && bj.TryGetProperty("blocks", out var bEl) &&
            bEl.ValueKind == JsonValueKind.Array)
        {
            foreach (var b in bEl.EnumerateArray())
            {
                if (stats.Summary != null)
                    stats.Summary.FiveHourCost = Math.Round(NumProp(b, "costUSD"), 2);
                break; // active block is first
            }
        }

        // weekly → current-week cost
        var weekly = await RunCcusageJsonAsync(ccusage, "weekly --json");
        if (weekly is JsonElement wj && wj.TryGetProperty("weekly", out var wEl) &&
            wEl.ValueKind == JsonValueKind.Array && stats.Summary != null)
        {
            var last = wEl.EnumerateArray().LastOrDefault();
            if (last.ValueKind == JsonValueKind.Object)
                stats.Summary.WeeklyCost = Math.Round(NumProp(last, "totalCost"), 2);
        }
    }

    /// Prefer a `ccusage` on PATH; else `npx -y ccusage@latest`; else none.
    private static string? ResolveCcusage()
    {
        if (OnPath("ccusage")) return "ccusage";
        if (OnPath("npx")) return "npx";
        return null;
    }

    private static bool OnPath(string exe)
    {
        var paths = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator);
        string[] exts = { ".cmd", ".exe", ".bat", "" };
        foreach (var dir in paths)
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            foreach (var ext in exts)
                try { if (File.Exists(Path.Combine(dir, exe + ext))) return true; } catch { }
        }
        return false;
    }

    private static async Task<JsonElement?> RunCcusageJsonAsync(string ccusage, string args)
    {
        string fullArgs = ccusage == "npx" ? $"-y ccusage@latest {args}" : args;
        string exe = ccusage == "npx" ? "npx" : "ccusage";
        // Live pricing first; retry --offline (the bundled table lags new models).
        var outp = await RunAsync(exe, fullArgs) ?? await RunAsync(exe, fullArgs + " --offline");
        if (string.IsNullOrWhiteSpace(outp)) return null;
        try
        {
            using var doc = JsonDocument.Parse(outp);
            return doc.RootElement.Clone();
        }
        catch { return null; }
    }

    private static async Task<string?> RunAsync(string exe, string args)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = args,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var proc = Process.Start(psi);
            if (proc == null) return null;
            string stdout = await proc.StandardOutput.ReadToEndAsync();
            await proc.WaitForExitAsync();
            return proc.ExitCode == 0 ? stdout : null;
        }
        catch { return null; }
    }

    private static void WriteAtomic(string path, string content)
    {
        string tmp = path + ".tmp";
        File.WriteAllText(tmp, content);
        File.Move(tmp, path, overwrite: true);
    }
}
