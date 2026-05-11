import SwiftUI
import AppKit

/// Liquid Glass redesign — translucent panels over a vibrant theme-tinted
/// desktop, hairline gloss, soft drop shadows. Built as a plain `HStack`
/// (not `NavigationSplitView`) because that doesn't render reliably inside
/// the custom `NSWindow` we need for `LSUIElement=true`.
struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()
    @StateObject private var activeTheme = ActiveTheme.shared
    @StateObject private var nav = SettingsNavigation.shared
    @State private var selection: SidebarItem = .general
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // Translucent system material that lets the wallpaper through.
            // .hudWindow gives the deep, glassy substrate; behindWindow blends
            // with the desktop rather than the layer behind us.
            LiquidWindowMaterial(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // Theme-tinted desktop wash on top, semi-transparent so the system
            // material still leaks color through.
            activeTheme.current.desktopGradient()
                .opacity(0.55)
                .ignoresSafeArea()

            // Top hairline gloss — fakes the rim of light at the window's top edge.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(0.18), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 1)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 210)

                // Vertical hairline divider between sidebar and detail
                Rectangle()
                    .fill(activeTheme.current.edge)
                    .frame(width: 0.5)

                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 920, height: 620)
        .environment(\.shuntTheme, activeTheme.current)
        .preferredColorScheme(.dark)
        .tint(activeTheme.current.accentDark)
        .onAppear {
            model.reload()
            // Apply any pending deep-link request (e.g. menubar "Edit Rules").
            if let req = nav.requestedTab {
                selection = req
                nav.requestedTab = nil
            }
        }
        .onReceive(nav.$requestedTab) { new in
            if let new {
                selection = new
                // Defer clearing to avoid mutating @Published while delivering.
                DispatchQueue.main.async { nav.requestedTab = nil }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand header: logo + wordmark
            HStack(spacing: 8) {
                ShuntLogo(size: 22, theme: activeTheme.current)
                Text("shunt")
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .tracking(-0.28)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(SidebarItem.allCases) { item in
                    SidebarRow(
                        item: item,
                        isSelected: selection == item,
                        theme: activeTheme.current
                    ) {
                        selection = item
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .background(
            // Sidebar gets a slightly more opaque glass than the body so the
            // delineation is felt without a hard divider.
            Color.white.opacity(0.025)
        )
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

// MARK: - Sidebar row (liquid glass)

private struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let theme: ShuntTheme
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(isSelected ? theme.accentDark : Color.white.opacity(0.62))
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .tracking(-0.13)
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.62))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                ZStack(alignment: .leading) {
                    // Active row gradient
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(theme.cardGradient()) : AnyShapeStyle(Color.clear))

                    // Hover-only fill (when not active)
                    if !isSelected && isHovering {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    }

                    // Accent indicator — luminous bar on the left edge
                    if isSelected {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(theme.accentDark)
                            .frame(width: 2.5)
                            .padding(.leading, -5)
                            .padding(.vertical, 8)
                            .shadow(color: theme.accentDark, radius: 4)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? theme.edge : .clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
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
