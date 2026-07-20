import AppKit
import SwiftUI

/// The click-to-open breakdown, hosted in an NSPopover. Mirrors the plasmoid's
/// fullRepresentation: a vertical tab rail on the left (Límites / Resumen /
/// Modelos / Proyectos), a 1px separator, and the tab content on the right.
struct PopoverView: View {
    @ObservedObject var model: QuotaModel
    /// Real fetch trigger (launches claude-brain-fetch, then reloads).
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
    /// Summary del chat bajo el cursor (se muestra en el pie de la pestaña Chats).
    @State private var hoveredSummary: String? = nil
    /// Proyecto expandido en la pestaña Proyectos (muestra sus sesiones para resumir).
    @State private var expandedProject: String? = nil
    /// Rango de tiempo activo (footer {hoy·7d·30d·∞}) para Resumen/Modelos/Proyectos/Chats.
    @State private var range: TimeRange = .all
    /// Rename en curso (c: proyecto vía clic-secundario / d: sesión), o nil. `renameText` es el campo.
    @State private var renameTarget: RenameTarget? = nil
    @State private var renameText: String = ""
    /// (A) "Sugerir nombre" corriendo (shell-out a `claude -p`) / su error transitorio.
    @State private var suggesting = false
    @State private var suggestError: String? = nil
    /// (B) Movimiento de sesión pendiente de confirmar / su error transitorio.
    @State private var moveRequest: MoveRequest? = nil
    @State private var moveError: String? = nil
    /// (e) Toggle "todas las máquinas": lee stats-global.json (sync) en vez del stats local.
    @State private var useGlobal = false

    /// Fuente de stats activa según el toggle (e). Si se pidió global pero no hay sync, cae a local.
    private var activeStats: Stats? { (useGlobal ? model.statsGlobal : model.stats) ?? model.stats }

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
        // Al ABRIR el popover (no solo al entrar a Cerebro): chequea updates Y lee el estado del
        // cerebro, para que el riel avise —sin abrir la pestaña— si hay versión nueva (⬆) o si al
        // cerebro le falta una pieza (🩹). Throttle 15 min en el chequeo de red.
        .task { await updater.checkIfStale() }
        .onAppear { brainState = BrainInspector.inspect() }
        // Rename de PROYECTO: .alert simple (sin summary ni botón async).
        .alert("Renombrar proyecto",
               isPresented: Binding(get: { renameTarget?.kind == .project },
                                    set: { if !$0 { renameTarget = nil } }),
               presenting: renameTarget) { t in
            TextField(t.current, text: $renameText)
            Button("Guardar") { applyRename(t) }
            Button("Restaurar original", role: .destructive) { renameText = ""; applyRename(t) }
            Button("Cancelar", role: .cancel) { renameTarget = nil }
        } message: { t in
            Text("Nuevo nombre para “\(t.current)”. Vacío para restaurar el original.")
        }
        // (A) Rename de SESIÓN en hoja propia: muestra el contexto (summary) y el botón "Sugerir
        // nombre" (async, mantiene el diálogo abierto — los botones de .alert lo cerrarían).
        .sheet(isPresented: Binding(get: { renameTarget?.kind == .session },
                                    set: { if !$0 { renameTarget = nil } })) {
            if let t = renameTarget { sessionRenameSheet(t) }
        }
        // (B) Confirmación breve antes de reubicar el transcript (reversible, pero mueve archivos).
        .confirmationDialog("¿Mover esta sesión a “\(moveRequest?.project ?? "")”?",
                            isPresented: Binding(get: { moveRequest != nil },
                                                 set: { if !$0 { moveRequest = nil } }),
                            presenting: moveRequest) { req in
            Button("Mover") { performMove(req) }
            Button("Cancelar", role: .cancel) { moveRequest = nil }
        } message: { req in
            Text("Se reubica el transcript al proyecto “\(req.project)”. Es reversible: se respalda antes de mover.")
        }
        // (B) Error de un movimiento fallido (sin romper la UI).
        .alert("No se pudo mover la sesión",
               isPresented: Binding(get: { moveError != nil },
                                    set: { if !$0 { moveError = nil } }),
               presenting: moveError) { _ in
            Button("OK", role: .cancel) { moveError = nil }
        } message: { Text($0) }
    }

    private func startRename(_ t: RenameTarget) {
        renameText = t.current
        suggesting = false
        suggestError = nil
        renameTarget = t
    }

    /// Escribe el alias y dispara un refetch — el fetch (proyectos) / sessions-extract (sesiones)
    /// releen los mapas y el widget se recarga con el nombre nuevo.
    private func applyRename(_ t: RenameTarget) {
        switch t.kind {
        case .project:
            model.renameProject(t.key, to: renameText)
            onRefresh()                                    // afecta la agregación → fetch completo
        case .session:
            model.renameSession(t.key, to: renameText)
            Task { await model.refreshSessions() }         // etiqueta al instante (sin esperar al fetch)
        }
        renameTarget = nil
    }

    // MARK: - (A) Hoja de renombrar sesión (contexto + Sugerir nombre)

    /// Diálogo de rename de SESIÓN: contexto de solo-lectura (summary), campo editable y el botón
    /// "Sugerir nombre" (que consume tokens). El summary se busca en las sesiones cargadas por id.
    @ViewBuilder
    private func sessionRenameSheet(_ t: RenameTarget) -> some View {
        let summary = model.sessions.first(where: { $0.id == t.key })?.summary
        VStack(alignment: .leading, spacing: 12) {
            Text("Renombrar sesión").font(.headline)

            if let summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("De qué trata (contexto)")
                        .font(.caption2).foregroundStyle(label.opacity(0.5))
                    Text(summary)
                        .font(.caption).foregroundStyle(label.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(6)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(label.opacity(0.05)))
            }

            TextField("Nueva etiqueta", text: $renameText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button(action: { suggestName(summary: summary) }) {
                    HStack(spacing: 5) {
                        if suggesting {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(suggesting ? "Generando…" : "Sugerir nombre").font(.caption)
                    }
                }
                .disabled(suggesting || (summary ?? "").isEmpty)
                .help("Usa `claude -p` sobre el contexto para proponer un nombre. Consume tokens de tu cuenta.")

                if let suggestError {
                    Text(suggestError).font(.caption2)
                        .foregroundStyle(Color(hex: "#dc3545")).lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            Text("Vacío para restaurar la etiqueta original. «Sugerir nombre» consume tokens.")
                .font(.caption2).foregroundStyle(label.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Restaurar original", role: .destructive) { renameText = ""; applyRename(t) }
                Spacer()
                Button("Cancelar", role: .cancel) { renameTarget = nil }
                Button("Guardar") { applyRename(t) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    /// Lanza el shell-out a `claude -p` en background; al volver rellena el campo (editable, NO guarda).
    private func suggestName(summary: String?) {
        guard let summary, !summary.isEmpty else { return }
        suggesting = true
        suggestError = nil
        Task {
            do {
                let name = try await model.suggestSessionName(summary: summary)
                if !name.isEmpty { renameText = name }
            } catch {
                suggestError = error.localizedDescription
            }
            suggesting = false
        }
    }

    // MARK: - (B) Mover una sesión a otro proyecto

    /// Proyectos destino para "Mover a…": derivados de las sesiones ya cargadas — un destino por `cwd`
    /// distinto, excluyendo el cwd actual de la sesión. Ordenados por nombre de proyecto.
    private func moveDestinations(excluding s: Session) -> [(project: String, cwd: String)] {
        var seen = Set<String>()
        var out: [(project: String, cwd: String)] = []
        for other in model.sessions where other.cwd != s.cwd {
            if seen.insert(other.cwd).inserted { out.append((other.project, other.cwd)) }
        }
        return out.sorted { $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending }
    }

    /// Ejecuta el movimiento (tras confirmar) en background; si ok refresca, si no muestra el error.
    private func performMove(_ req: MoveRequest) {
        moveRequest = nil
        Task {
            let r = await model.moveSession(id: req.session.id, toCwd: req.cwd)
            if r.ok { await model.refreshSessions(); onRefresh() } else { moveError = r.error }
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(spacing: 4) {
            railButton(0, "gauge", "Límites")
            railButton(1, "chart.bar.doc.horizontal", "Resumen")
            railButton(2, "chart.bar", "Modelos")
            railButton(3, "folder", "Proyectos")
            if !model.chats.isEmpty { railButton(4, "message", "Chats") }   // solo si hay chats locales
            railButton(5, "brain", "Cerebro", badge: updater.updateAvailable, heal: brainIncomplete)
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
    private func railButton(_ idx: Int, _ system: String, _ text: String, badge: Bool = false, heal: Bool = false) -> some View {
        RailButton(idx: idx, system: system, text: text, tab: $tab, badge: badge, heal: heal)
    }

    /// true si a alguna pieza GLOBAL del cerebro le falta estar instalada (según el ~/.claude real).
    /// Alimenta el 🩹 del riel — el mismo criterio que el recuadro de salud de la pestaña Cerebro.
    private var brainIncomplete: Bool {
        guard let st = brainState else { return false }
        return brainTiers.flatMap { $0.items.map(\.name) }
            .map { status($0, st) }
            .contains { $0 != .installed && $0 != .repoScoped }
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
        case 4:
            chatsTab
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
            Text(resetLine(resetIso))
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

    /// "Se restablece en Nmin" (futuro) o "Se restableció hace Nmin · actualizando…" (ya pasó → el %
    /// cacheado quedó viejo y el fetch disparado por el reset lo está poniendo al día).
    private func resetLine(_ iso: String?) -> String {
        if RelativeTime.isPast(iso) {
            return "Se restableció \(RelativeTime.relative(iso)) · actualizando…"
        }
        return "Se restablece \(RelativeTime.resetDetail(iso))"   // "en 4h 36min" / "el mié 7:59 a. m."
    }

    private func caption(_ bucket: Bucket?) -> String {
        guard let bucket else { return "" }
        var s = resetLine(bucket.resets_at)
        if let cost = bucket.cost_usd {
            s += String(format: " · ≈ $%.2f (API equiv local)", cost)
        }
        return s
    }

    // ===== Tab 1: Resumen =====

    private var resumenTab: some View {
        let s = activeStats?.summary
        let streaks = model.streaks
        let days = rangedDays()
        let hasStats = activeStats != nil
        // Agregados recalculados sobre el rango (a ∞ coinciden con summary).
        let toks = days.reduce(0.0) { $0 + ($1.tokens ?? 0) }
        let cost = days.reduce(0.0) { $0 + ($1.cost ?? 0) }
        let msgs = days.reduce(0.0) { $0 + ($1.messages ?? 0) }
        let activeDays = days.filter { ($0.tokens ?? 0) > 0 }.count
        // Sesiones: a ∞ el conteo exacto de summary; en rango, filtrado de sessions.json.
        let sessions = range == .all ? (s != nil ? Fmt.int(s?.sessions) : "—") : "\(rangedSessionCount())"
        let fav = rangedModels().first?.name
        let cards: [(String, String)] = [
            ("Sesiones",        sessions),
            ("Mensajes",        hasStats ? Fmt.int(msgs) : "—"),
            ("Tokens totales",  hasStats ? Fmt.tok(toks) : "—"),
            ("Días activos",    hasStats ? "\(activeDays)" : "—"),
            ("Racha actual",    "\(streaks.cur)d"),
            ("Racha más larga", "\(streaks.max)d"),
            ("Hora pico",       s != nil ? Fmt.hour(s?.peak_hour) : "—"),
            ("Modelo favorito", fav != nil ? Fmt.prettyModel(fav) : "—"),
            ("Costo API-equiv", hasStats ? String(format: "$%.0f", cost) : "—"),
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
            rangeFooter(machineToggle: true)
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
        let days = rangedDays()
        let maxTok = max(1, days.map { $0.tokens ?? 0 }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Uso por modelo").font(.headline)
            stackedChart(days, maxTok).frame(height: 110)
            // Encabezado + gráfico fijos; solo la lista scrollea (altura acotada al
            // espacio restante) → el popover no crece por más modelos que se acumulen.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach(rangedModels()) { m in
                        usageRow(m, color: model.modelColor(m.name), pretty: true)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            rangeFooter(machineToggle: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stackedChart(_ days: [StatsDay], _ maxTok: Double) -> some View {
        GeometryReader { geo in
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
        let days = rangedDays()
        let maxTok = max(1, days.map { ($0.projects ?? []).reduce(0.0) { $0 + ($1.tokens ?? 0) } }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Uso por proyecto").font(.headline)
            stackedProjectChart(days, maxTok).frame(height: 110)
            // Encabezado + gráfico fijos; solo la lista scrollea (altura acotada al
            // espacio restante) → el popover no crece por más proyectos que se acumulen.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach(rangedProjects()) { p in
                        projectRow(p)
                        if expandedProject == p.name {
                            sessionsList(for: p.name)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            rangeFooter(machineToggle: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Fila de proyecto: swatch + nombre (+ chevron si tiene sesiones) + tokens + %. Tap despliega
    /// sus sesiones de Claude Code para resumir.
    @ViewBuilder
    private func projectRow(_ p: UsageStat) -> some View {
        let name = p.name
        let n = model.sessions.filter { $0.project == name }.count
        Button {
            expandedProject = (expandedProject == name) ? nil : name
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(model.projectColor(name)).frame(width: 10, height: 10)
                Text(name).fontWeight(.bold).lineLimit(1)
                if n > 0 {
                    Image(systemName: expandedProject == name ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(label.opacity(0.5))
                }
                Spacer()
                Text("\(Fmt.tok(p.inTok)) in · \(Fmt.tok(p.outTok)) out").foregroundStyle(label.opacity(0.7))
                Text(String(format: "%.1f%%", p.pct)).fontWeight(.bold)
                    .foregroundStyle(model.projectColor(name)).frame(minWidth: 44, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(n == 0)
        .contextMenu {
            Button("Renombrar…") { startRename(RenameTarget(kind: .project, key: name, current: name)) }
            if model.projectAliased(name) {
                Button("Restaurar original") {
                    model.renameProject(name, to: ""); onRefresh()
                }
            }
        }
    }

    /// Sesiones de un proyecto (al desplegar): cada una resume en su cwd.
    @ViewBuilder
    private func sessionsList(for name: String) -> some View {
        let ss = Array(model.sessions.filter { $0.project == name }.prefix(12))
        VStack(spacing: 3) {
            ForEach(ss) { s in sessionRow(s) }
        }
        .padding(.leading, 18)
    }

    @ViewBuilder
    private func sessionRow(_ s: Session) -> some View {
        Button { resume(s) } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.left.circle").font(.system(size: 11)).foregroundStyle(accent)
                Text(s.label ?? "(sesión)").font(.caption).lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.relDate(s.updated_at)).font(.system(size: 10)).foregroundStyle(label.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Resumir en \(s.cwd)")
        .contextMenu {
            Button("Renombrar…") {
                startRename(RenameTarget(kind: .session, key: s.id, current: s.label ?? ""))
            }
            if model.sessionAliased(s.id) {
                Button("Restaurar original") { model.renameSession(s.id, to: ""); onRefresh() }
            }
            let dests = moveDestinations(excluding: s)
            if !dests.isEmpty {
                Menu("Mover a…") {
                    ForEach(dests.indices, id: \.self) { i in
                        Button(dests[i].project) {
                            moveRequest = MoveRequest(session: s, project: dests[i].project, cwd: dests[i].cwd)
                        }
                    }
                }
            }
        }
    }

    /// Abre Terminal.app y resume la sesión: `cd <cwd> && claude --resume <id>`.
    private func resume(_ s: Session) {
        let cmd = "cd \(shQuote(s.cwd)) && claude --resume \(shQuote(s.id))"
        let osa = "tell application \"Terminal\"\nactivate\ndo script \"\(appleEscape(cmd))\"\nend tell"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", osa]
        try? proc.run()
    }
    private func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func appleEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func stackedProjectChart(_ days: [StatsDay], _ maxTok: Double) -> some View {
        GeometryReader { geo in
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

    // ===== Tab 4: Chats =====

    /// Conversaciones recientes del app de escritorio (leídas del cache local por chats-extract.js,
    /// sin red ni cookies). Click abre el chat en claude.ai; hover muestra el summary.
    private var chatsTab: some View {
        let cs = rangedChats()
        return VStack(alignment: .leading, spacing: 10) {
            Text("Chats").font(.headline)
            if cs.isEmpty {
                Text(range == .all
                     ? "Sin conversaciones locales.\nAbre el app de escritorio de Claude y espera al próximo refresco."
                     : "Sin conversaciones en este rango.")
                    .font(.caption).foregroundStyle(label.opacity(0.6))
                Spacer()
            } else {
                VStack(spacing: 4) {                               // reparto por modelo con %
                    ForEach(chatsByModel(cs)) { chatModelRow($0) }
                }
                Divider().overlay(label.opacity(0.12))
                Text("recientes").font(.caption).foregroundStyle(label.opacity(0.5))
                ScrollView(.vertical, showsIndicators: true) {     // lista clickeable
                    VStack(spacing: 6) {
                        ForEach(cs.prefix(20)) { c in chatRow(c) }
                    }
                }
                .frame(maxHeight: .infinity)
                // Pie: resumen del chat bajo el cursor (hover CONFIABLE vía onHover; el .help no salía).
                Divider().overlay(label.opacity(0.12))
                Text(hoveredSummary ?? "Pasa el cursor sobre un chat para ver su resumen.")
                    .font(.caption)
                    .foregroundStyle(label.opacity(hoveredSummary == nil ? 0.4 : 0.75))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            }
            rangeFooter()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Fila del desglose por modelo: swatch + modelo + conteo + %.
    @ViewBuilder
    private func chatModelRow(_ r: ChatModelStat) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(model.modelColor(r.model)).frame(width: 10, height: 10)
            Text(Fmt.prettyModel(r.model)).fontWeight(.bold).lineLimit(1)
            Spacer()
            Text("\(r.count)").foregroundStyle(label.opacity(0.7))
            Text(String(format: "%.0f%%", r.pct)).fontWeight(.bold)
                .foregroundStyle(model.modelColor(r.model)).frame(minWidth: 44, alignment: .trailing)
        }
    }

    /// Una fila de chat (read-only): título + badge de modelo + fecha; hover -> summary (en el pie).
    @ViewBuilder
    private func chatRow(_ c: Chat) -> some View {
        HStack(spacing: 8) {
            Text(c.title).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 8)
            if let m = c.model { modelBadge(m) }
            Text(Self.relDate(c.updated_at ?? c.created_at))
                .font(.caption).foregroundStyle(label.opacity(0.6))
                .frame(minWidth: 48, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onHover { hovering in hoveredSummary = hovering ? (c.summary ?? "") : nil }
    }

    @ViewBuilder
    private func modelBadge(_ m: String) -> some View {
        let col = model.modelColor(m)
        Text(Fmt.prettyModel(m))
            .font(.caption2).fontWeight(.bold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(col.opacity(0.22), in: Capsule())
            .foregroundStyle(col)
    }

    // ---- datos derivados de model.chats para la pestaña Chats ----

    /// Reparto por modelo (conteo + % del total), ordenado desc.
    private func chatsByModel(_ chats: [Chat]) -> [ChatModelStat] {
        let total = chats.count
        guard total > 0 else { return [] }
        var counts: [String: Int] = [:]
        for c in chats { counts[c.model ?? "?", default: 0] += 1 }
        return counts.map { ChatModelStat(model: $0.key, count: $0.value,
                                          pct: Double($0.value) * 100 / Double(total)) }
            .sorted { $0.count > $1.count }
    }

    /// Fecha relativa desde el prefijo YYYY-MM-DD de un ISO (granularidad de día, robusto a micros).
    static func relDate(_ iso: String?) -> String {
        guard let iso, iso.count >= 10 else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: String(iso.prefix(10))) else { return "" }
        let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        if days <= 0 { return "hoy" }
        if days == 1 { return "ayer" }
        if days < 7 { return "hace \(days)d" }
        if days < 30 { return "hace \(days / 7)sem" }
        return "hace \(days / 30)mes"
    }

    // ---- Filtro de rango {hoy·7d·30d·∞} (Resumen/Modelos/Proyectos/Chats) ----

    /// Fecha de corte "yyyy-MM-dd" (hora local) para el rango activo; nil si ∞.
    private func rangeCutoff() -> String? {
        guard let back = range.daysBack,
              let d = Calendar.current.date(byAdding: .day, value: -back, to: Date()) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: d)
    }

    /// Días de stats.days[] dentro del rango (todos si ∞). Compara por prefijo de fecha.
    /// Usa la fuente activa (local o global según el toggle (e)).
    private func rangedDays() -> [StatsDay] {
        let all = activeStats?.days ?? []
        guard let cut = rangeCutoff() else { return all }
        return all.filter { ($0.date ?? "") >= cut }
    }

    /// Chats dentro del rango (por updated_at/created_at).
    private func rangedChats() -> [Chat] {
        guard let cut = rangeCutoff() else { return model.chats }
        return model.chats.filter { String(($0.updated_at ?? $0.created_at ?? "").prefix(10)) >= cut }
    }

    /// Sesiones (sessions.json) dentro del rango, por updated_at.
    private func rangedSessionCount() -> Int {
        guard let cut = rangeCutoff() else { return model.sessions.count }
        return model.sessions.filter { String(($0.updated_at ?? "").prefix(10)) >= cut }.count
    }

    /// Uso por modelo agregado sobre los días del rango.
    private func rangedModels() -> [UsageStat] {
        var acc: [String: (Double, Double)] = [:]
        for d in rangedDays() {
            for m in d.models ?? [] {
                let k = m.model ?? "?"; var v = acc[k] ?? (0, 0)
                v.0 += m.in_tok ?? 0; v.1 += m.out_tok ?? 0; acc[k] = v
            }
        }
        return usageStats(acc)
    }

    /// Uso por proyecto agregado sobre los días del rango.
    private func rangedProjects() -> [UsageStat] {
        var acc: [String: (Double, Double)] = [:]
        for d in rangedDays() {
            for p in d.projects ?? [] {
                let k = p.project ?? "?"; var v = acc[k] ?? (0, 0)
                v.0 += p.in_tok ?? 0; v.1 += p.out_tok ?? 0; acc[k] = v
            }
        }
        return usageStats(acc)
    }

    private func usageStats(_ acc: [String: (Double, Double)]) -> [UsageStat] {
        let grand = acc.values.reduce(0.0) { $0 + $1.0 + $1.1 }
        return acc.map {
            UsageStat(name: $0.key, inTok: $0.value.0, outTok: $0.value.1,
                      tot: $0.value.0 + $0.value.1,
                      pct: grand > 0 ? ($0.value.0 + $0.value.1) * 100 / grand : 0)
        }.sorted { $0.tot > $1.tot }
    }

    /// Fila de uso (modelo o proyecto): swatch + nombre + in/out + %.
    @ViewBuilder
    private func usageRow(_ u: UsageStat, color: Color, pretty: Bool) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(pretty ? Fmt.prettyModel(u.name) : u.name).fontWeight(.bold).lineLimit(1)
            Spacer()
            Text("\(Fmt.tok(u.inTok)) in · \(Fmt.tok(u.outTok)) out").foregroundStyle(label.opacity(0.7))
            Text(String(format: "%.1f%%", u.pct)).fontWeight(.bold).foregroundStyle(color)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    /// Footer con los 4 botones de rango; el activo va en acento. Si `machineToggle` y hay vista
    /// sincronizada (e), agrega a la derecha el par 🖥 esta / ☁️ todas.
    @ViewBuilder
    private func rangeFooter(machineToggle: Bool = false) -> some View {
        HStack(spacing: 4) {
            ForEach(TimeRange.allCases) { r in
                Button { range = r } label: {
                    Text(r.label)
                        .font(.caption2).fontWeight(range == r ? .bold : .regular)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(range == r ? accent.opacity(0.2) : label.opacity(0.06)))
                        .foregroundStyle(range == r ? accent : label.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if machineToggle, model.statsGlobal != nil {
                machinePills
            }
        }
        .padding(.top, 2)
    }

    /// (e) Par de píldoras 🖥 esta máquina / ☁️ todas. Solo aparece si hay stats-global.json.
    @ViewBuilder
    private var machinePills: some View {
        let n = model.statsGlobal?.machines?.count ?? 0
        HStack(spacing: 4) {
            machinePill(system: "desktopcomputer", on: !useGlobal) { useGlobal = false }
            machinePill(system: "cloud", label: n > 1 ? "\(n)" : nil, on: useGlobal) { useGlobal = true }
        }
        .help(useGlobal ? "Mostrando el uso combinado de todas tus máquinas (sync)"
                        : "Mostrando solo esta máquina")
    }

    @ViewBuilder
    private func machinePill(system: String, label extra: String? = nil, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 3) {
                Image(systemName: system).font(.system(size: 10))
                if let extra { Text(extra).font(.caption2).fontWeight(.bold) }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? accent.opacity(0.2) : label.opacity(0.06)))
            .foregroundStyle(on ? accent : label.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    // ===== Tab 5: Cerebro =====

    /// Infografía del cerebro global de Claude Code: los componentes instalados,
    /// jerarquizados de Hooks Forzosos (los que deniegan) → Skills (opt-in, las invocas tú).
    /// Contenido ESTÁTICO (refleja `brain/`); se mantiene a mano cuando cambian las piezas.
    private var cerebroTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Encabezado de marca: destello Claude + ícono claude-brain (icon-small).
            HStack(spacing: 7) {
                Image(systemName: "sparkle")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(accent)
                if let brand = BrandIcon.small {
                    Image(nsImage: brand)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                }
                Text("Cerebro global")
                    .font(.headline)
                Spacer(minLength: 0)
                mapaButton
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

    /// Enlace discreto al MAPA del cerebro: docs/mapa-cerebro.md versionado en el repo (GitHub).
    /// Abre el navegador con NSWorkspace; misma pastilla tenue que los toggles del widget.
    private var mapaButton: some View {
        Button(action: {
            if let url = URL(string: "https://github.com/unjordi/claude-brain/blob/main/docs/mapa-cerebro.md") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 3) {
                Text("🗺").font(.system(size: 10))
                Text("mapa").font(.caption2).fontWeight(.semibold)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(label.opacity(0.06)))
            .foregroundStyle(label.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help("Abre el mapa del cerebro (docs/mapa-cerebro.md del repo) en tu navegador.")
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
                    // Versión INSTALADA del brain (sello ~/.claude/.brain-version, lo estampa
                    // install-brain.sh). Discreta; si no hay sello (instalación vieja) no aparece.
                    if let v = st.version {
                        Text("· v\(v)")
                            .font(.caption2)
                            .foregroundStyle(label.opacity(0.5))
                    }
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
        case "Definition of Done", "Doc <= realidad", "Flujo de git", "Costo de delegación":
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
                emoji: "🔒", title: "Hooks Forzosos", color: Color(hex: "#cf5a49"),
                subtitle: "hooks que bloquean (deny) — no negociables",
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
                    BrainItem("✅", "dod-verificar", "Def. of Done (ver Norma 🎯 DoD) sin build+tests+memoria → denegado",
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
                emoji: "🔔", title: "Automático", color: accent,
                subtitle: "hooks que inyectan / recuerdan — no bloquean",
                items: [
                    BrainItem("🧭", "sesion-inicio", "al abrir/retomar reinyecta rama + norma de git + orden de leer memoria",
                              "SessionStart",
                              "Al abrir/retomar sesión o tras compactar, reinyecta la rama actual, la norma de git y la orden de leer MEMORY/estado. Antídoto a 'se me va la onda al cambiar de sesión o compu'."),
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
                emoji: "📜", title: "Normas", color: Color(hex: "#4a90d9"),
                subtitle: "reglas que Claude se autoimpone (CLAUDE.md)",
                items: [
                    BrainItem("🎯", "Definition of Done", "verde técnico ≠ Done/Listo/Ya Quedó; exige QA o un OK explícito",
                              "CLAUDE.md · norma",
                              "Algo es LISTO solo si tú lo validaste (QA) o autorizaste el cierre. 'Verde técnico' es necesario pero insuficiente; la autorización es acotada y NO transitiva."),
                    BrainItem("🪞", "Doc <= realidad", "cambió algo → actualiza su doc en la misma tanda, sin preguntar",
                              "CLAUDE.md · norma",
                              "Cuando cambia algo (config, ruta, comportamiento) se actualiza su doc en la misma tanda, sin preguntar. Primero revisar el estado real, luego editar: una doc que miente es peor que nada. Y con iniciativa: ¿vive en MÁS de un lugar (un README y su UI, varias plataformas, un ejemplo)? rastréalas (grep del valor viejo) y actualízalas todas — una copia desincronizada ya miente."),
                    BrainItem("🌿", "Flujo de git", "ramita → MR → develop (squash); main es release-only",
                              "CLAUDE.md · norma",
                              "Todo push va a ramitas; se integra por MR a develop con squash; main es release-only (decisión humana deliberada). 1–3 devs → auto-merge; ≥4 devs → se revisa."),
                    BrainItem("💰", "Costo de delegación", "gratis / incluido / con costo — window-aware, lee tu cuota",
                              "CLAUDE.md · norma",
                              "Reclutar agentes cuesta según nivel: gratis (local), incluido (Claude dentro de la ventana 5h) o con costo (overage / API externa / desconocido). La cadencia del permiso depende del nivel."),
                ]),
            BrainTier(
                emoji: "💡", title: "Skills", color: Color(hex: "#3aa76d"),
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
    /// ⬆ "hay actualización del widget" (mismo ícono del botón de update).
    var badge: Bool = false
    /// 🩹 "al cerebro le falta una pieza" (mismo ícono/rojo del curita).
    var heal: Bool = false
    @State private var hover = false

    var body: some View {
        let active = tab == idx
        let accent = Color(hex: "#e8884a")
        let label = Color(nsColor: .labelColor)
        let help: String = {
            switch (heal, badge) {
            case (true, true):  return "Al cerebro le falta una pieza y hay una actualización — abre Cerebro"
            case (true, false): return "Al cerebro le falta una pieza — abre Cerebro para curarlo 🩹"
            case (false, true): return "Hay una actualización del widget — abre Cerebro para instalarla"
            default:            return ""
            }
        }()
        HStack(spacing: 8) {
            Image(systemName: system).frame(width: 16)
            Text(text).fontWeight(active ? .bold : .regular).lineLimit(1)
            Spacer(minLength: 0)
            // Primero el 🩹 (rojo, más urgente: un guardrail no está activo); luego el ⬆ (update).
            if heal {
                Image(systemName: "bandage.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#dc3545"))
            }
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
        .help(help)
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

/// Rango de tiempo del footer {hoy·7d·30d·∞}. `.all` = histórico completo.
private enum TimeRange: CaseIterable, Identifiable {
    case today, d7, d30, all
    var id: Int { switch self { case .today: 0; case .d7: 1; case .d30: 2; case .all: 3 } }
    var label: String { switch self { case .today: "hoy"; case .d7: "7d"; case .d30: "30d"; case .all: "∞" } }
    /// Días hacia atrás desde hoy (incluyente); nil = sin recorte.
    var daysBack: Int? { switch self { case .today: 0; case .d7: 6; case .d30: 29; case .all: nil } }
}

/// Objetivo de un rename por clic-secundario: (c) proyecto o (d) sesión.
private struct RenameTarget: Identifiable {
    enum Kind { case project, session }
    let kind: Kind
    let key: String        // (c) nombre mostrado del proyecto · (d) id de la sesión
    let current: String    // texto que se precarga en el campo
    var id: String { "\(key)" }
}

/// (B) Movimiento de sesión pendiente de confirmar: qué sesión y a qué proyecto/cwd destino.
private struct MoveRequest: Identifiable {
    let session: Session
    let project: String
    let cwd: String
    var id: String { session.id + "→" + cwd }
}

/// Fila de uso agregada (modelo o proyecto) recalculada por rango: in/out/total/%.
private struct UsageStat: Identifiable {
    let name: String
    let inTok: Double
    let outTok: Double
    let tot: Double
    let pct: Double
    var id: String { name }
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
