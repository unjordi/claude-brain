import SwiftUI

/// The click-to-open breakdown, hosted in an NSPopover. Mirrors the plasmoid's
/// fullRepresentation: a vertical tab rail on the left (Límites / Resumen /
/// Modelos / Proyectos), a 1px separator, and the tab content on the right.
struct PopoverView: View {
    @ObservedObject var model: QuotaModel
    /// Real fetch trigger (launches claude-quota-fetch, then reloads).
    var onRefresh: () -> Void

    @State private var tab = 0
    /// Hoja del Cerebro actualmente expandida ("<tier>-<idx>"), o nil.
    @State private var expandedKey: String? = nil
    /// Estado REAL del cerebro leído de ~/.claude (se recarga al abrir la pestaña).
    @State private var brainState: BrainState? = nil
    /// El botón-curita está corriendo install-brain.sh.
    @State private var healing = false
    /// Mensaje transitorio tras curar/actualizar el cerebro.
    @State private var healMsg: String? = nil
    /// Autoupdate del widget (winturbo-style): chequeo de versión + botón de actualizar.
    @ObservedObject private var updater = Updater.shared

    // Neutral surfaces adapt to light/dark via labelColor; accents are fixed hex.
    private var label: Color { Color(nsColor: .labelColor) }
    private let accent = Color(hex: "#e8884a")

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(label.opacity(0.12)).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 520, height: 420)
        // Chequea updates al ABRIR el popover (no solo al entrar a Cerebro) → el badge del riel
        // se entera aunque no abras esa pestaña. Throttle 15 min adentro.
        .task { await updater.checkIfStale() }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(spacing: 4) {
            railButton(0, "gauge", "Límites")
            railButton(1, "chart.bar.doc.horizontal", "Resumen")
            railButton(2, "chart.bar", "Modelos")
            railButton(3, "folder", "Proyectos")
            railButton(4, "brain", "Cerebro", badge: updater.updateAvailable)
            Spacer()
            HStack(spacing: 6) {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(label.opacity(0.7))
                .help("Actualizar ahora")

                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(label.opacity(0.45))
                .help("Salir")
            }
            .padding(.bottom, 2)
        }
        .padding(6)
        .frame(width: 132)
    }

    @ViewBuilder
    private func railButton(_ idx: Int, _ system: String, _ text: String, badge: Bool = false) -> some View {
        RailButton(idx: idx, system: system, text: text, tab: $tab, badge: badge)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case 0:
            limitsTab
        case 1:
            ScrollView(.vertical, showsIndicators: false) { resumenTab }
        case 2:
            modelosTab
        case 3:
            proyectosTab
        default:
            ScrollView(.vertical, showsIndicators: true) { cerebroTab }
        }
    }

    // ===== Tab 0: Límites =====

    private var limitsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Límites de uso").font(.headline)
            usageSection("Sesión (5 h)", model.snapshot?.five_hour)
            usageSection("Semanal (7 d)", model.snapshot?.weekly)

            // Límites semanales por modelo (dinámicos): una fila por modelo.
            if !model.scopedLimits.isEmpty {
                Text("Por modelo (semanal)")
                    .font(.caption)
                    .foregroundStyle(label.opacity(0.6))
                ForEach(model.scopedLimits.indices, id: \.self) { i in
                    let lim = model.scopedLimits[i]
                    limitSection(lim.model ?? "—", lim.percent, lim.resets_at)
                }
            }

            // Gasto REAL de bolsillo — distinto del "Costo API-equiv" (Resumen).
            if let spend = model.snapshot?.spend, spend.enabled == true {
                spendSection(spend, model.snapshot?.extra_usage)
            }

            Spacer(minLength: 0)
            Text(model.footerText)
                .font(.caption)
                .fontWeight(model.accountMismatch ? .bold : .regular)
                .foregroundStyle(model.accountMismatch ? Color(hex: "#dc3545") : label.opacity(0.5))
        }
        .padding(16)
    }

    /// Una fila de límite por-modelo (título + %, barra, "Se restablece …").
    @ViewBuilder
    private func limitSection(_ title: String, _ pct: Double?, _ resetIso: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.bold)
                Spacer()
                Text(pct.map { String(format: "%.1f%%", $0) } ?? "—")
                    .fontWeight(.bold)
                    .foregroundStyle(pctColor(pct))
            }
            ProgressBar(pct: pct)
            Text("Se restablece \(RelativeTime.relative(resetIso))")
                .font(.caption)
                .foregroundStyle(label.opacity(0.65))
        }
    }

    /// Sección de GASTO REAL: dinero de bolsillo (spend) + overage (extra_usage).
    @ViewBuilder
    private func spendSection(_ spend: Spend, _ extra: ExtraUsage?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Gasto real").fontWeight(.bold)
                Spacer()
                // Headline = MONTO usado (no %); el color sigue por porcentaje.
                Text(Fmt.money(spend.used, spend.currency))
                    .fontWeight(.bold)
                    .foregroundStyle(pctColor(spend.percent))
            }
            ProgressBar(pct: spend.percent)
            Text(spendCaption(spend, extra))
                .font(.caption)
                .foregroundStyle(label.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func spendCaption(_ spend: Spend, _ extra: ExtraUsage?) -> String {
        // Monto usado / tope (redundante con el headline a propósito).
        var s = "\(Fmt.money(spend.used, spend.currency)) / \(Fmt.money(spend.cap, spend.currency))"
        if let cur = spend.currency { s += " \(cur)" }
        s += " — gasto real de bolsillo (no el equivalente incluido del plan)"
        if let extra, extra.enabled == true, let used = extra.used_credits {
            s += "\nSobreuso: \(Fmt.int(used)) / \(Fmt.int(extra.monthly_limit)) créditos"
            if let u = extra.utilization { s += String(format: " (%.1f%%)", u) }
        }
        return s
    }

    @ViewBuilder
    private func usageSection(_ title: String, _ bucket: Bucket?) -> some View {
        let pct = bucket?.percent
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.bold)
                Spacer()
                Text(pct.map { String(format: "%.1f%%", $0) } ?? "—")
                    .fontWeight(.bold)
                    .foregroundStyle(pctColor(pct))
            }
            ProgressBar(pct: pct)
            Text(caption(bucket))
                .font(.caption)
                .foregroundStyle(label.opacity(0.65))
        }
    }

    private func caption(_ bucket: Bucket?) -> String {
        guard let bucket else { return "" }
        var s = "Se restablece \(RelativeTime.relative(bucket.resets_at))"
        if let cost = bucket.cost_usd {
            s += String(format: " · ≈ $%.2f (API equiv local)", cost)
        }
        return s
    }

    // ===== Tab 1: Resumen =====

    private var resumenTab: some View {
        let s = model.stats?.summary
        let streaks = model.streaks
        let cards: [(String, String)] = [
            ("Sesiones",        s != nil ? Fmt.int(s?.sessions) : "—"),
            ("Mensajes",        s != nil ? Fmt.int(s?.messages) : "—"),
            ("Tokens totales",  s != nil ? Fmt.tok(s?.total_tokens) : "—"),
            ("Días activos",    s?.active_days.map { "\($0)" } ?? "—"),
            ("Racha actual",    "\(streaks.cur)d"),
            ("Racha más larga", "\(streaks.max)d"),
            ("Hora pico",       s != nil ? Fmt.hour(s?.peak_hour) : "—"),
            ("Modelo favorito", s != nil ? Fmt.prettyModel(s?.favorite_model) : "—"),
            ("Costo API-equiv", s?.total_cost.map { String(format: "$%.0f", $0) } ?? "—"),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            Text("Resumen").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                      spacing: 6) {
                ForEach(cards.indices, id: \.self) { i in
                    StatCard(label: cards[i].0, value: cards[i].1)
                }
            }
            Text("Actividad diaria (local)")
                .font(.caption)
                .foregroundStyle(label.opacity(0.6))
            heatmap
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var heatmap: some View {
        let cells = model.heatmapCells()
        let cell: CGFloat = 12
        let rows = Array(repeating: GridItem(.fixed(cell), spacing: 3), count: 7)
        let maxTok = model.maxDayTokens
        // LazyHGrid fills each column top-to-bottom (matches Grid.TopToBottom).
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, spacing: 3) {
                ForEach(cells) { c in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(cellColor(c.tokens, maxTok))
                        .frame(width: cell, height: cell)
                }
            }
        }
        .frame(height: cell * 7 + 3 * 6)
    }

    private func cellColor(_ tokens: Double, _ maxTok: Double) -> Color {
        if tokens <= 0 { return label.opacity(0.08) }
        let a = 0.25 + 0.75 * min(1, tokens / maxTok)
        return Color(hex: "#e8884a").opacity(a)
    }

    // ===== Tab 2: Modelos =====

    private var modelosTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uso por modelo").font(.headline)
            stackedChart.frame(height: 126)
            // Encabezado + gráfico fijos; solo la lista scrollea (altura acotada al
            // espacio restante) → el popover no crece por más modelos que se acumulen.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach(model.stats?.models ?? [], id: \.model) { m in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(model.modelColor(m.model))
                                .frame(width: 10, height: 10)
                            Text(Fmt.prettyModel(m.model)).fontWeight(.bold)
                            Spacer()
                            Text("\(Fmt.tok(m.in_tok)) in · \(Fmt.tok(m.out_tok)) out")
                                .foregroundStyle(label.opacity(0.7))
                            Text(String(format: "%.1f%%", m.pct ?? 0))
                                .fontWeight(.bold)
                                .foregroundStyle(model.modelColor(m.model))
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stackedChart: some View {
        let days = model.stats?.days ?? []
        let maxTok = model.maxDayTokens
        return GeometryReader { geo in
            let h = geo.size.height
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days.indices, id: \.self) { i in
                    let day = days[i]
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ForEach((day.models ?? []).indices, id: \.self) { j in
                            let seg = day.models![j]
                            Rectangle()
                                .fill(model.modelColor(seg.model))
                                .frame(height: h * CGFloat((seg.tokens ?? 0) / maxTok))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    // ===== Tab 3: Proyectos =====

    /// Uso de Claude Code por carpeta de proyecto — un subconjunto de Modelos
    /// (ese tab también cuenta otros CLIs de IA locales que ccusage detecta).
    private var proyectosTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uso por proyecto").font(.headline)
            stackedProjectChart.frame(height: 126)
            // Encabezado + gráfico fijos; solo la lista scrollea (altura acotada al
            // espacio restante) → el popover no crece por más proyectos que se acumulen.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach(model.stats?.projects ?? [], id: \.project) { p in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(model.projectColor(p.project))
                                .frame(width: 10, height: 10)
                            Text(p.project ?? "—").fontWeight(.bold).lineLimit(1)
                            Spacer()
                            Text("\(Fmt.tok(p.in_tok)) in · \(Fmt.tok(p.out_tok)) out")
                                .foregroundStyle(label.opacity(0.7))
                            Text(String(format: "%.1f%%", p.pct ?? 0))
                                .fontWeight(.bold)
                                .foregroundStyle(model.projectColor(p.project))
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stackedProjectChart: some View {
        let days = model.stats?.days ?? []
        let maxTok = model.maxDayTokens
        return GeometryReader { geo in
            let h = geo.size.height
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days.indices, id: \.self) { i in
                    let day = days[i]
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ForEach((day.projects ?? []).indices, id: \.self) { j in
                            let seg = day.projects![j]
                            Rectangle()
                                .fill(model.projectColor(seg.project))
                                .frame(height: h * CGFloat((seg.tokens ?? 0) / maxTok))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    // ===== Tab 4: Cerebro =====

    /// Infografía del cerebro global de Claude Code: los componentes instalados,
    /// jerarquizados de INVIOLABLE (hooks que deniegan) → SUGERENCIA LEVE (skills opt-in).
    /// Contenido ESTÁTICO (refleja `brain/`); se mantiene a mano cuando cambian las piezas.
    private var cerebroTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Encabezado de marca: destello Claude + 🧠.
            HStack(spacing: 7) {
                Image(systemName: "sparkle")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(accent)
                Text("🧠 Cerebro global")
                    .font(.headline)
            }
            Text("Guardarraíles + gobernanza + normas de Claude Code. Viaja por git, aplica en toda máquina. De más duro (arriba) a más leve (abajo). Toca una pieza para ver su evento y un ejemplo.")
                .font(.caption2)
                .foregroundStyle(label.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            updateBanner

            brainHealth

            ForEach(brainTiers.indices, id: \.self) { i in
                tierSection(brainTiers[i], tierIndex: i)
            }

            extrasSection

            Text("Instalado por `install-brain.sh` · probado por `test-brain.sh` · sin `jq` los hooks fallan ABIERTO (no bloquean).")
                .font(.caption2)
                .foregroundStyle(label.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(16)
        .onAppear { brainState = BrainInspector.inspect() }
        .task { await updater.checkIfStale() }
    }

    /// Banner de AUTOUPDATE (winturbo-style): solo aparece si el repo avanzó respecto al build actual.
    @ViewBuilder
    private var updateBanner: some View {
        if updater.updateAvailable {
            Button(action: { updater.runUpdate() }) {
                HStack(spacing: 6) {
                    if updater.updating {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    Text(updater.updating
                         ? "Actualizando… (se relanza sola)"
                         : (updater.canSelfUpdate
                            ? "Actualizar widget (\(updater.localShort) → \(updater.remoteShort))"
                            : "Hay versión nueva (\(updater.remoteShort)) — actualiza a mano"))
                        .font(.caption).fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.16)))
                .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .disabled(updater.updating || !updater.canSelfUpdate)
            .help(updater.canSelfUpdate
                  ? "Corre git pull + install.sh en tu clon y relanza el widget con la versión nueva."
                  : "No encuentro el clon del repo; actualiza a mano con git pull && ./install.sh.")
        }
    }

    /// Resumen de salud LEÍDO de la realidad: cuántas piezas globales están activas + leyenda + hora.
    @ViewBuilder
    private var brainHealth: some View {
        if let st = brainState {
            let globals = brainTiers.flatMap { $0.items.map(\.name) }
                .map { status($0, st) }
                .filter { $0 != .repoScoped }
            let active = globals.filter { $0 == .installed }.count
            let total = globals.count
            let allGood = active == total
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: allGood ? "checkmark.seal.fill" : "bandage.fill")
                        .foregroundStyle(allGood ? Color(hex: "#3aa76d") : Color(hex: "#dc3545"))
                    Text(allGood ? "Cerebro global completo y activo"
                                 : "Tu cerebro global está incompleto")
                        .font(.caption).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Text("leído \(Fmt.clock(st.scannedAt))")
                        .font(.system(size: 9)).foregroundStyle(label.opacity(0.4))
                }
                // Sin leyenda de estados (de cara al usuario: binario). El curita SOLO aparece si
                // falta algo; sano → sin botón (el sello verde ya lo dice). El matiz fino de cada
                // pieza vive en el detalle al tocarla y en el inspector (4 estados).
                if total - active > 0 {
                    healButton(missing: total - active)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(label.opacity(0.05)))
        }
    }

    /// Botón-curita 🩹 self-healing: corre el install-brain.sh EMPAQUETADO en el app para completar
    /// lo que falte / actualizar el andamiaje global, y re-lee el estado al terminar.
    @ViewBuilder
    private func healButton(missing: Int) -> some View {
        let heal = Color(hex: "#dc3545")   // rojo cruz-roja
        HStack(spacing: 7) {
            Button(action: healBrain) {
                HStack(spacing: 5) {
                    if healing {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: missing > 0 ? "bandage.fill" : "arrow.triangle.2.circlepath")
                            .rotationEffect(.degrees(missing > 0 ? -20 : 0))
                    }
                    Text(healing ? "Curando…"
                                 : (missing > 0 ? "Curar cerebro global (\(missing))" : "Actualizar cerebro global"))
                        .font(.caption).fontWeight(.semibold)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(missing > 0 ? heal.opacity(0.16) : label.opacity(0.08))
                )
                // Sano (10/10) → gris calmado: "actualizar" es mantenimiento opcional, no alarma.
                // Faltan piezas → rojo cruz-roja: acción recomendada.
                .foregroundStyle(missing > 0 ? heal : label.opacity(0.55))
            }
            .buttonStyle(.plain)
            .disabled(healing)
            .help("Corre install-brain.sh (empaquetado en el app): copia/cablea los hooks globales, la skill, el dashboard y el bloque de normas en tu ~/.claude. Idempotente.")

            if let healMsg {
                Text(healMsg).font(.system(size: 9)).foregroundStyle(label.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    /// Corre el instalador del cerebro empaquetado en el bundle, con PATH enriquecido (Finder da uno
    /// mínimo, sin Homebrew → jq no aparecería). Al terminar re-lee el estado para actualizar los puntos.
    private func healBrain() {
        guard let script = Bundle.main.resourceURL?
                .appendingPathComponent("brain/install-brain.sh"),
              FileManager.default.fileExists(atPath: script.path) else {
            healMsg = "no encontré el instalador en el app"
            return
        }
        healing = true; healMsg = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path]
            var env = ProcessInfo.processInfo.environment
            let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = extra + ":" + (env["PATH"] ?? "")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            var ok = false
            do { try p.run(); p.waitUntilExit(); ok = p.terminationStatus == 0 } catch { ok = false }
            _ = pipe.fileHandleForReading.readDataToEndOfFile()  // drena para no bloquear el pipe
            DispatchQueue.main.async {
                let fresh = BrainInspector.inspect()
                brainState = fresh
                healing = false
                healMsg = ok ? "✓ curado" : "✗ error (¿jq instalado?)"
            }
        }
    }

    /// Hooks cableados en settings.json que NO están en el catálogo del cerebro (doc=realidad completa).
    @ViewBuilder
    private var extrasSection: some View {
        if let st = brainState, !st.extras.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(label.opacity(0.3)).frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("➕").font(.title3)
                        Text("OTROS").font(.subheadline).fontWeight(.heavy)
                            .foregroundStyle(label.opacity(0.5))
                    }
                    Text("hooks cableados en tu settings.json, fuera del catálogo del cerebro")
                        .font(.caption2).foregroundStyle(label.opacity(0.6))
                    ForEach(st.extras.indices, id: \.self) { k in
                        HStack(spacing: 6) {
                            Image(systemName: BrainStatus.installed.symbol)
                                .font(.system(size: 8)).foregroundStyle(label.opacity(0.5))
                            Text(st.extras[k]).font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
            }
        }
    }

    /// Un nivel del cerebro: espina de color + encabezado + hojas con conectores de árbol.
    @ViewBuilder
    private func tierSection(_ tier: BrainTier, tierIndex: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(tier.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(tier.emoji).font(.title3)
                    Text(tier.title).font(.subheadline).fontWeight(.heavy)
                        .foregroundStyle(tier.color)
                }
                Text(tier.subtitle).font(.caption2).foregroundStyle(label.opacity(0.6))
                ForEach(tier.items.indices, id: \.self) { j in
                    brainLeaf(tier.items[j], tier: tierIndex, idx: j,
                              last: j == tier.items.count - 1, color: tier.color)
                }
            }
        }
    }

    /// Una hoja del árbol: conector + emoji + nombre (mono) — descripción, con chevron.
    /// Al tocarla se expande su evento (chip) + un ejemplo de cuándo actúa.
    @ViewBuilder
    private func brainLeaf(_ item: BrainItem, tier: Int, idx: Int, last: Bool, color: Color) -> some View {
        let key = "\(tier)-\(idx)"
        let isOpen = expandedKey == key
        let st = statusFor(item.name)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text(last ? "└─" : "├─")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(color.opacity(0.55))
                if let st {
                    Image(systemName: st.symbol)
                        .font(.system(size: 8))
                        .foregroundStyle(st.color)
                        .padding(.top, 3)
                }
                Text(item.emoji).font(.footnote)
                (Text(item.name).font(.system(.footnote, design: .monospaced)).fontWeight(.semibold)
                    + Text("  " + item.desc).font(.caption2).foregroundColor(label.opacity(0.62)))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(label.opacity(0.35))
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedKey = isOpen ? nil : key
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.event)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15)))
                    Text(item.detail)
                        .font(.caption2)
                        .foregroundStyle(label.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    if let st {
                        HStack(spacing: 4) {
                            Image(systemName: st.symbol).font(.system(size: 8)).foregroundStyle(st.color)
                            Text(st.label).font(.system(size: 9)).foregroundStyle(st.color)
                        }
                        .padding(.top, 1)
                    }
                }
                .padding(.leading, 22)
                .padding(.trailing, 4)
                .transition(.opacity)
            }
        }
    }

    /// Estado real de una pieza (por nombre) contra la evidencia leída de ~/.claude; nil si aún no se leyó.
    private func statusFor(_ name: String) -> BrainStatus? {
        guard let st = brainState else { return nil }
        return status(name, st)
    }

    private func status(_ name: String, _ st: BrainState) -> BrainStatus {
        if BrainState.knownGlobalHooks.contains(name) {
            let p = st.presentHooks.contains(name), w = st.wiredHooks.contains(name)
            return p && w ? .installed : (p ? .presentNotWired : .absent)
        }
        if BrainState.knownRepoHooks.contains(name) { return .repoScoped }
        switch name {
        case "cerrar-slice":
            return st.skills.contains("cerrar-slice") ? .installed : .absent
        case "Definición de LISTO", "Doc = realidad", "Flujo de git", "Costo de delegación":
            return st.hasNorms ? .installed : .absent
        default:
            return .absent
        }
    }

    /// Datos del cerebro. La ESTRUCTURA (qué piezas hay y su explicación) es curada; el ESTADO de
    /// instalación de cada una se LEE de la realidad (`~/.claude`) vía `statusFor`.
    private var brainTiers: [BrainTier] {
        [
            BrainTier(
                emoji: "🔒", title: "INVIOLABLE", color: Color(hex: "#dc3545"),
                subtitle: "hooks que BLOQUEAN (deny) — no negociables",
                items: [
                    BrainItem("🚧", "git-branch-guard", "push/merge a develop·main → denegado, te redirige a ramita→MR",
                              "PreToolUse · Bash",
                              "Escanea cada comando: si ve un `git push` o un merge que apunte a develop/main, lo deniega y te recuerda el flujo ramita→MR. Sin jq falla ABIERTO (no bloquea)."),
                    BrainItem("🔗", "merge-squash-guard", "MR a develop sin --squash → denegado (1 commit limpio)",
                              "PreToolUse · Bash",
                              "Un `gh pr merge`/`glab mr merge` a develop sin --squash se deniega, para que la ramita colapse a un commit curado. Los releases a main quedan exentos (conservan historia)."),
                    BrainItem("🕵️", "secret-scan", "commit/push con un secreto → denegado",
                              "PreToolUse · Bash",
                              "Escanea lo que ENTRA al repo (staged en commit, saliente en push) buscando llaves/tokens/claves privadas de formato inconfundible (AWS, PEM, Anthropic, OpenAI, GitHub, GitLab, Slack, Google). Si aparece uno → bloquea: una credencial pusheada queda comprometida aunque la borres. Escape: --no-verify."),
                    BrainItem("✋", "confirmar-merge-develop", "merge a develop sin tu OK → denegado; a main exige OK súper-explícito",
                              "PreToolUse · Bash",
                              "Antes de integrar por MR busca tu OK explícito en el chat reciente; a main exige lenguaje de release ('hasta main', 'libera'). Un 'sigue/avanza' NO cuenta como autorización."),
                    BrainItem("✅", "dod-verificar", "declarar “listo” sin build+tests+memoria → denegado",
                              "Stop",
                              "Al cerrar el turno, si dijiste 'listo/en producción' tras tocar código fuente, exige evidencia de build+tests verdes y memoria al día, o bloquea el cierre."),
                    BrainItem("💸", "delegacion-gate", "reclutar agente con costo → pide tu consentimiento (puede negar)",
                              "PreToolUse · Task",
                              "Al reclutar un agente calcula su nivel de costo (gratis/incluido/con costo, según tu ventana de 5h) y pide consentimiento mostrando tu cuota real. Puedes negar y el agente no corre."),
                    BrainItem("🛑", "limite-gasto", "reclutar agente con el gasto pasado del techo → denegado",
                              "PreToolUse · Task",
                              "Freno DURO (distinto del gate que pregunta): si el gasto real ya rebasó un techo configurable (sobreuso o ventana 5h), bloquea reclutar más agentes para que un workflow desbocado no siga quemando dinero. Techo por env (LIMITE_GASTO_OVERAGE_PCT / LIMITE_GASTO_5H_PCT)."),
                ]),
            BrainTier(
                emoji: "🔔", title: "AUTOMÁTICO", color: accent,
                subtitle: "hooks que inyectan / recuerdan — no bloquean",
                items: [
                    BrainItem("🧭", "sesion-inicio", "al abrir/retomar reinyecta rama + norma de git + orden de leer memoria",
                              "SessionStart",
                              "Al abrir/retomar sesión o tras compactar, reinyecta la rama actual, la norma de git y la orden de leer MEMORY/estado. Antídoto a 'se me va la onda al cambiar de sesión o compu'."),
                    BrainItem("💾", "precompact-volcar-estado", "antes de compactar, vuelca avance/decisiones/pendientes a memoria",
                              "PreCompact",
                              "Justo antes de que el contexto se compacte, te obliga a volcar avance/decisiones/pendientes a la memoria, para no perder el hilo en un sprint largo."),
                    BrainItem("📊", "recordar-dashboard", "antes de un push, recuerda actualizar el dashboard del cerebro",
                              "PreToolUse · Bash",
                              "Antes de un `git push` recuerda (no bloquea) actualizar el dashboard del cerebro: una línea a la bitácora + ajustar el mapa si cambió el layout de repos/proyectos."),
                    BrainItem("🕰️", "rama-vieja", "push de ramita muy atrás de develop → aviso (no bloquea)",
                              "PreToolUse · Bash",
                              "Antes de un push, si la ramita está muchos commits detrás de origin/develop (base vieja → el MR trae ruido/conflictos), avisa —no bloquea— y sugiere rebasar. Umbral configurable (RAMA_VIEJA_UMBRAL, def 40)."),
                    BrainItem("📝", "delegacion-registrar", "registra el consentimiento (materializa el “pregunta 1×”)",
                              "PostToolUse · Task",
                              "Tras un consentimiento aprobado lo registra para no volver a preguntar (1× por máquina o por workflow, según el nivel de costo). Materializa el 'pregunta una sola vez'."),
                ]),
            BrainTier(
                emoji: "📜", title: "NORMAS", color: Color(hex: "#4a90d9"),
                subtitle: "reglas que Claude se autoimpone (CLAUDE.md)",
                items: [
                    BrainItem("🎯", "Definición de LISTO", "verde técnico ≠ listo; exige tu QA o tu OK expreso",
                              "CLAUDE.md · norma",
                              "Algo es LISTO solo si tú lo validaste (QA) o autorizaste el cierre. 'Verde técnico' es necesario pero insuficiente; la autorización es acotada y NO transitiva."),
                    BrainItem("🪞", "Doc = realidad", "cambió algo → actualiza su doc en la misma tanda, sin preguntar",
                              "CLAUDE.md · norma",
                              "Cuando cambia algo (config, ruta, comportamiento) se actualiza su doc en la misma tanda, sin preguntar. Primero revisar el estado real, luego editar: una doc que miente es peor que nada."),
                    BrainItem("🌿", "Flujo de git", "ramita → MR → develop (squash); main es release-only",
                              "CLAUDE.md · norma",
                              "Todo push va a ramitas; se integra por MR a develop con squash; main es release-only (decisión humana deliberada). 1–3 devs → auto-merge; ≥4 devs → se revisa."),
                    BrainItem("💰", "Costo de delegación", "gratis / incluido / con costo — window-aware, lee tu cuota",
                              "CLAUDE.md · norma",
                              "Reclutar agentes cuesta según nivel: gratis (local), incluido (Claude dentro de la ventana 5h) o con costo (overage / API externa / desconocido). La cadencia del permiso depende del nivel."),
                ]),
            BrainTier(
                emoji: "💡", title: "SKILLS", color: Color(hex: "#3aa76d"),
                subtitle: "herramientas opt-in — las invocas tú",
                items: [
                    BrainItem("📦", "cerrar-slice", "build+tests+memoria al día + MR con resumen curado por slice",
                              "skill · opt-in",
                              "Ritual de cierre de un slice: build+tests verdes, memoria al día (bitácora), MR con resumen curado en prosa, y el Paso 5 de cosechar lo genérico de vuelta al cerebro global."),
                ]),
        ]
    }
}

// MARK: - Subcomponents

/// A rail tab button: active = orange 18% bg + accent bold text/icon; hover = labelColor 8%.
private struct RailButton: View {
    let idx: Int
    let system: String
    let text: String
    @Binding var tab: Int
    /// Muestra el ⬆ de "hay actualización" en la etiqueta (mismo ícono del botón de update).
    var badge: Bool = false
    @State private var hover = false

    var body: some View {
        let active = tab == idx
        let accent = Color(hex: "#e8884a")
        let label = Color(nsColor: .labelColor)
        HStack(spacing: 8) {
            Image(systemName: system).frame(width: 16)
            Text(text).fontWeight(active ? .bold : .regular).lineLimit(1)
            Spacer(minLength: 0)
            if badge {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
            }
        }
        .foregroundStyle(active ? accent : label)
        .padding(.horizontal, 8)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? accent.opacity(0.18)
                             : (hover ? label.opacity(0.08) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { tab = idx }
        .help(badge ? "Hay una actualización del widget — abre Cerebro para instalarla" : "")
    }
}

/// A rounded progress bar with animated fill width (250ms), matching UsageSection.
private struct ProgressBar: View {
    let pct: Double?
    var body: some View {
        let label = Color(nsColor: .labelColor)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(label.opacity(0.12))
                Capsule()
                    .fill(pctColor(pct))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, (pct ?? 0) / 100))))
                    .animation(.easeInOut(duration: 0.25), value: pct)
            }
        }
        .frame(height: 9)
    }
}

/// Un nivel del cerebro (tier) con sus hojas — datos estáticos de la pestaña Cerebro.
private struct BrainTier {
    let emoji: String
    let title: String
    let color: Color
    let subtitle: String
    let items: [BrainItem]
}

/// Una hoja del árbol del cerebro (un hook / norma / skill).
private struct BrainItem {
    let emoji: String
    let name: String
    let desc: String
    let event: String   // evento que lo dispara (chip al expandir)
    let detail: String  // ejemplo / detalle de cuándo actúa (al expandir)
    init(_ emoji: String, _ name: String, _ desc: String, _ event: String, _ detail: String) {
        self.emoji = emoji; self.name = name; self.desc = desc
        self.event = event; self.detail = detail
    }
}

/// A summary stat card: labelColor 6% bg, label (dim, small) over bold value.
private struct StatCard: View {
    let label: String
    let value: String
    var body: some View {
        let fg = Color(nsColor: .labelColor)
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(fg.opacity(0.6))
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 6).fill(fg.opacity(0.06)))
    }
}
