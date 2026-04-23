import SwiftUI
import AppKit

/// The DESIGN.md sidebar layout, implemented as a plain HStack rather than
/// `NavigationSplitView`. NavigationSplitView hosted inside a custom
/// `NSWindowController`-owned `NSWindow` (which we need because of
/// LSUIElement=true) renders as an empty shell — the sidebar list and detail
/// closures silently don't emit views. An HStack with a custom sidebar works
/// reliably across macOS 14+ and gives us full control over row style
/// (matches DESIGN.md §Layout exactly).
struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()
    @StateObject private var activeTheme = ActiveTheme.shared
    @State private var selection: SidebarItem = .general
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .background(SidebarVisualEffect())
            Divider()
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 820, height: 520)
        .environment(\.shuntTheme, activeTheme.current)
        .tint(activeTheme.current.accent(for: scheme))
        .onAppear { model.reload() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarItem.allCases) { item in
                SidebarRow(
                    item: item,
                    isSelected: selection == item,
                    accent: activeTheme.current.accent(for: scheme)
                ) {
                    selection = item
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .general:  GeneralTab(model: model)
        case .rules:    RulesTab(model: model)
        case .monitor:  MonitorTab()
        case .upstream: UpstreamTab(model: model)
        case .themes:   ThemesTab(activeTheme: activeTheme)
        case .advanced: AdvancedTab(model: model)
        case .about:    AboutTab()
        }
    }
}

// MARK: - Sidebar row (DESIGN.md §Layout: 14pt icon + 13pt label, 8pt/6pt padding)

private struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let accent: Color
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(isSelected ? accent : Color.primary.opacity(0.8))
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? accent : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return accent.opacity(0.15) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }
}

// MARK: - Sidebar material (NSVisualEffectView .sidebar)

private struct SidebarVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Sidebar items

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case general, rules, monitor, upstream, themes, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:  return "General"
        case .rules:    return "Rules"
        case .monitor:  return "Monitor"
        case .upstream: return "Upstream"
        case .themes:   return "Themes"
        case .advanced: return "Advanced"
        case .about:    return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:  return "gauge.with.needle"
        case .rules:    return "arrow.triangle.branch"
        case .monitor:  return "waveform"
        case .upstream: return "arrow.up.right"
        case .themes:   return "paintbrush"
        case .advanced: return "slider.horizontal.3"
        case .about:    return "info.circle"
        }
    }
}
