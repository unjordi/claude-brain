import AppKit
import SwiftUI

/// Autoactualización del widget, estilo winturbo: la app trae embebido el SHA/fecha del commit
/// con que se buildeó (version.json, escrito por make-app.sh). Al abrir la pestaña Cerebro consulta
/// `commits/main` de GitHub; si el repo avanzó, ofrece un botón que hace `git ff origin/main` +
/// `install.sh` COMPLETO (widget + cerebro, igual que Linux → sin asimetría) y relanza. El botón "🩹
/// Curar cerebro global" queda como el self-heal SIN git pull (reinstala el cerebro empaquetado en el
/// app). El clon a actualizar se RESUELVE localmente (ver resolveClonePath): la ruta embebida es la
/// del build —en un .app precompilado en CI, la del runner, que no existe en la Mac—, así que se
/// prefiere el clon de instalación local (~/.claude-brain). FAIL-OPEN: sin red / sin version.json /
/// sin clon local → no molesta (el botón invita a actualizar a mano).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published var updateAvailable = false
    @Published var updating = false
    @Published var localShort = "?"
    @Published var remoteShort = "?"
    @Published var message: String? = nil
    /// true si podemos auto-actualizar (hay clon en disco); si no, el botón invita a hacerlo a mano.
    @Published var canSelfUpdate = false

    private var repoPath = ""
    private var localDate: Date? = nil
    private var lastCheck: Date? = nil
    private static let slug = "unjordi/claude-brain"

    private func loadLocal() {
        guard repoPath.isEmpty,
              let url = Bundle.main.resourceURL?.appendingPathComponent("version.json"),
              let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        localShort = o["sha"] ?? "?"
        localDate = o["date"].flatMap { ISO8601DateFormatter().date(from: $0) }
        // La ruta EMBEBIDA (o["repo"]) es la del BUILD; en un .app precompilado en CI es la del runner
        // (/Users/runner/work/...) que NO existe en la Mac del usuario → antes canSelfUpdate quedaba
        // false y el botón caía a "actualiza a mano". Resolvemos el clon de instalación LOCAL.
        repoPath = Self.resolveClonePath(embedded: o["repo"] ?? "")
        canSelfUpdate = !repoPath.isEmpty
    }

    /// Clon local para auto-actualizar. Prefiere el embebido si EXISTE aquí (build local), luego
    /// $CLAUDE_BRAIN_DIR, luego ~/.claude-brain (el clon oculto que siembra el bootstrap). Devuelve ""
    /// si ninguno tiene macos/install.sh → sin auto-update (el botón invita a hacerlo a mano).
    private static func resolveClonePath(embedded: String) -> String {
        let fm = FileManager.default
        var candidates: [String] = []
        if !embedded.isEmpty { candidates.append(embedded) }
        if let env = ProcessInfo.processInfo.environment["CLAUDE_BRAIN_DIR"], !env.isEmpty { candidates.append(env) }
        candidates.append(fm.homeDirectoryForCurrentUser.path + "/.claude-brain")
        for c in candidates where fm.fileExists(atPath: c + "/macos/install.sh") { return c }
        return ""
    }

    /// Chequea GitHub como mucho 1×/15 min (evita el rate-limit anónimo). Fire-and-forget desde la vista.
    func checkIfStale() async {
        loadLocal()
        if let lc = lastCheck, Date().timeIntervalSince(lc) < 900 { return }   // < 15 min → no re-consulta
        lastCheck = Date()
        await check()
    }

    private func check() async {
        guard localShort != "?" else { return }   // sin version.json (build viejo) → no molesta
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.slug)/commits/main")!)
        req.timeoutInterval = 6
        req.setValue("claude-brain", forHTTPHeaderField: "User-Agent")   // GitHub lo exige
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fullSha = root["sha"] as? String else { return }   // fail-open
        let remoteDate = ((root["commit"] as? [String: Any])?["committer"] as? [String: Any])?["date"] as? String
        let rDate = remoteDate.flatMap { ISO8601DateFormatter().date(from: $0) }
        // Novedad = commit distinto Y (si tenemos fechas) más reciente que el buildeado.
        let differs = !fullSha.hasPrefix(localShort)
        let newer = (localDate == nil || rDate == nil) ? true : (rDate! > localDate!.addingTimeInterval(2))
        remoteShort = String(fullSha.prefix(7))
        updateAvailable = differs && newer
    }

    /// Jala lo último y reinstala TODO (widget + cerebro), luego relanza — `install.sh` COMPLETO, igual
    /// que el botón de Linux (SIN `--no-brain`): un botón = un one-stop, sin asimetría entre OS. Detacha
    /// el proceso (nohup) para que sobreviva a que la app se cierre, y sale para que install.sh abra la nueva.
    func runUpdate() {
        guard canSelfUpdate, !repoPath.isEmpty else {
            message = "actualiza a mano: git pull && ./install.sh"
            return
        }
        updating = true; message = nil
        // Script DETACHADO (nohup → sobrevive a que la app se cierre). Solo si el fast-forward a
        // origin/main tiene éxito: mata la instancia vieja y corre install.sh (que reconstruye y abre
        // la nueva). Si el merge aborta (árbol sucio / no-ff), NO mata nada y la app sigue viva → sin
        // riesgo de quedarte sin widget. El `pkill` va justo antes de reinstalar, no a ciegas.
        let inner = "sleep 1; cd '\(repoPath)' && git fetch origin --quiet && git merge --ff-only origin/main "
            + "&& { pkill -f 'Claude Brain Widget.app/Contents/MacOS/ClaudeBrain'; bash '\(repoPath)/macos/install.sh'; }"
        let cmd = "nohup bash -lc \"\(inner)\" >/tmp/claude-brain-update.log 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", cmd]
        do { try p.run() } catch { updating = false; message = "no pude lanzar el update"; return }
        // Éxito → el script mata esta app y abre la nueva (nunca llega el fallback). Fracaso → a los
        // 60 s reseteamos el estado y avisamos (el árbol quedó intacto).
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.updating else { return }
            self.updating = false
            self.message = "el update no completó (revisa /tmp/claude-brain-update.log)"
        }
    }
}
