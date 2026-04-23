import SwiftUI

struct ThemesTab: View {
    @ObservedObject var activeTheme: ActiveTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Themes")
                    .font(.shuntTitle1)
                Text("Visual variants that preserve the Precision Utility identity. Pick one that matches your workspace.")
                    .font(.shuntBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(ShuntTheme.all) { theme in
                        ThemeCard(
                            theme: theme,
                            isSelected: theme.id == activeTheme.current.id,
                            colorScheme: colorScheme
                        ) {
                            activeTheme.select(theme)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }
}

private struct ThemeCard: View {
    let theme: ShuntTheme
    let isSelected: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                swatches
                    .frame(width: 96)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(theme.name)
                            .font(.shuntLabelStrong)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.accent(for: colorScheme))
                                .font(.system(size: 13))
                        }
                    }
                    Text(theme.rationale)
                        .font(.shuntCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                preview
                    .frame(width: 120, height: 48)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent(for: colorScheme) : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var swatches: some View {
        HStack(spacing: 4) {
            swatch(theme.accent(for: colorScheme), label: "Accent")
            swatch(theme.statusActive(for: colorScheme), label: "Status")
            swatch(theme.windowBg(for: colorScheme), label: "Window")
        }
    }

    private func swatch(_ color: Color, label: String) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .frame(width: 28, height: 28)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.windowBg(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.statusActive(for: colorScheme))
                    .frame(width: 6, height: 6)
                Text("Routing")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.accent(for: colorScheme))
            }
        }
    }
}
