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

    /// Default. Evolves the v0.1 Signal Amber into a deeper, more pigmented
    /// burnt orange — "heated tungsten" rather than "safety tape".
    static let filament = ShuntTheme(
        id: "filament",
        name: "Filament",
        rationale: "Warm tungsten on graphite. The generalist default.",
        accentLight:        Color(hex: 0xC2410C),
        accentDark:         Color(hex: 0xFB923C),
        statusActiveLight:  Color(hex: 0x15803D),
        statusActiveDark:   Color(hex: 0x4ADE80),
        windowBgLight:      Color(hex: 0xFAF8F4),
        windowBgDark:       Color(hex: 0x17160F),
        rowHoverLight:      Color(hex: 0xF3ECDF),
        rowHoverDark:       Color(hex: 0x231F14)
    )

    /// Cool lab instrument. Iodine blue rather than the overused teal.
    static let iodine = ShuntTheme(
        id: "iodine",
        name: "Iodine",
        rationale: "Lab glass at 6500K. For the dark-terminal developer.",
        accentLight:        Color(hex: 0x2563EB),
        accentDark:         Color(hex: 0x7CA8FF),
        statusActiveLight:  Color(hex: 0x059669),
        statusActiveDark:   Color(hex: 0x34D399),
        windowBgLight:      Color(hex: 0xF7F8FA),
        windowBgDark:       Color(hex: 0x0F1115),
        rowHoverLight:      Color(hex: 0xEAEEF6),
        rowHoverDark:       Color(hex: 0x181C24)
    )

    /// Archival ink on cotton stock. Editorial restraint, not retro kitsch.
    static let blueprint = ShuntTheme(
        id: "blueprint",
        name: "Blueprint",
        rationale: "Archival ink on cotton stock. For the editorial minimalist.",
        accentLight:        Color(hex: 0x1E3A8A),
        accentDark:         Color(hex: 0xA5B8E3),
        statusActiveLight:  Color(hex: 0x166534),
        statusActiveDark:   Color(hex: 0x7DD3A0),
        windowBgLight:      Color(hex: 0xF5F1E8),
        windowBgDark:       Color(hex: 0x131722),
        rowHoverLight:      Color(hex: 0xECE6D6),
        rowHoverDark:       Color(hex: 0x1B2130)
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
