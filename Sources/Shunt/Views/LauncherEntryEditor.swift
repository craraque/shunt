import SwiftUI
import ShuntCore

/// Modal sheet for editing a single `UpstreamLauncherEntry`. The caller owns
/// persistence — this view only calls `onSave(updatedEntry)` or `onCancel`.
struct LauncherEntryEditor: View {
    @State private var draft: UpstreamLauncherEntry
    private let onSave: (UpstreamLauncherEntry) -> Void
    private let onCancel: () -> Void

    // Health-probe sub-form state broken out so SwiftUI bindings play nicely
    // across the enum's associated values. We translate back into the enum
    // at save time.
    @State private var probeKind: ProbeKind
    @State private var cidr: String
    @State private var probeURLText: String

    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

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
                return "Fastest. TCP connect to the upstream host:port. Returns OK even before ZCC-style auth completes, so the tunnel may enable while traffic still leaks to the ISP."
            case .socks5Handshake:
                return "Connects + exchanges the SOCKS5 greeting (05 01 00 → 05 00). Proves a SOCKS5 server is answering, not that it forwards to the expected egress."
            case .egressCidrMatch:
                return "Fetches the probe URL through the SOCKS5 proxy and passes only if the returned IP falls inside the given CIDR. Use when you know the expected egress range (e.g. Zscaler 136.226.0.0/16)."
            case .egressDiffersFromDirect:
                return "Fetches the probe URL both directly and through the proxy and passes only if the two IPs differ. CIDR-free, works for any upstream whose purpose is to shift egress. Recommended default for Zscaler/VPN setups."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(draft.name.isEmpty ? "New launcher entry" : "Edit entry")
                    .font(.shuntTitle2)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    basics
                    commands
                    probe
                    timing
                    warningBanner
                }
                .padding(24)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { persistAndDismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent(for: scheme))
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              draft.startCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 620)
    }

    // MARK: - Sections

    private var basics: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(label: "Entry", icon: "rectangle.and.text.magnifyingglass")
            FormRow("Name") {
                TextField("Tart VM — mac-zscaler-test", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 380)
            }
            FormRow("Enabled") {
                Toggle("", isOn: $draft.enabled)
                    .labelsHidden()
            }
        }
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                label: "Commands",
                icon: "terminal",
                tooltip: "Shell commands run via /bin/zsh -l -c so your login PATH resolves binaries. The start command should block (stay in the foreground) for the lifetime of the prerequisite — Shunt tracks its PID to stop it later."
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Start command")
                    .font(.shuntLabel)
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft.startCommand)
                    .font(.shuntMonoData)
                    .frame(minHeight: 54)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Stop command (optional)")
                    .font(.shuntLabel)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { draft.stopCommand ?? "" },
                    set: { draft.stopCommand = $0.isEmpty ? nil : $0 }
                ))
                .font(.shuntMonoData)
                .frame(minHeight: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                Text("Leave empty to send SIGTERM to the tracked PID (10 s grace, then SIGKILL).")
                    .font(.shuntCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var probe: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                label: "Health probe",
                icon: "waveform.path.ecg",
                tooltip: "How Shunt decides the prerequisite is ready. Port-level probes are fastest; egress probes validate the end-to-end path and avoid false positives during the upstream's own auth window."
            )

            Picker("", selection: $probeKind) {
                ForEach(ProbeKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 360, alignment: .leading)

            Text(probeKind.detail)
                .font(.shuntCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            switch probeKind {
            case .portOpen, .socks5Handshake:
                EmptyView()
            case .egressCidrMatch:
                FormRow("Expected CIDR") {
                    TextField("136.226.0.0/16", text: $cidr)
                        .textFieldStyle(.roundedBorder)
                        .font(.shuntMonoData)
                        .frame(width: 260)
                }
                FormRow("Probe URL") {
                    TextField("https://ifconfig.me/ip", text: $probeURLText)
                        .textFieldStyle(.roundedBorder)
                        .font(.shuntMonoData)
                        .frame(width: 380)
                }
            case .egressDiffersFromDirect:
                FormRow("Probe URL") {
                    TextField("https://ifconfig.me/ip", text: $probeURLText)
                        .textFieldStyle(.roundedBorder)
                        .font(.shuntMonoData)
                        .frame(width: 380)
                }
            }
        }
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(label: "Timing", icon: "timer")
            FormRow("Start timeout") {
                Stepper(value: $draft.startTimeoutSeconds, in: 10...300, step: 5) {
                    Text("\(draft.startTimeoutSeconds) s")
                        .font(.shuntMonoData)
                        .frame(width: 60, alignment: .leading)
                }
                .frame(width: 220, alignment: .leading)
            }
            FormRow("Probe interval") {
                Stepper(value: $draft.probeIntervalSeconds, in: 1...30, step: 1) {
                    Text("\(draft.probeIntervalSeconds) s")
                        .font(.shuntMonoData)
                        .frame(width: 60, alignment: .leading)
                }
                .frame(width: 220, alignment: .leading)
            }
        }
    }

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Shunt will execute this command as your user via a login shell. Only add commands you fully trust — Shunt does not sandbox or validate them.")
                .font(.shuntCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
