import SwiftUI

/// A selectable color theme. Liquid Glass identity (macOS Tahoe-style):
/// translucent panels over a vibrant desktop gradient, accent + signal
/// gradients on the brand mark, and theme-reactive surfaces.
///
/// The palette is dark-first (the visual language assumes dark glass over
/// vibrant wallpaper). Light-mode tokens are kept slightly toned for
/// backwards compatibility but most surfaces look intended only in dark.
///
/// Views read the active palette via `@Environment(\.shuntTheme)` (see
/// ActiveTheme.swift for the Environment plumbing).
struct ShuntTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let rationale: String

    // Legacy accent/status (kept for backwards-compat with existing call sites)
    let accentLight: Color
    let accentDark: Color
    let statusActiveLight: Color
    let statusActiveDark: Color
    let windowBgLight: Color
    let windowBgDark: Color
    let rowHoverLight: Color
    let rowHoverDark: Color

    // Liquid Glass tokens — the new design language. All single-variant
    // (the design is dark-only); they read the same in light + dark mode.
    let accent2: Color           // second stop for accent gradients
    let accentSoft: Color        // ~18% alpha tint for soft fills
    let signal: Color            // "routing live" terminus color
    let signalDeep: Color        // gradient stop deeper than signal
    let glass: Color             // base glass fill (~6% alpha white)
    let glassStrong: Color       // emphasized glass (~10% alpha)
    let edge: Color              // hairline border
    let edgeStrong: Color        // emphasized hairline
    let bg0: Color               // logo squircle gradient stop 0
    let bg1: Color               // logo squircle gradient stop 1
    let desktopHi: Color         // desktop radial gradient highlight
    let desktopMid: Color        // desktop radial gradient mid
    let desktopLo: Color         // desktop radial gradient low

    // Resolved token accessors (kept for backwards-compat).
    func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? accentDark : accentLight
    }
    func statusActive(for scheme: ColorScheme) -> Color {
        scheme == .dark ? statusActiveDark : statusActiveLight
    }
    func windowBg(for scheme: ColorScheme) -> Color {
        scheme == .dark ? windowBgDark : windowBgLight
    }
    func rowHover(for scheme: ColorScheme) -> Color {
        scheme == .dark ? rowHoverDark : rowHoverLight
    }

    /// 12% alpha tint of the accent — active sidebar row, selected rule card.
    func accentSubtle(for scheme: ColorScheme) -> Color {
        accent(for: scheme).opacity(0.12)
    }

    /// 22% alpha tint of status-active — status-pill background.
    func statusActiveSubtle(for scheme: ColorScheme) -> Color {
        statusActive(for: scheme).opacity(0.22)
    }
}

// MARK: - Built-in themes (Liquid Glass redesign)

extension ShuntTheme {

    /// Warm tungsten body. Amber accent, mint signal LED.
    static let filament = ShuntTheme(
        id: "filament",
        name: "Filament",
        rationale: "Heated tungsten on graphite. Mint signal LED. The generalist default.",
        accentLight:        Color(hex: 0xFF7A1A),
        accentDark:         Color(hex: 0xFFB266),
        statusActiveLight:  Color(hex: 0x10B981),
        statusActiveDark:   Color(hex: 0x7CF3A8),
        windowBgLight:      Color(hex: 0xFAF6EE),
        windowBgDark:       Color(hex: 0x110804),
        rowHoverLight:      Color(hex: 0xF3EADA),
        rowHoverDark:       Color(hex: 0x231E12),
        accent2:            Color(hex: 0xFF7A1A),
        accentSoft:         Color(hex: 0xFFB266).opacity(0.18),
        signal:             Color(hex: 0x7CF3A8),
        signalDeep:         Color(hex: 0x10B981),
        glass:              Color.white.opacity(0.06),
        glassStrong:        Color.white.opacity(0.10),
        edge:               Color.white.opacity(0.10),
        edgeStrong:         Color.white.opacity(0.16),
        bg0:                Color(hex: 0x221913),
        bg1:                Color(hex: 0x0E0805),
        desktopHi:          Color(hex: 0x4A2D18),
        desktopMid:         Color(hex: 0x2A1A0F),
        desktopLo:          Color(hex: 0x110804)
    )

    /// Cobalt lab glass. Sky-blue accent, teal signal.
    static let iodine = ShuntTheme(
        id: "iodine",
        name: "Iodine",
        rationale: "Cobalt glass at 6500K. Teal signal LED. For the cool-terminal developer.",
        accentLight:        Color(hex: 0x5687FF),
        accentDark:         Color(hex: 0xA6C8FF),
        statusActiveLight:  Color(hex: 0x10B981),
        statusActiveDark:   Color(hex: 0x7AF0CC),
        windowBgLight:      Color(hex: 0xF5F7FA),
        windowBgDark:       Color(hex: 0x050810),
        rowHoverLight:      Color(hex: 0xE6ECF6),
        rowHoverDark:       Color(hex: 0x161D27),
        accent2:            Color(hex: 0x5687FF),
        accentSoft:         Color(hex: 0xA6C8FF).opacity(0.18),
        signal:             Color(hex: 0x7AF0CC),
        signalDeep:         Color(hex: 0x10B981),
        glass:              Color.white.opacity(0.06),
        glassStrong:        Color.white.opacity(0.10),
        edge:               Color.white.opacity(0.10),
        edgeStrong:         Color.white.opacity(0.18),
        bg0:                Color(hex: 0x0F1A2E),
        bg1:                Color(hex: 0x040814),
        desktopHi:          Color(hex: 0x1F3A6E),
        desktopMid:         Color(hex: 0x0F1A2E),
        desktopLo:          Color(hex: 0x050810)
    )

    /// Violet ink with lime signal. High-contrast complementary pair.
    static let blueprint = ShuntTheme(
        id: "blueprint",
        name: "Blueprint",
        rationale: "Violet ink, lime signal LED. For the editorial maximalist.",
        accentLight:        Color(hex: 0x8B6CFF),
        accentDark:         Color(hex: 0xC7B8FF),
        statusActiveLight:  Color(hex: 0x84CC16),
        statusActiveDark:   Color(hex: 0xD9F985),
        windowBgLight:      Color(hex: 0xF7F5FA),
        windowBgDark:       Color(hex: 0x0A0815),
        rowHoverLight:      Color(hex: 0xECE4F6),
        rowHoverDark:       Color(hex: 0x1C1626),
        accent2:            Color(hex: 0x8B6CFF),
        accentSoft:         Color(hex: 0xC7B8FF).opacity(0.18),
        signal:             Color(hex: 0xD9F985),
        signalDeep:         Color(hex: 0x84CC16),
        glass:              Color.white.opacity(0.06),
        glassStrong:        Color.white.opacity(0.10),
        edge:               Color.white.opacity(0.10),
        edgeStrong:         Color.white.opacity(0.16),
        bg0:                Color(hex: 0x1A1A2E),
        bg1:                Color(hex: 0x0A0A18),
        desktopHi:          Color(hex: 0x3A2A66),
        desktopMid:         Color(hex: 0x1A1430),
        desktopLo:          Color(hex: 0x0A0815)
    )

    /// Anodized aluminum. Monochrome with a single cyan signal.
    static let chassis = ShuntTheme(
        id: "chassis",
        name: "Chassis",
        rationale: "Anodized aluminum with one indicator LED. For the OLED / rack purist.",
        accentLight:        Color(hex: 0xA8A8A8),
        accentDark:         Color(hex: 0xF2F2F2),
        statusActiveLight:  Color(hex: 0x0891B2),
        statusActiveDark:   Color(hex: 0x5BE9F5),
        windowBgLight:      Color(hex: 0xFCFCFB),
        windowBgDark:       Color(hex: 0x050505),
        rowHoverLight:      Color(hex: 0xF0EFEC),
        rowHoverDark:       Color(hex: 0x141414),
        accent2:            Color(hex: 0xA8A8A8),
        accentSoft:         Color(hex: 0xF2F2F2).opacity(0.14),
        signal:             Color(hex: 0x5BE9F5),
        signalDeep:         Color(hex: 0x0891B2),
        glass:              Color.white.opacity(0.05),
        glassStrong:        Color.white.opacity(0.09),
        edge:               Color.white.opacity(0.09),
        edgeStrong:         Color.white.opacity(0.16),
        bg0:                Color(hex: 0x1C1C1C),
        bg1:                Color(hex: 0x000000),
        desktopHi:          Color(hex: 0x2A2A2A),
        desktopMid:         Color(hex: 0x141414),
        desktopLo:          Color(hex: 0x050505)
    )

    static let all: [ShuntTheme] = [.filament, .iodine, .blueprint, .chassis]

    /// Look up a theme by id, mapping legacy ids to their successors so
    /// existing settings don't silently reset to default.
    static func byID(_ id: String) -> ShuntTheme {
        let legacy: [String: String] = [
            "signal-amber":    "filament",
            "graphite-cyan":   "iodine",
            "paper-blueprint": "blueprint",
            "carbon-mono":     "chassis"
        ]
        let normalized = legacy[id] ?? id
        return all.first { $0.id == normalized } ?? .filament
    }

    /// Desktop gradient (radial). Visible behind translucent panels.
    func desktopGradient() -> RadialGradient {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: desktopHi,  location: 0.0),
                .init(color: desktopMid, location: 0.40),
                .init(color: desktopLo,  location: 1.0)
            ]),
            center: UnitPoint(x: 0.75, y: 0.25),
            startRadius: 0,
            endRadius: 800
        )
    }

    /// Logo squircle background gradient.
    func logoChassisGradient() -> LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [bg0, bg1]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Accent linear gradient (top-to-bottom). Used on logo beams,
    /// primary buttons, toggle when on.
    func accentGradient() -> LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [accentDark, accent2]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Signal gradient — deep at the bottom, bright at the top.
    func signalGradient() -> LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [signal, signalDeep]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Glass card gradient — top-to-bottom from glassStrong to glass.
    func cardGradient() -> LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [glassStrong, glass]),
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Environment key

private struct ShuntThemeKey: EnvironmentKey {
    static let defaultValue: ShuntTheme = .filament
}

extension EnvironmentValues {
    var shuntTheme: ShuntTheme {
        get { self[ShuntThemeKey.self] }
        set { self[ShuntThemeKey.self] = newValue }
    }
}

// MARK: - Color hex helper

extension Color {
    /// Hex literal initializer. Explicitly sRGB so the color renders the same
    /// way through SwiftUI's GraphicsContext (Canvas) as through normal view
    /// fills — without `.sRGB` the bare `init(red:green:blue:)` defaults to a
    /// device color space and warm/saturated values come back desaturated when
    /// drawn into a Canvas (manifests as silver-looking amber, etc.).
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
