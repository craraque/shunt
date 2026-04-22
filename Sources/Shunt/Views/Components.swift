import SwiftUI

// Reusable SwiftUI components wired to the Shunt design system.

/// Small uppercase monospace section header, Signal Amber tint.
/// Example: "PROXY" / "INTERFACE BINDING" / "ABOUT THIS VERSION".
struct SectionHeader: View {
    let label: String

    var body: some View {
        Text(label.uppercased())
            .font(.shuntMonoLabel)
            .kerning(1.0)
            .foregroundStyle(Color.signalAmber)
    }
}

/// Pill indicator of routing state. Green when active (with a soft glow),
/// neutral gray when idle.
struct StatusPill: View {
    enum Kind {
        case active
        case idle
        case custom(text: String, color: Color)
    }

    let kind: Kind

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

    private var dotColor: Color {
        switch kind {
        case .active: return .pcbGreen
        case .idle: return .secondary
        case .custom(_, let c): return c
        }
    }
    private var glowColor: Color {
        switch kind {
        case .active: return Color.pcbGreen.opacity(0.5)
        default: return .clear
        }
    }
    private var textColor: Color {
        switch kind {
        case .active: return .pcbGreen
        case .idle: return .secondary
        case .custom(_, let c): return c
        }
    }
    private var background: Color {
        switch kind {
        case .active: return .pcbGreen100.opacity(0.5)
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

/// Hero status card shown on the top of the General tab.
struct StatusCard: View {
    let title: String
    let detail: String
    let active: Bool

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
                    Color.signalAmber.opacity(0.09),
                    Color.signalAmber.opacity(0.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.shuntSeparator, lineWidth: 1)
        )
    }
}

/// Standard two-column form row: 160pt label + flexible value.
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
