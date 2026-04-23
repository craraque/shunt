import SwiftUI

struct AboutTab: View {
    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            BlueprintGrid()
            VStack(spacing: 14) {
                Spacer().frame(height: 16)
                TurnoutMark(
                    size: 112,
                    accent: theme.accent(for: scheme),
                    statusActive: theme.statusActive(for: scheme),
                    routing: true
                )
                Text("Shunt")
                    .font(.shuntDisplay)
                Text("Version \(appVersion) · build \(appBuild)")
                    .font(.shuntMonoData)
                    .foregroundStyle(.secondary)
                Text("Per-app network routing for macOS. Send traffic from selected apps through a configurable SOCKS5 upstream — leave everything else on your normal network.")
                    .font(.shuntCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.top, 6)
                Spacer()
                Text("MADE BY CESAR ARAQUE")
                    .font(.shuntMonoLabel)
                    .kerning(1.5)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }
}

/// Subtle blueprint-style grid background. Used only on the About tab — the
/// one place decoration is allowed in the design system.
private struct BlueprintGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            let stroke = GraphicsContext.Shading.color(Color(nsColor: .separatorColor).opacity(0.6))
            var x: CGFloat = 0
            while x <= size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(p, with: stroke, lineWidth: 0.5)
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(p, with: stroke, lineWidth: 0.5)
                y += spacing
            }
        }
    }
}

/// Renders the Turnout mark at any size. Uses the 18-unit canvas geometry
/// from MenubarIcons but scaled up, with theme colors. The routing parameter
/// toggles between the idle and active rendering so the About tab can show
/// the live state.
struct TurnoutMark: View {
    let size: CGFloat
    let accent: Color
    let statusActive: Color
    let routing: Bool

    init(size: CGFloat,
         accent: Color = Color(hex: 0xC2410C),
         statusActive: Color = Color(hex: 0x15803D),
         routing: Bool = true) {
        self.size = size
        self.accent = accent
        self.statusActive = statusActive
        self.routing = routing
    }

    var body: some View {
        Canvas { [accent, statusActive, routing] ctx, canvasSize in
            // Scale 18-unit canvas up to target size
            let s = canvasSize.width / 18.0
            ctx.scaleBy(x: s, y: s)

            // Sub-linear stroke scaling so 100pt doesn't look clubbed.
            let railStroke: CGFloat = {
                if canvasSize.width <= 24 { return 2.6 }
                if canvasSize.width <= 64 { return 2.4 }
                return 2.2
            }()
            let diagStroke: CGFloat = railStroke - 0.4

            let recede = Color.primary.opacity(0.35)

            // Top rail (main line) — recedes in active state
            var topRail = Path()
            topRail.move(to: CGPoint(x: 2, y: 6))
            topRail.addLine(to: CGPoint(x: 16, y: 6))
            ctx.stroke(topRail,
                       with: .color(routing ? recede : .primary),
                       style: StrokeStyle(lineWidth: railStroke, lineCap: .round))

            // Bottom rail (diverted line) — active in routing state
            var bottomRail = Path()
            bottomRail.move(to: CGPoint(x: 2, y: 12))
            bottomRail.addLine(to: CGPoint(x: 16, y: 12))
            ctx.stroke(bottomRail,
                       with: .color(routing ? accent : .primary),
                       style: StrokeStyle(lineWidth: railStroke, lineCap: .round))

            // Switch diagonal connecting the two rails
            var diagonal = Path()
            diagonal.move(to: CGPoint(x: 8, y: 6))
            diagonal.addLine(to: CGPoint(x: 11, y: 12))
            ctx.stroke(diagonal,
                       with: .color(routing ? accent : .primary),
                       style: StrokeStyle(lineWidth: diagStroke, lineCap: .round))

            // Switch-point dot at the diagonal's midpoint
            let dotR: CGFloat = 2.0
            let switchRect = CGRect(
                x: 9.5 - dotR, y: 9 - dotR,
                width: dotR * 2, height: dotR * 2
            )
            ctx.fill(Path(ellipseIn: switchRect),
                     with: .color(routing ? accent : .primary))

            // Active-state terminus cap at the right end of the bottom rail
            if routing {
                let capR: CGFloat = 1.8
                let capRect = CGRect(
                    x: 16 - capR, y: 12 - capR,
                    width: capR * 2, height: capR * 2
                )
                ctx.fill(Path(ellipseIn: capRect),
                         with: .color(statusActive))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Legacy — kept as an alias so any external reference still compiles. The
/// new name is `TurnoutMark`. This wraps it with the default accent so the
/// v0.2.0 signature (no theme colors) keeps working.
struct AppIconMark: View {
    let size: CGFloat
    let accent: Color

    init(size: CGFloat, accent: Color = Color(hex: 0xC2410C)) {
        self.size = size
        self.accent = accent
    }

    var body: some View {
        TurnoutMark(size: size, accent: accent, routing: true)
    }
}
