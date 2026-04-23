import Foundation
import NetworkExtension
import ShuntCore
import os

final class ShuntProxyProvider: NETransparentProxyProvider {
    private let logger = Logger(subsystem: "com.craraque.shunt.proxy", category: "provider")

    private var activeRules: [Rule] = []
    private var upstream = UpstreamProxy()

    private var bridges: [ObjectIdentifier: SOCKS5Bridge] = [:]
    private let bridgesLock = NSLock()

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let proto = self.protocolConfiguration as? NETunnelProviderProtocol
        let settings = SettingsStore.decodeFromProvider(proto?.providerConfiguration)
        activeRules = settings.rules.filter { $0.enabled && $0.isValid }
        upstream = settings.upstream

        let ruleSummary = activeRules
            .map { "\($0.name)[apps=\($0.apps.count),hosts=\($0.hosts.count),\($0.action.rawValue)]" }
            .joined(separator: "; ")
        logger.info("startProxy; rules=\(ruleSummary, privacy: .public) upstream=\(self.upstream.host, privacy: .public):\(self.upstream.port, privacy: .public) bindIf=\(self.upstream.bindInterface ?? "none", privacy: .public)")

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

        guard let tcp = flow as? NEAppProxyTCPFlow else {
            // v0.1 decision: UDP is pass-through by design (voice/video latency).
            // Diagnostic log so the Monitor tab can surface "this app also
            // tried UDP and we passed through".
            logger.info("FLOW udp source=\(source, privacy: .public) — pass-through (UDP by design)")
            return false
        }

        guard let hostEndpoint = tcp.remoteEndpoint as? NWHostEndpoint,
              let port = UInt16(hostEndpoint.port) else {
            logger.error("cannot parse remoteEndpoint \(tcp.remoteEndpoint.debugDescription, privacy: .public)")
            return false
        }

        // Extract hostname (what the app dialed, pre-DNS) and IP (post-DNS
        // literal from the endpoint). remoteHostname may be the IP literal
        // itself when the app dialed by IP directly — normalize.
        let preResolved = tcp.remoteHostname ?? ""
        let endpointHost = hostEndpoint.hostname

        let hostnameForMatch: String? = {
            guard !preResolved.isEmpty, !HostMatcher.isIPLiteral(preResolved) else { return nil }
            return preResolved
        }()
        let ipForMatch: String? = {
            if HostMatcher.isIPLiteral(endpointHost) { return endpointHost }
            if HostMatcher.isIPLiteral(preResolved) { return preResolved }
            return nil
        }()

        // DIAGNOSTIC log for every TCP flow received — surfaces silent
        // non-matches so "why isn't my rule firing" is actionable via logs.
        // Format: FLOW tcp <app> preResolved=<...> endpoint=<ip>:<port> hostForMatch=<...> ipForMatch=<...>
        logger.info("FLOW tcp source=\(source, privacy: .public) preResolved=\(preResolved.isEmpty ? "<empty>" : preResolved, privacy: .public) endpoint=\(endpointHost, privacy: .public):\(port, privacy: .public) hostMatch=\(hostnameForMatch ?? "<nil>", privacy: .public) ipMatch=\(ipForMatch ?? "<nil>", privacy: .public)")

        // Rule evaluation:
        //   • A .direct match short-circuits and passes the flow through.
        //   • Otherwise the first .route match claims the flow.
        //   • No match → pass through (default transparent-proxy behavior).
        var matched: Rule.Action? = nil
        var matchedRuleName: String = ""
        for rule in activeRules where
            HostMatcher.ruleMatches(rule, bundleID: source, hostname: hostnameForMatch, ip: ipForMatch)
        {
            if rule.action == .direct {
                matched = .direct
                matchedRuleName = rule.name
                break
            }
            if matched == nil {
                matched = .route
                matchedRuleName = rule.name
            }
        }

        guard matched == .route else {
            if matched == .direct {
                logger.info("DIRECT rule=\(matchedRuleName, privacy: .public) source=\(source, privacy: .public) → pass-through")
            } else {
                logger.info("SKIP source=\(source, privacy: .public) endpoint=\(endpointHost, privacy: .public):\(port, privacy: .public) — no rule matched")
            }
            return false
        }

        // Prefer the pre-resolution hostname over the already-resolved IP when
        // we hand off to SOCKS5 (ATYP 0x03) so the upstream proxy (Zscaler,
        // 3proxy, etc.) can apply hostname-based policy.
        let targetHost: String = (!preResolved.isEmpty) ? preResolved : endpointHost

        logger.info("CLAIM \(source, privacy: .public) → \(targetHost, privacy: .public):\(port, privacy: .public) (endpoint=\(endpointHost, privacy: .public))")
        let bridge = SOCKS5Bridge(
            flow: tcp,
            socksHost: upstream.host,
            socksPort: upstream.port,
            bindInterface: upstream.bindInterface,
            remoteHost: targetHost,
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
