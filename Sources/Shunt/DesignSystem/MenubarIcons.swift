import AppKit

// Shunt design system — menubar icon rendering.
// Draws the railway-shunt mark inline via NSBezierPath so we don't ship a
// separate PNG asset. Two states: idle (monochrome template that follows
// menubar theme) and routing (Signal Amber siding + PCB Green live dot).

enum MenubarIcons {
    /// 18×18pt, monochrome, isTemplate=true. Follows menubar theme color.
    static func idle() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            drawMark(
                mainRailsColor: .black,
                sidingColor: .black,
                switchDotColor: .black,
                liveDot: nil
            )
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Shunt — idle"
        return image
    }

    /// 18×18pt, colored. Signal Amber siding + PCB Green "live" dot. Not a
    /// template — the tint persists regardless of menubar theme so the active
    /// state is unambiguous.
    static func routing() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Main rails stay in a soft neutral so they don't compete with the
            // amber siding. Use labelColor so it still adapts to theme.
            drawMark(
                mainRailsColor: NSColor.labelColor.withAlphaComponent(0.55),
                sidingColor: NSColor(red: 232/255, green: 134/255, blue: 15/255, alpha: 1),
                switchDotColor: NSColor(red: 232/255, green: 134/255, blue: 15/255, alpha: 1),
                liveDot: NSColor(red: 34/255, green: 197/255, blue: 94/255, alpha: 1)
            )
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Shunt — routing"
        return image
    }

    /// Draws the railway shunt mark onto the current NSGraphicsContext at 18×18.
    ///
    /// Geometry is a simplified version of Resources/Icon-compact.svg, rescaled
    /// to 18×18 drawing coordinates.
    private static func drawMark(
        mainRailsColor: NSColor,
        sidingColor: NSColor,
        switchDotColor: NSColor,
        liveDot: NSColor?
    ) {
        // Note: NSImage drawing origin is bottom-left, but our geometry is
        // conceptually top-left. Flip y via (18 - y) for each point.

        // Stroke widths scaled for 18pt canvas.
        let railWidth: CGFloat = 1.6
        let sidingWidth: CGFloat = 1.6

        // Main rails — two parallel horizontal lines
        mainRailsColor.setStroke()
        for y: CGFloat in [6.5, 10.5] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 2, y: y))
            path.line(to: NSPoint(x: 16, y: y))
            path.lineWidth = railWidth
            path.lineCapStyle = .round
            path.stroke()
        }

        // Siding — two parallel curves diverging upward-right
        sidingColor.setStroke()
        let siding1 = NSBezierPath()
        siding1.move(to: NSPoint(x: 8, y: 10.5))      // from top rail at switch
        siding1.curve(
            to: NSPoint(x: 16, y: 16),
            controlPoint1: NSPoint(x: 11, y: 13),
            controlPoint2: NSPoint(x: 14, y: 15.5)
        )
        siding1.lineWidth = sidingWidth
        siding1.lineCapStyle = .round
        siding1.stroke()

        let siding2 = NSBezierPath()
        siding2.move(to: NSPoint(x: 9.5, y: 6.5))     // from bottom rail at switch
        siding2.curve(
            to: NSPoint(x: 16.5, y: 13),
            controlPoint1: NSPoint(x: 12.5, y: 9),
            controlPoint2: NSPoint(x: 15, y: 12)
        )
        siding2.lineWidth = sidingWidth
        siding2.lineCapStyle = .round
        siding2.stroke()

        // Switch point marker (amber dot at the junction)
        switchDotColor.setFill()
        let switchRect = NSRect(x: 7.5, y: 7.7, width: 2.6, height: 2.6)
        NSBezierPath(ovalIn: switchRect).fill()

        // Live dot — reserved for routing state
        if let live = liveDot {
            live.setFill()
            let liveRect = NSRect(x: 14.6, y: 14.6, width: 3.0, height: 3.0)
            NSBezierPath(ovalIn: liveRect).fill()
        }
    }
}
