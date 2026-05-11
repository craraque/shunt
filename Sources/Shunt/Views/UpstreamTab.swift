import SwiftUI
import Darwin
import ShuntCore

struct UpstreamTab: View {
    @ObservedObject var model: SettingsViewModel
    @State private var host: String = ""
    @State private var portText: String = ""
    @State private var bindInterface: String = ""
    @State private var availableInterfaces: [String] = []
    @State private var authEnabled: Bool = false
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var useRemoteDNS: Bool = true
    @State private var applyStatus: ApplyStatus = .idle
    @State private var applyResetTask: Task<Void, Never>?
    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private enum ApplyStatus: Equatable {
        case idle
        case applying
        case ok
        case error(String)
    }

    private enum ReverseTunnelTemplate: CaseIterable, Identifiable {
        case tart
        case parallels
        case plainSSH
        case nestedSSH

        var id: String { title }

        var title: String {
            switch self {
            case .tart: return "Tart VM"
            case .parallels: return "Parallels VM"
            case .plainSSH: return "Plain SSH"
            case .nestedSSH: return "Nested SSH / network host"
            }
        }

        var systemImage: String {
            switch self {
            case .tart, .parallels: return "desktopcomputer"
            case .plainSSH: return "terminal"
            case .nestedSSH: return "network"
            }
        }

        /// Prefix run before the generated `ssh -N -R ...` command. These are
        /// intentionally editable placeholders in the Launcher tab.
        var commandPrefix: String {
            switch self {
            case .tart:
                return "tart exec <vm-name>"
            case .parallels:
                return "prlctl exec \"<vm-name>\""
            case .plainSSH:
                return ""
            case .nestedSSH:
                return "ssh user@network-host"
            }
        }

        /// Host address as seen from the machine that runs the generated SSH
        /// command. Users should edit this in the Launcher entry if their VM or
        /// network host sees the Mac at a different address.
        var hostBridgeIP: String {
            switch self {
            case .tart: return "192.168.64.1"
            case .parallels: return "10.211.55.2"
            case .plainSSH, .nestedSSH: return "host.local"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Upstream")
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.65)
                        .foregroundStyle(.white)
                    Text("Forward matched app traffic to a SOCKS5 upstream.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.62))
                }

                connectionSection

                actionStatusSection

                Divider().padding(.vertical, 4)

                UpstreamLauncherSection(model: model, templateMenu: AnyView(reverseTunnelTemplateMenu))
            }
            .padding(28)
        }
        .onAppear {
            host = model.settings.upstream.host
            portText = String(model.settings.upstream.port)
            bindInterface = model.settings.upstream.bindInterface ?? ""
            username = model.settings.upstream.username
            password = model.settings.upstream.password
            authEnabled = !username.isEmpty || !password.isEmpty
            useRemoteDNS = model.settings.upstream.useRemoteDNS
            refreshInterfaces()
            model.refreshSystemExtensionHealth()
        }
    }

    // MARK: - Layout sections

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LiquidSectionLabel(text: "Connection", theme: theme)
            LiquidCard(theme: theme, padding: EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)) {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 18) {
                        compactField(label: "Host") {
                            TextField("127.0.0.1", text: $host)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity)
                        }
                        compactField(label: "Port", width: 96) {
                            TextField("1080", text: $portText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5, design: .monospaced))
                                .monospacedDigit()
                                .frame(width: 96)
                        }
                    }
                    .padding(.vertical, 8)

                    rowDivider

                    HStack(alignment: .top, spacing: 18) {
                        compactField(label: "Bind interface") {
                            Picker("", selection: $bindInterface) {
                                Text("None / routing table").tag("")
                                ForEach(availableInterfaces, id: \.self) { name in
                                    Text(name).tag(name).font(.system(size: 12.5, design: .monospaced))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help("Use only when the upstream is reachable through a specific NIC, such as a Parallels bridge.")
                        }
                        compactField(label: "DNS", width: 160) {
                            Toggle("Resolve upstream", isOn: $useRemoteDNS)
                                .toggleStyle(.switch)
                                .tint(theme.accentDark)
                        }
                    }
                    .padding(.vertical, 8)

                    rowDivider

                    VStack(spacing: 0) {
                        HStack {
                            Toggle("Authentication required", isOn: $authEnabled)
                                .toggleStyle(.switch)
                                .tint(theme.accentDark)
                            Spacer()
                            Text("Leave off for anonymous SOCKS5 upstreams.")
                                .font(.shuntCaption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)

                        if authEnabled {
                            rowDivider
                            HStack(alignment: .top, spacing: 18) {
                                compactField(label: "Username") {
                                    TextField("user", text: $username)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12.5, design: .monospaced))
                                }
                                compactField(label: "Password") {
                                    SecureField("••••••••", text: $password)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12.5, design: .monospaced))
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
            Text("Remote DNS sends hostnames in SOCKS5 CONNECT. Turn it off only if your upstream rejects domain-name CONNECT.")
                .font(.shuntCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    apply()
                } label: {
                    applyButtonLabel.frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(applyButtonTint)
                .keyboardShortcut(.defaultAction)
                .disabled(applyStatus == .applying)
                .animation(.easeInOut(duration: 0.18), value: applyStatus)

                Button("Test Connection") {
                    apply()
                    model.testConnection()
                }

                Spacer()

                if let health = model.systemExtensionHealth,
                   health.status.requiresUserAction {
                    Button(extensionActionTitle(for: health.status)) {
                        performExtensionAction(for: health.status)
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.accent(for: scheme))
                }
            }

            statusCard
        }
    }

    private var reverseTunnelTemplateMenu: some View {
        Menu {
            ForEach(ReverseTunnelTemplate.allCases) { template in
                Button {
                    applyReverseSSHTunnelPreset(template)
                } label: {
                    Label(template.title, systemImage: template.systemImage)
                }
            }
        } label: {
            Label("Add SSH reverse tunnel", systemImage: "arrow.triangle.2.circlepath")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .tint(theme.accent(for: scheme))
        .help("Creates an editable ssh -R launcher stage and sets upstream to 127.0.0.1:1080.")
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result = model.testConnectionResult {
                statusRow(
                    icon: result.contains("OK") ? "checkmark.circle.fill" : result.hasPrefix("Testing") ? "clock" : "exclamationmark.triangle.fill",
                    title: "SOCKS5 upstream",
                    detail: result,
                    color: result.contains("OK") ? theme.statusActive(for: scheme) : .orange
                )
            }

            statusRow(
                icon: applyStatusIcon,
                title: "Extension apply",
                detail: applyStatusDetail,
                color: applyStatusColor
            )

            if let health = model.systemExtensionHealth {
                statusRow(
                    icon: extensionStatusIcon(health.status),
                    title: "System Extension",
                    detail: "\(health.status.title). \(health.detail)",
                    color: extensionStatusColor(health.status),
                    actions: {
                        if health.status.requiresUserAction {
                            Button(extensionActionTitle(for: health.status)) { performExtensionAction(for: health.status) }
                                .buttonStyle(.bordered)
                            Button("Settings") { model.openSystemExtensionSettings() }
                                .buttonStyle(.bordered)
                        }
                    }
                )
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    // MARK: - Helpers

    private var rowDivider: some View {
        Rectangle()
            .fill(theme.edge)
            .frame(height: 0.5)
    }

    private func liquidRow<Content: View>(label: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 150, alignment: .leading)
            content()
            Spacer()
        }
        .padding(.vertical, 10)
    }

    private func compactField<Content: View>(label: String, width: CGFloat? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.shuntCaption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(width: width, alignment: .leading)
    }

    private func statusRow<Actions: View>(
        icon: String,
        title: String,
        detail: String,
        color: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(title)
                .font(.shuntCaption.weight(.medium))
                .frame(width: 120, alignment: .leading)
            Text(detail)
                .font(.shuntCaption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(detail)
            Spacer(minLength: 8)
            actions()
        }
    }

    private func statusRow(
        icon: String,
        title: String,
        detail: String,
        color: Color
    ) -> some View {
        statusRow(icon: icon, title: title, detail: detail, color: color) { EmptyView() }
    }

    private var applyStatusIcon: String {
        switch applyStatus {
        case .idle: return "circle"
        case .applying: return "clock"
        case .ok: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var applyStatusDetail: String {
        switch applyStatus {
        case .idle:
            return "No live changes applied yet."
        case .applying:
            return "Saving configuration and pushing live rules to the extension…"
        case .ok:
            return "Configuration saved and applied live."
        case .error(let msg):
            if msg == "<no reply>" {
                return "Configuration saved, but the Network Extension did not reply. Update the extension or reload the tunnel."
            }
            return msg
        }
    }

    private var applyStatusColor: Color {
        switch applyStatus {
        case .idle: return .secondary
        case .applying: return theme.accent(for: scheme)
        case .ok: return theme.statusActive(for: scheme)
        case .error: return .orange
        }
    }

    private func extensionStatusIcon(_ status: SystemExtensionCompatibilityStatus) -> String {
        switch status {
        case .compatible: return "checkmark.circle.fill"
        case .updateAvailable: return "arrow.up.circle.fill"
        case .updateRequired, .awaitingUserApproval, .restartRequired, .notInstalled, .bundledMissing, .unknown: return "exclamationmark.triangle.fill"
        }
    }

    private func extensionStatusColor(_ status: SystemExtensionCompatibilityStatus) -> Color {
        switch status {
        case .compatible: return theme.statusActive(for: scheme)
        case .updateAvailable: return theme.accent(for: scheme)
        case .updateRequired, .awaitingUserApproval, .restartRequired, .notInstalled, .bundledMissing, .unknown: return .orange
        }
    }

    private func extensionActionTitle(for status: SystemExtensionCompatibilityStatus) -> String {
        switch status {
        case .awaitingUserApproval:
            return "Open Settings"
        case .restartRequired:
            return "Restart Required"
        case .updateAvailable, .updateRequired:
            return "Update Extension"
        case .notInstalled, .bundledMissing, .unknown, .compatible:
            return "Activate"
        }
    }

    private func performExtensionAction(for status: SystemExtensionCompatibilityStatus) {
        switch status {
        case .awaitingUserApproval, .restartRequired:
            model.openSystemExtensionSettings()
        case .updateAvailable, .updateRequired, .notInstalled, .bundledMissing, .unknown, .compatible:
            model.updateSystemExtension()
        }
    }

    private func applyReverseSSHTunnelPreset(_ template: ReverseTunnelTemplate = .tart) {
        model.applyReverseSSHTunnelPreset(
            commandPrefix: template.commandPrefix,
            hostBridgeIP: template.hostBridgeIP
        )
        host = model.settings.upstream.host
        portText = String(model.settings.upstream.port)
        bindInterface = model.settings.upstream.bindInterface ?? ""
        username = model.settings.upstream.username
        password = model.settings.upstream.password
        authEnabled = !username.isEmpty || !password.isEmpty
        useRemoteDNS = model.settings.upstream.useRemoteDNS
        applyResetTask?.cancel()
        applyStatus = .ok
        applyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { applyStatus = .idle }
        }
    }

    private func apply() {
        let port = UInt16(portText) ?? model.settings.upstream.port
        portText = String(port)
        let user = authEnabled ? username.trimmingCharacters(in: .whitespaces) : ""
        let pass = authEnabled ? password : ""
        model.updateUpstream(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            bindInterface: bindInterface.isEmpty ? nil : bindInterface,
            username: user,
            password: pass,
            useRemoteDNS: useRemoteDNS
        )
        applyResetTask?.cancel()
        applyStatus = .applying
        let startedAt = Date()
        AppServices.shared.proxyManager.applyRulesLive { result in
            // Hold "Applying…" for at least 600ms so the spinner is visible
            // even when the IPC roundtrip is sub-millisecond.
            let elapsed = Date().timeIntervalSince(startedAt)
            let delay = max(0, 0.6 - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                switch result {
                case .success:
                    applyStatus = .ok
                case .failure(let error):
                    applyStatus = .error(error.localizedDescription)
                }
                model.refreshSystemExtensionHealth()
                applyResetTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if !Task.isCancelled { applyStatus = .idle }
                }
            }
        }
    }

    @ViewBuilder
    private var applyButtonLabel: some View {
        switch applyStatus {
        case .idle:
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle")
                Text("Apply")
            }
        case .applying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                    .colorInvert().brightness(1)
                Text("Applying…")
            }
        case .ok:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("Applied")
            }
        case .error:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Failed")
            }
        }
    }

    private var applyButtonTint: Color {
        switch applyStatus {
        case .idle, .applying:
            return theme.accent(for: scheme)
        case .ok:
            return theme.statusActive(for: scheme)
        case .error:
            return .orange
        }
    }

    private func refreshInterfaces() {
        availableInterfaces = Self.listInterfaces()
        if !bindInterface.isEmpty && !availableInterfaces.contains(bindInterface) {
            availableInterfaces.append(bindInterface)
        }
    }

    private static func listInterfaces() -> [String] {
        var result = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            let family = cur.pointee.ifa_addr?.pointee.sa_family ?? 0
            if (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0,
               family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) {
                let name = String(cString: cur.pointee.ifa_name)
                result.insert(name)
            }
            ptr = cur.pointee.ifa_next
        }
        return result.sorted()
    }
}
