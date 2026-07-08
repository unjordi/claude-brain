import SwiftUI

/// The click-to-open breakdown, hosted in an NSPopover. Mirrors the plasmoid's
/// fullRepresentation: a vertical tab rail on the left (Límites / Resumen /
/// Modelos / Proyectos), a 1px separator, and the tab content on the right.
struct PopoverView: View {
    @ObservedObject var model: QuotaModel
    /// Real fetch trigger (launches claude-quota-fetch, then reloads).
    var onRefresh: () -> Void

    @State private var tab = 0

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
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(spacing: 4) {
            railButton(0, "gauge", "Límites")
            railButton(1, "chart.bar.doc.horizontal", "Resumen")
            railButton(2, "chart.bar", "Modelos")
            railButton(3, "folder", "Proyectos")
            railButton(4, "brain", "Cerebro")
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
    private func railButton(_ idx: Int, _ system: String, _ text: String) -> some View {
        RailButton(idx: idx, system: system, text: text, tab: $tab)
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
            Text("Guardarraíles + gobernanza + normas de Claude Code. Viaja por git, aplica en toda máquina. De más duro (arriba) a más leve (abajo).")
                .font(.caption2)
                .foregroundStyle(label.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(brainTiers.indices, id: \.self) { i in
                tierSection(brainTiers[i])
            }

            Text("Instalado por `install-brain.sh` · probado por `test-brain.sh` · sin `jq` los hooks fallan ABIERTO (no bloquean).")
                .font(.caption2)
                .foregroundStyle(label.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// Un nivel del cerebro: espina de color + encabezado + hojas con conectores de árbol.
    @ViewBuilder
    private func tierSection(_ tier: BrainTier) -> some View {
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
                    brainLeaf(tier.items[j], last: j == tier.items.count - 1, color: tier.color)
                }
            }
        }
    }

    /// Una hoja del árbol: conector monoespaciado + emoji + nombre (mono) — descripción.
    @ViewBuilder
    private func brainLeaf(_ item: BrainItem, last: Bool, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(last ? "└─" : "├─")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(color.opacity(0.55))
            Text(item.emoji).font(.footnote)
            (Text(item.name).font(.system(.footnote, design: .monospaced)).fontWeight(.semibold)
                + Text("  " + item.desc).font(.caption2).foregroundColor(label.opacity(0.62)))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Datos ESTÁTICOS del cerebro (reflejan `brain/hooks`, `brain/norms`, `brain/skills`).
    private var brainTiers: [BrainTier] {
        [
            BrainTier(
                emoji: "🔒", title: "INVIOLABLE", color: Color(hex: "#dc3545"),
                subtitle: "hooks que BLOQUEAN (deny) — no negociables",
                items: [
                    BrainItem("🚧", "git-branch-guard", "push/merge a develop·main → denegado, te redirige a ramita→MR"),
                    BrainItem("🔗", "merge-squash-guard", "MR a develop sin --squash → denegado (1 commit limpio)"),
                    BrainItem("✋", "confirmar-merge-develop", "merge a develop sin tu OK → denegado; a main exige OK súper-explícito"),
                    BrainItem("✅", "dod-verificar", "declarar “listo” sin build+tests+memoria → denegado"),
                    BrainItem("💸", "delegacion-gate", "reclutar agente con costo → pide tu consentimiento (puede negar)"),
                ]),
            BrainTier(
                emoji: "🔔", title: "AUTOMÁTICO", color: accent,
                subtitle: "hooks que inyectan / recuerdan — no bloquean",
                items: [
                    BrainItem("🧭", "sesion-inicio", "al abrir/retomar reinyecta rama + norma de git + orden de leer memoria"),
                    BrainItem("💾", "precompact-volcar-estado", "antes de compactar, vuelca avance/decisiones/pendientes a memoria"),
                    BrainItem("📊", "recordar-dashboard", "antes de un push, recuerda actualizar el dashboard del cerebro"),
                    BrainItem("📝", "delegacion-registrar", "registra el consentimiento (materializa el “pregunta 1×”)"),
                ]),
            BrainTier(
                emoji: "📜", title: "NORMAS", color: Color(hex: "#4a90d9"),
                subtitle: "reglas que Claude se autoimpone (CLAUDE.md)",
                items: [
                    BrainItem("🎯", "Definición de LISTO", "verde técnico ≠ listo; exige tu QA o tu OK expreso"),
                    BrainItem("🪞", "Doc = realidad", "cambió algo → actualiza su doc en la misma tanda, sin preguntar"),
                    BrainItem("🌿", "Flujo de git", "ramita → MR → develop (squash); main es release-only"),
                    BrainItem("💰", "Costo de delegación", "gratis / incluido / con costo — window-aware, lee tu cuota"),
                ]),
            BrainTier(
                emoji: "💡", title: "SKILLS", color: Color(hex: "#3aa76d"),
                subtitle: "herramientas opt-in — las invocas tú",
                items: [
                    BrainItem("📦", "cerrar-slice", "build+tests+memoria al día + MR con resumen curado por slice"),
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
    @State private var hover = false

    var body: some View {
        let active = tab == idx
        let accent = Color(hex: "#e8884a")
        let label = Color(nsColor: .labelColor)
        HStack(spacing: 8) {
            Image(systemName: system).frame(width: 16)
            Text(text).fontWeight(active ? .bold : .regular).lineLimit(1)
            Spacer(minLength: 0)
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
    init(_ emoji: String, _ name: String, _ desc: String) {
        self.emoji = emoji; self.name = name; self.desc = desc
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
