import Foundation
import NetworkExtension
import ShuntCore
import os

final class ShuntProxyProvider: NETransparentProxyProvider {
    private let logger = Logger(subsystem: "com.craraque.shunt.proxy", category: "provider")

    private var claimedBundleIDs: Set<String> = []
    private var upstream = UpstreamProxy()

    private var bridges: [ObjectIdentifier: SOCKS5Bridge] = [:]
    private let bridgesLock = NSLock()

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let proto = self.protocolConfiguration as? NETunnelProviderProtocol
        let settings = SettingsStore.decodeFromProvider(proto?.providerConfiguration)
        claimedBundleIDs = settings.enabledBundleIDs
        upstream = settings.upstream
        logger.info("startProxy; bundles=\(self.claimedBundleIDs.sorted().joined(separator: ","), privacy: .public) upstream=\(self.upstream.host, privacy: .public):\(self.upstream.port, privacy: .public) bindIf=\(self.upstream.bindInterface ?? "none", privacy: .public)")

        let tunnelSettings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let tcp = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .TCP,
            direction: .outbound
        )
        let udp = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .UDP,
            direction: .outbound
        )
        tunnelSettings.includedNetworkRules = [tcp, udp]

        setTunnelNetworkSettings(tunnelSettings) { [weak self] error in
            if let error {
                self?.logger.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }
            self?.logger.info("tunnel settings applied; listening for flows")
            completionHandler(nil)
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        logger.info("stopProxy reason=\(reason.rawValue, privacy: .public)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let source = flow.metaData.sourceAppSigningIdentifier
        guard claimedBundleIDs.contains(source) else { return false }

        guard let tcp = flow as? NEAppProxyTCPFlow else {
            logger.info("non-TCP flow from \(source, privacy: .public) — not handled (Phase 3b TCP only)")
            return false
        }

        guard let hostEndpoint = tcp.remoteEndpoint as? NWHostEndpoint,
              let port = UInt16(hostEndpoint.port) else {
            logger.error("cannot parse remoteEndpoint \(tcp.remoteEndpoint.debugDescription, privacy: .public)")
            return false
        }

        logger.info("CLAIM \(source, privacy: .public) → \(hostEndpoint.hostname, privacy: .public):\(port, privacy: .public)")
        let bridge = SOCKS5Bridge(
            flow: tcp,
            socksHost: upstream.host,
            socksPort: upstream.port,
            bindInterface: upstream.bindInterface,
            remoteHost: hostEndpoint.hostname,
            remotePort: port,
            logger: logger
        )
        let key = ObjectIdentifier(bridge)
        bridge.onFinish = { [weak self] in
            guard let self else { return }
            self.bridgesLock.lock()
            self.bridges.removeValue(forKey: key)
            self.bridgesLock.unlock()
        }
        bridgesLock.lock()
        bridges[key] = bridge
        bridgesLock.unlock()
        bridge.start()
        return true
    }
}
