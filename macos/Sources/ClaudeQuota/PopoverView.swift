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
            ScrollView(.vertical, showsIndicators: false) { modelosTab }
        default:
            ScrollView(.vertical, showsIndicators: false) { proyectosTab }
        }
    }

    // ===== Tab 0: Límites =====

    private var limitsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Límites de uso").font(.headline)
            usageSection("Sesión (5 h)", model.snapshot?.five_hour)
            usageSection("Semanal (7 d)", model.snapshot?.weekly)
            Spacer(minLength: 0)
            Text(model.footerText)
                .font(.caption)
                .fontWeight(model.accountMismatch ? .bold : .regular)
                .foregroundStyle(model.accountMismatch ? Color(hex: "#dc3545") : label.opacity(0.5))
        }
        .padding(16)
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
            Spacer(minLength: 0)
        }
        .padding(16)
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
            Spacer(minLength: 0)
        }
        .padding(16)
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
