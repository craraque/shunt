import SwiftUI

struct AboutTab: View {
    var body: some View {
        ZStack {
            BlueprintGrid()
            VStack(spacing: 14) {
                Spacer().frame(height: 16)
                AppIconMark(size: 96)
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
            let stroke = GraphicsContext.Shading.color(.shuntSeparator.opacity(0.6))
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

/// Renders the railway shunt icon as a SwiftUI Canvas drawing. Size scales the
/// 160-unit viewBox down to whatever pt size the caller wants. Used in the
/// About tab and anywhere else we want to show the brand mark in-app (without
/// loading the .icns file).
struct AppIconMark: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, canvasSize in
            // Scale 160-unit viewBox to canvas
            let s = canvasSize.width / 160.0
            ctx.scaleBy(x: s, y: s)

            // Background — rounded square with vertical gradient
            let bgRect = CGRect(x: 0, y: 0, width: 160, height: 160)
            let bgPath = Path(roundedRect: bgRect, cornerRadius: 36)
            ctx.fill(
                bgPath,
                with: .linearGradient(
                    Gradient(colors: [Color(red: 0.169, green: 0.165, blue: 0.157),
                                      Color(red: 0.102, green: 0.102, blue: 0.098)]),
                    startPoint: CGPoint(x: 80, y: 0),
                    endPoint: CGPoint(x: 80, y: 160)
                )
            )

            // Cross ties
            let tieColor = Color(red: 0.894, green: 0.878, blue: 0.847).opacity(0.4)
            for x in [24.0, 40, 56, 100, 116, 132] {
                let r = CGRect(x: x, y: 94, width: 3, height: 24)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(tieColor))
            }

            // Main rails
            let rail = Color(red: 0.949, green: 0.945, blue: 0.933)
            for y in [99.0, 113] {
                var p = Path()
                p.move(to: CGPoint(x: 22, y: y))
                p.addLine(to: CGPoint(x: 138, y: y))
                ctx.stroke(p, with: .color(rail),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            // Switch point
            ctx.fill(
                Path(ellipseIn: CGRect(x: 74.5, y: 102.5, width: 7, height: 7)),
                with: .color(.signalAmber)
            )

            // Siding curves (Amber)
            let sidingStyle = StrokeStyle(lineWidth: 3, lineCap: .round)
            var siding1 = Path()
            siding1.move(to: CGPoint(x: 72, y: 99))
            siding1.addQuadCurve(to: CGPoint(x: 126, y: 52), control: CGPoint(x: 92, y: 72))
            ctx.stroke(siding1, with: .color(.signalAmber), style: sidingStyle)

            var siding2 = Path()
            siding2.move(to: CGPoint(x: 84, y: 113))
            siding2.addQuadCurve(to: CGPoint(x: 138, y: 66), control: CGPoint(x: 104, y: 86))
            ctx.stroke(siding2, with: .color(.signalAmber), style: sidingStyle)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
