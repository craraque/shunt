import SwiftUI
import Darwin

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Upstream")
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.65)
                        .foregroundStyle(.white)
                    Text("The local SOCKS5 proxy claimed traffic is forwarded into.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.62))
                }

                LiquidSectionLabel(text: "SOCKS5 endpoint", theme: theme)
                LiquidCard(theme: theme, padding: EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18)) {
                    VStack(spacing: 0) {
                        liquidRow(label: "Host") {
                            AnyView(
                                TextField("10.211.55.5", text: $host)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .monospacedDigit()
                                    .frame(width: 260)
                            )
                        }
                        rowDivider
                        liquidRow(label: "Port") {
                            AnyView(
                                TextField("1080", text: $portText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .monospacedDigit()
                                    .frame(width: 120)
                            )
                        }
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(theme.accent(for: scheme))
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Advanced SSH reverse tunnel template")
                            .font(.shuntLabel.weight(.medium))
                            .foregroundStyle(.white)
                        Text("Sets upstream to `127.0.0.1:1080` and adds an editable `ssh -R` launcher with an egress-diff probe. Tart is only the default dev command; replace it for Parallels/production. Launcher commands run in a shell, so edit only trusted commands.")
                            .font(.shuntCaption)
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        applyReverseSSHTunnelPreset()
                    } label: {
                        Label("Add template", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.accent(for: scheme))
                }
                .padding(12)
                .background(theme.accent(for: scheme).opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.accent(for: scheme).opacity(0.25), lineWidth: 0.5)
                )

                LiquidSectionLabel(text: "Interface binding", theme: theme)
                LiquidCard(theme: theme, padding: EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18)) {
                    liquidRow(label: "Bind to") {
                        AnyView(
                            Picker("", selection: $bindInterface) {
                                Text("None (use routing table)").tag("")
                                ForEach(availableInterfaces, id: \.self) { name in
                                    Text(name).tag(name).font(.system(size: 12.5, design: .monospaced))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 260, alignment: .leading)
                        )
                    }
                }

                Text("Select an interface only when the upstream is unreachable via the primary NIC — e.g. a Parallels shared network on `bridge100`.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                LiquidSectionLabel(text: "DNS resolution", theme: theme)
                LiquidCard(theme: theme, padding: EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18)) {
                    liquidRow(label: "Resolve via upstream") {
                        AnyView(
                            Toggle("", isOn: $useRemoteDNS)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .tint(theme.accentDark)
                        )
                    }
                }
                Text("When ON, hostnames are forwarded in the SOCKS5 CONNECT (ATYP=0x03) so the upstream resolves them — recommended for hostname-based policies (Zscaler URL filtering, SNI matching) and to avoid leaking routed queries to your local DNS. Falls back to IP literal when the destination has no FQDN. Turn OFF only if your upstream rejects domain-name CONNECT.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                LiquidSectionLabel(text: "Authentication", theme: theme)
                LiquidCard(theme: theme, padding: EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18)) {
                    VStack(spacing: 0) {
                        liquidRow(label: "Required") {
                            AnyView(
                                Toggle("", isOn: $authEnabled)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .tint(theme.accentDark)
                            )
                        }
                        if authEnabled {
                            rowDivider
                            liquidRow(label: "Username") {
                                AnyView(
                                    TextField("user", text: $username)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .frame(width: 220)
                                )
                            }
                            rowDivider
                            liquidRow(label: "Password") {
                                AnyView(
                                    SecureField("••••••••", text: $password)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .frame(width: 220)
                                )
                            }
                        }
                    }
                }
                Text("Most upstreams (3proxy, microsocks default) accept anonymous connections — leave OFF. Turn ON only if your SOCKS5 server requires user/pass per RFC 1929.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        apply()
                    } label: {
                        applyButtonLabel
                            .frame(minWidth: 110)
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
                    if case .error(let msg) = applyStatus {
                        Text(msg)
                            .font(.shuntCaption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(msg)
                    }
                    Spacer()
                }

                if let result = model.testConnectionResult {
                    HStack(spacing: 8) {
                        if result.contains("OK") {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.statusActive(for: scheme))
                        } else if result.hasPrefix("Testing") {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(result)
                            .font(.shuntMonoData)
                            .foregroundStyle(result.contains("OK") ? theme.statusActive(for: scheme) : .secondary)
                    }
                    .padding(.top, 2)
                }

                Divider().padding(.vertical, 4)

                UpstreamLauncherSection(model: model)
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
        }
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

    private func applyReverseSSHTunnelPreset() {
        model.applyReverseSSHTunnelPreset()
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
