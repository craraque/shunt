import SwiftUI

/// A selectable color theme. Every theme preserves the Precision Utility
/// identity (flat colors, no gradients in UI, SF + SF Mono typography). Only
/// the accent + status-active + window-tint tokens change across themes.
///
/// Theme tokens are split light/dark so each mode can be hand-tuned. Views
/// read the active palette via `@Environment(\.shuntTheme)` (see
/// ActiveTheme.swift for the Environment plumbing).
struct ShuntTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let rationale: String

    let accentLight: Color
    let accentDark: Color
    let statusActiveLight: Color
    let statusActiveDark: Color
    let windowBgLight: Color
    let windowBgDark: Color
    let rowHoverLight: Color
    let rowHoverDark: Color

    // Resolved token accessors. Views read these with a ColorScheme argument.
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

// MARK: - Built-in themes (v0.2.1 — modern refresh)

extension ShuntTheme {

    /// Warm tungsten body with a classic green "on" LED. Each theme from
    /// v0.2.2 follows the Chassis pattern: a distinct accent hue for the
    /// app's identity, paired with a signature LED colour that makes the
    /// menubar icon recognisable at a glance.
    static let filament = ShuntTheme(
        id: "filament",
        name: "Filament",
        rationale: "Heated tungsten on graphite. Green indicator LED. The generalist default.",
        accentLight:        Color(hex: 0xEA580C),
        accentDark:         Color(hex: 0xFDBA74),
        statusActiveLight:  Color(hex: 0x22C55E),
        statusActiveDark:   Color(hex: 0x86EFAC),
        windowBgLight:      Color(hex: 0xFAF6EE),
        windowBgDark:       Color(hex: 0x17140D),
        rowHoverLight:      Color(hex: 0xF3EADA),
        rowHoverDark:       Color(hex: 0x231E12)
    )

    /// Cobalt lab glass with a teal LED — analogous-but-distinct cool pair.
    /// Teal (not green) keeps Iodine visually separate from Filament in the
    /// menubar even when both themes live in the same dock.
    static let iodine = ShuntTheme(
        id: "iodine",
        name: "Iodine",
        rationale: "Cobalt glass at 6500K. Teal indicator LED. For the cool-terminal developer.",
        accentLight:        Color(hex: 0x2563EB),
        accentDark:         Color(hex: 0xBFDBFE),
        statusActiveLight:  Color(hex: 0x14B8A6),
        statusActiveDark:   Color(hex: 0x5EEAD4),
        windowBgLight:      Color(hex: 0xF5F7FA),
        windowBgDark:       Color(hex: 0x0C1117),
        rowHoverLight:      Color(hex: 0xE6ECF6),
        rowHoverDark:       Color(hex: 0x161D27)
    )

    /// Violet ink with a lime LED — complementary pair for high visual
    /// contrast. Renamed in spirit from navy-on-cotton to vivid violet so
    /// it doesn't compete with Iodine on the blue axis.
    static let blueprint = ShuntTheme(
        id: "blueprint",
        name: "Blueprint",
        rationale: "Violet ink on cotton, lime indicator LED. For the editorial maximalist.",
        accentLight:        Color(hex: 0x7C3AED),
        accentDark:         Color(hex: 0xDDD6FE),
        statusActiveLight:  Color(hex: 0x84CC16),
        statusActiveDark:   Color(hex: 0xBEF264),
        windowBgLight:      Color(hex: 0xF7F5FA),
        windowBgDark:       Color(hex: 0x110E1A),
        rowHoverLight:      Color(hex: 0xECE4F6),
        rowHoverDark:       Color(hex: 0x1C1626)
    )

    /// Anodized aluminum with one indicator LED. Monochrome + single cyan signal.
    static let chassis = ShuntTheme(
        id: "chassis",
        name: "Chassis",
        rationale: "Anodized aluminum with one indicator LED. For the OLED / rack purist.",
        accentLight:        Color(hex: 0x0A0A0A),
        accentDark:         Color(hex: 0xF5F5F4),
        statusActiveLight:  Color(hex: 0x0891B2),
        statusActiveDark:   Color(hex: 0x22D3EE),
        windowBgLight:      Color(hex: 0xFCFCFB),
        windowBgDark:       Color(hex: 0x080808),
        rowHoverLight:      Color(hex: 0xF0EFEC),
        rowHoverDark:       Color(hex: 0x141414)
    )

    static let all: [ShuntTheme] = [.filament, .iodine, .blueprint, .chassis]

    /// Look up a theme by id, mapping legacy v0.2.0 ids to their v0.2.1
    /// successors so existing settings don't silently reset to default.
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
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
