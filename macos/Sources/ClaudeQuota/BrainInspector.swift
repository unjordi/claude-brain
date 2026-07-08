import SwiftUI

/// Estado de instalación de una pieza del cerebro, leído de la realidad (`~/.claude`).
enum BrainStatus {
    case installed        // global: script presente + cableado, o norma/skill presente
    case presentNotWired  // global: el script existe pero NO está cableado en settings.json
    case absent           // global: se esperaba y no está
    case repoScoped       // viaja por repo (no verificable desde el ~/.claude global)

    // NOTA: mantenemos los 4 casos para la PRECISIÓN interna (el detalle al tocar los distingue por
    // `label`), pero de cara al usuario el color/símbolo COLAPSAN a binario: verde=bien, rojo=faltante
    // (sin cablear y ausente se ven igual → "algo falta, cúralo"), azul discreto=por-repo (no cuenta).
    var symbol: String {
        switch self {
        case .installed:       return "checkmark.circle.fill"
        case .presentNotWired: return "exclamationmark.circle.fill"
        case .absent:          return "exclamationmark.circle.fill"
        case .repoScoped:      return "circle.dashed"
        }
    }
    var color: Color {
        switch self {
        case .installed:       return Color(hex: "#3aa76d")
        case .presentNotWired: return Color(hex: "#dc3545")
        case .absent:          return Color(hex: "#dc3545")
        case .repoScoped:      return Color(hex: "#4a90d9").opacity(0.6)
        }
    }
    /// Texto de ayuda al expandir la pieza.
    var label: String {
        switch self {
        case .installed:       return "instalado + cableado en tu ~/.claude"
        case .presentNotWired: return "el script existe pero NO está cableado en settings.json"
        case .absent:          return "no instalado en tu ~/.claude"
        case .repoScoped:      return "viaja por repo: se copia al .claude/ de cada proyecto"
        }
    }
}

/// Evidencia real leída de `~/.claude` en un instante dado. Puro I/O de lectura, tolerante a fallos.
struct BrainState {
    var presentHooks: Set<String> = []   // basenames sin .sh en ~/.claude/hooks
    var wiredHooks: Set<String> = []      // basenames referenciados en settings.json
    var hasNorms: Bool = false            // ~/.claude/CLAUDE.md trae el marcador BEGIN claude-brain
    var skills: Set<String> = []          // subcarpetas de ~/.claude/skills con SKILL.md
    var extras: [String] = []             // hooks cableados que no están en el catálogo conocido
    var scannedAt: Date = Date()

    /// Los 5 hooks de tier global que instala install-brain.sh.
    static let knownGlobalHooks: Set<String> = [
        "git-branch-guard", "merge-squash-guard", "recordar-dashboard",
        "secret-scan", "rama-vieja", "limite-gasto",
        "delegacion-gate", "delegacion-registrar",
    ]
    /// Los hooks repo-scoped (fuente en brain/hooks, no globales) — pueden aparecer cableados en un repo.
    static let knownRepoHooks: Set<String> = [
        "sesion-inicio", "precompact-volcar-estado", "dod-verificar", "confirmar-merge-develop",
    ]

    /// # de piezas GLOBALES esperadas que FALTAN: hooks no (presentes+cableados) + normas + la skill.
    /// Espeja el criterio del recuadro de salud; alimenta el 🩹 del riel y de la píldora de la barra.
    var globalMissing: Int {
        var n = 0
        for h in Self.knownGlobalHooks where !(presentHooks.contains(h) && wiredHooks.contains(h)) { n += 1 }
        if !hasNorms { n += 1 }
        if !skills.contains("cerrar-slice") { n += 1 }
        return n
    }
    var isComplete: Bool { globalMissing == 0 }
}

/// Lee `~/.claude` y arma un `BrainState`. Todo el I/O es de LECTURA y fail-safe (si algo falta,
/// esa pieza queda como ausente en vez de romper). Así la pestaña Cerebro refleja la realidad.
enum BrainInspector {
    static func inspect() -> BrainState {
        var st = BrainState()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let claude = home.appendingPathComponent(".claude")

        // (1) Hooks presentes: *.sh en ~/.claude/hooks
        let hooksDir = claude.appendingPathComponent("hooks")
        if let items = try? fm.contentsOfDirectory(atPath: hooksDir.path) {
            for f in items where f.hasSuffix(".sh") {
                st.presentHooks.insert(String(f.dropLast(3)))
            }
        }

        // (2) Hooks cableados: basenames referenciados en los comandos de settings.json
        let settings = claude.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settings),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hooks = root["hooks"] as? [String: Any] {
            var commands: [String] = []
            for (_, entriesAny) in hooks {
                guard let entries = entriesAny as? [[String: Any]] else { continue }
                for entry in entries {
                    guard let hs = entry["hooks"] as? [[String: Any]] else { continue }
                    for h in hs { if let c = h["command"] as? String { commands.append(c) } }
                }
            }
            let rx = try? NSRegularExpression(pattern: #"/hooks/([A-Za-z0-9._-]+)\.sh"#)
            for c in commands {
                let range = NSRange(c.startIndex..., in: c)
                rx?.enumerateMatches(in: c, range: range) { m, _, _ in
                    if let m, let r = Range(m.range(at: 1), in: c) {
                        st.wiredHooks.insert(String(c[r]))
                    }
                }
            }
        }

        // (3) Normas: instaladas por el marcador de inyección, O presentes por contenido (escritas a
        //     mano). Ambas gobiernan de verdad → cuentan como activas (doc=realidad: reflejamos el
        //     efecto real, no solo si pasaron por install-brain.sh).
        let claudeMd = claude.appendingPathComponent("CLAUDE.md")
        if let txt = try? String(contentsOf: claudeMd, encoding: .utf8) {
            st.hasNorms = txt.contains("BEGIN claude-brain")
                || txt.contains("Definición de \"LISTO\"")
                || txt.contains("reflejo de la realidad")
        }

        // (4) Skills: subcarpetas de ~/.claude/skills con un SKILL.md
        let skillsDir = claude.appendingPathComponent("skills")
        if let dirs = try? fm.contentsOfDirectory(atPath: skillsDir.path) {
            for d in dirs {
                let skillFile = skillsDir.appendingPathComponent(d).appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: skillFile.path) { st.skills.insert(d) }
            }
        }

        // (5) Extras: hooks cableados que no reconocemos (ni global ni repo-scoped del catálogo)
        let known = BrainState.knownGlobalHooks.union(BrainState.knownRepoHooks)
        st.extras = st.wiredHooks.subtracting(known).sorted()

        st.scannedAt = Date()
        return st
    }
}
