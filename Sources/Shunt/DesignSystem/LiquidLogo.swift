import SwiftUI

// Shunt mark — a literal railway-shunt diagram. Two horizontal rails joined
// by a diagonal switch link. Symmetric across the horizontal midline.
//
// Geometry (100×100 viewBox; spec source: design-handoff 2026-04-27):
//   Squircle chassis: rx = 28% of size, theme bg gradient (corner→corner).
//   Top rail:    (14, 36) → (86, 36), stroke width 9, round caps.
//   Bottom rail: (14, 64) → (86, 64), stroke width 9, round caps.
//   Switch link: quadratic (38, 36) ⌒ (50, 50) ⌒ (62, 64), width 9.
//   Inner glass highlight on each stroke: width 1.8, white @ 55% alpha.
//   Junction nodes: filled circles r=4.5 at (38, 36) and (62, 64), signal color,
//                   with a r=1.4 white-90% specular offset (-1.2, -1.2).
//   Bloom:    ellipse cx=50 cy=50, rx=34 ry=14, accent @ 22%, painted BEHIND
//             the rails as a soft highlight in the switch zone.
//   Gloss:    radial cx=0.32 cy=0.18 r=0.7, white 30%→0%, on top.
//   Hairline: 0.5px white-10% stroke, inset 0.5px, sealing the chassis.
//
// All three rail/switch strokes share a horizontal accent gradient:
//   accent @ 40% → accent @ 100% → accent2 @ 40%

struct ShuntLogo: View {
    let size: CGFloat
    let theme: ShuntTheme

    init(size: CGFloat, theme: ShuntTheme = .filament) {
        self.size = size
        self.theme = theme
    }

    var body: some View {
        Canvas { ctx, _ in
            let s = size
            let unit = s / 100.0
            let radius = s * 0.28

            // 1. Squircle chassis (corner-to-corner bg gradient)
            let chassisRect = CGRect(x: 0, y: 0, width: s, height: s)
            let chassisPath = Path(roundedRect: chassisRect, cornerRadius: radius, style: .continuous)
            ctx.fill(chassisPath, with: .linearGradient(
                Gradient(colors: [theme.bg0, theme.bg1]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: s, y: s)
            ))

            // 2. Bloom — ellipse behind the rails, in the switch zone
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 4 * unit))
                let bloomRect = CGRect(
                    x: (50 - 34) * unit, y: (50 - 14) * unit,
                    width: 68 * unit, height: 28 * unit
                )
                layer.fill(Path(ellipseIn: bloomRect),
                           with: .color(theme.accentDark.opacity(0.22)))
            }

            // 3. Three strokes (top rail, bottom rail, switch link), each with
            //    the same horizontal accent gradient + an inner glass highlight.
            let stroke = StrokeStyle(lineWidth: 9 * unit, lineCap: .round)
            let highlightStroke = StrokeStyle(lineWidth: 1.8 * unit, lineCap: .round)
            let highlightColor = Color.white.opacity(0.55)

            // Horizontal stroke gradient: accent@40% → accent@100% → accent2@40%
            let railShading: GraphicsContext.Shading = .linearGradient(
                Gradient(stops: [
                    .init(color: theme.accentDark.opacity(0.4), location: 0.0),
                    .init(color: theme.accentDark, location: 0.5),
                    .init(color: theme.accent2.opacity(0.4), location: 1.0)
                ]),
                startPoint: CGPoint(x: 14 * unit, y: 50 * unit),
                endPoint: CGPoint(x: 86 * unit, y: 50 * unit)
            )

            // Top rail
            var topRail = Path()
            topRail.move(to: CGPoint(x: 14 * unit, y: 36 * unit))
            topRail.addLine(to: CGPoint(x: 86 * unit, y: 36 * unit))
            ctx.stroke(topRail, with: railShading, style: stroke)

            // Bottom rail
            var botRail = Path()
            botRail.move(to: CGPoint(x: 14 * unit, y: 64 * unit))
            botRail.addLine(to: CGPoint(x: 86 * unit, y: 64 * unit))
            ctx.stroke(botRail, with: railShading, style: stroke)

            // Switch link
            var switchLink = Path()
            switchLink.move(to: CGPoint(x: 38 * unit, y: 36 * unit))
            switchLink.addQuadCurve(
                to: CGPoint(x: 62 * unit, y: 64 * unit),
                control: CGPoint(x: 50 * unit, y: 50 * unit)
            )
            ctx.stroke(switchLink, with: railShading, style: stroke)

            // Inner glass highlights — width 1.8, white 55%, painted on top
            // of the colored strokes. Drawn last so the highlights sit
            // cleanly atop the gradient.
            ctx.stroke(topRail, with: .color(highlightColor), style: highlightStroke)
            ctx.stroke(botRail, with: .color(highlightColor), style: highlightStroke)
            ctx.stroke(switchLink, with: .color(highlightColor), style: highlightStroke)

            // 4. Junction nodes (signal color) + specular highlight
            for (cx, cy) in [(38.0, 36.0), (62.0, 64.0)] {
                let nodeRect = CGRect(
                    x: (cx - 4.5) * unit, y: (cy - 4.5) * unit,
                    width: 9 * unit, height: 9 * unit
                )
                ctx.fill(Path(ellipseIn: nodeRect), with: .color(theme.signal))
                let specRect = CGRect(
                    x: (cx - 1.2 - 1.4) * unit, y: (cy - 1.2 - 1.4) * unit,
                    width: 2.8 * unit, height: 2.8 * unit
                )
                ctx.fill(Path(ellipseIn: specRect), with: .color(.white.opacity(0.9)))
            }

            // 5. Top gloss — radial highlight in upper-left of squircle
            let glossPath = Path(roundedRect: chassisRect, cornerRadius: radius, style: .continuous)
            ctx.fill(glossPath, with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0.30), location: 0.0),
                    .init(color: .white.opacity(0.05), location: 0.45),
                    .init(color: .white.opacity(0.0), location: 1.0)
                ]),
                center: CGPoint(x: 0.32 * s, y: 0.18 * s),
                startRadius: 0,
                endRadius: 0.7 * s
            ))

            // 6. Chassis hairline (sealed edge)
            let hairline = Path(roundedRect: chassisRect.insetBy(dx: 0.5, dy: 0.5),
                                cornerRadius: max(radius - 0.5, 0), style: .continuous)
            ctx.stroke(hairline, with: .color(.white.opacity(0.10)), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
    }
}

// Single-color silhouette for the menu bar (template image, 18×18 viewBox).
// Pure line art — no gradients, no glass. Tinted with theme accent + signal
// when "routing" is active; otherwise renders at 70% currentColor for the
// idle template look (macOS handles dark-mode inversion automatically).
struct ShuntGlyph: View {
    var size: CGFloat = 18
    var color: Color = .primary
    var accent: Color? = nil
    var signal: Color? = nil
    var dimmed: Bool = true   // true = idle (70% currentColor); false = active

    var body: some View {
        Canvas { ctx, _ in
            let unit = size / 18.0
            let strokeStyle = StrokeStyle(lineWidth: 1.8 * unit, lineCap: .round)

            // Idle: all strokes at 70% currentColor
            // Active: accent color full opacity + signal circles
            let strokeColor: Color = dimmed
                ? color.opacity(0.7)
                : (accent ?? color)

            // Top rail
            var topRail = Path()
            topRail.move(to: CGPoint(x: 2 * unit, y: 6 * unit))
            topRail.addLine(to: CGPoint(x: 16 * unit, y: 6 * unit))
            ctx.stroke(topRail, with: .color(strokeColor), style: strokeStyle)

            // Bottom rail
            var botRail = Path()
            botRail.move(to: CGPoint(x: 2 * unit, y: 12 * unit))
            botRail.addLine(to: CGPoint(x: 16 * unit, y: 12 * unit))
            ctx.stroke(botRail, with: .color(strokeColor), style: strokeStyle)

            // Switch link — quadratic (6,6) ⌒ (9,9) ⌒ (12,12)
            var switchLink = Path()
            switchLink.move(to: CGPoint(x: 6 * unit, y: 6 * unit))
            switchLink.addQuadCurve(
                to: CGPoint(x: 12 * unit, y: 12 * unit),
                control: CGPoint(x: 9 * unit, y: 9 * unit)
            )
            ctx.stroke(switchLink, with: .color(strokeColor), style: strokeStyle)

            // Active state: signal-colored junction dots
            if !dimmed, let sig = signal {
                let r: CGFloat = 1.4 * unit
                for (cx, cy) in [(6.0, 6.0), (12.0, 12.0)] {
                    let rect = CGRect(
                        x: cx * unit - r, y: cy * unit - r,
                        width: r * 2, height: r * 2
                    )
                    ctx.fill(Path(ellipseIn: rect), with: .color(sig))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct ShuntWordmark: View {
    let size: CGFloat
    let theme: ShuntTheme

    init(size: CGFloat = 28, theme: ShuntTheme = .filament) {
        self.size = size
        self.theme = theme
    }

    var body: some View {
        HStack(spacing: size * 0.28) {
            ShuntLogo(size: size * 1.15, theme: theme)
            Text("shunt")
                .font(.system(size: size, weight: .semibold, design: .default))
                .tracking(-0.025 * size)
                .foregroundStyle(.white)
        }
    }
}
