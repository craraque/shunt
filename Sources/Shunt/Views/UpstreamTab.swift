import SwiftUI
import Darwin

struct UpstreamTab: View {
    @ObservedObject var model: SettingsViewModel
    @State private var host: String = ""
    @State private var portText: String = ""
    @State private var bindInterface: String = ""
    @State private var availableInterfaces: [String] = []
    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Upstream")
                    .font(.shuntTitle1)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        label: "SOCKS5 endpoint",
                        icon: "arrow.up.right",
                        tooltip: "Where claimed traffic is forwarded — typically a SOCKS5 proxy running inside a VM with the corporate VPN."
                    )
                    VStack(spacing: 0) {
                        FormRow("Host") {
                            TextField("10.211.55.5", text: $host)
                                .textFieldStyle(.roundedBorder)
                                .font(.shuntMonoData)
                                .frame(width: 260)
                        }
                        Divider()
                        FormRow("Port") {
                            TextField("1080", text: $portText)
                                .textFieldStyle(.roundedBorder)
                                .font(.shuntMonoData)
                                .frame(width: 120)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        label: "Interface binding",
                        icon: "cable.connector",
                        tooltip: "Force the extension to dial the upstream out a specific NIC. Needed only when the upstream lives on a virtual bridge (e.g. bridge100 for Parallels) that isn't reachable via the default route."
                    )
                    VStack(spacing: 0) {
                        FormRow("Bind to") {
                            Picker("", selection: $bindInterface) {
                                Text("None (use routing table)").tag("")
                                ForEach(availableInterfaces, id: \.self) { name in
                                    Text(name).tag(name).font(.shuntMonoData)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 260, alignment: .leading)
                            .font(.shuntMonoData)
                        }
                    }
                    .padding(.horizontal, 4)

                    Text("Select an interface only when the upstream is unreachable via the primary NIC — e.g. a Parallels shared network on `bridge100`.")
                        .font(.shuntCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }

                HStack(spacing: 8) {
                    Button("Apply") { apply() }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent(for: scheme))
                        .keyboardShortcut(.defaultAction)

                    Button("Test Connection") {
                        apply()
                        model.testConnection()
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
            refreshInterfaces()
        }
    }

    private func apply() {
        let port = UInt16(portText) ?? model.settings.upstream.port
        portText = String(port)
        model.updateUpstream(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            bindInterface: bindInterface.isEmpty ? nil : bindInterface
        )
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
