import AppKit
import SwiftUI

// Shunt menubar mark — switch diagram silhouette (18×18 viewBox).
//
// Geometry per design-handoff 2026-04-27:
//   Top rail:    (2, 6) → (16, 6),   stroke 1.8, round caps
//   Bottom rail: (2, 12) → (16, 12), stroke 1.8, round caps
//   Switch link: quad (6, 6) ⌒ (9, 9) ⌒ (12, 12), stroke 1.8
//
// Idle (template): all strokes at 70% currentColor — macOS handles
// dark-mode inversion automatically because `isTemplate = true`.
//
// Active (non-template): all strokes full opacity in accent color,
// plus filled signal-color circles (r=1.4) at the switch endpoints
// (6,6) and (12,12).
//
// Pending: same as routing, with a pulsing alpha on the LED dots so
// the icon reads as "working" rather than fully "live".

enum MenubarIcons {

    /// 18×18 template image. All strokes at 70% black; macOS inverts in
    /// dark mode because `isTemplate = true`.
    static func idle() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            drawSwitch(strokeColor: NSColor.black.withAlphaComponent(0.7),
                       junctionColor: nil)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Shunt — idle"
        return image
    }

    /// 18×18 non-template image. Strokes resolved to current label color;
    /// junction circles in `statusActive` (signal) color.
    static func routing(accent: NSColor, statusActive: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            drawSwitch(strokeColor: accent, junctionColor: statusActive)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Shunt — routing"
        return image
    }

    /// Convenience: render routing() using a ShuntTheme. Re-rendered by
    /// AppDelegate when system appearance flips.
    static func routing(theme: ShuntTheme) -> NSImage {
        let isDark = NSApp?.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        let accent = isDark ? theme.accentDark : theme.accentLight
        return routing(
            accent: NSColor(accent),
            statusActive: NSColor(theme.signal)
        )
    }

    /// Pulsing "working" state — same silhouette, junction LEDs at the
    /// caller-provided alpha so AppDelegate can sine-wave-pulse them while
    /// `ProxyActivity.shared.busy`.
    static func pending(theme: ShuntTheme, ledAlpha: CGFloat = 1.0) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Strokes in resolved label color (non-template; we re-render on
            // appearance flips via KVO in AppDelegate).
            let isDark = NSApp?.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua
            let stroke = isDark
                ? NSColor.white.withAlphaComponent(0.88)
                : NSColor.black.withAlphaComponent(0.85)
            let junction = NSColor(theme.signal).withAlphaComponent(ledAlpha)
            drawSwitch(strokeColor: stroke, junctionColor: junction)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Shunt — working"
        return image
    }

    // MARK: - Drawing

    /// Draws the switch silhouette: top rail, bottom rail, quadratic switch
    /// link, optional junction circles. Coordinates are in 18×18 top-left
    /// origin (Y flipped to AppKit's bottom-left origin).
    private static func drawSwitch(
        strokeColor: NSColor,
        junctionColor: NSColor?
    ) {
        let strokeW: CGFloat = 1.8

        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x, y: 18 - y)
        }

        strokeColor.setStroke()

        // Top rail
        let topRail = NSBezierPath()
        topRail.move(to: pt(2, 6))
        topRail.line(to: pt(16, 6))
        topRail.lineWidth = strokeW
        topRail.lineCapStyle = .round
        topRail.stroke()

        // Bottom rail
        let bottomRail = NSBezierPath()
        bottomRail.move(to: pt(2, 12))
        bottomRail.line(to: pt(16, 12))
        bottomRail.lineWidth = strokeW
        bottomRail.lineCapStyle = .round
        bottomRail.stroke()

        // Switch link — quadratic (6,6) ⌒ (9,9) ⌒ (12,12)
        let switchLink = NSBezierPath()
        switchLink.move(to: pt(6, 6))
        switchLink.curve(
            to: pt(12, 12),
            // NSBezierPath.curve uses cubic; convert quadratic to cubic:
            // cp1 = start + 2/3*(quadCP - start),  cp2 = end + 2/3*(quadCP - end)
            controlPoint1: pt(6 + (2.0/3.0) * (9 - 6), 6 + (2.0/3.0) * (9 - 6)),
            controlPoint2: pt(12 + (2.0/3.0) * (9 - 12), 12 + (2.0/3.0) * (9 - 12))
        )
        switchLink.lineWidth = strokeW
        switchLink.lineCapStyle = .round
        switchLink.stroke()

        // Junction LEDs (active state only)
        if let junctionColor {
            junctionColor.setFill()
            let r: CGFloat = 1.4
            for (cx, cy) in [(6.0, 6.0), (12.0, 12.0)] {
                let rect = NSRect(
                    x: cx - r, y: (18 - cy) - r,
                    width: r * 2, height: r * 2
                )
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }
}
