import Foundation
import NetworkExtension
import ShuntCore

final class ProxyManager {
    private static let providerBundleIdentifier = "com.craraque.shunt.proxy"
    private static let displayName = "Shunt"

    private let settingsStore = SettingsStore()

    func enable() {
        Log.info("ProxyManager.enable: loadAllFromPreferences (callback)")
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

    func disable() async {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            guard let manager = managers.first else {
                Log.info("No manager to disable")
                return
            }
            manager.connection.stopVPNTunnel()
            manager.isEnabled = false
            try await manager.saveToPreferences()
            Log.info("Proxy disabled")
        } catch {
            Log.error("ProxyManager.disable failed: \(error.localizedDescription)")
        }
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
