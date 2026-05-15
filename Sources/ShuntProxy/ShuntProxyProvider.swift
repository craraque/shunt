import Foundation
import NetworkExtension
import ShuntCore
import os

final class ShuntProxyProvider: NETransparentProxyProvider {
    private let logger = Logger(subsystem: "com.craraque.shunt.proxy", category: "provider")

    // activeRules + upstream are read on every handleNewFlow (NE-callback
    // queue) AND written when the main app posts the applyRules Darwin
    // notification (a different queue), so they need a lock. Pre-Darwin
    // they were only touched on the NE callback queue and Apple's
    // serialization made the lock unnecessary.
    private var activeRules: [Rule] = []
    private var upstream = UpstreamProxy()
    private let stateLock = NSLock()

    private var bridges: [ObjectIdentifier: SOCKS5Bridge] = [:]
    private let bridgesLock = NSLock()

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        reloadSettingsFromProtocolConfiguration(reason: "startProxy")
        registerApplyRulesObserver()

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
        unregisterApplyRulesObserver()
        closeActiveBridges()
        completionHandler()
    }

    private func closeActiveBridges() {
        bridgesLock.lock()
        let activeBridges = Array(bridges.values)
        bridges.removeAll()
        bridgesLock.unlock()

        for bridge in activeBridges {
            bridge.close()
        }
    }

    // Re-read settings from the current `protocolConfiguration` and swap
    // `activeRules` / `upstream` under the state lock. NE keeps
    // `protocolConfiguration` updated on the running extension after the
    // main app calls `manager.saveToPreferences()`, so this re-reads the
    // current source of truth without any IPC dance with the main app.
    //
    // Called from `startProxy` (first load) and from the Darwin
    // notification handler (live updates after Apply).
    private func reloadSettingsFromProtocolConfiguration(reason: String) {
        let proto = self.protocolConfiguration as? NETunnelProviderProtocol
        let settings = SettingsStore.decodeFromProvider(proto?.providerConfiguration)
        let newRules = settings.rules.filter { $0.enabled && $0.isValid }
        let newUpstream = settings.upstream

        stateLock.lock()
        activeRules = newRules
        upstream = newUpstream
        stateLock.unlock()

        let summary = newRules
            .map { "\($0.name)[apps=\($0.apps.count),hosts=\($0.hosts.count),\($0.action.rawValue)]" }
            .joined(separator: "; ")
        logger.notice("reloadSettings(\(reason, privacy: .public)); rules=\(summary, privacy: .public) upstream=\(newUpstream.host, privacy: .public):\(newUpstream.port, privacy: .public) bindIf=\(newUpstream.bindInterface ?? "none", privacy: .public)")
    }

    // Apple's NETunnelProviderSession.sendProviderMessage() silently drops
    // messages to NETransparentProxyProvider on current macOS — the SE
    // never receives `handleAppMessage`. We use cross-process Darwin
    // notifications instead: the main app posts after a successful
    // saveToPreferences (which updates `protocolConfiguration`), and we
    // re-read the current config when the notification fires.
    private func registerApplyRulesObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<ShuntProxyProvider>.fromOpaque(observer).takeUnretainedValue()
                me.reloadSettingsFromProtocolConfiguration(reason: "darwin-applyRules")
            },
            SettingsStore.applyRulesDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
        logger.info("Registered Darwin observer for \(SettingsStore.applyRulesDarwinNotification, privacy: .public)")
    }

    private func unregisterApplyRulesObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveEveryObserver(center, observer)
    }

    // Fallback if Apple ever fixes sendProviderMessage delivery. Today this
    // is never called for NETransparentProxyProvider, but keeping the
    // handler keeps the wire compatible.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard let newSettings = try? JSONDecoder().decode(ShuntSettings.self, from: messageData) else {
            completionHandler?(Data("err:decode".utf8))
            return
        }
        completionHandler?(Data("ok".utf8))
        let newRules = newSettings.rules.filter { $0.enabled && $0.isValid }
        stateLock.lock()
        activeRules = newRules
        upstream = newSettings.upstream
        stateLock.unlock()
        logger.notice("handleAppMessage applied (legacy path)")
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // Snapshot the rule/upstream state under the lock so the rest of
        // the method works against a consistent view (a Darwin-notification
        // swap on another thread can otherwise interleave).
        stateLock.lock()
        let rules = activeRules
        let currentUpstream = upstream
        stateLock.unlock()

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
        for rule in rules where
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

        // DNS-resolution policy: when `upstream.useRemoteDNS` is on (default),
        // hand the pre-resolution hostname to SOCKS5 (ATYP 0x03) so the
        // upstream proxy applies hostname-based policy and we don't leak the
        // routed query to the host's local resolver. When OFF, always send
        // the OS-resolved IP literal (ATYP 0x01/0x04) — useful when the
        // upstream rejects domain-name CONNECT, or for debugging IP-based
        // rules.
        let targetHost: String
        if currentUpstream.useRemoteDNS && !preResolved.isEmpty && !HostMatcher.isIPLiteral(preResolved) {
            targetHost = preResolved
        } else {
            targetHost = endpointHost
        }

        logger.info("CLAIM \(source, privacy: .public) → \(targetHost, privacy: .public):\(port, privacy: .public) (endpoint=\(endpointHost, privacy: .public))")
        let bridge = SOCKS5Bridge(
            flow: tcp,
            socksHost: currentUpstream.host,
            socksPort: currentUpstream.port,
            bindInterface: currentUpstream.bindInterface,
            username: currentUpstream.username,
            password: currentUpstream.password,
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
