import SwiftUI
import Darwin

struct UpstreamTab: View {
    @ObservedObject var model: SettingsViewModel
    @State private var host: String = ""
    @State private var portText: String = ""
    @State private var bindInterface: String = ""
    @State private var availableInterfaces: [String] = []

    var body: some View {
        Form {
            Section("SOCKS5 Upstream") {
                TextField("Host", text: $host, prompt: Text("10.211.55.5 or proxy.example.com"))
                TextField("Port", text: $portText, prompt: Text("1080"))
                    .frame(maxWidth: 120)
            }

            Section("Interface binding") {
                Picker("Bind to", selection: $bindInterface) {
                    Text("None (use routing table)").tag("")
                    ForEach(availableInterfaces, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Text("Select an interface only when the upstream lives on a virtual network that is unreachable via the primary network interface (e.g. a Parallels shared network on bridge100).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Apply") {
                        apply()
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("Test Connection") {
                        apply()
                        model.testConnection()
                    }

                    Spacer()
                }
                if let result = model.testConnectionResult {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(result.contains("OK") ? .green : .secondary)
                }
            }
        }
        .formStyle(.grouped)
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
        // Make sure the current value appears even if the interface was not
        // detected yet (e.g. Parallels VM not running when the tab opens).
        if !bindInterface.isEmpty && !availableInterfaces.contains(bindInterface) {
            availableInterfaces.append(bindInterface)
        }
    }

    /// Enumerate UP IPv4 interfaces the user can bind to.
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
