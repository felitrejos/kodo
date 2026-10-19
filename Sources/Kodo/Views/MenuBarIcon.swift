import AppKit

/// Kodo's menu bar glyph: the taiko drum from the app icon, drawn as a template image so
/// macOS tints it like any other menu bar icon.
@MainActor
enum MenuBarIcon {
    enum Style {
        /// Speaker Sync playing.
        case filled
        case outlined
        case muted
    }

    private static let size = NSSize(width: 18, height: 18)
    private static let cache: [Style: NSImage] = [
        .filled: draw(.filled),
        .outlined: draw(.outlined),
        .muted: draw(.muted),
    ]

    static func image(_ style: Style) -> NSImage {
        cache[style] ?? draw(style)
    }

    private static func draw(_ style: Style) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let body = drumBody(closed: style == .filled)
            let head = NSBezierPath(ovalIn: NSRect(x: 3, y: 7.4, width: 12, height: 3))
            // The sticks rest on the rim, crossing above the head.
            let sticks = NSBezierPath()
            sticks.move(to: NSPoint(x: 4.2, y: 1.6))
            sticks.line(to: NSPoint(x: 12.2, y: 6.6))
            sticks.move(to: NSPoint(x: 13.8, y: 1.6))
            sticks.line(to: NSPoint(x: 5.8, y: 6.6))
            sticks.lineCapStyle = .round

            if style == .filled {
                body.fill()
                head.fill()
                // A thin cut between the head and the body keeps the drum readable when solid.
                cut(head, width: 1.1)
            } else {
                body.lineWidth = 1.3
                body.stroke()
                head.lineWidth = 1.3
                head.stroke()
            }

            // A hairline of room around the sticks keeps them distinct from the rim.
            cut(sticks, width: 2.8)
            sticks.lineWidth = 1.6
            sticks.stroke()

            if style == .muted {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2, y: 2))
                slash.line(to: NSPoint(x: 16, y: 16))
                slash.lineCapStyle = .round
                cut(slash, width: 3.6)
                slash.lineWidth = 1.5
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Kodo"
        return image
    }

    /// A gently bulging barrel, like the logo's drum, from the head down.
    /// Open at the top when outlined, so no line runs across the head.
    private static func drumBody(closed: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 3, y: 8.9))
        path.curve(to: NSPoint(x: 4.2, y: 16.2), controlPoint1: NSPoint(x: 2, y: 11.5), controlPoint2: NSPoint(x: 2.6, y: 15.1))
        path.curve(to: NSPoint(x: 13.8, y: 16.2), controlPoint1: NSPoint(x: 6.6, y: 17.4), controlPoint2: NSPoint(x: 11.4, y: 17.4))
        path.curve(to: NSPoint(x: 15, y: 8.9), controlPoint1: NSPoint(x: 15.4, y: 15.1), controlPoint2: NSPoint(x: 16, y: 11.5))
        if closed {
            path.close()
        }
        path.lineCapStyle = .round
        return path
    }

    private static func cut(_ path: NSBezierPath, width: CGFloat) {
        guard let context = NSGraphicsContext.current else {
            return
        }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        let original = path.lineWidth
        path.lineWidth = width
        path.stroke()
        path.lineWidth = original
        context.restoreGraphicsState()
    }
}
