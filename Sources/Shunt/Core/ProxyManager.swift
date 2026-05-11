import Foundation
import NetworkExtension
import ShuntCore

final class ProxyManager {
    private static let providerBundleIdentifier = "com.craraque.shunt.proxy"
    private static let displayName = "Shunt"

    /// Posted (on the main queue) when the upstream launcher fails during
    /// `enable()` with a non-cancellation error. `userInfo["error"]` is the
    /// localized description. UI consumers subscribe to surface the failure
    /// inline so the toggle can snap back and an error banner can render.
    ///
    /// Cancellation (Disable clicked mid-enable, or Shunt internally asked
    /// the launcher to stop) is **not** posted — that's the user's own
    /// action, not a failure, and bouncing the toggle based on it would
    /// recreate the exact self-cancel loop we fixed.
    static let launcherFailedNotification = Notification.Name("ShuntLauncherFailed")

    private let settingsStore = SettingsStore()

    /// Public entry point. Runs the upstream launcher first (if any stages
    /// are configured); only proceeds to the NE tunnel setup if the launcher
    /// succeeds. An empty launcher is a no-op — behaviour identical to pre-3f
    /// builds.
    func enable() {
        Task { @MainActor in
            ProxyActivity.shared.begin()
            defer { ProxyActivity.shared.end() }
            let settings = settingsStore.load()
            if !settings.launcher.stages.isEmpty {
                ProxyActivity.shared.seed(from: settings.launcher)
                do {
                    Log.info("launcher: starting \(settings.launcher.stages.count) stage(s)")
                    try await AppServices.shared.launcherEngine.startAll(
                        launcher: settings.launcher,
                        upstream: settings.upstream,
                        onEvent: { event in
                            Log.info("launcher: stage=\(event.stageIndex + 1) \"\(event.entryName)\" → \(event.state) owned=\(event.ownedByUs)\(event.detail.map { " [\($0)]" } ?? "")")
                            Task { @MainActor in
                                ProxyActivity.shared.record(event)
                            }
                        }
                    )
                    Log.info("launcher: all stages healthy — proceeding to tunnel")
                } catch is CancellationError {
                    // Intentional cancellation (Disable clicked during enable,
                    // or a second enable cancelled us). Not a failure — do not
                    // post the launcherFailed notification or the toggle UI
                    // would bounce off on every rapid Enable→Disable cycle.
                    Log.info("launcher: cancelled — tunnel NOT enabled")
                    return
                } catch {
                    Log.error("launcher failed: \(error.localizedDescription) — NOT enabling tunnel")
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: Self.launcherFailedNotification,
                            object: nil,
                            userInfo: ["error": error.localizedDescription]
                        )
                    }
                    return
                }
            }
            self.enableTunnel()
        }
    }

    /// Existing tunnel-enable logic, invoked after the launcher has brought
    /// all prerequisites up (or immediately when there are no prerequisites).
    private func enableTunnel() {
        Log.info("ProxyManager.enableTunnel: loadAllFromPreferences (callback)")
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            if let error {
                let ns = error as NSError
                Log.error("loadAll failed: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
                return
            }
            Log.info("loadAll returned \(managers?.count ?? 0) manager(s)")
            let manager = managers?.first ?? NETransparentProxyManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleIdentifier
            proto.serverAddress = Self.displayName
            let settings = self.settingsStore.load()
            do {
                proto.providerConfiguration = try SettingsStore.encodeForProvider(settings)
                Log.info("providerConfiguration set: \(settings.managedApps.count) app(s), upstream=\(settings.upstream.host):\(settings.upstream.port)")
            } catch {
                Log.error("failed to encode providerConfiguration: \(error.localizedDescription)")
            }
            manager.protocolConfiguration = proto
            manager.localizedDescription = Self.displayName
            manager.isEnabled = true

            Log.info("calling saveToPreferences (callback)")
            manager.saveToPreferences { error in
                if let error {
                    let ns = error as NSError
                    Log.error("save failed: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription) info=\(ns.userInfo)")
                    return
                }
                Log.info("save succeeded, calling loadFromPreferences")
                manager.loadFromPreferences { error in
                    if let error {
                        let ns = error as NSError
                        Log.error("reload failed: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
                        return
                    }
                    // startVPNTunnel on an already-running tunnel is a no-op,
                    // so the provider never re-reads the new providerConfiguration.
                    // When the tunnel is already up we must stopVPNTunnel first,
                    // wait for the status to become .disconnected, then start again.
                    let status = manager.connection.status
                    let alreadyRunning = status != .disconnected && status != .invalid
                    if alreadyRunning {
                        Log.info("tunnel already running (status=\(status.rawValue)) — restarting to pick up new providerConfiguration")
                        manager.connection.stopVPNTunnel()
                        self.waitForDisconnected(manager) {
                            Self.startTunnel(manager)
                        }
                    } else {
                        Log.info("reload succeeded, starting tunnel")
                        Self.startTunnel(manager)
                    }
                }
            }
        }
    }

    private static func startTunnel(_ manager: NETransparentProxyManager) {
        do {
            try manager.connection.startVPNTunnel()
            Log.info("startVPNTunnel OK")
        } catch {
            let ns = error as NSError
            Log.error("startVPNTunnel failed: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
        }
    }

    /// Poll connection.status until it becomes .disconnected, up to ~5 s.
    /// NE has no native completion callback for stop; polling is the standard
    /// recipe (see TN3120 sample code).
    private func waitForDisconnected(
        _ manager: NETransparentProxyManager,
        attempts: Int = 0,
        completion: @escaping () -> Void
    ) {
        let status = manager.connection.status
        if status == .disconnected || status == .invalid || attempts >= 50 {
            if attempts >= 50 {
                Log.error("timed out waiting for disconnected (status=\(status.rawValue)) — starting anyway")
            }
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForDisconnected(manager, attempts: attempts + 1, completion: completion)
        }
    }

    /// Push the current on-disk settings (rules + upstream) into the running
    /// provider via NETunnelProviderSession IPC. Does NOT cycle the tunnel
    /// and does NOT touch the upstream launcher, so Tart / sshuttle / any
    /// other dependency keeps running. The on-disk providerConfiguration is
    /// also refreshed so a future cold-start has the latest rules.
    ///
    /// Call from the Apply button on the Rules tab. Safe to call when the
    /// tunnel is idle — the IPC leg is skipped and only the persistent
    /// config is updated.
    func applyRulesLive(completion: @escaping (Result<Void, Swift.Error>) -> Void = { _ in }) {
        let settings = settingsStore.load()
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            if let error {
                Log.error("applyRulesLive loadAll failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            guard let manager = managers?.first else {
                Log.info("applyRulesLive: no manager configured — nothing to update")
                completion(.failure(NSError(
                    domain: "Shunt.ProxyManager",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Proxy is not configured"]
                )))
                return
            }

            let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleIdentifier
            proto.serverAddress = Self.displayName
            do {
                proto.providerConfiguration = try SettingsStore.encodeForProvider(settings)
            } catch {
                Log.error("applyRulesLive encode failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            manager.protocolConfiguration = proto

            manager.saveToPreferences { error in
                if let error {
                    let ns = error as NSError
                    Log.error("applyRulesLive save failed: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                manager.loadFromPreferences { _ in
                    let status = manager.connection.status
                    guard status == .connected || status == .reasserting else {
                        Log.info("applyRulesLive: tunnel not active (status=\(status.rawValue)) — providerConfiguration persisted; provider will read on next start")
                        completion(.success(()))
                        return
                    }
                    guard let session = manager.connection as? NETunnelProviderSession else {
                        Log.error("applyRulesLive: connection is not NETunnelProviderSession")
                        completion(.failure(NSError(
                            domain: "Shunt.ProxyManager",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Tunnel session unavailable"]
                        )))
                        return
                    }
                    do {
                        let payload = try JSONEncoder().encode(settings)
                        try session.sendProviderMessage(payload) { reply in
                            let ack = reply.flatMap { String(data: $0, encoding: .utf8) } ?? "<no reply>"
                            if ack.hasPrefix("ok") {
                                Log.info("applyRulesLive: provider ack=\(ack)")
                                completion(.success(()))
                            } else {
                                Log.error("applyRulesLive: provider replied \(ack)")
                                completion(.failure(NSError(
                                    domain: "Shunt.ProxyManager",
                                    code: 3,
                                    userInfo: [NSLocalizedDescriptionKey: ack]
                                )))
                            }
                        }
                    } catch {
                        Log.error("applyRulesLive sendProviderMessage failed: \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// Restart the NE tunnel to force the provider to re-read state from
    /// scratch. Does NOT touch the upstream launcher — Tart / sshuttle /
    /// etc. stay running. Active TCP flows through Shunt are dropped while
    /// the tunnel cycles (typically 1-2 s).
    ///
    /// Call from the "Reload Tunnel" button on the General tab when Apply
    /// is not enough (e.g. you need a fresh SOCKS bridge pool).
    func reloadTunnel(completion: @escaping (Result<Void, Swift.Error>) -> Void = { _ in }) {
        Log.info("ProxyManager.reloadTunnel")
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            if let error {
                Log.error("reloadTunnel loadAll failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            guard let manager = managers?.first else {
                Log.info("reloadTunnel: no manager configured")
                completion(.failure(NSError(
                    domain: "Shunt.ProxyManager",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Proxy is not configured"]
                )))
                return
            }

            // Refresh providerConfiguration so the restarted tunnel picks up
            // current settings — same as enableTunnel does.
            let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleIdentifier
            proto.serverAddress = Self.displayName
            let settings = self.settingsStore.load()
            do {
                proto.providerConfiguration = try SettingsStore.encodeForProvider(settings)
            } catch {
                Log.error("reloadTunnel encode failed: \(error.localizedDescription)")
            }
            manager.protocolConfiguration = proto
            manager.isEnabled = true

            manager.saveToPreferences { error in
                if let error {
                    Log.error("reloadTunnel save failed: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                manager.loadFromPreferences { _ in
                    let status = manager.connection.status
                    let alreadyRunning = status != .disconnected && status != .invalid
                    if alreadyRunning {
                        Log.info("reloadTunnel: stopping (status=\(status.rawValue))")
                        manager.connection.stopVPNTunnel()
                        self.waitForDisconnected(manager) {
                            Self.startTunnel(manager)
                            completion(.success(()))
                        }
                    } else {
                        Log.info("reloadTunnel: tunnel not running — starting")
                        Self.startTunnel(manager)
                        completion(.success(()))
                    }
                }
            }
        }
    }

    func disable() async {
        await MainActor.run { ProxyActivity.shared.begin() }
        defer {
            Task { @MainActor in
                ProxyActivity.shared.reset()
                ProxyActivity.shared.end()
            }
        }
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            guard let manager = managers.first else {
                Log.info("No manager to disable")
                await stopLauncherIfAny()
                return
            }
            manager.connection.stopVPNTunnel()
            manager.isEnabled = false
            try await manager.saveToPreferences()
            Log.info("Proxy disabled")
        } catch {
            Log.error("ProxyManager.disable failed: \(error.localizedDescription)")
        }
        await stopLauncherIfAny()
    }

    /// Tears down anything the upstream launcher started. Safe to call even
    /// when no launcher was configured (no-op).
    private func stopLauncherIfAny() async {
        let settings = settingsStore.load()
        guard !settings.launcher.stages.isEmpty else { return }
        Log.info("launcher: stopping (stages=\(settings.launcher.stages.count))")
        await AppServices.shared.launcherEngine.stopAll(
            launcher: settings.launcher,
            onEvent: { event in
                Log.info("launcher stop: stage=\(event.stageIndex + 1) \"\(event.entryName)\" → \(event.state) owned=\(event.ownedByUs)")
                Task { @MainActor in
                    ProxyActivity.shared.record(event)
                }
            }
        )
    }

    func removeConfig(completion: @escaping () -> Void) {
        // Clear BOTH NETransparentProxyManager (current) AND NEAppProxyProviderManager
        // (legacy, left over from earlier sessions) configs.
        Log.info("ProxyManager.removeConfig: scanning both NETransparentProxyManager + NEAppProxyProviderManager")
        let outer = DispatchGroup()

        outer.enter()
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            if let error {
                let ns = error as NSError
                Log.error("NETransparentProxyManager loadAll failed: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
                outer.leave()
                return
            }
            let list = managers ?? []
            Log.info("NETransparentProxyManager: \(list.count)")
            let inner = DispatchGroup()
            for manager in list {
                inner.enter()
                manager.removeFromPreferences { error in
                    if let error {
                        Log.error("remove (transparent) failed: \(error.localizedDescription)")
                    } else {
                        Log.info("removed transparent manager \(manager.localizedDescription ?? "?")")
                    }
                    inner.leave()
                }
            }
            inner.notify(queue: .main) { outer.leave() }
        }

        outer.enter()
        NEAppProxyProviderManager.loadAllFromPreferences { managers, error in
            if let error {
                let ns = error as NSError
                Log.error("NEAppProxyProviderManager loadAll failed: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
                outer.leave()
                return
            }
            let list = managers ?? []
            Log.info("NEAppProxyProviderManager: \(list.count)")
            let inner = DispatchGroup()
            for manager in list {
                inner.enter()
                manager.removeFromPreferences { error in
                    if let error {
                        Log.error("remove (app-proxy) failed: \(error.localizedDescription)")
                    } else {
                        Log.info("removed app-proxy manager \(manager.localizedDescription ?? "?")")
                    }
                    inner.leave()
                }
            }
            inner.notify(queue: .main) { outer.leave() }
        }

        outer.notify(queue: .main) {
            Log.info("removeConfig complete")
            completion()
        }
    }

    func status() async -> String {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            guard let manager = managers.first else { return "no-config" }
            return "enabled=\(manager.isEnabled) status=\(manager.connection.status.rawValue)"
        } catch {
            return "error=\(error.localizedDescription)"
        }
    }

    /// NEVPNStatus raw value. 0 if there's no manager configured.
    func statusRaw() async -> Int {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            guard let manager = managers.first else { return 0 }
            return manager.connection.status.rawValue
        } catch {
            return 0
        }
    }

    /// Cached synchronous probe. Returns true if a previous status query saw
    /// a manager exist. Used by the menubar to distinguish "no extension" vs
    /// "extension present, tunnel just idle". Updated by the async probes.
    func hasAnyConfig() -> Bool {
        cachedHasConfig
    }

    private var cachedHasConfig = false

    func refreshCachedState() async {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            cachedHasConfig = !managers.isEmpty
        } catch {
            cachedHasConfig = false
        }
    }
}
