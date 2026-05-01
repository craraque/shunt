import SwiftUI
import NetworkExtension

struct GeneralTab: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject private var activity = ProxyActivity.shared
    @State private var statusRaw: Int = 0
    @State private var reloadStatus: ReloadStatus = .idle
    @State private var reloadResetTask: Task<Void, Never>?

    /// Set when statusRaw transitions into 3 (.connected). Cleared on
    /// transition out. Used to render the "uptime mm:ss" mono next to the
    /// Routing pill in the hero.
    @State private var routingSince: Date? = nil
    @State private var nowTick: Date = Date()

    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

    private enum ReloadStatus: Equatable {
        case idle, reloading, ok, error(String)
    }

    /// User's last-expressed intent for the proxy toggle. Decoupled from the
    /// polled tunnel status so the toggle doesn't bounce while the launcher
    /// is still bringing up prereqs (which can take 30-60 s with a cold VM).
    @State private var desiredEnabled: Bool = false
    @State private var statusTimer: Timer?
    @State private var launcherFailedObserver: NSObjectProtocol?
    @State private var lastLauncherError: String?
    @Environment(\.shuntTheme) private var theme

    private let services = AppServices.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                title

                statusHero

                if let err = lastLauncherError {
                    launcherErrorBanner(err)
                }

                LiquidSectionLabel(text: "Behavior", theme: theme)
                LiquidCard(theme: theme, padding: EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18)) {
                    VStack(spacing: 0) {
                        liquidRow(label: "Enabled", trailing: {
                            AnyView(
                                Toggle("", isOn: Binding<Bool>(
                                    get: { isRouting || isConnecting },
                                    set: { newValue in
                                        desiredEnabled = newValue
                                        handleToggle(newValue)
                                    }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .tint(theme.accentDark)
                            )
                        })
                        rowDivider
                        liquidRow(label: "Upstream", trailing: {
                            AnyView(monoText(upstreamSummary))
                        })
                        rowDivider
                        liquidRow(label: "State", trailing: {
                            AnyView(
                                HStack(spacing: 8) {
                                    if isRouting {
                                        LiquidPill(text: "Routing", dot: true, kind: .active, theme: theme)
                                    } else if isConnecting {
                                        LiquidPill(text: "Connecting", kind: .accent, theme: theme)
                                    } else {
                                        LiquidPill(text: statusWord, kind: .neutral, theme: theme)
                                    }
                                }
                            )
                        })
                        if !activity.entries.isEmpty {
                            rowDivider
                            liquidRow(label: "Prerequisites", trailing: {
                                AnyView(
                                    HStack(spacing: 8) {
                                        monoText("\(activity.runningCount)/\(activity.entries.count) ready",
                                                 color: activity.runningCount == activity.entries.count
                                                    ? theme.signal : theme.accentDark)
                                        if activity.busy {
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                )
                            })
                        }
                        rowDivider
                        liquidRow(label: "Launch at login", trailing: {
                            AnyView(
                                HStack(spacing: 8) {
                                    Toggle("", isOn: Binding<Bool>(
                                        get: { launchAtLogin.isEnabled },
                                        set: { launchAtLogin.set($0) }
                                    ))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .tint(theme.accentDark)
                                    if let err = launchAtLogin.lastError {
                                        Text(err)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.orange)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .help(err)
                                    }
                                }
                            )
                        })
                    }
                }

                LiquidSectionLabel(text: "System Extension", theme: theme)
                LiquidCard(theme: theme, padding: EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18)) {
                    VStack(spacing: 0) {
                        liquidRow(label: "Status", trailing: {
                            AnyView(
                                LiquidPill(
                                    text: extensionInstalled ? "activated" : "not installed",
                                    dot: extensionInstalled,
                                    kind: extensionInstalled ? .active : .neutral,
                                    theme: theme
                                )
                            )
                        })
                        rowDivider
                        liquidRow(label: "Manage", trailing: {
                            AnyView(
                                HStack(spacing: 6) {
                                    Button("Activate") { services.extensionManager.activate() }
                                    Button("Deactivate") { services.extensionManager.deactivate() }
                                }
                            )
                        })
                    }
                }

                LiquidSectionLabel(text: "About this version", theme: theme)
                LiquidCard(theme: theme, padding: EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18)) {
                    liquidRow(label: "Version", trailing: {
                        AnyView(monoText("\(Self.appVersion) · build \(Self.appBuild)"))
                    })
                }

                Text("Rule changes apply live via the Apply button on the Rules tab. Use Reload Tunnel for a full tunnel restart without stopping launcher dependencies.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.36))
                    .padding(.top, 4)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .onAppear {
            refresh()
            launchAtLogin.refresh()
            // Faster tick (1Hz) so uptime mm:ss updates smoothly. The work
            // inside refresh() is just an `await statusRaw()` poll plus some
            // state mutation — cheap enough at 1Hz.
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                refresh()
            }
            launcherFailedObserver = NotificationCenter.default.addObserver(
                forName: ProxyManager.launcherFailedNotification,
                object: nil,
                queue: .main
            ) { note in
                let msg = note.userInfo?["error"] as? String ?? "unknown error"
                lastLauncherError = msg
                desiredEnabled = false
            }
        }
        .onDisappear {
            statusTimer?.invalidate()
            statusTimer = nil
            if let obs = launcherFailedObserver {
                NotificationCenter.default.removeObserver(obs)
                launcherFailedObserver = nil
            }
        }
    }

    // MARK: - Title

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("General")
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.65)
                .foregroundStyle(.white)
            Text("Routing engine status and core preferences.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    // MARK: - Status hero

    private var statusHero: some View {
        ZStack {
            // Outer glass card
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.cardGradient())
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(theme.edgeStrong, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

            // Bloom — top-right corner, accent
            ZStack {
                AccentBloom(theme: theme, diameter: 220, opacity: 0.18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .offset(x: 30, y: -40)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 16) {
                ShuntLogo(size: 56, theme: theme)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if isRouting {
                            LiquidPill(text: "Routing", dot: true, kind: .active, theme: theme)
                        } else if isConnecting || activity.busy {
                            LiquidPill(text: "Connecting", kind: .accent, theme: theme)
                        } else if extensionInstalled {
                            LiquidPill(text: "Idle", kind: .neutral, theme: theme)
                        } else {
                            LiquidPill(text: "Not installed", kind: .warn, theme: theme)
                        }
                        if let uptime = uptimeString {
                            monoText("uptime \(uptime)", color: .white.opacity(0.62), size: 11)
                        } else if !upstreamSummary.isEmpty && extensionInstalled {
                            monoText(upstreamSummary, color: .white.opacity(0.62), size: 11)
                        }
                    }
                    Text(statusTitle)
                        .font(.system(size: 19, weight: .medium))
                        .tracking(-0.38)
                        .foregroundStyle(.white)
                    Text(statusDetail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 12)

                VStack(spacing: 6) {
                    Button {
                        let isOn = isRouting || isConnecting
                        let next = !isOn
                        desiredEnabled = next
                        handleToggle(next)
                    } label: {
                        HStack(spacing: 6) {
                            let isOn = isRouting || isConnecting
                            Image(systemName: isOn ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(isOn ? "Disable" : "Enable")
                        }
                        .frame(minWidth: 96)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accentDark)
                    .controlSize(.regular)

                    Button {
                        reloadTunnel()
                    } label: {
                        reloadButtonLabel
                            .frame(minWidth: 96)
                    }
                    .buttonStyle(.bordered)
                    .tint(reloadStatus == .ok ? theme.signal : (reloadStatus == .reloading ? theme.accentDark : .white.opacity(0.5)))
                    .disabled(!extensionInstalled || reloadStatus == .reloading)
                    .animation(.easeInOut(duration: 0.18), value: reloadStatus)
                    .help("Restart the NE tunnel without stopping launcher dependencies (Tart, etc.).")
                }
            }
            .padding(20)
        }
        .frame(minHeight: 110)
    }

    // MARK: - Helpers

    private var rowDivider: some View {
        Rectangle()
            .fill(theme.edge)
            .frame(height: 0.5)
    }

    private func liquidRow(label: String, @ViewBuilder trailing: @escaping () -> AnyView) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 150, alignment: .leading)
            trailing()
            Spacer()
        }
        .padding(.vertical, 10)
    }

    private func monoText(_ s: String, color: Color = .white.opacity(0.85), size: CGFloat = 12.5) -> some View {
        Text(s)
            .font(.system(size: size, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(color)
    }

    private func launcherErrorBanner(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Launcher failed: \(err)")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { lastLauncherError = nil }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.5)
        )
    }

    // MARK: - Derived

    private var isRouting: Bool { statusRaw == 3 }
    private var isConnecting: Bool { statusRaw == 2 || statusRaw == 4 }
    private var extensionInstalled: Bool { statusRaw != 0 }

    private var statusTitle: String {
        if isRouting {
            let count = model.settings.managedApps.filter(\.enabled).count
            return "Routing \(count) \(count == 1 ? "app" : "apps")"
        }
        if activity.busy {
            if activity.entries.isEmpty { return "Starting…" }
            return "Starting \(activity.runningCount)/\(activity.entries.count) prereqs…"
        }
        if isConnecting { return "Connecting…" }
        if extensionInstalled { return "Proxy idle" }
        return "Extension not installed"
    }

    private var statusDetail: String {
        if isRouting || isConnecting {
            return "via \(upstreamSummary)"
        }
        if activity.busy {
            return "bringing up prerequisites"
        }
        return "no traffic is being routed"
    }

    private var statusWord: String {
        switch statusRaw {
        case 0: return "not configured"
        case 1: return "disconnected"
        case 2: return "connecting"
        case 3: return "routing"
        case 4: return "reconnecting"
        case 5: return "disconnecting"
        default: return "unknown"
        }
    }

    private var upstreamSummary: String {
        let host = model.settings.upstream.host
        let port = model.settings.upstream.port
        let bind = model.settings.upstream.bindInterface
        if let bind, !bind.isEmpty {
            return "\(host):\(port) · \(bind)"
        }
        return "\(host):\(port)"
    }

    // MARK: - Actions

    private func refresh() {
        Task { @MainActor in
            let raw = await services.proxyManager.statusRaw()
            let wasRouting = (statusRaw == 3)
            let isRoutingNow = (raw == 3)
            statusRaw = raw
            // Track the moment we entered .connected so the hero can render uptime.
            if isRoutingNow && !wasRouting {
                routingSince = Date()
            } else if !isRoutingNow && wasRouting {
                routingSince = nil
            }
            nowTick = Date()
        }
    }

    private var uptimeString: String? {
        guard let since = routingSince else { return nil }
        let total = Int(nowTick.timeIntervalSince(since))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    private func handleToggle(_ newValue: Bool) {
        if newValue {
            lastLauncherError = nil
            services.proxyManager.enable()
        } else {
            Task { await services.proxyManager.disable() }
        }
    }

    @ViewBuilder
    private var reloadButtonLabel: some View {
        switch reloadStatus {
        case .idle:
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                Text("Reload")
            }
        case .reloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reloading…")
            }
        case .ok:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                Text("Reloaded")
            }
        case .error:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text("Failed")
            }
        }
    }

    private func reloadTunnel() {
        reloadResetTask?.cancel()
        reloadStatus = .reloading
        let startedAt = Date()
        services.proxyManager.reloadTunnel { result in
            let elapsed = Date().timeIntervalSince(startedAt)
            let delay = max(0, 0.6 - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                switch result {
                case .success:
                    reloadStatus = .ok
                case .failure(let error):
                    reloadStatus = .error(error.localizedDescription)
                }
                reloadResetTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if !Task.isCancelled { reloadStatus = .idle }
                }
            }
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }
}
