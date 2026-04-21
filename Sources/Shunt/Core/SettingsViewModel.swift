import Foundation
import AppKit
import ShuntCore

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: ShuntSettings
    @Published var lastError: String?
    @Published var testConnectionResult: String?

    private let store: SettingsStore

    init(store: SettingsStore = AppServices.shared.settingsStore) {
        self.store = store
        self.settings = store.load()
    }

    func reload() {
        settings = store.load()
    }

    func save() {
        do {
            try store.save(settings)
            lastError = nil
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Apps

    func addApp(bundleID: String, displayName: String, appPath: String?) {
        guard !bundleID.isEmpty else { return }
        if settings.managedApps.contains(where: { $0.bundleID == bundleID }) { return }
        settings.managedApps.append(
            ManagedApp(bundleID: bundleID, displayName: displayName, appPath: appPath, enabled: true)
        )
        save()
    }

    func removeApp(id: UUID) {
        settings.managedApps.removeAll { $0.id == id }
        save()
    }

    func toggleApp(id: UUID) {
        guard let idx = settings.managedApps.firstIndex(where: { $0.id == id }) else { return }
        settings.managedApps[idx].enabled.toggle()
        save()
    }

    /// Extract bundle info from a user-selected .app bundle.
    func importAppBundle(at url: URL) -> (bundleID: String, name: String)? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else {
            return nil
        }
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (bundleID, name)
    }

    // MARK: - Upstream

    func updateUpstream(host: String, port: UInt16, bindInterface: String?) {
        settings.upstream.host = host
        settings.upstream.port = port
        settings.upstream.bindInterface = (bindInterface?.isEmpty ?? true) ? nil : bindInterface
        save()
    }

    /// Best-effort SOCKS5 handshake test. Runs on a background queue.
    /// Result is published on `testConnectionResult`.
    func testConnection() {
        let host = settings.upstream.host
        let port = settings.upstream.port
        testConnectionResult = "Testing…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.performSocksHandshake(host: host, port: port)
            DispatchQueue.main.async { self?.testConnectionResult = result }
        }
    }

    private nonisolated static func performSocksHandshake(host: String, port: UInt16) -> String {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let rv = getaddrinfo(host, String(port), &hints, &result)
        guard rv == 0, let info = result else {
            return "DNS failed: \(String(cString: gai_strerror(rv)))"
        }
        defer { freeaddrinfo(info) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return "socket() failed errno=\(errno)" }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            return "Connect failed (errno=\(errno))"
        }

        let greeting: [UInt8] = [0x05, 0x01, 0x00]
        guard greeting.withUnsafeBufferPointer({ buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0) == buf.count
        }) else {
            return "TCP connected but send() failed"
        }

        var reply = [UInt8](repeating: 0, count: 2)
        let n = Darwin.recv(fd, &reply, reply.count, 0)
        guard n == 2 else { return "TCP connected, no SOCKS5 reply" }
        guard reply[0] == 0x05 else {
            return "Not a SOCKS5 server (got version byte 0x\(String(reply[0], radix: 16)))"
        }
        if reply[1] == 0xFF {
            return "SOCKS5 reachable but rejected auth methods"
        }
        return "SOCKS5 handshake OK"
    }
}
