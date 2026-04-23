import SwiftUI
import NetworkExtension

struct GeneralTab: View {
    @ObservedObject var model: SettingsViewModel
    @State private var statusRaw: Int = 0
    @State private var proxyEnabled: Bool = false
    @State private var statusTimer: Timer?
    @State private var busy = false
    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private let services = AppServices.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("General")
                    .font(.shuntTitle1)

                StatusCard(
                    title: statusTitle,
                    detail: statusDetail,
                    active: isRouting
                )

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        label: "Proxy",
                        icon: "bolt.horizontal.fill",
                        tooltip: "Toggle the per-app proxy on or off. Disable to send all traffic via the host network temporarily."
                    )
                    VStack(spacing: 0) {
                        FormRow("Enabled") {
                            Toggle("", isOn: $proxyEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .tint(theme.accent(for: scheme))
                                .disabled(busy)
                                .onChange(of: proxyEnabled) { _, newValue in
                                    handleToggle(newValue)
                                }
                        }
                        Divider()
                        FormRow("Upstream") {
                            MonoText(upstreamSummary, color: .secondary)
                        }
                        Divider()
                        FormRow("State") {
                            MonoText(
                                statusWord,
                                color: isRouting ? theme.statusActive(for: scheme) : .secondary
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        label: "System extension",
                        icon: "puzzlepiece.extension",
                        tooltip: "The kernel-level component that intercepts flows and routes claimed apps through the upstream. Activation prompts macOS for permission once."
                    )
                    VStack(spacing: 0) {
                        FormRow("Status") {
                            MonoText(
                                extensionInstalled ? "activated" : "not installed",
                                color: extensionInstalled ? theme.statusActive(for: scheme) : .secondary
                            )
                        }
                        Divider()
                        HStack(spacing: 8) {
                            Text("Manage")
                                .font(.shuntLabel)
                                .foregroundStyle(.secondary)
                                .frame(width: 140, alignment: .leading)
                            Button("Activate") { services.extensionManager.activate() }
                            Button("Deactivate") { services.extensionManager.deactivate() }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.horizontal, 4)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        label: "About this version",
                        icon: "info.circle",
                        tooltip: "App and build numbers. Useful for filing issues."
                    )
                    VStack(spacing: 0) {
                        FormRow("Version") {
                            MonoText("\(Self.appVersion) · build \(Self.appBuild)", color: .secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                Text("Changes to Apps or Upstream take effect the next time you re-enable the proxy.")
                    .font(.shuntCaption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(28)
        }
        .onAppear {
            refresh()
            statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                refresh()
            }
        }
        .onDisappear {
            statusTimer?.invalidate()
            statusTimer = nil
        }
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
        if isConnecting { return "Connecting…" }
        if extensionInstalled { return "Proxy idle" }
        return "Extension not installed"
    }

    private var statusDetail: String {
        isRouting || isConnecting
            ? "via \(upstreamSummary)"
            : "no traffic is being routed"
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

    // MARK: - Refresh + actions

    private func refresh() {
        Task { @MainActor in
            let raw = await services.proxyManager.statusRaw()
            statusRaw = raw
            proxyEnabled = raw == 2 || raw == 3 || raw == 4
        }
    }

    private func handleToggle(_ newValue: Bool) {
        busy = true
        if newValue {
            services.proxyManager.enable()
        } else {
            Task { await services.proxyManager.disable() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            refresh()
            busy = false
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }
}
