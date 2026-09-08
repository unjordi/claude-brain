using System.Diagnostics;
using System.Globalization;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace Cortex;

/// <summary>
/// Autoactualización LIGERA del widget, estilo winturbo — puerto Windows de macos/Updater.swift.
/// La app trae embebido (version.json, escrito por install.ps1 junto al exe) el SHA + fecha del
/// commit con que se buildeó y la ruta de su clon. Al abrir la pestaña Cerebro chequea GitHub.
///
/// DOS rutas de update (fail-open en ambas). AMBAS dejan la máquina ONE-STOP (widget + hooks del
/// cerebro), igual que el botón de Mac/Linux — sin asimetría entre OS:
///  1) DESCARGA (preferida, fase 2): consulta el release rolling 'windows-latest'; si trae el asset
///     Cortex.exe con un build-sha distinto al embebido, BAJA el exe y hace swap (SIN .NET SDK),
///     refresca brain/ (si hay clon) y RE-CABLEA los hooks con el install-brain.ps1 empaquetado.
///  2) GIT (fallback pre-release): si no hay release aún, compara `commits/main` y —solo con clon—
///     hace `git fetch` + `checkout -B main origin/main` (fuerza-alinea, mismo patrón que
///     bootstrap.ps1) + `install.ps1` (que ya instala cerebro + widget).
/// FAIL-OPEN: sin red / sin version.json / sin release ni clon → no molesta.
///
/// Enfoque de AUTO-REEMPLAZO en Windows: el exe es self-contained single-file y, si estuviera
/// corriendo, `install.ps1` no podría sobreescribirlo (lock). Por eso NO nos auto-cerramos a
/// ciegas: escribimos un pequeño .ps1 temporal, lo lanzamos DETACHADO (UseShellExecute, ventana
/// oculta) y ese script hace el fetch+align y — solo si tuvo éxito — corre `install.ps1`, que ES
/// quien detiene la instancia vieja (soltando el lock), reconstruye, recopia el exe y relanza.
/// `checkout -B main origin/main` FUERZA-ALINEA el clon a origin/main (descarta cualquier rama
/// leftover o commit local — este clon es infraestructura, no un checkout de dev); antes,
/// `merge --ff-only` fallaba PARA SIEMPRE si el clon quedaba en una rama leftover o con commits
/// locales. Si el fetch/checkout fallan (p. ej. sin red) el script no toca nada: la app sigue viva
/// → nunca te quedas sin widget. El script vive en un proceso aparte (pwsh/powershell), así que
/// sobrevive a que `install.ps1` mate al widget.
/// </summary>
internal sealed class Updater
{
    public static readonly Updater Shared = new();

    // Estado leído/escrito en el hilo de UI (la comprobación de red marshalea de vuelta vía el
    // callback de CheckIfStale). Simples lecturas para el paint del banner.
    public bool UpdateAvailable { get; private set; }
    public bool Updating { get; set; }
    public string LocalShort { get; private set; } = "?";
    public string RemoteShort { get; private set; } = "?";
    /// Versión legible MAJOR.MINOR.<count> embebida por install.ps1 (campo `version` de version.json).
    /// null en builds viejos sin el campo (fail-open) → la UI simplemente no la muestra.
    public string? LocalVersion { get; private set; }
    /// Fecha del commit con que se buildeó (campo `date` de version.json), UTC. null si falta.
    public DateTime? BuiltAt => _localDate;
    public string? Message { get; set; }
    /// true si hay clon en disco (podemos auto-actualizar); si no, el banner invita a hacerlo a mano.
    public bool CanSelfUpdate { get; private set; }

    /// El escape REAL para una máquina que no puede auto-actualizar (espeja Updater.swift/main.qml):
    /// migra el clon al nombre canónico, alinea a origin/main y reinstala. Ni install.ps1 a secas ni
    /// un git pull manual migran `claude-brain-repo`→`cortex-repo` — SOLO bootstrap.ps1 lo hace.
    private const string BootstrapOneLiner =
        "irm https://raw.githubusercontent.com/unjordi/cortex/main/bootstrap.ps1 | iex";

    /// Ruta de un clon que SÍ vemos en disco (aunque no sirva para auto-actualizar, p.ej. sin
    /// windows\install.ps1), para mostrarla en el mensaje "a mano". null si no hay ninguno visible.
    public string? DiscoveredClonePath { get; private set; }

    /// Mensaje "a mano" HONESTO: el one-liner real de bootstrap + la ruta descubierta cuando la hay.
    public string ManualUpdateHint
    {
        get
        {
            string where_ = string.IsNullOrEmpty(DiscoveredClonePath) ? "" : $" (tu clon: {DiscoveredClonePath})";
            return $"No puedo auto-actualizar{where_}. Corre en PowerShell: {BootstrapOneLiner}";
        }
    }

    private string _repoPath = "";
    private DateTime? _localDate;      // UTC
    private DateTime? _lastCheck;      // UTC
    private bool _loaded;
    private const string Slug = "unjordi/cortex";

    // Ruta de DESCARGA (fase 2): URL del asset Cortex.exe en el release rolling 'windows-latest'
    // + su build-sha. Si está presente, actualizamos bajando el exe (SIN clon ni .NET SDK).
    private string? _assetUrl;
    private string _remoteFullSha = "";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(6) };

    /// Lee version.json (escrito por install.ps1 junto al exe) una sola vez. Fail-open: cualquier
    /// problema → LocalShort se queda en "?" y el chequeo no molesta.
    private void LoadLocal()
    {
        if (_loaded) return;
        _loaded = true;
        try
        {
            string path = Path.Combine(AppContext.BaseDirectory, "version.json");
            if (!File.Exists(path)) return;
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var root = doc.RootElement;
            LocalShort = root.TryGetProperty("sha", out var sha) ? sha.GetString() ?? "?" : "?";
            LocalVersion = root.TryGetProperty("version", out var ver) ? ver.GetString() : null;
            string embedded = root.TryGetProperty("repo", out var repo) ? repo.GetString() ?? "" : "";
            // La ruta EMBEBIDA (version.json.repo) es la del BUILD; en un exe precompilado en CI es la
            // del runner, que NO existe en la maquina del usuario. Resolvemos el clon LOCAL con la misma
            // cadena de fallback que macos/Updater.swift (resolveClonePath). Sin esto, un exe de release
            // dejaba CanSelfUpdate=false y el fallback git-based no arrancaba.
            _repoPath = ResolveClonePath(embedded);
            DiscoveredClonePath = DiscoverClonePathForDisplay();
            if (root.TryGetProperty("date", out var d)
                && DateTimeOffset.TryParse(d.GetString(), CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out var dt))
                _localDate = dt.UtcDateTime;
            // Podemos auto-actualizar (git-based) si resolvimos un clon con el reinstalador de Windows.
            CanSelfUpdate = _repoPath.Length > 0;
        }
        catch { /* fail-open */ }
    }

    /// Clon local para auto-actualizar (git-based). Espeja resolveClonePath de macos/Updater.swift:
    /// prefiere el EMBEBIDO si existe aqui (build local), luego $CLAUDE_BRAIN_DIR, luego el clon oculto
    /// que siembra bootstrap.ps1 (%LOCALAPPDATA%\cortex-repo). Devuelve "" si ninguno trae
    /// windows\install.ps1 -> sin auto-update git-based (el banner invita a hacerlo a mano; la ruta de
    /// DESCARGA del release no necesita clon). CLAUDE_BRAIN_DIR puede venir en forward-slash (asi lo
    /// exporta bootstrap.ps1 para bash) — Path.Combine/File.Exists lo manejan igual en Windows.
    private static string ResolveClonePath(string embedded)
    {
        string env = Environment.GetEnvironmentVariable("CLAUDE_BRAIN_DIR") ?? "";
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string localRepo = local.Length > 0 ? Path.Combine(local, "cortex-repo") : "";
        // FALLBACK pre-rename: mid-migración claude-brain→cortex el clon puede seguir con el nombre viejo.
        string localRepoOld = local.Length > 0 ? Path.Combine(local, "claude-brain-repo") : "";
        foreach (var c in new[] { embedded, env, localRepo, localRepoOld })
            if (c.Length > 0 && File.Exists(Path.Combine(c, "windows", "install.ps1")))
                return c;
        return "";
    }

    /// Para el mensaje "a mano": ¿hay ALGÚN clon visible en disco, aunque no sirva para auto-actualizar?
    /// Nombre viejo primero (es la señal de "te quedaste en el rename"), luego el canónico. Mismo orden
    /// que resolveClonePath/resolveRepoPath en macOS/Linux.
    private static string? DiscoverClonePathForDisplay()
    {
        string env = Environment.GetEnvironmentVariable("CLAUDE_BRAIN_DIR") ?? "";
        if (env.Length > 0 && Directory.Exists(env)) return env;
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (local.Length == 0) return null;
        string oldRepo = Path.Combine(local, "claude-brain-repo");
        if (Directory.Exists(oldRepo)) return oldRepo;
        string newRepo = Path.Combine(local, "cortex-repo");
        if (Directory.Exists(newRepo)) return newRepo;
        return null;
    }

    /// Chequea GitHub como mucho 1×/15 min (evita el rate-limit anónimo). Fire-and-forget desde la
    /// vista: corre la red en un Task y, si el estado cambió, invoca `onResult` (fuera del hilo de
    /// UI) para que el llamador re-pinte el popup por su cuenta.
    public void CheckIfStale(Action onResult)
    {
        LoadLocal();
        if (LocalShort == "?") return;   // sin version.json (build viejo) → no molesta
        if (_lastCheck is DateTime lc && (DateTime.UtcNow - lc).TotalSeconds < 900) return;
        _lastCheck = DateTime.UtcNow;
        _ = Task.Run(async () =>
        {
            bool before = UpdateAvailable;
            await CheckAsync();
            if (UpdateAvailable != before) { try { onResult(); } catch { } }
        });
    }

    /// Fuerza el chequeo de versión SALTANDO el throttle de 15 min. Lo dispara el botón ↻ (refrescar
    /// cuota debe además re-chequear versión al instante). Resetea `_lastCheck` y reusa CheckIfStale,
    /// que corre CheckAsync en un Task y llama `onResult` si UpdateAvailable cambió (para que el botón
    /// ⬆/banner aparezcan). Espeja `forceCheck()` de macos/Updater.swift.
    public void ForceCheck(Action onResult)
    {
        _lastCheck = null;
        CheckIfStale(onResult);
    }

    private async Task CheckAsync()
    {
        // Ruta preferida: el release 'windows-latest' (descarga del exe, SIN .NET SDK ni clon). Si
        // aún no existe el release (404) o falla, cae al chequeo git-based (commits/main + rebuild).
        try
        {
            using var ctsR = new CancellationTokenSource(TimeSpan.FromSeconds(6));
            if (await CheckReleaseAsync(ctsR.Token)) return;
        }
        catch { /* fail-open → intenta la ruta git-based abajo */ }

        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get,
                $"https://api.github.com/repos/{Slug}/commits/main");
            req.Headers.UserAgent.ParseAdd("cortex");   // GitHub lo exige
            req.Headers.Accept.ParseAdd("application/vnd.github+json");
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(6));
            using var resp = await Http.SendAsync(req, cts.Token);
            if (!resp.IsSuccessStatusCode) return;                    // fail-open
            var body = await resp.Content.ReadAsStringAsync(cts.Token);
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            if (!root.TryGetProperty("sha", out var shaEl)) return;
            string fullSha = shaEl.GetString() ?? "";
            if (fullSha.Length == 0) return;

            DateTime? rDate = null;
            if (root.TryGetProperty("commit", out var commit)
                && commit.TryGetProperty("committer", out var committer)
                && committer.TryGetProperty("date", out var dateEl)
                && DateTimeOffset.TryParse(dateEl.GetString(), CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out var parsed))
                rDate = parsed.UtcDateTime;

            // Novedad = commit distinto Y (si tenemos fechas) más reciente que el buildeado.
            bool differs = !fullSha.StartsWith(LocalShort, StringComparison.OrdinalIgnoreCase);
            bool newer = (_localDate == null || rDate == null)
                ? true
                : rDate > _localDate.Value.AddSeconds(2);
            RemoteShort = fullSha.Length >= 7 ? fullSha[..7] : fullSha;
            UpdateAvailable = differs && newer;
        }
        catch { /* fail-open: sin red / json raro / timeout → no molesta */ }
    }

    /// Consulta el release rolling 'windows-latest': si trae el asset Cortex.exe y un
    /// 'build-sha:' distinto al embebido, prepara la DESCARGA (no requiere clon ni SDK). Devuelve
    /// true si MANEJÓ el chequeo (haya o no update); false si no hay release/asset/sha comparable →
    /// el llamador cae a la ruta git-based. Fail-open vía el catch del llamador.
    private async Task<bool> CheckReleaseAsync(CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get,
            $"https://api.github.com/repos/{Slug}/releases/tags/windows-latest");
        req.Headers.UserAgent.ParseAdd("cortex");
        req.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var resp = await Http.SendAsync(req, ct);
        if (!resp.IsSuccessStatusCode) return false;   // sin release aún (404) → fallback git-based
        var body = await resp.Content.ReadAsStringAsync(ct);
        using var doc = JsonDocument.Parse(body);
        var root = doc.RootElement;

        // build-sha del cuerpo del release (lo escribe release-windows.yml).
        string full = "";
        if (root.TryGetProperty("body", out var bodyEl) && bodyEl.GetString() is string b)
        {
            var m = System.Text.RegularExpressions.Regex.Match(b, "build-sha:\\s*([0-9a-fA-F]{7,40})");
            if (m.Success) full = m.Groups[1].Value;
        }
        if (full.Length == 0) return false;            // sin sha comparable → fallback

        // asset Cortex.exe
        string? url = null;
        if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
            foreach (var a in assets.EnumerateArray())
                if (a.TryGetProperty("name", out var n) && n.GetString() == "Cortex.exe"
                    && a.TryGetProperty("browser_download_url", out var u) && u.GetString() is string dl)
                { url = dl; break; }
        if (url == null) return false;                 // release sin exe → fallback

        _assetUrl = url;
        _remoteFullSha = full;
        RemoteShort = full.Length >= 7 ? full[..7] : full;
        CanSelfUpdate = true;                          // la descarga no necesita clon
        UpdateAvailable = !full.StartsWith(LocalShort, StringComparison.OrdinalIgnoreCase);
        return true;
    }

    /// Lanza el update DETACHADO. Espeja `runUpdate` del Swift: solo reinstala si el fast-forward a
    /// origin/main tiene éxito; si aborta, NO toca nada (la app sigue viva). Devuelve true si logró
    /// LANZAR el script (no garantiza que el update complete — eso lo resuelve el propio script:
    /// en éxito mata esta app y abre la nueva; en fallo, el llamador resetea el estado por timeout).
    public bool TryLaunchUpdate()
    {
        // Ruta de DESCARGA (release): no necesita clon ni .NET SDK. Preferida cuando hay asset.
        if (_assetUrl != null) return TryLaunchDownloadUpdate();

        // Ruta git-based (fallback pre-release): requiere clon con el reinstalador de Windows.
        if (!CanSelfUpdate || _repoPath.Length == 0)
        {
            Message = ManualUpdateHint;
            return false;
        }

        // Script temporal: MIGRA el clon (rename claude-brain-repo→cortex-repo) si aplica, luego
        // fuerza-alinea a origin/main (mismo patrón que bootstrap.ps1: `checkout -B main origin/main`,
        // en vez de `merge --ff-only`, que fallaba PARA SIEMPRE si el clon quedaba en una rama leftover
        // o con commits locales) y, SOLO si tuvo éxito, corre install.ps1 (detiene la instancia vieja
        // soltando el lock del exe, reconstruye y relanza). Si el fetch/checkout fallan, sale sin tocar
        // nada. Corre en su propio proceso pwsh/powershell → sobrevive a que install.ps1 mate al widget.
        // install.ps1 se resuelve del $repo YA migrado (no del _repoPath viejo), para que apunte al
        // nombre canónico tras el rename.
        string script =
            "$ErrorActionPreference = 'SilentlyContinue'\n" +
            $"$repo = '{_repoPath.Replace("'", "''")}'\n" +
            "$canon = Join-Path $env:LOCALAPPDATA 'cortex-repo'\n" +
            "if ($repo -ne $canon -and (Test-Path $repo) -and -not (Test-Path $canon)) { Move-Item -LiteralPath $repo -Destination $canon; if (Test-Path $canon) { $repo = $canon } }\n" +
            "Start-Sleep -Seconds 1\n" +
            "git -C $repo fetch origin\n" +
            "if ($LASTEXITCODE -ne 0) { exit 1 }\n" +
            "git -C $repo checkout -B main origin/main\n" +
            "if ($LASTEXITCODE -ne 0) { exit 1 }   # falló el align (p. ej. conflicto con cambios locales) → NO relanzar, app intacta\n" +
            "& (Join-Path $repo 'windows\\install.ps1')\n";

        return LaunchDetached(script, "cortex-update.ps1");
    }

    /// Fase 2: descarga el exe del release y hace SWAP. No necesita clon ni .NET SDK. Fail-open
    /// DURO: el script solo detiene/reemplaza el widget SI la descarga fue válida; ante cualquier
    /// fallo de descarga, la app queda intacta (peor caso = no auto-actualiza, nunca un brick).
    private bool TryLaunchDownloadUpdate()
    {
        string? exe = Environment.ProcessPath;   // el exe instalado que corre ahora
        if (string.IsNullOrEmpty(exe))
        {
            Message = "no pude ubicar el exe para reemplazar";
            return false;
        }
        string shortSha = _remoteFullSha.Length >= 7 ? _remoteFullSha[..7] : _remoteFullSha;

        // Detachado: baja el exe a TEMP; SOLO si es válido (existe y pesa MBs) detiene el widget
        // (suelta el lock del single-file), reemplaza el exe, reescribe version.json, refresca brain/
        // (si hay clon), RE-CABLEA los hooks del cerebro (install-brain empaquetado, one-stop) y
        // relanza. Si la descarga falla → exit sin tocar nada.
        var sb = new StringBuilder();
        sb.Append("$ErrorActionPreference='SilentlyContinue'\n");
        sb.Append($"$url='{_assetUrl!.Replace("'", "''")}'\n");
        sb.Append($"$exe='{exe.Replace("'", "''")}'\n");
        sb.Append($"$repo='{_repoPath.Replace("'", "''")}'\n");
        sb.Append($"$sha='{shortSha.Replace("'", "''")}'\n");
        sb.Append("$dir=Split-Path $exe\n");
        sb.Append("$tmp=Join-Path $env:TEMP 'Cortex.new.exe'\n");
        sb.Append("Start-Sleep -Seconds 1\n");
        sb.Append("try { Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing } catch { exit 1 }\n");
        sb.Append("if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 1000000) { exit 1 }\n");
        sb.Append("Get-Process Cortex -ErrorAction SilentlyContinue | Stop-Process -Force\n");
        sb.Append("Start-Sleep -Milliseconds 900\n");
        sb.Append("Copy-Item $tmp $exe -Force\n");
        sb.Append("if (-not $?) { Start-Process $exe; exit 1 }\n");   // copy falló → relanzo la vieja
        sb.Append("$vj = @{ sha=$sha; date=''; repo=$repo; branch='main' } | ConvertTo-Json -Compress\n");
        sb.Append("Set-Content -Path (Join-Path $dir 'version.json') -Value $vj -Encoding utf8\n");
        sb.Append("if ($repo -and (Test-Path (Join-Path $repo '.git'))) {\n");
        // Best-effort: fuerza-alinea el clon a origin/main (mismo patrón que bootstrap.ps1) en vez de
        // `merge --ff-only`, que se quedaba fallando para siempre si el clon tenía una rama leftover o
        // commits locales — este refresco es no-gating (SilentlyContinue), pero un align que sí converge
        // deja el clon útil para el próximo ciclo en vez de repetir el mismo fallo indefinidamente.
        sb.Append("  git -C $repo fetch origin; git -C $repo checkout -B main origin/main\n");
        sb.Append("  $bsrc = Join-Path $repo 'brain'\n");
        sb.Append("  if (Test-Path $bsrc) { Copy-Item $bsrc (Join-Path $dir 'brain') -Recurse -Force }\n");
        sb.Append("}\n");
        // ONE-STOP (paridad con install.sh de Mac/Linux y con la ruta git de Windows): re-cablea los
        // HOOKS del cerebro corriendo el install-brain.ps1 EMPAQUETADO junto al exe (mismo que el
        // botón-curita). Idempotente, sin clon ni .NET SDK (solo Git Bash). Sin esto, la ruta de
        // descarga solo cambiaba el exe y dejaba los hooks viejos → asimetría vs los otros botones.
        sb.Append("$bi = Join-Path $dir 'brain\\install-brain.ps1'\n");
        sb.Append("if (Test-Path $bi) { try { & $bi } catch {} }\n");
        // (Re)crea el acceso directo del menu Inicio, para que un install viejo (sin .lnk) lo gane al
        // autoactualizar y para refrescar el icono/target. Best-effort. Espeja install.ps1.
        sb.Append("$sm=[Environment]::GetFolderPath('Programs')\n");
        sb.Append("Remove-Item (Join-Path $sm 'Claude Quota.lnk') -Force -EA SilentlyContinue\n");   // limpia el shortcut legacy (pre-rebrand)
        sb.Append("try { $ws=New-Object -ComObject WScript.Shell; $lk=$ws.CreateShortcut((Join-Path $sm 'Cortex.lnk')); $lk.TargetPath=$exe; $lk.WorkingDirectory=$dir; $lk.IconLocation=$exe; $lk.Description='Cortex Widget'; $lk.Save() } catch {}\n");
        sb.Append("Remove-Item $tmp -Force\n");
        sb.Append("Start-Process $exe\n");
        return LaunchDetached(sb.ToString(), "cortex-update-dl.ps1");
    }

    /// Escribe el script a un .ps1 temporal y lo lanza DETACHADO (UseShellExecute + ventana oculta),
    /// para que sobreviva a que el update cierre esta app. pwsh primero, powershell de respaldo.
    private bool LaunchDetached(string script, string tmpName)
    {
        string tmp = Path.Combine(Path.GetTempPath(), tmpName);
        try { File.WriteAllText(tmp, script, new UTF8Encoding(false)); }
        catch { Message = "no pude escribir el script de update"; return false; }

        foreach (var shell in new[] { "pwsh", "powershell" })
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = shell,
                    UseShellExecute = true,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                };
                psi.ArgumentList.Add("-NoProfile");
                psi.ArgumentList.Add("-ExecutionPolicy");
                psi.ArgumentList.Add("Bypass");
                psi.ArgumentList.Add("-File");
                psi.ArgumentList.Add(tmp);
                var p = Process.Start(psi);
                if (p != null) return true;
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // Este PowerShell no está en el PATH → probar el siguiente.
            }
            catch { break; }
        }
        Message = "no encontré pwsh/powershell para lanzar el update";
        return false;
    }
}
