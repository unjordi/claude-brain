import AppKit
import SwiftUI

/// Owns the menu-bar status item and the popover. Polls the cache files every
/// 10s (the plasmoid's cadence) and redraws the two-row pill; the launchd agent
/// does the actual ccusage fetch on its own 5-minute floor, and the popover's
/// "Actualizar ahora" button can force one on demand.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = QuotaModel()
    private var timer: Timer?
    private var fetching = false

    // The launchd agent refreshes every 5 min, but its StartInterval doesn't
    // reliably catch up after the machine sleeps. If the cache is older than
    // this, the app kicks off its own fetch — only ever when already stale, so
    // the 5-minute polling floor is preserved.
    private let staleThreshold: Double = 330  // 5.5 min
    private lazy var fetchScript = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/claude-brain-fetch").path

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 520, height: 420)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model, onRefresh: { [weak self] in self?.forceFetch() })
        )

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        model.reload()
        // Avisos del cerebro para la píldora (sin abrir el popover): 🩹 si le falta una pieza,
        // ⬆ si hay versión nueva. El estado del cerebro se lee del ~/.claude real (barato); el de
        // update se leyó en el último chequeo (se refresca abajo, throttle 15 min).
        let heal = !BrainInspector.inspect().isComplete
        // refresh() siempre corre en main (applicationDidFinishLaunching / Timer / main.async);
        // assumeIsolated deja leer la propiedad @MainActor del Updater sin marcar toda la clase.
        let updateAvail = MainActor.assumeIsolated { Updater.shared.updateAvailable }
        if let button = statusItem.button {
            let five = PillImage.RowData(label: "5h",
                                         pct: model.fivePct,
                                         reset: model.snapshot?.five_hour?.resets_at)
            let week = PillImage.RowData(label: "7d",
                                         pct: model.weekPct,
                                         reset: model.snapshot?.weekly?.resets_at)
            button.image = PillImage.render(five: five, week: week,
                                            hasError: model.statusKey == "error",
                                            update: updateAvail, heal: heal,
                                            appearance: button.effectiveAppearance)
            var tip = model.tooltip
            if heal { tip += " · 🩹 al cerebro le falta una pieza" }
            if updateAvail { tip += " · ⬆ actualización disponible" }
            button.toolTip = tip
        }
        // Refresca si el caché superó el piso de 5.5 min, O si una ventana YA pasó su reset (el %
        // cacheado quedó viejo) y el caché tiene >60s — así el 100% no se queda pegado tras el reset.
        if let age = model.ageSeconds, age > staleThreshold || (model.anyResetPassed && age > 60) { runFetch() }
        Task { @MainActor in await Updater.shared.checkIfStale() }
    }

    /// Force a real fetch regardless of cache age (from the popover button).
    private func forceFetch() { runFetch() }

    /// Run the fetch script off the main thread; reload the UI when it finishes.
    /// Guarded so only one fetch is ever in flight.
    private func runFetch() {
        guard !fetching, FileManager.default.isExecutableFile(atPath: fetchScript) else { return }
        fetching = true
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [fetchScript]
        // GUI apps inherit a minimal PATH; the script needs jq + ccusage/npx.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        proc.environment = env
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.fetching = false
                self?.refresh()
            }
        }
        do { try proc.run() } catch { fetching = false }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.reload()
            // Refresca si el caché superó el piso de 5.5 min, O si una ventana YA pasó su reset (el %
        // cacheado quedó viejo) y el caché tiene >60s — así el 100% no se queda pegado tras el reset.
        if let age = model.ageSeconds, age > staleThreshold || (model.anyResetPassed && age > 60) { runFetch() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
