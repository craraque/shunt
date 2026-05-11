import SwiftUI

// Reusable SwiftUI components wired to the Shunt design system.
// Color tokens come from the active theme via @Environment(\.shuntTheme).

/// Small uppercase monospace section header, theme-accent tint.
/// Example: "PROXY" / "INTERFACE BINDING" / "ABOUT THIS VERSION".
///
/// Optionally takes a SF Symbol icon (rendered at 10pt secondary) and a
/// `.help()` tooltip — pattern mirrors `RulesTab.SectionLabel`. All section
/// headers across the app should pass both whenever there's a meaningful
/// icon and a useful explanation, for visual + behavioral consistency.
struct SectionHeader: View {
    let label: String
    let icon: String?
    let tooltip: String?
    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    init(label: String, icon: String? = nil, tooltip: String? = nil) {
        self.label = label
        self.icon = icon
        self.tooltip = tooltip
    }

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.accent(for: scheme).opacity(0.8))
            }
            Text(label.uppercased())
                .font(.shuntMonoLabel)
                .kerning(1.0)
                .foregroundStyle(theme.accent(for: scheme))
        }
        .contentShape(Rectangle())
        .help(tooltip ?? "")
    }
}

/// Pill indicator of routing state. Theme's status-active color when live,
/// neutral gray when idle.
struct StatusPill: View {
    enum Kind {
        case active
        case idle
        case custom(text: String, color: Color)
    }

    let kind: Kind
    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .shadow(color: glowColor, radius: 3)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
    }

    private var activeColor: Color { theme.statusActive(for: scheme) }

    private var dotColor: Color {
        switch kind {
        case .active: return activeColor
        case .idle: return .secondary
        case .custom(_, let c): return c
        }
    }
    private var glowColor: Color {
        switch kind {
        case .active: return activeColor.opacity(0.5)
        default: return .clear
        }
    }
    private var textColor: Color {
        switch kind {
        case .active: return activeColor
        case .idle: return .secondary
        case .custom(_, let c): return c
        }
    }
    private var background: Color {
        switch kind {
        case .active: return activeColor.opacity(0.22)
        case .idle: return Color.secondary.opacity(0.12)
        case .custom(_, let c): return c.opacity(0.12)
        }
    }
    private var label: String {
        switch kind {
        case .active: return "Active"
        case .idle: return "Idle"
        case .custom(let t, _): return t
        }
    }
}

/// Hero status card shown on the top of the General tab. Background is a
/// subtle theme-accent tint fading diagonally.
struct StatusCard: View {
    let title: String
    let detail: String
    let active: Bool
    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("STATUS")
                    .font(.shuntMonoLabel)
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.shuntTitle2)
                Text(detail)
                    .font(.shuntCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(kind: active ? .active : .idle)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    theme.accent(for: scheme).opacity(0.09),
                    theme.accent(for: scheme).opacity(0.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

/// Standard two-column form row: 140pt label + flexible value.
struct FormRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.shuntLabel)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            content
                .font(.shuntLabel)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

/// Simple text wrapper that applies the shunt mono data font and tabular nums,
/// and lets the caller opt-in to a color.
struct MonoText: View {
    let text: String
    let color: Color?
    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.shuntMonoData)
            .foregroundStyle(color ?? Color.primary)
    }
}
