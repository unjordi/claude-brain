import AppKit
import SwiftUI

// MARK: - state.json (límites)

/// One usage bucket (5-hour block or weekly), as written by claude-quota-fetch.
struct Bucket: Codable {
    let percent: Double?
    let cost_usd: Double?
    let cost_cap: Double?
    let resets_at: String?
}

/// Un límite acotado en el tiempo de `.limits[]` (session/weekly_all/weekly_scoped).
/// Solo presente en basis=="oauth"; los scoped traen `model` (display_name).
struct LimitEntry: Codable {
    let kind: String?
    let model: String?        // scope.model.display_name, o nil si no es scoped
    let percent: Double?
    let resets_at: String?
    let severity: String?
    let is_active: Bool?
}

/// Gasto REAL de bolsillo (dinero), ya normalizado (amount_minor/10^exponent).
struct Spend: Codable {
    let used: Double?
    let cap: Double?
    let currency: String?
    let percent: Double?
    let enabled: Bool?
}

/// Overage (créditos de sobreuso).
struct ExtraUsage: Codable {
    let used_credits: Double?
    let monthly_limit: Double?
    let currency: String?
    let utilization: Double?
    let enabled: Bool?
}

/// The full state.json snapshot.
struct Snapshot: Codable {
    let updated_at: String?
    let status: String?
    let basis: String?          // "oauth" (datos reales) | "cost" (estimado local)
    let account_email: String?
    let account_uuid: String?
    let account_mismatch: Bool?   // cuenta fijada ≠ cuenta activa (guardia de identidad)
    let error: String?
    let five_hour: Bucket?
    let weekly: Bucket?
    let limits: [LimitEntry]?     // solo en oauth; la GUI filtra los weekly_scoped
    let spend: Spend?             // solo en oauth: dinero real de bolsillo
    let extra_usage: ExtraUsage?  // solo en oauth: overage
}

// MARK: - stats.json (uso local vía ccusage)

struct Stats: Codable {
    let updated_at: String?
    let days: [StatsDay]?
    let models: [StatsModel]?
    let projects: [StatsProject]?
    let summary: StatsSummary?
}

struct StatsDay: Codable {
    let date: String?
    let in_tok: Double?
    let out_tok: Double?
    let tokens: Double?
    let cost: Double?
    let models: [DayModel]?
    let projects: [DayProject]?
}

struct DayModel: Codable {
    let model: String?
    let tokens: Double?
}

struct DayProject: Codable {
    let project: String?
    let tokens: Double?
}

struct StatsModel: Codable {
    let model: String?
    let in_tok: Double?
    let out_tok: Double?
    let cost: Double?
    let tot: Double?
    let pct: Double?
}

/// Claude-only usage by project folder (~/.claude/projects/<slug>) — a subset
/// of the Modelos tab's totals, which also count other locally-detected agent
/// CLIs (e.g. Gemini) that ccusage aggregates alongside Claude Code.
struct StatsProject: Codable {
    let project: String?
    let in_tok: Double?
    let out_tok: Double?
    let tot: Double?
    let pct: Double?
}

struct StatsSummary: Codable {
    let total_tokens: Double?
    let total_cost: Double?
    let active_days: Int?
    let favorite_model: String?
    let sessions: Double?
    let messages: Double?
    let peak_hour: Int?
}

/// A single day cell of the GitHub-style heatmap.
struct HeatCell: Identifiable {
    let id: Int
    let tokens: Double
}

// MARK: - Model

/// Reads the cache files every refresh tick and exposes derived view state.
/// Mirrors the logic of the Plasma plasmoid (main.qml) so the two ports behave
/// identically.
final class QuotaModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var stats: Stats?
    @Published var loadError: String?

    /// ~/Library/Caches/claude-quota/state.json — same path the fetch script writes.
    static var stateURL: URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cache.appendingPathComponent("claude-quota/state.json")
    }
    /// ~/Library/Caches/claude-quota/stats.json — local ccusage breakdown.
    static var statsURL: URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cache.appendingPathComponent("claude-quota/stats.json")
    }

    /// Reload from disk. On read/parse failure of state.json we keep the last good
    /// snapshot (so a mid-write torn read doesn't blank the UI) but record the error.
    /// stats.json is best-effort: absent/broken just leaves `stats` untouched.
    func reload() {
        do {
            let data = try Data(contentsOf: Self.stateURL)
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        if let data = try? Data(contentsOf: Self.statsURL),
           let s = try? JSONDecoder().decode(Stats.self, from: data) {
            stats = s
        }
    }

    // MARK: - Derived state (parallels main.qml)

    var statusKey: String {
        if loadError != nil && snapshot == nil { return "error" }
        guard let snap = snapshot else { return "error" }
        if snap.error != nil { return "error" }
        return snap.status ?? "error"
    }

    var fivePct: Double? { snapshot?.five_hour?.percent }
    var weekPct: Double? { snapshot?.weekly?.percent }

    /// Límites semanales acotados a UN modelo (weekly_scoped con modelo) — se
    /// renderizan dinámicamente, sin hardcodear modelos. Paralelo a main.qml.
    var scopedLimits: [LimitEntry] {
        (snapshot?.limits ?? []).filter { $0.kind == "weekly_scoped" && $0.model != nil }
    }

    /// Tooltip mirroring toolTipMainText: "Claude: 5h N% · 7d M%".
    var tooltip: String {
        if statusKey == "error" { return "Claude Limits — sin datos" }
        let five = fivePct.map { "\(Int($0.rounded()))%" } ?? "—"
        let wk   = weekPct.map { "\(Int($0.rounded()))%" } ?? "—"
        let warn = accountMismatch ? " ⚠ otra cuenta" : ""
        return "Claude: 5h \(five) · 7d \(wk)\(warn)"
    }

    /// Whether the active account differs from the pinned one (account guard).
    var accountMismatch: Bool { snapshot?.account_mismatch ?? false }

    /// Age of the snapshot in seconds, or nil if unknown/unparseable.
    var ageSeconds: Double? {
        guard let iso = snapshot?.updated_at,
              let date = RelativeTime.parse(iso) else { return nil }
        return -date.timeIntervalSinceNow
    }

    /// ¿Alguna ventana (5h / semanal) YA pasó su reset? Si sí, el % cacheado es viejo (debería
    /// haber bajado) → conviene refrescar aunque el caché no haya llegado al piso de 5 min.
    var anyResetPassed: Bool {
        RelativeTime.isPast(snapshot?.five_hour?.resets_at)
            || RelativeTime.isPast(snapshot?.weekly?.resets_at)
    }

    /// Footer of the Límites tab (correo · ⟳ 5 min + al reset 5h · últ. act. hace: …).
    var footerText: String {
        if let err = loadError, snapshot == nil { return "error: \(err)" }
        guard let snap = snapshot else { return "cargando…" }
        if let err = snap.error { return "error: \(err)" }
        let account = snap.account_email ?? (snap.basis == "oauth" ? "datos reales" : "estimado local")
        if snap.account_mismatch == true {
            return "⚠ \(account) no es la cuenta fijada · ⟳ 5 min + al reset 5h · act. hace: \(RelativeTime.compactReset(snap.updated_at))"
        }
        return "\(account) · ⟳ 5 min + al reset 5h · últ. act. hace: \(RelativeTime.compactReset(snap.updated_at))"
    }

    // MARK: - stats-derived helpers

    /// Palette assigned by index into stats.models (already sorted desc by tot).
    static let modelPalette = ["#e8884a", "#5b9bd5", "#9b6dd6", "#5fb98e", "#d6a15b", "#c96daa"]

    func modelColor(_ name: String?) -> Color {
        Color(hex: modelHex(name))
    }
    func modelHex(_ name: String?) -> String {
        guard let models = stats?.models, let name else { return Self.modelPalette[0] }
        for (i, m) in models.enumerated() where m.model == name {
            return Self.modelPalette[i % Self.modelPalette.count]
        }
        return Self.modelPalette[0]
    }

    func projectColor(_ name: String?) -> Color {
        Color(hex: projectHex(name))
    }
    func projectHex(_ name: String?) -> String {
        guard let projects = stats?.projects, let name else { return Self.modelPalette[0] }
        for (i, p) in projects.enumerated() where p.project == name {
            return Self.modelPalette[i % Self.modelPalette.count]
        }
        return Self.modelPalette[0]
    }

    var maxDayTokens: Double {
        guard let days = stats?.days, !days.isEmpty else { return 1 }
        return max(1, days.map { $0.tokens ?? 0 }.max() ?? 1)
    }

    // rachas (días consecutivos con uso), port de streaks{} en main.qml
    var streaks: (cur: Int, max: Int) {
        guard let days = stats?.days, !days.isEmpty else { return (0, 0) }
        var active = Set<String>()
        for d in days {
            if let date = d.date, (d.tokens ?? 0) > 0 { active.insert(date) }
        }
        if active.isEmpty { return (0, 0) }

        let cal = Fmt.utcCalendar
        let df = Fmt.dayFormatter
        let dates = active.compactMap { df.date(from: $0) }.sorted()

        var longest = 0, run = 0
        var prev: Date? = nil
        for t in dates {
            if let p = prev, cal.dateComponents([.day], from: p, to: t).day == 1 { run += 1 }
            else { run = 1 }
            longest = max(longest, run)
            prev = t
        }

        var cur = 0
        var d = df.date(from: df.string(from: Date()))!   // hoy, truncado a día UTC
        if !active.contains(df.string(from: d)) {
            d = cal.date(byAdding: .day, value: -1, to: d)!
        }
        while active.contains(df.string(from: d)) {
            cur += 1
            d = cal.date(byAdding: .day, value: -1, to: d)!
        }
        return (cur, longest)
    }

    /// GitHub-style heatmap: continuous range from the first day with data,
    /// week-aligned starting on the Sunday of that first week. Column-major.
    func heatmapCells() -> [HeatCell] {
        guard let days = stats?.days, !days.isEmpty else { return [] }
        let cal = Fmt.utcCalendar
        let df = Fmt.dayFormatter
        var m = [String: Double]()
        var minD: Date? = nil, maxD: Date? = nil
        for d in days {
            guard let ds = d.date, let dt = df.date(from: ds) else { continue }
            m[ds] = d.tokens ?? 0
            if minD == nil || dt < minD! { minD = dt }
            if maxD == nil || dt > maxD! { maxD = dt }
        }
        guard let minDate = minD, let maxDate = maxD else { return [] }
        // retroceder al domingo de la semana del primer día (weekday 1 = domingo)
        let weekday = cal.component(.weekday, from: minDate)
        var cur = cal.date(byAdding: .day, value: -(weekday - 1), to: minDate)!
        var cells: [HeatCell] = []
        var i = 0
        while cur <= maxDate {
            cells.append(HeatCell(id: i, tokens: m[df.string(from: cur)] ?? 0))
            i += 1
            cur = cal.date(byAdding: .day, value: 1, to: cur)!
        }
        return cells
    }
}

// MARK: - Formato / color (ports de las funciones de main.qml)

/// pctColor: null → gris; >90 → rojo (throttle); resto → naranja acento.
func pctHex(_ p: Double?) -> String {
    guard let p else { return "#777777" }
    return p > 90 ? "#dc3545" : "#e8884a"
}
func pctColor(_ p: Double?) -> Color { Color(hex: pctHex(p)) }

enum Fmt {
    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = utcCalendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Hora local corta "HH:mm" (para el sello "leído …" del Cerebro).
    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
    static func clock(_ d: Date) -> String { clockFormatter.string(from: d) }

    /// fmtTok: 1.2M / 3.4k / entero.
    static func tok(_ n: Double?) -> String {
        guard let n else { return "—" }
        if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
        if n >= 1e3 { return String(format: "%.1fk", n / 1e3) }
        return "\(Int(n.rounded()))"
    }

    /// fmtInt: separador de miles con coma.
    static func int(_ n: Double?) -> String {
        guard let n else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: n.rounded())) ?? "\(Int(n.rounded()))"
    }

    /// fmtMoney: "$5.35" (used/cap ya vienen divididos por 10^exponent).
    static func money(_ v: Double?, _ currency: String?) -> String {
        guard let v else { return "—" }
        let sym = currency == "USD" ? "$" : (currency.map { "\($0) " } ?? "$")
        return String(format: "\(sym)%.2f", v)
    }

    /// fmtHour: "9 p.m.", 12 → "12 a.m." / "12 p.m." (-1 → "—").
    static func hour(_ h: Int?) -> String {
        guard let h, h >= 0 else { return "—" }
        let ampm = h < 12 ? "a.m." : "p.m."
        var hh = h % 12
        if hh == 0 { hh = 12 }
        return "\(hh) \(ampm)"
    }

    /// prettyModel: quita "claude-", capitaliza familia, junta versiones con "."
    /// descartando sellos de fecha (≥6 dígitos). "claude-opus-4-8" → "Opus 4.8".
    static func prettyModel(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "—" }
        let parts = id.replacingOccurrences(of: "^claude-", with: "", options: .regularExpression)
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = parts.first, !first.isEmpty else { return "—" }
        let fam = first.prefix(1).uppercased() + first.dropFirst()
        // "claude-opus-4-8"->"Opus 4.8"; "gemini-3.1-pro-preview"->"Gemini 3.1 Pro".
        // Enteros consecutivos se unen con "." (estilo Claude); un segmento ya
        // punteado ("3.1") se toma tal cual; palabras (pro/flash) se capitalizan;
        // se descarta ruido (preview/exp/latest) y sellos de fecha (>=6 dígitos).
        let noise: Set<String> = ["preview", "exp", "latest"]
        var tokens: [String] = []
        var nums: [String] = []
        func flush() { if !nums.isEmpty { tokens.append(nums.joined(separator: ".")); nums = [] } }
        loop: for i in 1..<parts.count {
            let p = parts[i]
            if !p.isEmpty && p.allSatisfy({ $0.isNumber }) {
                if p.count >= 6 { break loop }   // sello de fecha tipo 20251001
                nums.append(p)
            } else if p.range(of: "^[0-9]+\\.[0-9]+$", options: .regularExpression) != nil {
                flush(); tokens.append(p)         // versión ya punteada, p.ej. 3.1
            } else if !p.isEmpty && !noise.contains(p.lowercased()) {
                flush(); tokens.append(p.prefix(1).uppercased() + p.dropFirst())
            }
        }
        flush()
        return tokens.isEmpty ? fam : "\(fam) \(tokens.joined(separator: " "))"
    }
}

/// Formatea un timestamp ISO-8601 como texto relativo en español.
/// relative(): "hace 2min" / "en 3h"; compactReset(): solo magnitud ("5min"/"3h"/"2d").
enum RelativeTime {
    // ccusage's 5h block usa fracciones ("…T06:00:00.000Z"); el límite semanal no.
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return withFraction.date(from: iso) ?? plain.date(from: iso)
    }

    static func relative(_ iso: String?) -> String {
        guard let iso else { return "" }
        guard let date = parse(iso) else { return iso }
        let diff = Int(date.timeIntervalSinceNow.rounded())
        let abs = Swift.abs(diff)
        let val: Int
        let unit: String
        // Math.round como el QML (90 min -> "2h", no "1h")
        switch abs {
        case ..<60:    val = abs;                                unit = "s"
        case ..<3600:  val = Int((Double(abs) / 60).rounded());  unit = "min"
        case ..<86400: val = Int((Double(abs) / 3600).rounded()); unit = "h"
        default:       val = Int((Double(abs) / 86400).rounded()); unit = "d"
        }
        return diff < 0 ? "hace \(val)\(unit)" : "en \(val)\(unit)"
    }

    /// ¿El instante ya pasó? (resets_at en el pasado → la ventana ya se reinició y el % cacheado es viejo).
    static func isPast(_ iso: String?) -> Bool {
        guard let date = parse(iso) else { return false }
        return date.timeIntervalSinceNow < 0
    }

    static func compactReset(_ iso: String?) -> String {
        guard let iso else { return "" }
        guard let date = parse(iso) else { return "" }
        let abs = Swift.abs(Int(date.timeIntervalSinceNow.rounded()))
        if abs < 3600  { return "\(Int((Double(abs) / 60).rounded()))min" }
        if abs < 86400 { return "\(Int((Double(abs) / 3600).rounded()))h" }
        return "\(Int((Double(abs) / 86400).rounded()))d"
    }
}

// MARK: - Color/NSColor desde hex "#rrggbb"

extension Color {
    init(hex: String) {
        let (r, g, b) = hexRGB(hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let (r, g, b) = hexRGB(hex)
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

private func hexRGB(_ hex: String) -> (Double, Double, Double) {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    return (Double((v >> 16) & 0xff) / 255.0,
            Double((v >> 8) & 0xff) / 255.0,
            Double(v & 0xff) / 255.0)
}
