import AppKit
import SwiftUI

/// Autoactualización LIGERA del widget, estilo winturbo: la app trae embebido el SHA/fecha del commit
/// con que se buildeó (version.json, escrito por make-app.sh) y la ruta de su clon. Al abrir la
/// pestaña Cerebro consulta `commits/main` de GitHub; si el repo avanzó, ofrece un botón que hace
/// `git pull` + `install.sh` y relanza. FAIL-OPEN: sin red / sin version.json / sin clon → no molesta.
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
        repoPath = o["repo"] ?? ""
        localDate = o["date"].flatMap { ISO8601DateFormatter().date(from: $0) }
        canSelfUpdate = !repoPath.isEmpty && FileManager.default.fileExists(atPath: repoPath + "/macos/install.sh")
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
        req.setValue("claude-quota-widget", forHTTPHeaderField: "User-Agent")   // GitHub lo exige
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

    /// Jala lo último y reinstala (widget, sin tocar el cerebro), luego relanza. Detacha el proceso
    /// (nohup) para que sobreviva a que la app se cierre, y sale para que install.sh abra la versión nueva.
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
            + "&& { pkill -f 'Claude Brain Widget.app/Contents/MacOS/ClaudeQuota'; bash '\(repoPath)/macos/install.sh' --no-brain; }"
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
