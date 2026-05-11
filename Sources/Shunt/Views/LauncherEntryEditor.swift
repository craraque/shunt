import SwiftUI
import AppKit
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
    @State private var probeHost: String
    @State private var probePortText: String
    @State private var probeCommand: String

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
            _probeHost = State(initialValue: "127.0.0.1")
            _probePortText = State(initialValue: "1080")
            _probeCommand = State(initialValue: "")
        case .socks5Handshake:
            _probeKind = State(initialValue: .socks5Handshake)
            _cidr = State(initialValue: "")
            _probeURLText = State(initialValue: HealthProbe.defaultProbeURL.absoluteString)
            _probeHost = State(initialValue: "127.0.0.1")
            _probePortText = State(initialValue: "1080")
            _probeCommand = State(initialValue: "")
        case .tcpConnect(let host, let port):
            _probeKind = State(initialValue: .tcpConnect)
            _cidr = State(initialValue: "")
            _probeURLText = State(initialValue: HealthProbe.defaultProbeURL.absoluteString)
            _probeHost = State(initialValue: host)
            _probePortText = State(initialValue: String(port))
            _probeCommand = State(initialValue: "")
        case .socks5HandshakeAt(let host, let port):
            _probeKind = State(initialValue: .socks5HandshakeAt)
            _cidr = State(initialValue: "")
            _probeURLText = State(initialValue: HealthProbe.defaultProbeURL.absoluteString)
            _probeHost = State(initialValue: host)
            _probePortText = State(initialValue: String(port))
            _probeCommand = State(initialValue: "")
        case .commandExitZero(let command):
            _probeKind = State(initialValue: .commandExitZero)
            _cidr = State(initialValue: "")
            _probeURLText = State(initialValue: HealthProbe.defaultProbeURL.absoluteString)
            _probeHost = State(initialValue: "127.0.0.1")
            _probePortText = State(initialValue: "1080")
            _probeCommand = State(initialValue: command)
        case .egressCidrMatch(let c, let u):
            _probeKind = State(initialValue: .egressCidrMatch)
            _cidr = State(initialValue: c)
            _probeURLText = State(initialValue: u.absoluteString)
            _probeHost = State(initialValue: "127.0.0.1")
            _probePortText = State(initialValue: "1080")
            _probeCommand = State(initialValue: "")
        case .egressDiffersFromDirect(let u):
            _probeKind = State(initialValue: .egressDiffersFromDirect)
            _cidr = State(initialValue: "")
            _probeURLText = State(initialValue: u.absoluteString)
            _probeHost = State(initialValue: "127.0.0.1")
            _probePortText = State(initialValue: "1080")
            _probeCommand = State(initialValue: "")
        }
    }

    enum ProbeKind: String, CaseIterable, Identifiable {
        case portOpen, socks5Handshake, tcpConnect, socks5HandshakeAt, commandExitZero, egressCidrMatch, egressDiffersFromDirect
        var id: String { rawValue }
        var label: String {
            switch self {
            case .portOpen: return "Upstream port open (TCP)"
            case .socks5Handshake: return "Upstream SOCKS5 handshake"
            case .tcpConnect: return "Custom TCP host/port"
            case .socks5HandshakeAt: return "Custom SOCKS5 host/port"
            case .commandExitZero: return "Command exits 0"
            case .egressCidrMatch: return "Egress IP matches CIDR"
            case .egressDiffersFromDirect: return "Egress IP differs from direct"
            }
        }
        var detail: String {
            switch self {
            case .portOpen:
                return "Fastest. TCP connect to the configured upstream host:port. For reverse tunnels, use this only after the tunnel stage has run."
            case .socks5Handshake:
                return "Connects to the configured upstream and exchanges the SOCKS5 greeting (05 01 00 → 05 00)."
            case .tcpConnect:
                return "TCP connect to an explicit host/port, independent of the upstream settings. Good for VM SSH readiness, e.g. 192.0.2.10:22."
            case .socks5HandshakeAt:
                return "SOCKS5 greeting against an explicit host/port. Good for checking a reverse tunnel listener such as 127.0.0.1:1080."
            case .commandExitZero:
                return "Runs a shell command and passes only when it exits 0. Good for VM-ready checks such as prlctl exec \"VM\" /usr/bin/true."
            case .egressCidrMatch:
                return "Fetches the probe URL through the SOCKS5 proxy and passes only if the returned IP falls inside the given CIDR. Use when you know the expected upstream egress range."
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
                            TextField("Tart VM — mac-zscaler-test", text: $draft.name)
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
                        ShellCommandEditor(text: $draft.startCommand)
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
                        ShellCommandEditor(text: Binding(
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
                    case .tcpConnect, .socks5HandshakeAt:
                        VStack(spacing: 0) {
                            row(label: "Host") {
                                AnyView(
                                    TextField("127.0.0.1", text: $probeHost)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .frame(width: 260)
                                )
                            }
                            rowDivider
                            row(label: "Port") {
                                AnyView(
                                    TextField("1080", text: $probePortText)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .frame(width: 120)
                                )
                            }
                        }
                        .padding(.top, 8)
                    case .commandExitZero:
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Probe command")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.62))
                            ShellCommandEditor(text: $probeCommand)
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
                        .padding(.top, 8)
                    case .egressCidrMatch:
                        VStack(spacing: 0) {
                            row(label: "Expected CIDR") {
                                AnyView(
                                    TextField("136.226.0.0/16", text: $cidr)
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

    private var cleanedProbeHost: String {
        let trimmed = probeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "127.0.0.1" : trimmed
    }

    private var cleanedProbePort: UInt16 {
        UInt16(probePortText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1080
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
        draft.startCommand = draft.startCommand
            .normalizingShellPunctuation()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = draft.stopCommand {
            let trimmed = s
                .normalizingShellPunctuation()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            draft.stopCommand = trimmed.isEmpty ? nil : trimmed
        }

        switch probeKind {
        case .portOpen:
            draft.healthProbe = .portOpen
        case .socks5Handshake:
            draft.healthProbe = .socks5Handshake
        case .tcpConnect:
            draft.healthProbe = .tcpConnect(
                host: cleanedProbeHost,
                port: cleanedProbePort
            )
        case .socks5HandshakeAt:
            draft.healthProbe = .socks5HandshakeAt(
                host: cleanedProbeHost,
                port: cleanedProbePort
            )
        case .commandExitZero:
            draft.healthProbe = .commandExitZero(
                command: probeCommand
                    .normalizingShellPunctuation()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
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

private struct ShellCommandEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = .white
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = .white
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
