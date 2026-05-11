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
        resolveMissingAppPaths()
    }

    func reload() {
        settings = store.load()
        resolveMissingAppPaths()
    }

    /// For any managed app that lacks an `appPath` (seeded entries or rows created
    /// by bundle ID before LaunchServices was queried), resolve the path via
    /// `NSWorkspace` and persist it so the row can render its icon. Applies to
    /// both the legacy `managedApps` list and the apps nested inside `rules`.
    private func resolveMissingAppPaths() {
        var changed = false
        for idx in settings.managedApps.indices where
            settings.managedApps[idx].appPath == nil &&
            !settings.managedApps[idx].bundleID.isEmpty
        {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: settings.managedApps[idx].bundleID) {
                settings.managedApps[idx].appPath = url.path
                changed = true
            }
        }
        for rIdx in settings.rules.indices {
            for aIdx in settings.rules[rIdx].apps.indices where
                settings.rules[rIdx].apps[aIdx].appPath == nil &&
                !settings.rules[rIdx].apps[aIdx].bundleID.isEmpty
            {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: settings.rules[rIdx].apps[aIdx].bundleID) {
                    settings.rules[rIdx].apps[aIdx].appPath = url.path
                    changed = true
                }
            }
        }
        if changed { try? store.save(settings) }
    }

    func save() {
        // Rules are the ground truth (post-3d.6). Derive `managedApps` so the
        // v1 extension binary (which only reads managedApps) keeps working
        // until it is rebuilt with the rule-aware code in 3d.7.
        settings.managedApps = ShuntSettings.deriveManagedApps(from: settings.rules)
        do {
            try store.save(settings)
            lastError = nil
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Legacy managedApps ops (still used by ProxyManager logging only)

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

    /// Scans the `.app` bundle at `url` for nested `.app` helper bundles
    /// whose `CFBundleIdentifier` shares the parent's reverse-DNS prefix
    /// (e.g. `com.google.Chrome.helper` is a helper of `com.google.Chrome`).
    ///
    /// Chromium-based browsers and Electron apps route network traffic through
    /// helper processes rather than the main app, so `NEAppProxyFlow` attributes
    /// those flows to the helper's bundle id. Unless the helpers are added to
    /// a rule too, the extension never claims the real traffic.
    ///
    /// Returns the helpers sorted by bundle id for a stable alert.
    struct HelperBundle: Hashable {
        let bundleID: String
        let name: String
        let path: String
    }
    func findHelperBundles(in appURL: URL, parentBundleID: String) -> [HelperBundle] {
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [HelperBundle] = []
        var seenIDs = Set<String>()
        let parentPrefix = parentBundleID + "."

        for case let subURL as URL in enumerator where subURL.pathExtension == "app" {
            // Skip the outer bundle itself.
            guard subURL != appURL else { continue }

            let infoURL = subURL.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: infoURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let bundleID = plist["CFBundleIdentifier"] as? String,
                  bundleID != parentBundleID,
                  bundleID.hasPrefix(parentPrefix),
                  !seenIDs.contains(bundleID)
            else { continue }

            seenIDs.insert(bundleID)
            let name = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
                ?? subURL.lastPathComponent
            found.append(HelperBundle(bundleID: bundleID, name: name, path: subURL.path))
        }
        return found.sorted { $0.bundleID < $1.bundleID }
    }

    // MARK: - Rule ops (post-3d.6)

    /// Insert an empty rule at the end of the list and return its id.
    @discardableResult
    func addRule() -> UUID {
        let rule = Rule(name: "New rule", enabled: true, apps: [], hosts: [], action: .route)
        settings.rules.append(rule)
        save()
        return rule.id
    }

    func removeRules(ids: Set<UUID>) {
        settings.rules.removeAll { ids.contains($0.id) }
        save()
    }

    func toggleRule(id: UUID) {
        guard let idx = settings.rules.firstIndex(where: { $0.id == id }) else { return }
        settings.rules[idx].enabled.toggle()
        save()
    }

    func updateRuleName(id: UUID, name: String) {
        guard let idx = settings.rules.firstIndex(where: { $0.id == id }) else { return }
        settings.rules[idx].name = name
        save()
    }

    func updateRuleAction(id: UUID, action: Rule.Action) {
        guard let idx = settings.rules.firstIndex(where: { $0.id == id }) else { return }
        settings.rules[idx].action = action
        save()
    }

    /// Fuse selected rules into a single rule. Takes the anchor (first) rule's
    /// name + id + action, and unions its apps and hosts with the others'.
    /// Others are deleted. Returns the anchor rule id, or nil if fewer than 2
    /// rules are selected.
    @discardableResult
    func mergeRules(ids: Set<UUID>) -> UUID? {
        guard ids.count >= 2 else { return nil }
        let selected = settings.rules.filter { ids.contains($0.id) }
        guard let anchor = selected.first else { return nil }

        var mergedApps: [ManagedApp] = []
        var seenAppIDs = Set<String>()
        for rule in selected {
            for app in rule.apps where !seenAppIDs.contains(app.bundleID) {
                seenAppIDs.insert(app.bundleID)
                mergedApps.append(app)
            }
        }

        var mergedHosts: [HostPattern] = []
        var seenHosts = Set<String>()
        for rule in selected {
            for host in rule.hosts {
                let key = "\(host.kind.rawValue):\(host.pattern.lowercased())"
                guard !seenHosts.contains(key) else { continue }
                seenHosts.insert(key)
                mergedHosts.append(host)
            }
        }

        let merged = Rule(
            id: anchor.id,
            name: anchor.name,
            enabled: selected.contains { $0.enabled },
            apps: mergedApps,
            hosts: mergedHosts,
            action: anchor.action
        )

        // Replace anchor in place, drop the rest.
        let otherIDs = ids.subtracting([anchor.id])
        settings.rules.removeAll { otherIDs.contains($0.id) }
        if let anchorIdx = settings.rules.firstIndex(where: { $0.id == anchor.id }) {
            settings.rules[anchorIdx] = merged
        }
        save()
        return anchor.id
    }

    // MARK: - Apps inside a rule

    /// Add an app (bundle+name+path) to the given rule, unless already present.
    func addAppToRule(ruleID: UUID, bundleID: String, displayName: String, appPath: String?) {
        guard !bundleID.isEmpty,
              let ruleIdx = settings.rules.firstIndex(where: { $0.id == ruleID }) else { return }
        if settings.rules[ruleIdx].apps.contains(where: { $0.bundleID == bundleID }) { return }
        settings.rules[ruleIdx].apps.append(
            ManagedApp(bundleID: bundleID, displayName: displayName, appPath: appPath, enabled: true)
        )
        save()
    }

    /// Append a blank draft app row inside a rule and return its id so the UI
    /// can focus the bundle-ID TextField.
    @discardableResult
    func addEmptyAppToRule(ruleID: UUID) -> UUID? {
        guard let ruleIdx = settings.rules.firstIndex(where: { $0.id == ruleID }) else { return nil }
        let app = ManagedApp(bundleID: "", displayName: "", appPath: nil, enabled: true)
        settings.rules[ruleIdx].apps.append(app)
        save()
        return app.id
    }

    func removeAppFromRule(ruleID: UUID, appID: UUID) {
        guard let ruleIdx = settings.rules.firstIndex(where: { $0.id == ruleID }) else { return }
        settings.rules[ruleIdx].apps.removeAll { $0.id == appID }
        save()
    }

    /// Called when the user commits a bundle ID on a draft app inside a rule.
    /// Resolves path + display name via LaunchServices.
    func enrichAppInRule(ruleID: UUID, appID: UUID) {
        guard let ruleIdx = settings.rules.firstIndex(where: { $0.id == ruleID }),
              let appIdx = settings.rules[ruleIdx].apps.firstIndex(where: { $0.id == appID })
        else { return }
        let trimmed = settings.rules[ruleIdx].apps[appIdx].bundleID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        settings.rules[ruleIdx].apps[appIdx].bundleID = trimmed
        guard !trimmed.isEmpty else { save(); return }
        if settings.rules[ruleIdx].apps[appIdx].appPath == nil,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            settings.rules[ruleIdx].apps[appIdx].appPath = url.path
            if settings.rules[ruleIdx].apps[appIdx].displayName.isEmpty,
               let info = importAppBundle(at: url) {
                settings.rules[ruleIdx].apps[appIdx].displayName = info.name
            }
        }
        save()
    }

    // MARK: - Hosts inside a rule

    @discardableResult
    func addHostToRule(ruleID: UUID) -> UUID? {
        guard let ruleIdx = settings.rules.firstIndex(where: { $0.id == ruleID }) else { return nil }
        let host = HostPattern(kind: .suffix, pattern: "")
        settings.rules[ruleIdx].hosts.append(host)
        save()
        return host.id
    }

    func removeHostFromRule(ruleID: UUID, hostID: UUID) {
        guard let ruleIdx = settings.rules.firstIndex(where: { $0.id == ruleID }) else { return }
        settings.rules[ruleIdx].hosts.removeAll { $0.id == hostID }
        save()
    }

    // MARK: - Upstream

    func updateUpstream(host: String,
                        port: UInt16,
                        bindInterface: String?,
                        username: String = "",
                        password: String = "",
                        useRemoteDNS: Bool? = nil) {
        settings.upstream.host = host
        settings.upstream.port = port
        settings.upstream.bindInterface = (bindInterface?.isEmpty ?? true) ? nil : bindInterface
        settings.upstream.username = username
        settings.upstream.password = password
        if let useRemoteDNS {
            settings.upstream.useRemoteDNS = useRemoteDNS
        }
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

    // MARK: - Upstream launcher (Phase 3f)

    /// One-click template for an advanced SSH reverse tunnel topology:
    /// Shunt talks to host loopback, while a launcher entry creates a remote →
    /// host SSH forward and waits for proxied egress to differ from host direct
    /// egress before enabling the Network Extension. The generated command is
    /// editable in the Launcher section; the default command prefix targets a
    /// local Tart development VM, but production can use any VM or remote-host
    /// command that runs `ssh -R` from the machine that owns the SOCKS proxy.
    func applyReverseSSHTunnelPreset(
        commandPrefix: String = "tart exec tahoe-base",
        hostBridgeIP: String = "192.168.64.1",
        hostPort: UInt16 = 1080,
        remoteSocksPort: UInt16 = 1080,
        sshIdentityPath: String = "~/.ssh/id_shunt_tunnel"
    ) {
        let preset = ReverseSSHTunnelPreset(
            commandPrefix: commandPrefix,
            hostBridgeIP: hostBridgeIP,
            hostPort: hostPort,
            remoteSocksPort: remoteSocksPort,
            sshIdentityPath: sshIdentityPath
        )
        var launcher = settings.launcher
        if launcher.stages.isEmpty {
            launcher = preset.launcher
        } else {
            launcher.stages.append(contentsOf: preset.launcher.stages)
        }
        settings.upstream = preset.upstream
        settings.launcher = launcher
        save()
    }

    func addLauncherStage() {
        let nextNumber = settings.launcher.stages.count + 1
        var launcher = settings.launcher
        launcher.stages.append(
            UpstreamLauncherStage(name: "Stage \(nextNumber)", entries: [])
        )
        settings.launcher = launcher
        save()
    }

    func removeLauncherStage(stageID: UUID) {
        settings.launcher.stages.removeAll { $0.id == stageID }
        save()
    }

    func renameLauncherStage(stageID: UUID, to name: String) {
        guard let idx = settings.launcher.stages.firstIndex(where: { $0.id == stageID }) else { return }
        settings.launcher.stages[idx].name = name
        save()
    }

    func addLauncherEntry(to stageID: UUID) {
        guard let idx = settings.launcher.stages.firstIndex(where: { $0.id == stageID }) else { return }
        settings.launcher.stages[idx].entries.append(
            UpstreamLauncherEntry(name: "New entry")
        )
        save()
    }

    func removeLauncherEntry(stageID: UUID, entryID: UUID) {
        guard let sIdx = settings.launcher.stages.firstIndex(where: { $0.id == stageID }) else { return }
        settings.launcher.stages[sIdx].entries.removeAll { $0.id == entryID }
        save()
    }

    func updateLauncherEntry(stageID: UUID, entry: UpstreamLauncherEntry) {
        guard let sIdx = settings.launcher.stages.firstIndex(where: { $0.id == stageID }) else { return }
        guard let eIdx = settings.launcher.stages[sIdx].entries.firstIndex(where: { $0.id == entry.id }) else { return }
        settings.launcher.stages[sIdx].entries[eIdx] = entry
        save()
    }

    /// Promote a single entry to a brand-new stage inserted immediately after
    /// the entry's current stage. Used by the `[⋯]` menu action.
    func promoteEntryToOwnStage(stageID: UUID, entryID: UUID) {
        guard let sIdx = settings.launcher.stages.firstIndex(where: { $0.id == stageID }) else { return }
        guard let eIdx = settings.launcher.stages[sIdx].entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = settings.launcher.stages[sIdx].entries.remove(at: eIdx)
        let newName = "Stage \(settings.launcher.stages.count + 1)"
        let newStage = UpstreamLauncherStage(name: newName, entries: [entry])
        settings.launcher.stages.insert(newStage, at: sIdx + 1)
        save()
    }

    /// Move the entry into the previous stage (merging the two stages from the
    /// entry's perspective). If the entry is already in the first stage, no-op.
    func mergeEntryWithPreviousStage(stageID: UUID, entryID: UUID) {
        guard let sIdx = settings.launcher.stages.firstIndex(where: { $0.id == stageID }) else { return }
        guard sIdx > 0 else { return }
        guard let eIdx = settings.launcher.stages[sIdx].entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = settings.launcher.stages[sIdx].entries.remove(at: eIdx)
        settings.launcher.stages[sIdx - 1].entries.append(entry)
        // If the source stage is now empty, keep it — user may still want the slot.
        save()
    }

    func moveLauncherEntryUp(stageID: UUID, entryID: UUID) {
        guard let sIdx = settings.launcher.stages.firstIndex(where: { $0.id == stageID }) else { return }
        guard let eIdx = settings.launcher.stages[sIdx].entries.firstIndex(where: { $0.id == entryID }), eIdx > 0 else { return }
        settings.launcher.stages[sIdx].entries.swapAt(eIdx, eIdx - 1)
        save()
    }

    func moveLauncherEntryDown(stageID: UUID, entryID: UUID) {
        guard let sIdx = settings.launcher.stages.firstIndex(where: { $0.id == stageID }) else { return }
        let count = settings.launcher.stages[sIdx].entries.count
        guard let eIdx = settings.launcher.stages[sIdx].entries.firstIndex(where: { $0.id == entryID }), eIdx < count - 1 else { return }
        settings.launcher.stages[sIdx].entries.swapAt(eIdx, eIdx + 1)
        save()
    }
}
