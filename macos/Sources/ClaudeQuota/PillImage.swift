import AppKit

/// Renders the two-row menu-bar indicator (AppKit analogue of the plasmoid's
/// compactRepresentation): a "5h" row and a "7d" row, each = label + mini bar +
/// "N%" + "⟳{compactReset}". Height ≈ 22px (the usable menu-bar height); its
/// width measures to the actual rendered content so the status item never
/// collapses. isTemplate = false because it carries its own accent colors.
enum PillImage {
    struct RowData {
        let label: String
        let pct: Double?
        let reset: String?
    }

    private static let height: CGFloat = 22
    private static let barW: CGFloat = 30
    private static let barH: CGFloat = 4
    private static let gap: CGFloat = 3
    private static let labelFont = NSFont.systemFont(ofSize: 8, weight: .regular)
    private static let pctFont   = NSFont.systemFont(ofSize: 8, weight: .bold)
    private static let resetFont = NSFont.systemFont(ofSize: 7, weight: .regular)

    static func render(five: RowData, week: RowData, hasError: Bool,
                       update: Bool = false, heal: Bool = false,
                       appearance: NSAppearance?) -> NSImage {
        let rows = [five, week]

        // Column X where the label ends / the bar starts (aligned across rows).
        let labelW = ceil(rows.map { width($0.label, labelFont) }.max() ?? 8)
        let barX = labelW + gap
        let pctX = barX + barW + gap

        // Per-row trailing content (pct + optional reset) → total width.
        var maxWidth: CGFloat = pctX
        for r in rows {
            let pctW = ceil(width(pctText(r, hasError: hasError), pctFont))
            var w = pctX + pctW
            let rt = resetText(r)
            if !rt.isEmpty { w += gap + ceil(width(rt, resetFont)) }
            maxWidth = max(maxWidth, w)
        }
        // Reserva una columna a la derecha para los avisos del cerebro (🩹 falta pieza / ⬆ update),
        // para que la píldora te avise sin abrir el popover.
        let dotD: CGFloat = 6
        let anyDot = update || heal
        let totalW = ceil(maxWidth) + 2 + (anyDot ? dotD + 4 : 0)

        let image = NSImage(size: NSSize(width: totalW, height: height))
        let draw = {
            image.lockFocus()
            // Two rows: top row center y=15, bottom row center y=6 (2px inner margins).
            drawRow(rows[0], hasError: hasError, centerY: 15, barX: barX, pctX: pctX)
            drawRow(rows[1], hasError: hasError, centerY: 6,  barX: barX, pctX: pctX)
            // Avisos del cerebro a la derecha: 🩹 rojo (falta pieza) arriba, ⬆ naranja (update) abajo.
            if anyDot {
                let dx = totalW - dotD - 2
                if heal && update {
                    drawDot(x: dx, y: 12, d: dotD, hex: "#dc3545")
                    drawDot(x: dx, y: 3,  d: dotD, hex: "#e8884a")
                } else {
                    drawDot(x: dx, y: (height - dotD) / 2, d: dotD, hex: heal ? "#dc3545" : "#e8884a")
                }
            }
            image.unlockFocus()
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        image.isTemplate = false
        return image
    }

    // MARK: - drawing

    private static func drawRow(_ r: RowData, hasError: Bool, centerY: CGFloat,
                                barX: CGFloat, pctX: CGFloat) {
        let accent = NSColor(hex: pctHex(r.pct))

        // label
        drawText(r.label, font: labelFont,
                 color: NSColor.labelColor.withAlphaComponent(0.7),
                 x: 0, centerY: centerY)

        // mini bar (solo si hay dato)
        if let p = r.pct {
            let barY = centerY - barH / 2
            let bg = NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: barW, height: barH),
                                  xRadius: barH / 2, yRadius: barH / 2)
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            bg.fill()
            let fillW = barW * CGFloat(max(0, min(1, p / 100)))
            if fillW > 0 {
                let fg = NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: fillW, height: barH),
                                      xRadius: barH / 2, yRadius: barH / 2)
                accent.setFill()
                fg.fill()
            }
        }

        // "N%" (o "!"/"…")
        let pt = pctText(r, hasError: hasError)
        let pctW = drawText(pt, font: pctFont, color: accent, x: pctX, centerY: centerY)

        // "⟳{compactReset}"
        let rt = resetText(r)
        if !rt.isEmpty {
            drawText(rt, font: resetFont,
                     color: NSColor.labelColor.withAlphaComponent(0.55),
                     x: pctX + pctW + gap, centerY: centerY)
        }
    }

    private static func pctText(_ r: RowData, hasError: Bool) -> String {
        if let p = r.pct { return "\(Int(p.rounded()))%" }
        return hasError ? "!" : "…"
    }
    private static func resetText(_ r: RowData) -> String {
        guard let reset = r.reset, !reset.isEmpty, r.pct != nil else { return "" }
        let c = RelativeTime.compactReset(reset)
        return c.isEmpty ? "" : "⟳\(c)"
    }

    @discardableResult
    private static func drawText(_ s: String, font: NSFont, color: NSColor,
                                 x: CGFloat, centerY: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: NSPoint(x: x, y: centerY - sz.height / 2), withAttributes: attrs)
        return sz.width
    }

    private static func width(_ s: String, _ font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    /// Un puntito relleno (aviso del cerebro) en la píldora de la barra.
    private static func drawDot(x: CGFloat, y: CGFloat, d: CGFloat, hex: String) {
        NSColor(hex: hex).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
    }
}
