import AppKit
import SwiftUI

// Shunt menubar mark — "Turnout (top-down)".
//
// A railway switch as seen from above: two parallel horizontal rails with a
// short diagonal connector that diverts traffic from one to the other. The
// switch-point dot sits at the diagonal's midpoint.
//
// Horizontal composition, symmetric on the horizontal axis. No vertical
// elongation, no ambiguous silhouette. The silhouette reads as "two tracks"
// instantly, and the diagonal + dot communicates "switch" without needing
// to know the metaphor.
//
// Idle: all four elements at labelColor, isTemplate=true.
// Routing: top rail recedes; bottom rail + diagonal + switch dot adopt the
// theme accent; a terminus cap at the right end of the bottom rail adopts
// the theme status-active color.

enum MenubarIcons {

    /// 18×18pt monochrome template. Follows menubar theme color.
    static func idle() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            drawMark(
                topRailColor: .black,
                bottomRailColor: .black,
                diagonalColor: .black,
                switchDotColor: .black,
                terminusCap: nil
            )
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Shunt — idle"
        return image
    }

    /// 18×18pt colored. Top rail recedes (main route, traffic not diverted);
    /// bottom rail + diagonal + switch dot take the theme accent; terminus cap
    /// at right end of bottom rail adopts theme status-active.
    static func routing(accent: NSColor, statusActive: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let recede = NSColor.labelColor.withAlphaComponent(0.40)
            drawMark(
                topRailColor: recede,
                bottomRailColor: accent,
                diagonalColor: accent,
                switchDotColor: accent,
                terminusCap: statusActive
            )
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Shunt — routing"
        return image
    }

    /// Convenience: render routing() using a ShuntTheme.
    static func routing(theme: ShuntTheme) -> NSImage {
        // Menubar background is fixed by macOS, so themes whose light accent
        // is near-black (Chassis) must use their dark variant for legibility.
        let useDark = theme.id == "chassis"
        let accent = useDark ? theme.accentDark : theme.accentLight
        let live = useDark ? theme.statusActiveDark : theme.statusActiveLight
        return routing(
            accent: NSColor(accent),
            statusActive: NSColor(live)
        )
    }

    // MARK: - Drawing

    /// Draws the top-down turnout. Coordinates are expressed in the 18-pt
    /// top-left-origin space; Y is flipped here to AppKit's bottom-left
    /// origin.
    private static func drawMark(
        topRailColor: NSColor,
        bottomRailColor: NSColor,
        diagonalColor: NSColor,
        switchDotColor: NSColor,
        terminusCap: NSColor?
    ) {
        let railStroke: CGFloat = 2.6
        let diagonalStroke: CGFloat = 2.2

        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x, y: 18 - y)
        }

        // 1. Top rail (main line, horizontal)
        topRailColor.setStroke()
        let topRail = NSBezierPath()
        topRail.move(to: pt(2, 6))
        topRail.line(to: pt(16, 6))
        topRail.lineWidth = railStroke
        topRail.lineCapStyle = .round
        topRail.stroke()

        // 2. Bottom rail (diverted line, horizontal)
        bottomRailColor.setStroke()
        let bottomRail = NSBezierPath()
        bottomRail.move(to: pt(2, 12))
        bottomRail.line(to: pt(16, 12))
        bottomRail.lineWidth = railStroke
        bottomRail.lineCapStyle = .round
        bottomRail.stroke()

        // 3. Switch diagonal — connects top rail to bottom rail (the physical
        //    switch that lets traffic transfer). Slightly thinner than rails
        //    so it reads as a connector, not a third track.
        diagonalColor.setStroke()
        let diagonal = NSBezierPath()
        diagonal.move(to: pt(8, 6))
        diagonal.line(to: pt(11, 12))
        diagonal.lineWidth = diagonalStroke
        diagonal.lineCapStyle = .round
        diagonal.stroke()

        // 4. Switch-point dot at the diagonal's midpoint
        switchDotColor.setFill()
        let dotR: CGFloat = 2.0
        let switchRect = NSRect(
            x: 9.5 - dotR, y: (18 - 9) - dotR,
            width: dotR * 2, height: dotR * 2
        )
        NSBezierPath(ovalIn: switchRect).fill()

        // 5. Active-state terminus cap at the right end of the bottom rail.
        if let cap = terminusCap {
            cap.setFill()
            let capR: CGFloat = 1.8
            let capRect = NSRect(
                x: 16 - capR, y: (18 - 12) - capR,
                width: capR * 2, height: capR * 2
            )
            NSBezierPath(ovalIn: capRect).fill()
        }
    }
}
