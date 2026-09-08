import AppKit
import SwiftUI

/// Autoactualización del widget, estilo winturbo: la app trae embebido el SHA/fecha del commit
/// con que se buildeó (version.json, escrito por make-app.sh). Al abrir la pestaña Cerebro consulta
/// `commits/main` de GitHub; si el repo avanzó, ofrece un botón que hace `git ff origin/main` +
/// `install.sh` COMPLETO (widget + cerebro, igual que Linux → sin asimetría) y relanza. El botón "🩹
/// Curar cerebro global" queda como el self-heal SIN git pull (reinstala el cerebro empaquetado en el
/// app). El clon a actualizar se RESUELVE localmente (ver resolveClonePath): la ruta embebida es la
/// del build —en un .app precompilado en CI, la del runner, que no existe en la Mac—, así que se
/// prefiere el clon de instalación local (~/.cortex). FAIL-OPEN: sin red / sin version.json /
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
    /// Versión LEGIBLE que auto-incrementa ("<PREFIJO>.<count>", campo `version` de version.json).
    /// nil en builds viejos sin el campo — no rompe la detección de update (esa va por `sha`).
    @Published var localVersion: String? = nil
    /// Fecha del build (prefijo YYYY-MM-DD del campo `date`); nil si falta.
    @Published var builtAt: String? = nil

    /// El escape REAL para una máquina que no puede auto-actualizar (build vieja sin fallback #322,
    /// clon corrupto, etc.): migra `~/.claude-brain`→`~/.cortex`, alinea a origin/main y reinstala.
    /// Ni `install.sh` ni `install-brain.sh` a secas migran el clon — SOLO bootstrap.sh lo hace.
    static let bootstrapOneLiner =
        "curl -fsSL https://raw.githubusercontent.com/unjordi/cortex/main/bootstrap.sh | bash"

    /// Ruta del clon que SÍ encontramos en disco (para mostrarla en el mensaje "a mano"), aunque no
    /// sirva para auto-actualizar (p.ej. le falta macos/install.sh). Preferimos el nombre VIEJO
    /// (~/.claude-brain) porque es la señal de que el usuario cayó en el rename #312 sin migrar; si no
    /// existe, mostramos ~/.cortex. "" si no hay ningún clon visible.
    @Published var discoveredClonePath = ""

    /// Mensaje "actualiza a mano" HONESTO: el one-liner real de bootstrap (no `git pull && ./install.sh`,
    /// que no migra el clon) + la ruta descubierta cuando la hay, para que el usuario sepa DÓNDE está
    /// parado antes de correrlo.
    var manualUpdateHint: String {
        let where_ = discoveredClonePath.isEmpty ? "" : " (tu clon: \(discoveredClonePath))"
        return "No puedo auto-actualizar\(where_). Corre en tu terminal:\n\(Self.bootstrapOneLiner)"
    }

    private var repoPath = ""
    private var localDate: Date? = nil
    private var lastCheck: Date? = nil
    private static let slug = "unjordi/cortex"

    private func loadLocal() {
        guard repoPath.isEmpty,
              let url = Bundle.main.resourceURL?.appendingPathComponent("version.json"),
              let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        localShort = o["sha"] ?? "?"
        localDate = o["date"].flatMap { ISO8601DateFormatter().date(from: $0) }
        // Fail-open: campos nuevos ausentes en builds viejos → nil (no rompe la detección por sha).
        localVersion = (o["version"]?.isEmpty == false) ? o["version"] : nil
        builtAt = (o["date"]?.isEmpty == false) ? o["date"].map { String($0.prefix(10)) } : nil
        // La ruta EMBEBIDA (o["repo"]) es la del BUILD; en un .app precompilado en CI es la del runner
        // (/Users/runner/work/...) que NO existe en la Mac del usuario → antes canSelfUpdate quedaba
        // false y el botón caía a "actualiza a mano". Resolvemos el clon de instalación LOCAL.
        repoPath = Self.resolveClonePath(embedded: o["repo"] ?? "")
        canSelfUpdate = !repoPath.isEmpty
        discoveredClonePath = Self.discoverClonePathForDisplay()
    }

    /// Para el mensaje "a mano": ¿hay ALGÚN clon visible en disco, aunque no sirva para auto-actualizar?
    /// Nombre viejo primero (es la señal de "te quedaste en el rename"), luego el canónico.
    private static func discoverClonePathForDisplay() -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        if let env = ProcessInfo.processInfo.environment["CLAUDE_BRAIN_DIR"], !env.isEmpty,
           fm.fileExists(atPath: env) { return env }
        let old = home + "/.claude-brain"
        if fm.fileExists(atPath: old) { return old }
        let new = home + "/.cortex"
        if fm.fileExists(atPath: new) { return new }
        return ""
    }

    /// Clon local para auto-actualizar. Prefiere el embebido si EXISTE aquí (build local), luego
    /// $CLAUDE_BRAIN_DIR, luego ~/.cortex (el clon oculto que siembra el bootstrap), y como FALLBACK
    /// el nombre viejo ~/.claude-brain (pre-rename): mid-migración claude-brain→cortex el clon aún
    /// puede estar bajo el nombre viejo, y sin este fallback el widget no lo hallaba → canSelfUpdate
    /// quedaba false → "actualiza a mano", justo cuando el update es el que MIGRA el clon a ~/.cortex
    /// (círculo vicioso). Con el fallback: el ⬆ funciona sobre ~/.claude-brain y el install.sh migra.
    /// Devuelve "" si ninguno tiene macos/install.sh → sin auto-update (el botón invita a hacerlo a mano).
    private static func resolveClonePath(embedded: String) -> String {
        let fm = FileManager.default
        var candidates: [String] = []
        if !embedded.isEmpty { candidates.append(embedded) }
        if let env = ProcessInfo.processInfo.environment["CLAUDE_BRAIN_DIR"], !env.isEmpty { candidates.append(env) }
        candidates.append(fm.homeDirectoryForCurrentUser.path + "/.cortex")
        candidates.append(fm.homeDirectoryForCurrentUser.path + "/.claude-brain")   // fallback pre-rename
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

    /// Chequeo FORZADO por acción explícita del usuario (botón ↻): SALTA el throttle de 15 min. El
    /// throttle protege a los chequeos automáticos (tab/timer) del rate-limit anónimo; un clic
    /// deliberado sí puede consultar. Paridad: KDE forceRefresh y Windows OnRefresh hacen lo mismo.
    func forceCheck() async {
        loadLocal()
        lastCheck = Date()
        await check()
    }

    private func check() async {
        guard localShort != "?" else { return }   // sin version.json (build viejo) → no molesta
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.slug)/commits/main")!)
        req.timeoutInterval = 6
        req.setValue("cortex", forHTTPHeaderField: "User-Agent")   // GitHub lo exige
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
            message = manualUpdateHint
            return
        }
        updating = true; message = nil
        // Script DETACHADO (nohup → sobrevive a que la app se cierre). Solo si el fetch+alinear a
        // origin/main tiene éxito: mata la instancia vieja y corre install.sh (que reconstruye y abre
        // la nueva). `checkout -B main origin/main` (mismo patrón que bootstrap.sh:84) FUERZA-ALINEA
        // el clon a origin/main, descartando cualquier rama leftover o commit local — este clon es un
        // artefacto de infraestructura, no un checkout de desarrollo del usuario; antes, `merge --ff-only`
        // fallaba PARA SIEMPRE si el clon quedaba en una rama leftover o con commits locales, dejando el
        // botón ⬆ "sin completar" sin diagnóstico. Si el fetch/checkout fallan (p. ej. sin red), NO mata
        // nada y la app sigue viva → sin riesgo de quedarte sin widget. El `pkill` va justo antes de
        // reinstalar, no a ciegas.
        // MIGRACIÓN DEL CLON (rename claude-brain→cortex): si el clon vive bajo el nombre VIEJO y ~/.cortex
        // aún no existe, lo renombra ANTES de actualizar → el nombre canónico queda y el próximo update lo
        // halla directo (sin depender del fallback).
        // OJO — NO quites los \$ de SRC/DST/DIR: `inner` viaja DENTRO de las comillas DOBLES del
        // `bash -lc "\(inner)"` EXTERNO (cmd), así que el \ es lo único que impide que el shell EXTERNO
        // expanda esas vars a VACÍO (aún no existen ahí) antes de que corra el bash INTERNO. Sin el \:
        // `cd` queda pelón → $HOME → `git fetch` fuera de todo repo → "fatal: not a git repository", y el
        // botón ⬆ nunca converge. Con \$ las expande el bash INTERNO, que es donde se asignan.
        let canonical = FileManager.default.homeDirectoryForCurrentUser.path + "/.cortex"
        let inner = "sleep 1; SRC='\(repoPath)'; DST='\(canonical)'; "
            + "[ \\$SRC != \\$DST ] && [ -d \\$SRC ] && [ ! -e \\$DST ] && mv \\$SRC \\$DST; "
            + "DIR=\\$DST; [ -d \\$DIR/.git ] || DIR=\\$SRC; "
            + "cd \\$DIR && git fetch origin --quiet && git checkout -B main origin/main "
            + "&& { pkill -f 'Cortex Widget.app/Contents/MacOS/Cortex'; bash \\$DIR/macos/install.sh; }"
        let cmd = "nohup bash -lc \"\(inner)\" >/tmp/cortex-update.log 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", cmd]
        do { try p.run() } catch { updating = false; message = "no pude lanzar el update"; return }
        // Éxito → el script mata esta app y abre la nueva (nunca llega el fallback). Fracaso → a los
        // 60 s reseteamos el estado y avisamos (el árbol quedó intacto).
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.updating else { return }
            self.updating = false
            self.message = "el update no completó (revisa /tmp/cortex-update.log)"
        }
    }
}
