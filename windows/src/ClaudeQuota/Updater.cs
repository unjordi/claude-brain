using System.Diagnostics;
using System.Globalization;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace ClaudeQuota;

/// <summary>
/// Autoactualización LIGERA del widget, estilo winturbo — puerto Windows de macos/Updater.swift.
/// La app trae embebido (version.json, escrito por install.ps1 junto al exe) el SHA + fecha del
/// commit con que se buildeó y la ruta de su clon. Al abrir la pestaña Cerebro consulta
/// `commits/main` de GitHub; si el repo avanzó, ofrece un banner que hace `git fetch` +
/// `merge --ff-only` + `install.ps1` y relanza. FAIL-OPEN: sin red / sin version.json / sin
/// clon → no molesta.
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

    /// Lanza el update DETACHADO. Espeja `runUpdate` del Swift: solo reinstala si el fast-forward a
    /// origin/main tiene éxito; si aborta, NO toca nada (la app sigue viva). Devuelve true si logró
    /// LANZAR el script (no garantiza que el update complete — eso lo resuelve el propio script:
    /// en éxito mata esta app y abre la nueva; en fallo, el llamador resetea el estado por timeout).
    public bool TryLaunchUpdate()
    {
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

        string tmp = Path.Combine(Path.GetTempPath(), "claude-quota-update.ps1");
        try { File.WriteAllText(tmp, script, new UTF8Encoding(false)); }
        catch { Message = "no pude escribir el script de update"; return false; }

        // Lanzar DETACHADO: UseShellExecute=true + ventana oculta → proceso independiente que
        // sobrevive a que install.ps1 cierre esta app. pwsh primero, powershell de respaldo.
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
