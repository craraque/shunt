import Foundation
import Network
import Darwin

/// Health probe implementations for the upstream launcher. Each function runs
/// a single attempt and returns a `ProbeResult`; the engine drives retries and
/// timeouts on top.
public enum LauncherProbes {

    public struct ProbeResult: Sendable, Equatable {
        public let ok: Bool
        public let detail: String
        public init(ok: Bool, detail: String) {
            self.ok = ok
            self.detail = detail
        }
    }

    /// Dispatch a single attempt of the requested probe mode against the
    /// upstream proxy. Intended to be called by the engine in a polling loop;
    /// a single failure here is not authoritative until the outer timeout
    /// elapses.
    public static func run(
        _ probe: HealthProbe,
        upstream: UpstreamProxy,
        connectTimeout: TimeInterval = 2.0
    ) async -> ProbeResult {
        switch probe {
        case .portOpen:
            return await portOpen(host: upstream.host, port: upstream.port, timeout: connectTimeout)
        case .socks5Handshake:
            return await socks5Handshake(host: upstream.host, port: upstream.port, timeout: connectTimeout)
        case .tcpConnect(let host, let port):
            return await portOpen(host: host, port: port, timeout: connectTimeout)
        case .socks5HandshakeAt(let host, let port):
            return await socks5Handshake(host: host, port: port, timeout: connectTimeout)
        case .commandExitZero(let command):
            return await commandExitZero(command: command, timeout: connectTimeout)
        case .egressCidrMatch(let cidr, let probeURL):
            return await egressCidrMatch(upstream: upstream, cidr: cidr, probeURL: probeURL)
        case .egressDiffersFromDirect(let probeURL):
            return await egressDiffersFromDirect(upstream: upstream, probeURL: probeURL)
        }
    }

    // MARK: - portOpen

    /// TCP connect to `host:port`. `ok` when `NWConnection` reaches `.ready`.
    public static func portOpen(host: String, port: UInt16, timeout: TimeInterval = 2.0) async -> ProbeResult {
        let endpoint = NWEndpoint.hostPort(
            host: .init(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        let connection = NWConnection(to: endpoint, using: .tcp)

        return await withCheckedContinuation { cont in
            let handled = AtomicBool()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard handled.compareAndSet(expected: false, new: true) else { return }
                    connection.cancel()
                    cont.resume(returning: ProbeResult(ok: true, detail: "port open"))
                case .failed(let error):
                    guard handled.compareAndSet(expected: false, new: true) else { return }
                    connection.cancel()
                    cont.resume(returning: ProbeResult(ok: false, detail: "connect failed: \(error)"))
                case .cancelled:
                    guard handled.compareAndSet(expected: false, new: true) else { return }
                    cont.resume(returning: ProbeResult(ok: false, detail: "cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: probeQueue)

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if handled.compareAndSet(expected: false, new: true) {
                    connection.cancel()
                    cont.resume(returning: ProbeResult(ok: false, detail: "timeout after \(timeout)s"))
                }
            }
        }
    }

    // MARK: - socks5Handshake

    /// Connect + SOCKS5 greeting. Sends `05 01 00` (one method, NO AUTH),
    /// expects `05 00` (method selected: NO AUTH). This proves a SOCKS5
    /// server is answering but not that the upstream egress path works.
    public static func socks5Handshake(host: String, port: UInt16, timeout: TimeInterval = 2.0) async -> ProbeResult {
        let endpoint = NWEndpoint.hostPort(
            host: .init(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        let connection = NWConnection(to: endpoint, using: .tcp)

        return await withCheckedContinuation { cont in
            let handled = AtomicBool()
            func finish(_ result: ProbeResult) {
                guard handled.compareAndSet(expected: false, new: true) else { return }
                connection.cancel()
                cont.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let greeting = Data([0x05, 0x01, 0x00])
                    connection.send(content: greeting, completion: .contentProcessed { err in
                        if let err {
                            finish(ProbeResult(ok: false, detail: "send failed: \(err)"))
                            return
                        }
                        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, recvErr in
                            if let recvErr {
                                finish(ProbeResult(ok: false, detail: "recv failed: \(recvErr)"))
                                return
                            }
                            guard let data, data.count == 2 else {
                                finish(ProbeResult(ok: false, detail: "short read"))
                                return
                            }
                            if data[0] == 0x05 && data[1] == 0x00 {
                                finish(ProbeResult(ok: true, detail: "socks5 ready"))
                            } else {
                                let hex = data.map { String(format: "%02x", $0) }.joined()
                                finish(ProbeResult(ok: false, detail: "unexpected reply: \(hex)"))
                            }
                        }
                    })
                case .failed(let error):
                    finish(ProbeResult(ok: false, detail: "connect failed: \(error)"))
                case .cancelled:
                    finish(ProbeResult(ok: false, detail: "cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: probeQueue)

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish(ProbeResult(ok: false, detail: "timeout after \(timeout)s"))
            }
        }
    }

    // MARK: - commandExitZero

    /// Runs `command` through the user's login shell and returns OK only when
    /// it exits 0. Output is discarded; callers get a compact status detail.
    public static func commandExitZero(command: String, timeout: TimeInterval = 5.0) async -> ProbeResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ProbeResult(ok: false, detail: "empty command")
        }

        return await withCheckedContinuation { cont in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-l", "-c", trimmed]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice

            let handled = AtomicBool()
            @Sendable func finish(_ result: ProbeResult) {
                guard handled.compareAndSet(expected: false, new: true) else { return }
                if task.isRunning { task.terminate() }
                cont.resume(returning: result)
            }

            task.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    finish(ProbeResult(ok: true, detail: "command exited 0"))
                } else {
                    finish(ProbeResult(ok: false, detail: "command exited \(proc.terminationStatus)"))
                }
            }

            do {
                try task.run()
            } catch {
                finish(ProbeResult(ok: false, detail: "spawn failed: \(error.localizedDescription)"))
                return
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish(ProbeResult(ok: false, detail: "command timeout after \(timeout)s"))
            }
        }
    }

    // MARK: - egressCidrMatch

    public static func egressCidrMatch(upstream: UpstreamProxy, cidr: String, probeURL: URL) async -> ProbeResult {
        do {
            let ip = try await fetchEgressIP(via: upstream, probeURL: probeURL)
            let pattern = HostPattern(kind: .cidr, pattern: cidr)
            if HostMatcher.matches(pattern, hostname: nil, ip: ip) {
                return ProbeResult(ok: true, detail: "egress \(ip) ∈ \(cidr)")
            }
            return ProbeResult(ok: false, detail: "egress \(ip) ∉ \(cidr)")
        } catch {
            return ProbeResult(ok: false, detail: "fetch via SOCKS5 failed: \(error.localizedDescription)")
        }
    }

    // MARK: - egressDiffersFromDirect

    public static func egressDiffersFromDirect(upstream: UpstreamProxy, probeURL: URL) async -> ProbeResult {
        async let direct = fetchEgressIP(direct: true, probeURL: probeURL, via: upstream)
        async let proxied = fetchEgressIP(direct: false, probeURL: probeURL, via: upstream)
        do {
            let (a, b) = try await (direct, proxied)
            if a != b, !a.isEmpty, !b.isEmpty {
                return ProbeResult(ok: true, detail: "direct=\(a) proxied=\(b)")
            }
            return ProbeResult(ok: false, detail: "direct==proxied (\(a)) — upstream not yet routing")
        } catch {
            return ProbeResult(ok: false, detail: "probe fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - egress fetch helper

    private static func fetchEgressIP(direct: Bool = false, probeURL: URL, via upstream: UpstreamProxy) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.urlCache = nil
        if !direct {
            // macOS URLSession accepts SOCKS via the CFNetwork keys. SOCKS5 is
            // auto-negotiated; no explicit version knob.
            config.connectionProxyDictionary = [
                kCFNetworkProxiesSOCKSEnable: 1,
                kCFNetworkProxiesSOCKSProxy: upstream.host,
                kCFNetworkProxiesSOCKSPort: Int(upstream.port),
            ] as [AnyHashable: Any]
        }
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(from: probeURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "Probe", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Probe", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "non-utf8 body"])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fetchEgressIP(via upstream: UpstreamProxy, probeURL: URL) async throws -> String {
        try await fetchEgressIP(direct: false, probeURL: probeURL, via: upstream)
    }

    // Shared dispatch queue for NWConnection callbacks.
    private static let probeQueue = DispatchQueue(label: "shunt.launcher.probes")
}

// MARK: - Small atomic flag (handler de-dup)

/// `NWConnection`'s `stateUpdateHandler` can fire multiple times; we also have
/// a timeout Task that races with it. This minimal atomic bool ensures only
/// the first finisher resumes the continuation.
private final class AtomicBool: @unchecked Sendable {
    private var value: Bool = false
    private let lock = NSLock()

    func compareAndSet(expected: Bool, new: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value == expected {
            value = new
            return true
        }
        return false
    }
}
