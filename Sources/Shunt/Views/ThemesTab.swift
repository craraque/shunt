import SwiftUI

struct ThemesTab: View {
    @ObservedObject var activeTheme: ActiveTheme
    @Environment(\.shuntTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Themes")
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.65)
                        .foregroundStyle(.white)
                    Text("The chosen theme tints the menu-bar glyph, the app icon, and accent colors throughout the interface.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineSpacing(2)
                        .frame(maxWidth: 480, alignment: .leading)
                }
                .padding(.bottom, 16)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(ShuntTheme.all) { t in
                        ThemeCard(
                            theme: t,
                            isSelected: t.id == activeTheme.current.id
                        ) {
                            activeTheme.select(t)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
    }
}

private struct ThemeCard: View {
    let theme: ShuntTheme
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                // Theme's desktop gradient as the card background.
                theme.desktopGradient()

                // Selected check badge — accent gradient with glow
                if isSelected {
                    ZStack {
                        Circle()
                            .fill(theme.accentGradient())
                            .frame(width: 22, height: 22)
                            .shadow(color: theme.accentDark, radius: 6)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: 0x1A0F05))
                    }
                    .padding(10)
                }

                VStack(alignment: .leading, spacing: 0) {
                    // Header — logo + name + hex chips
                    HStack(spacing: 10) {
                        ShuntLogo(size: 40, theme: theme)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.name)
                                .font(.system(size: 16, weight: .medium))
                                .tracking(-0.32)
                                .foregroundStyle(.white)
                            Text(hexLabel)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.62))
                        }
                        Spacer()
                    }
                    .padding(.bottom, 14)

                    // Mini menu-bar preview chip
                    HStack(spacing: 8) {
                        ShuntGlyph(
                            size: 14,
                            color: .white,
                            accent: theme.accentDark,
                            signal: theme.signal,
                            dimmed: false
                        )
                        Text("4.82 MB/s")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.62))
                        Spacer()
                        LiquidPill(text: "Routing", dot: true, kind: .active, theme: theme)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(theme.glassStrong)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(theme.edge, lineWidth: 0.5)
                    )

                    // Swatch row
                    HStack(spacing: 4) {
                        swatch(theme.bg0)
                        swatch(theme.bg1)
                        swatch(theme.accentDark)
                        swatch(theme.accent2)
                        swatch(theme.signal)
                    }
                    .frame(height: 16)
                    .padding(.top, 10)
                }
                .padding(16)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.desktopGradient())
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accentDark : theme.edge,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
            .shadow(color: isSelected ? theme.accentSoft : .black.opacity(0.4),
                    radius: isSelected ? 14 : 8,
                    y: isSelected ? 6 : 4)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
    }

    private var hexLabel: String {
        // Show theme.bg0 + accent in hex (rough — Color → cgColor → uppercase hex string)
        let bg = hexString(theme.bg0)
        let ac = hexString(theme.accentDark)
        return "\(bg) · \(ac)"
    }

    private func hexString(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .black
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
