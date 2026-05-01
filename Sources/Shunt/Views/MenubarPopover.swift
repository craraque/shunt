import SwiftUI
import AppKit

// MARK: - Menubar popover model
//
// Lightweight observable used to push state from AppDelegate into the
// SwiftUI popover content. The popover is rebuilt cheaply each time it
// opens, so we don't need a lot of state coordination here.

@MainActor
final class MenubarPopoverModel: ObservableObject {
    @Published var statusRaw: Int = 0
    @Published var upstreamHost: String = ""
    @Published var upstreamPort: UInt16 = 0
    @Published var upstreamBindInterface: String? = nil
    @Published var connectionCount: Int = 0
    @Published var routedCount: Int = 0
    @Published var directCount: Int = 0
    @Published var lastClaimBundle: String? = nil
    @Published var lastClaimTarget: String? = nil
    @Published var theme: ShuntTheme = .filament

    /// Phase 6a — true when Shunt is in a transitional state (launcher
    /// starting/stopping or NE tunnel connecting/reasserting/disconnecting).
    /// Drives the morphing toggle's spinner and disables straight re-clicks.
    @Published var isWorking: Bool = false
    /// Phase 6b — short status string ("Starting macOS guest…", etc) when
    /// `isWorking == true`. Falls back to the default subtitle otherwise.
    @Published var workingDescription: String? = nil
    /// Phase 6e — set while a reload-tunnel-only operation is in flight.
    /// Renders the inline ↻ button as a spinner so the user gets feedback
    /// even though the master toggle stays in its routing state.
    @Published var isReloadingTunnel: Bool = false
    /// Phase 6c — set when the user has asked Shunt to disable as soon as
    /// the in-flight enable completes. Surfaced as a small banner so they
    /// know the click was queued, not lost.
    @Published var disableQueued: Bool = false

    var isRouting: Bool { statusRaw == 3 }
    var isConnecting: Bool { statusRaw == 2 || statusRaw == 4 }
    var extensionInstalled: Bool { statusRaw != 0 }

    var statusLabel: String {
        switch statusRaw {
        case 3: return "Routing"
        case 2, 4: return "Connecting"
        case 5: return "Disconnecting"
        case 1: return "Idle"
        case 0: return "No extension"
        default: return "Unknown"
        }
    }

    /// Subtitle string displayed below the brand name in the header. Live
    /// status wins (`workingDescription`), else routing/idle copy.
    var headerSubtitle: String {
        if let live = workingDescription, !live.isEmpty { return live }
        return isRouting ? "Live routing" : "Routing engine"
    }

    var upstreamSummary: String {
        guard !upstreamHost.isEmpty else { return "—" }
        if let bind = upstreamBindInterface, !bind.isEmpty {
            return "\(upstreamHost):\(upstreamPort) · \(bind)"
        }
        return "\(upstreamHost):\(upstreamPort)"
    }
}

// MARK: - Popover view
//
// Liquid-glass popover hanging from the menubar glyph. Header with brand +
// master toggle, status section with upstream summary, and a menu items
// list with shortcuts.

struct MenubarPopoverView: View {
    @ObservedObject var model: MenubarPopoverModel

    var onMasterToggle: (Bool) -> Void
    var onOpenSettings: () -> Void
    var onReloadTunnel: () -> Void
    var onShowMonitor: () -> Void
    var onShowRules: () -> Void
    var onAbout: () -> Void
    var onQuit: () -> Void

    /// `true` if the user just pressed Option while clicking on something
    /// — used by the master toggle to escalate to "reload tunnel only"
    /// instead of doing a full enable/disable cycle.
    @State private var optionDown: Bool = false

    private let width: CGFloat = 360

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            header
            Divider().background(theme.edge)
            statusSection
            Divider().background(theme.edge)
            menuList
        }
        .frame(width: width)
        .background(
            ZStack {
                LiquidWindowMaterial(material: .popover, blendingMode: .behindWindow)
                theme.desktopGradient().opacity(0.45)
                LinearGradient(
                    colors: [.white.opacity(0.18), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            }
        )
        .preferredColorScheme(.dark)
        .environment(\.shuntTheme, theme)
    }

    // MARK: Header — logo + wordmark + master toggle

    private var header: some View {
        let theme = model.theme
        return HStack(spacing: 12) {
            ShuntLogo(size: 36, theme: theme)
            VStack(alignment: .leading, spacing: 1) {
                Text("shunt")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.28)
                    .foregroundStyle(.white)
                Text(model.headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .animation(.easeInOut(duration: 0.18), value: model.headerSubtitle)
                if model.disableQueued {
                    Text("Disable queued — will run when current op finishes")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer()

            // Reload-tunnel-only button (6e). Visible whenever the tunnel is
            // up; click bounces only the NE provider, keeping launcher
            // entries (VM, sshuttle, etc.) running. Same affordance you get
            // from Option+click on the main toggle.
            if model.isRouting || model.isReloadingTunnel {
                reloadTunnelButton
            }

            // Master toggle (6a). Morphs into a spinner when busy.
            masterToggle
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // The morphing master toggle. Inline because we need:
    //   - a spinner overlay when `isWorking`
    //   - capture of Option modifier on the click (Option+click = reload tunnel only)
    //   - explicit disabled state when sysext isn't installed
    @ViewBuilder
    private var masterToggle: some View {
        let theme = model.theme
        let on = model.isRouting || model.isConnecting
        ZStack {
            // The visual switch — read-only when busy, otherwise drives the
            // toggle action via custom hit-testing below.
            Toggle("", isOn: .constant(on))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(theme.accentDark)
                .opacity(model.isWorking ? 0.55 : 1.0)
                .allowsHitTesting(false)

            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(.trailing, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Snapshot Option modifier at click time. SwiftUI's gesture
            // doesn't surface modifierFlags directly; pull from NSApp.
            let opt = NSEvent.modifierFlags.contains(.option)
            if opt && model.isRouting {
                // Power-user shortcut: ⌥+click while routing reloads tunnel
                // without touching launcher dependencies.
                onReloadTunnel()
                return
            }
            onMasterToggle(!on)
        }
        .disabled(!model.extensionInstalled)
        .help(toggleHelp)
    }

    private var toggleHelp: String {
        if !model.extensionInstalled { return "System extension not installed yet." }
        if model.isWorking, let desc = model.workingDescription { return desc }
        if model.isRouting { return "Click to disable. Option-click to reload the tunnel only." }
        return "Click to enable Shunt routing."
    }

    @ViewBuilder
    private var reloadTunnelButton: some View {
        let theme = model.theme
        Button {
            onReloadTunnel()
        } label: {
            ZStack {
                if model.isReloadingTunnel {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .tint(theme.accent(for: .dark))
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accentDark)
                }
            }
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(theme.glass)
            )
            .overlay(
                Circle().strokeBorder(theme.edge, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isReloadingTunnel)
        .help("Reload tunnel without restarting VM/dependencies")
    }

    // MARK: Status — pill + upstream summary + connection count

    private var statusSection: some View {
        let theme = model.theme
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                if model.isRouting {
                    LiquidPill(text: "Live", dot: true, kind: .active, theme: theme)
                } else if model.isConnecting {
                    LiquidPill(text: "Connecting", kind: .accent, theme: theme)
                } else if model.extensionInstalled {
                    LiquidPill(text: "Idle", kind: .neutral, theme: theme)
                } else {
                    LiquidPill(text: "No extension", kind: .warn, theme: theme)
                }

                Text(verbatim: "upstream  ·  \(model.upstreamSummary)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }

            // Quick stats — connections / routed / direct
            HStack(spacing: 6) {
                statTile(label: "Connections",
                         value: model.connectionCount > 0 ? "\(model.connectionCount)" : "—")
                statTile(label: "Routed",
                         value: compactNumber(model.routedCount))
                statTile(label: "Direct",
                         value: compactNumber(model.directCount))
            }

            // Last claim — what flow Shunt routed most recently
            if let bundle = model.lastClaimBundle, let target = model.lastClaimTarget {
                lastClaimCard(bundle: bundle, target: target)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func lastClaimCard(bundle: String, target: String) -> some View {
        let theme = model.theme
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LAST CLAIM")
                    .font(.system(size: 10))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.36))
                Spacer()
                LiquidPill(text: "matched", kind: .accent, theme: theme)
            }
            Text(bundle)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("→ \(target)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.glass)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.edge, lineWidth: 0.5)
        )
    }

    /// Compact integer formatting: 0..999 raw, 1.2k, 12.3k, 1.2M, …
    private func compactNumber(_ n: Int) -> String {
        if n == 0 { return "0" }
        if n < 1_000 { return "\(n)" }
        if n < 10_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        if n < 1_000_000 { return "\(n / 1_000)k" }
        if n < 10_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        return "\(n / 1_000_000)M"
    }

    private func statTile(label: String, value: String) -> some View {
        let theme = model.theme
        return VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.36))
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.glass)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.edge, lineWidth: 0.5)
        )
    }

    // MARK: Menu items list

    private var menuList: some View {
        VStack(spacing: 0) {
            menuRow(icon: "gearshape", title: "Open Shunt…", shortcut: "⌘,",
                    action: onOpenSettings)
            menuRow(icon: "arrow.triangle.branch", title: "Edit Rules", shortcut: "⌘R",
                    action: onShowRules)
            menuRow(icon: "waveform", title: "Show Live Monitor", shortcut: "⌘L",
                    action: onShowMonitor)
            menuRow(icon: "arrow.clockwise", title: "Reload Tunnel",
                    action: onReloadTunnel)
            menuDivider
            menuRow(icon: "info.circle", title: "About Shunt", action: onAbout)
            menuDivider
            menuRow(icon: "power", title: "Quit Shunt", shortcut: "⌘Q",
                    muted: true, action: onQuit)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func menuRow(
        icon: String,
        title: String,
        shortcut: String? = nil,
        muted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let theme = model.theme
        MenubarPopoverRow(
            icon: icon,
            title: title,
            shortcut: shortcut,
            muted: muted,
            theme: theme,
            action: action
        )
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(model.theme.edge)
            .frame(height: 0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct MenubarPopoverRow: View {
    let icon: String
    let title: String
    let shortcut: String?
    let muted: Bool
    let theme: ShuntTheme
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(muted ? Color.white.opacity(0.36) : theme.accentDark)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(muted ? Color.white.opacity(0.62) : Color.white)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.36))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
