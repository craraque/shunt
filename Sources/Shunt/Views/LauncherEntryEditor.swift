import SwiftUI
import ShuntCore

/// Modal sheet for editing a single `UpstreamLauncherEntry`. Liquid glass
/// styled — translucent background, accent-tinted section labels, edge
/// hairline borders. Caller owns persistence via `onSave` / `onCancel`.
struct LauncherEntryEditor: View {
    @State private var draft: UpstreamLauncherEntry
    private let onSave: (UpstreamLauncherEntry) -> Void
    private let onCancel: () -> Void

    @State private var probeKind: ProbeKind
    @State private var cidr: String
    @State private var probeURLText: String

    @Environment(\.shuntTheme) private var theme

    init(entry: UpstreamLauncherEntry,
         onSave: @escaping (UpstreamLauncherEntry) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: entry)
        self.onSave = onSave
        self.onCancel = onCancel

        switch entry.healthProbe {
        case .portOpen:
            _probeKind = State(initialValue: .portOpen)
            _cidr = State(initialValue: "")
            _probeURLText = State(initialValue: HealthProbe.defaultProbeURL.absoluteString)
        case .socks5Handshake:
            _probeKind = State(initialValue: .socks5Handshake)
            _cidr = State(initialValue: "")
            _probeURLText = State(initialValue: HealthProbe.defaultProbeURL.absoluteString)
        case .egressCidrMatch(let c, let u):
            _probeKind = State(initialValue: .egressCidrMatch)
            _cidr = State(initialValue: c)
            _probeURLText = State(initialValue: u.absoluteString)
        case .egressDiffersFromDirect(let u):
            _probeKind = State(initialValue: .egressDiffersFromDirect)
            _cidr = State(initialValue: "")
            _probeURLText = State(initialValue: u.absoluteString)
        }
    }

    enum ProbeKind: String, CaseIterable, Identifiable {
        case portOpen, socks5Handshake, egressCidrMatch, egressDiffersFromDirect
        var id: String { rawValue }
        var label: String {
            switch self {
            case .portOpen: return "Port open (TCP)"
            case .socks5Handshake: return "SOCKS5 handshake"
            case .egressCidrMatch: return "Egress IP matches CIDR"
            case .egressDiffersFromDirect: return "Egress IP differs from direct"
            }
        }
        var detail: String {
            switch self {
            case .portOpen:
                return "Fastest. TCP connect to the upstream host:port. Returns OK as soon as the service accepts connections, which may be before the upstream path is fully ready."
            case .socks5Handshake:
                return "Connects + exchanges the SOCKS5 greeting (05 01 00 → 05 00). Proves a SOCKS5 server is answering, not that it forwards to the expected egress."
            case .egressCidrMatch:
                return "Fetches the probe URL through the SOCKS5 proxy and passes only if the returned IP falls inside the given CIDR. Use when you know the expected egress range (e.g. upstream provider 203.0.113.0/24)."
            case .egressDiffersFromDirect:
                return "Fetches the probe URL both directly and through the proxy and passes only if the two IPs differ. CIDR-free, works for any upstream whose purpose is to shift egress."
            }
        }
    }

    var body: some View {
        ZStack {
            LiquidWindowMaterial(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
            theme.desktopGradient()
                .opacity(0.55)
                .ignoresSafeArea()
            // Hairline gloss at top
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(0.18), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 1)
                Spacer()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                // Header
                Text(draft.name.isEmpty ? "New launcher entry" : "Edit entry")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.55)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 14)

                Rectangle()
                    .fill(theme.edge)
                    .frame(height: 0.5)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        basics
                        commands
                        ownership
                        probe
                        timing
                        warningBanner
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                }

                Rectangle()
                    .fill(theme.edge)
                    .frame(height: 0.5)

                HStack {
                    Spacer()
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button {
                        persistAndDismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                            Text("Save")
                        }
                        .frame(minWidth: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accentDark)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              draft.startCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 640, height: 640)
        .preferredColorScheme(.dark)
        .environment(\.shuntTheme, theme)
    }

    // MARK: - Sections

    private var basics: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiquidSectionLabel(text: "Entry", theme: theme)
            LiquidCard(theme: theme, padding: EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)) {
                VStack(spacing: 0) {
                    row(label: "Name") {
                        AnyView(
                            TextField("Tart VM — proxy-vm", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 380)
                        )
                    }
                    rowDivider
                    row(label: "Enabled") {
                        AnyView(
                            Toggle("", isOn: $draft.enabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .tint(theme.accentDark)
                        )
                    }
                }
            }
        }
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiquidSectionLabel(text: "Commands", theme: theme)
            LiquidCard(theme: theme) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start command")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.62))
                        TextEditor(text: $draft.startCommand)
                            .font(.system(size: 12.5, design: .monospaced))
                            .frame(minHeight: 54)
                            .scrollContentBackground(.hidden)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.black.opacity(0.28))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(theme.edgeStrong, lineWidth: 0.5)
                            )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stop command (optional)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.62))
                        TextEditor(text: Binding(
                            get: { draft.stopCommand ?? "" },
                            set: { draft.stopCommand = $0.isEmpty ? nil : $0 }
                        ))
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(minHeight: 48)
                        .scrollContentBackground(.hidden)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.black.opacity(0.28))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(theme.edgeStrong, lineWidth: 0.5)
                        )
                        Text("Leave empty to send SIGTERM to the tracked PID (10 s grace, then SIGKILL).")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.36))
                    }
                }
            }
        }
    }

    private var ownership: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiquidSectionLabel(text: "When already running", theme: theme)
            LiquidCard(theme: theme) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $draft.externalPolicy) {
                        Text("Ask each time").tag(LauncherExternalPolicy.ask)
                        Text("Always reclaim (Shunt manages it)").tag(LauncherExternalPolicy.alwaysReclaim)
                        Text("Never reclaim (manual lifecycle)").tag(LauncherExternalPolicy.neverReclaim)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 360, alignment: .leading)

                    Text(externalPolicyDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var externalPolicyDetail: String {
        switch draft.externalPolicy {
        case .ask:
            return "If Shunt finds this entry already running on enable, it will ask whether to take over its lifecycle. Your answer is remembered."
        case .alwaysReclaim:
            return "Shunt always treats already-running instances as its own and runs the stop command on disable. Use for VMs (prlctl, tart) you fully delegate to Shunt."
        case .neverReclaim:
            return "Shunt only stops what it itself spawned in this session. Use when something else may have started this daemon and stopping it would inconvenience another consumer."
        }
    }

    private var probe: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiquidSectionLabel(text: "Health probe", theme: theme)
            LiquidCard(theme: theme) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $probeKind) {
                        ForEach(ProbeKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 360, alignment: .leading)

                    Text(probeKind.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    switch probeKind {
                    case .portOpen, .socks5Handshake:
                        EmptyView()
                    case .egressCidrMatch:
                        VStack(spacing: 0) {
                            row(label: "Expected CIDR") {
                                AnyView(
                                    TextField("203.0.113.0/24", text: $cidr)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .frame(width: 260)
                                )
                            }
                            rowDivider
                            row(label: "Probe URL") {
                                AnyView(
                                    TextField("https://ifconfig.me/ip", text: $probeURLText)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .frame(width: 380)
                                )
                            }
                        }
                        .padding(.top, 8)
                    case .egressDiffersFromDirect:
                        row(label: "Probe URL") {
                            AnyView(
                                TextField("https://ifconfig.me/ip", text: $probeURLText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .frame(width: 380)
                            )
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiquidSectionLabel(text: "Timing", theme: theme)
            LiquidCard(theme: theme, padding: EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)) {
                VStack(spacing: 0) {
                    row(label: "Start timeout") {
                        AnyView(
                            Stepper(value: $draft.startTimeoutSeconds, in: 10...300, step: 5) {
                                Text("\(draft.startTimeoutSeconds) s")
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .frame(width: 60, alignment: .leading)
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 200, alignment: .leading)
                        )
                    }
                    rowDivider
                    row(label: "Probe interval") {
                        AnyView(
                            Stepper(value: $draft.probeIntervalSeconds, in: 1...30, step: 1) {
                                Text("\(draft.probeIntervalSeconds) s")
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .frame(width: 60, alignment: .leading)
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 200, alignment: .leading)
                        )
                    }
                }
            }
        }
    }

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Shunt will execute this command as your user via a login shell. Only add commands you fully trust — Shunt does not sandbox or validate them.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private var rowDivider: some View {
        Rectangle()
            .fill(theme.edge)
            .frame(height: 0.5)
    }

    private func row<Content: View>(label: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 130, alignment: .leading)
            content()
            Spacer()
        }
        .padding(.vertical, 10)
    }

    // MARK: - Save

    private func persistAndDismiss() {
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        draft.startCommand = draft.startCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = draft.stopCommand {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.stopCommand = trimmed.isEmpty ? nil : trimmed
        }

        switch probeKind {
        case .portOpen:
            draft.healthProbe = .portOpen
        case .socks5Handshake:
            draft.healthProbe = .socks5Handshake
        case .egressCidrMatch:
            let url = URL(string: probeURLText) ?? HealthProbe.defaultProbeURL
            draft.healthProbe = .egressCidrMatch(
                cidr: cidr.trimmingCharacters(in: .whitespaces),
                probeURL: url
            )
        case .egressDiffersFromDirect:
            let url = URL(string: probeURLText) ?? HealthProbe.defaultProbeURL
            draft.healthProbe = .egressDiffersFromDirect(probeURL: url)
        }

        onSave(draft)
    }
}
