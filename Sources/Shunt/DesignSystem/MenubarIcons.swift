import AppKit
import SwiftUI

// Shunt menubar mark — "Turnout (top-down)".
//
// A railway switch as seen from above: two parallel horizontal rails with a
// diagonal connector and a switch-point dot at the midpoint. The silhouette
// is identical in both states — what changes is the switch dot, which acts
// as the **indicator LED**:
//
// • **Idle**: full turnout in system label color (template image). The dot
//   sits small and subdued — the switch is present but not firing.
//
// • **Routing**: same turnout; rails/diagonal stay monochrome; the dot
//   grows and takes the theme accent color with a soft halo behind it. The
//   switch is *lit*.
//
// Keeping the silhouette constant and changing only one element ("the LED
// comes on") is the standard menubar pattern for state signalling — far
// less noisy than swapping the whole mark on every enable/disable.

enum MenubarIcons {

    /// 18×18pt monochrome template. Full turnout composition in system label
    /// color; switch-point dot is small and unlit.
    static func idle() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            drawTurnout(
                railColor: .black,
                diagonalColor: .black,
                switchDotColor: .black,
                switchDotHalo: nil,
                switchDotRadius: 1.7,
                topRailAlpha: 1.0
            )
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Shunt — idle"
        return image
    }

    /// 18×18pt coloured. **Silhouette is identical to `idle()`** — the same
    /// monochrome turnout — with one added element: a status LED in the
    /// bottom-right corner, drawn in the theme's **`statusActive`** color
    /// (the "live signal" hue — green in most themes, cyan in Chassis). The
    /// LED is noticeably larger than the central switch-point dot. The base
    /// icon is the app's identity; the LED is the state indicator.
    static func routing(accent: NSColor, statusActive: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Base turnout in the resolved label color (non-template image
            // can't auto-tint on appearance changes — we re-render on
            // effectiveAppearance KVO in AppDelegate).
            let rails = resolvedLabelColor()
            drawTurnout(
                railColor: rails,
                diagonalColor: rails,
                switchDotColor: rails,
                switchDotHalo: nil,
                switchDotRadius: 1.7,
                topRailAlpha: 1.0
            )
            drawCornerLED(color: statusActive)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Shunt — routing"
        return image
    }

    /// Convenience: render routing() using a ShuntTheme, resolving the
    /// accent + statusActive variants against the current system
    /// appearance. `AppDelegate` re-renders the icon when appearance flips
    /// (KVO on `effectiveAppearance`).
    static func routing(theme: ShuntTheme) -> NSImage {
        let isDark = NSApp?.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        let accent = isDark ? theme.accentDark : theme.accentLight
        let live = isDark ? theme.statusActiveDark : theme.statusActiveLight
        return routing(
            accent: NSColor(accent),
            statusActive: NSColor(live)
        )
    }

    // MARK: - Drawing

    /// Pick a rail color that reads against the menubar: near-black in light
    /// appearance, near-white in dark. We can't use `NSColor.labelColor`
    /// directly here because the routing image is non-template, so the
    /// system won't re-tint it on appearance changes — we resolve concretely
    /// at paint time. `AppDelegate` observes `effectiveAppearance` and
    /// re-renders the icon when it flips.
    private static func resolvedLabelColor() -> NSColor {
        let isDark = NSApp?.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        return isDark
            ? NSColor.white.withAlphaComponent(0.88)
            : NSColor.black.withAlphaComponent(0.85)
    }

    /// Accent-coloured "status LED" dot in the bottom-right corner of the
    /// 18-pt canvas. Drawn on top of the turnout in the routing state only.
    /// Larger than the central switch-point dot (r=3.0 vs 1.7) so it reads
    /// immediately as a separate indicator element.
    private static func drawCornerLED(color: NSColor) {
        color.setFill()
        let r: CGFloat = 3.0
        let centerX: CGFloat = 14.0
        let centerY: CGFloat = 14.5     // visual (top-left) Y
        let rect = NSRect(
            x: centerX - r,
            y: (18 - centerY) - r,
            width: r * 2,
            height: r * 2
        )
        NSBezierPath(ovalIn: rect).fill()
    }

    /// Draws the full top-down turnout: two horizontal rails, a diagonal
    /// switch connector, and the switch-point dot (optionally with a halo
    /// ring behind it). Coordinates are in 18-pt top-left-origin space;
    /// Y is flipped here to AppKit's bottom-left origin.
    ///
    /// `topRailAlpha` lets the caller lift the top rail off the primary
    /// hierarchy: full alpha reads as two equal tracks, lower alpha signals
    /// "this is the unused/main route" while the bottom rail stays dominant.
    private static func drawTurnout(
        railColor: NSColor,
        diagonalColor: NSColor,
        switchDotColor: NSColor,
        switchDotHalo: NSColor?,
        switchDotRadius: CGFloat,
        topRailAlpha: CGFloat
    ) {
        let railStroke: CGFloat = 2.6
        let diagonalStroke: CGFloat = 2.2

        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x, y: 18 - y)
        }

        // 1. Top rail (main line, horizontal)
        railColor.withAlphaComponent(topRailAlpha).setStroke()
        let topRail = NSBezierPath()
        topRail.move(to: pt(2, 6))
        topRail.line(to: pt(16, 6))
        topRail.lineWidth = railStroke
        topRail.lineCapStyle = .round
        topRail.stroke()

        // 2. Bottom rail (diverted line, horizontal)
        railColor.setStroke()
        let bottomRail = NSBezierPath()
        bottomRail.move(to: pt(2, 12))
        bottomRail.line(to: pt(16, 12))
        bottomRail.lineWidth = railStroke
        bottomRail.lineCapStyle = .round
        bottomRail.stroke()

        // 3. Switch diagonal — connects top rail to bottom rail. Slightly
        //    thinner than rails so it reads as a connector, not a third track.
        diagonalColor.setStroke()
        let diagonal = NSBezierPath()
        diagonal.move(to: pt(8, 6))
        diagonal.line(to: pt(11, 12))
        diagonal.lineWidth = diagonalStroke
        diagonal.lineCapStyle = .round
        diagonal.stroke()

        // 4. Switch-point dot at the diagonal's midpoint. Optional halo ring
        //    bleeds past the dot radius for the "LED is powered" feel in the
        //    routing state.
        let centerX: CGFloat = 9.5
        let centerY: CGFloat = 9
        if let halo = switchDotHalo {
            halo.setFill()
            let haloR = switchDotRadius + 1.6
            let haloRect = NSRect(
                x: centerX - haloR, y: (18 - centerY) - haloR,
                width: haloR * 2, height: haloR * 2
            )
            NSBezierPath(ovalIn: haloRect).fill()
        }
        switchDotColor.setFill()
        let dotRect = NSRect(
            x: centerX - switchDotRadius, y: (18 - centerY) - switchDotRadius,
            width: switchDotRadius * 2, height: switchDotRadius * 2
        )
        NSBezierPath(ovalIn: dotRect).fill()
    }
}
