import SwiftUI
import AppKit

// MARK: - Window-level visual effect material
//
// macOS Tahoe-style "liquid glass" surfaces. We embed an NSVisualEffectView
// to get the system's translucent material — the desktop wallpaper bleeds
// through with the requested blur + saturation.

struct LiquidWindowMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = emphasized
        return v
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.isEmphasized = emphasized
    }
}

// MARK: - LiquidCard
//
// The standard glass surface: top-to-bottom gradient (glassStrong → glass)
// with an edge hairline and a 1px inset highlight. Used for status hero,
// settings rows containers, theme tile previews, etc.

struct LiquidCard<Content: View>: View {
    let theme: ShuntTheme
    let cornerRadius: CGFloat
    let padding: EdgeInsets
    let strong: Bool   // true = use edgeStrong + slightly heavier inset
    @ViewBuilder let content: () -> Content

    init(
        theme: ShuntTheme,
        cornerRadius: CGFloat = 14,
        padding: EdgeInsets = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16),
        strong: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.theme = theme
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.strong = strong
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(theme.cardGradient())
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(strong ? theme.edgeStrong : theme.edge, lineWidth: 0.5)
            )
            .overlay(
                // 1px inset highlight at the top — fakes the "rim of light"
                // on glass when light hits the top edge.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 1)
                    .blendMode(.plusLighter)
                    .mask(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(LinearGradient(colors: [.white, .clear],
                                                  startPoint: .top, endPoint: .center))
                    )
            )
    }
}

// MARK: - LiquidPill
//
// Small status badge. Variants: neutral, active (signal/green), accent, warn.

enum LiquidPillKind {
    case neutral, active, accent, warn
}

struct LiquidPill: View {
    let text: String
    var dot: Bool = false
    var kind: LiquidPillKind = .neutral
    let theme: ShuntTheme

    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle()
                    .fill(palette.fg)
                    .frame(width: 6, height: 6)
                    .shadow(color: kind == .active ? palette.fg : .clear, radius: 4)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.fg)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(palette.bg)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(palette.ring, lineWidth: 0.5)
        )
    }

    private var palette: (bg: Color, fg: Color, ring: Color) {
        switch kind {
        case .neutral:
            return (theme.glass, .white.opacity(0.62), theme.edge)
        case .active:
            return (theme.signal.opacity(0.12), theme.signal, theme.signal.opacity(0.30))
        case .accent:
            return (theme.accentSoft, theme.accentDark, theme.edgeStrong)
        case .warn:
            return (Color.orange.opacity(0.12), Color(hex: 0xFCD34D), Color.orange.opacity(0.28))
        }
    }
}

// MARK: - SectionLabel (liquid)
//
// Section header — uppercase mono accent label. Replaces older Components
// SectionHeader in places where we want the exact liquid-glass look.

struct LiquidSectionLabel: View {
    let text: String
    let theme: ShuntTheme

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .tracking(1.5)              // ~0.14em on 10.5pt
            .textCase(.uppercase)
            .foregroundStyle(theme.accentDark)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }
}

// MARK: - Theme-tinted bloom
//
// A soft circular accent glow used behind hero content (status hero, About).

struct AccentBloom: View {
    let theme: ShuntTheme
    var color: Color? = nil
    var diameter: CGFloat = 220
    var opacity: Double = 0.18

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: (color ?? theme.accentDark), location: 0),
                        .init(color: .clear, location: 0.6)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .opacity(opacity)
            .blur(radius: 20)
            .allowsHitTesting(false)
    }
}
