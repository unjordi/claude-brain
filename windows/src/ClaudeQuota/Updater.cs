using System.Diagnostics;
using System.Globalization;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace ClaudeQuota;

/// <summary>
/// Autoactualización LIGERA del widget, estilo winturbo — puerto Windows de macos/Updater.swift.
/// La app trae embebido (version.json, escrito por install.ps1 junto al exe) el SHA + fecha del
/// commit con que se buildeó y la ruta de su clon. Al abrir la pestaña Cerebro chequea GitHub.
///
/// DOS rutas de update (fail-open en ambas):
///  1) DESCARGA (preferida, fase 2): consulta el release rolling 'windows-latest'; si trae el asset
///     ClaudeQuota.exe con un build-sha distinto al embebido, BAJA el exe y hace swap — SIN clon ni
///     .NET SDK. La publica release-windows.yml al hacer release a main.
///  2) GIT (fallback pre-release): si no hay release aún, compara `commits/main` y —solo con clon—
///     hace `git fetch` + `merge --ff-only` + `install.ps1` (recompila).
/// FAIL-OPEN: sin red / sin version.json / sin release ni clon → no molesta.
///
/// Enfoque de AUTO-REEMPLAZO en Windows: el exe es self-contained single-file y, si estuviera
/// corriendo, `install.ps1` no podría sobreescribirlo (lock). Por eso NO nos auto-cerramos a
/// ciegas: escribimos un pequeño .ps1 temporal, lo lanzamos DETACHADO (UseShellExecute, ventana
/// oculta) y ese script hace el ff-merge y — solo si tuvo éxito — corre `install.ps1`, que ES
/// quien detiene la instancia vieja (soltando el lock), reconstruye, recopia el exe y relanza.
/// Si el ff aborta (árbol sucio / no-ff) el script no toca nada: la app sigue viva → nunca te
/// quedas sin widget. El script vive en un proceso aparte (pwsh/powershell), así que sobrevive a
/// que `install.ps1` mate al widget.
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
    public string? Message { get; set; }
    /// true si hay clon en disco (podemos auto-actualizar); si no, el banner invita a hacerlo a mano.
    public bool CanSelfUpdate { get; private set; }

    private string _repoPath = "";
    private DateTime? _localDate;      // UTC
    private DateTime? _lastCheck;      // UTC
    private bool _loaded;
    private const string Slug = "unjordi/claude-brain";

    // Ruta de DESCARGA (fase 2): URL del asset ClaudeQuota.exe en el release rolling 'windows-latest'
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
            _repoPath = root.TryGetProperty("repo", out var repo) ? repo.GetString() ?? "" : "";
            if (root.TryGetProperty("date", out var d)
                && DateTimeOffset.TryParse(d.GetString(), CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out var dt))
                _localDate = dt.UtcDateTime;
            // Podemos auto-actualizar si el clon existe y trae el reinstalador de Windows.
            CanSelfUpdate = _repoPath.Length > 0
                && File.Exists(Path.Combine(_repoPath, "windows", "install.ps1"));
        }
        catch { /* fail-open */ }
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
            req.Headers.UserAgent.ParseAdd("claude-quota-widget");   // GitHub lo exige
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

    /// Consulta el release rolling 'windows-latest': si trae el asset ClaudeQuota.exe y un
    /// 'build-sha:' distinto al embebido, prepara la DESCARGA (no requiere clon ni SDK). Devuelve
    /// true si MANEJÓ el chequeo (haya o no update); false si no hay release/asset/sha comparable →
    /// el llamador cae a la ruta git-based. Fail-open vía el catch del llamador.
    private async Task<bool> CheckReleaseAsync(CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get,
            $"https://api.github.com/repos/{Slug}/releases/tags/windows-latest");
        req.Headers.UserAgent.ParseAdd("claude-quota-widget");
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

        // asset ClaudeQuota.exe
        string? url = null;
        if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
            foreach (var a in assets.EnumerateArray())
                if (a.TryGetProperty("name", out var n) && n.GetString() == "ClaudeQuota.exe"
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
            Message = "actualiza a mano: git pull && pwsh -File windows\\install.ps1";
            return false;
        }

        string installPs1 = Path.Combine(_repoPath, "windows", "install.ps1");
        // Script temporal: ff-merge y, SOLO si tuvo éxito, correr install.ps1 (que detiene la
        // instancia vieja soltando el lock del exe, reconstruye y relanza). Si el ff aborta, sale
        // sin tocar nada. Corre en su propio proceso pwsh/powershell → sobrevive a que install.ps1
        // mate al widget.
        string script =
            "$ErrorActionPreference = 'SilentlyContinue'\n" +
            $"$repo = '{_repoPath.Replace("'", "''")}'\n" +
            "Start-Sleep -Seconds 1\n" +
            "git -C $repo fetch origin\n" +
            "if ($LASTEXITCODE -ne 0) { exit 1 }\n" +
            "git -C $repo merge --ff-only origin/main\n" +
            "if ($LASTEXITCODE -ne 0) { exit 1 }   # árbol sucio / no-ff → NO relanzar, app intacta\n" +
            $"& '{installPs1.Replace("'", "''")}'\n";

        return LaunchDetached(script, "claude-quota-update.ps1");
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
        // si hay clon (para el botón-curita) y relanza. Si la descarga falla → exit sin tocar nada.
        var sb = new StringBuilder();
        sb.Append("$ErrorActionPreference='SilentlyContinue'\n");
        sb.Append($"$url='{_assetUrl!.Replace("'", "''")}'\n");
        sb.Append($"$exe='{exe.Replace("'", "''")}'\n");
        sb.Append($"$repo='{_repoPath.Replace("'", "''")}'\n");
        sb.Append($"$sha='{shortSha.Replace("'", "''")}'\n");
        sb.Append("$dir=Split-Path $exe\n");
        sb.Append("$tmp=Join-Path $env:TEMP 'ClaudeQuota.new.exe'\n");
        sb.Append("Start-Sleep -Seconds 1\n");
        sb.Append("try { Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing } catch { exit 1 }\n");
        sb.Append("if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 1000000) { exit 1 }\n");
        sb.Append("Get-Process ClaudeQuota -ErrorAction SilentlyContinue | Stop-Process -Force\n");
        sb.Append("Start-Sleep -Milliseconds 900\n");
        sb.Append("Copy-Item $tmp $exe -Force\n");
        sb.Append("if (-not $?) { Start-Process $exe; exit 1 }\n");   // copy falló → relanzo la vieja
        sb.Append("$vj = @{ sha=$sha; date=''; repo=$repo; branch='main' } | ConvertTo-Json -Compress\n");
        sb.Append("Set-Content -Path (Join-Path $dir 'version.json') -Value $vj -Encoding utf8\n");
        sb.Append("if ($repo -and (Test-Path (Join-Path $repo '.git'))) {\n");
        sb.Append("  git -C $repo fetch origin; git -C $repo merge --ff-only origin/main\n");
        sb.Append("  $bsrc = Join-Path $repo 'brain'\n");
        sb.Append("  if (Test-Path $bsrc) { Copy-Item $bsrc (Join-Path $dir 'brain') -Recurse -Force }\n");
        sb.Append("}\n");
        sb.Append("Remove-Item $tmp -Force\n");
        sb.Append("Start-Process $exe\n");
        return LaunchDetached(sb.ToString(), "claude-quota-update-dl.ps1");
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
