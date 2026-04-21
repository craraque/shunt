import Foundation
import Darwin
import os

/// Minimal async TCP client using POSIX sockets + DispatchSource.
/// Used by the SOCKS5 bridge because NEProvider.createTCPConnection and Network.NWConnection
/// both end up with their connections interface-scoped to the primary host NIC (e.g. en9/WiFi),
/// which can't reach a Parallels shared-network VM (10.211.55.x lives on bridge100).
/// POSIX connect() uses the host's routing table directly — no scoping.
final class POSIXTCPClient {
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "com.craraque.shunt.proxy.posix")
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    private var pendingReads: [(min: Int, max: Int, completion: (Data?, Error?) -> Void)] = []
    private let logger: Logger
    private var didClose = false

    var onClose: ((Error?) -> Void)?

    init(logger: Logger) {
        self.logger = logger
    }

    func connect(host: String, port: UInt16, bindInterface: String? = nil, completion: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.doConnect(host: host, port: port, bindInterface: bindInterface, completion: completion)
        }
    }

    private func doConnect(host: String, port: UInt16, bindInterface: String?, completion: @escaping (Error?) -> Void) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let rv = getaddrinfo(host, String(port), &hints, &result)
        guard rv == 0, let info = result else {
            let msg = String(cString: gai_strerror(rv))
            logger.error("getaddrinfo(\(host, privacy: .public)) failed: \(msg, privacy: .public)")
            completion(Self.errorFor("getaddrinfo: \(msg)"))
            return
        }
        defer { freeaddrinfo(info) }

        fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else {
            completion(Self.errorFor("socket() errno=\(errno)"))
            return
        }

        // Bypass NECP scoping — NE providers' outbound sockets are scoped to the primary NIC
        // by default, which blocks reaching Parallels bridge100 (10.211.55.x). Per Quinn
        // thread 736083, IP_BOUND_IF on the raw socket overrides the NECP scoping.
        if let ifName = bindInterface {
            let idx = if_nametoindex(ifName)
            if idx == 0 {
                logger.error("if_nametoindex(\(ifName, privacy: .public)) returned 0 — interface not found")
            } else {
                var value = UInt32(idx)
                let opt: Int32 = info.pointee.ai_family == AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF
                let level: Int32 = info.pointee.ai_family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP
                let rc = setsockopt(fd, level, opt, &value, socklen_t(MemoryLayout<UInt32>.size))
                if rc != 0 {
                    logger.error("setsockopt BOUND_IF \(ifName, privacy: .public) failed errno=\(errno)")
                } else {
                    logger.info("bound socket to \(ifName, privacy: .public) (ifindex=\(idx, privacy: .public))")
                }
            }
        }

        let cr = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        guard cr == 0 else {
            logger.error("connect(\(host, privacy: .public):\(port, privacy: .public)) failed errno=\(errno)")
            Darwin.close(fd); fd = -1
            completion(Self.errorFor("connect errno=\(errno)"))
            return
        }

        // Non-blocking for async reads
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        startReadLoop()
        logger.info("POSIX TCP connected \(host, privacy: .public):\(port, privacy: .public) fd=\(self.fd, privacy: .public)")
        completion(nil)
    }

    private func startReadLoop() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource = src
        src.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 16384)
            let n = Darwin.read(self.fd, &buf, buf.count)
            if n > 0 {
                self.readBuffer.append(contentsOf: buf[0..<n])
                self.drainPendingReads()
            } else if n == 0 {
                // EOF
                self.closeInternal(error: nil)
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                self.closeInternal(error: Self.errorFor("read errno=\(errno)"))
            }
        }
        src.resume()
    }

    func read(minimum: Int, maximum: Int, completion: @escaping (Data?, Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingReads.append((minimum, maximum, completion))
            self.drainPendingReads()
        }
    }

    private func drainPendingReads() {
        while let req = pendingReads.first, readBuffer.count >= req.min {
            let take = min(readBuffer.count, req.max)
            let chunk = readBuffer.prefix(take)
            readBuffer.removeFirst(take)
            pendingReads.removeFirst()
            req.completion(Data(chunk), nil)
        }
    }

    func write(_ data: Data, completion: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else {
                completion(Self.errorFor("socket closed"))
                return
            }
            var remaining = data
            while !remaining.isEmpty {
                let n = remaining.withUnsafeBytes { ptr -> Int in
                    return Darwin.send(self.fd, ptr.baseAddress, ptr.count, 0)
                }
                if n > 0 {
                    remaining = remaining.subdata(in: n..<remaining.count)
                } else if n == 0 {
                    completion(Self.errorFor("send returned 0"))
                    return
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        usleep(1000)
                        continue
                    }
                    completion(Self.errorFor("send errno=\(errno)"))
                    return
                }
            }
            completion(nil)
        }
    }

    func close() {
        queue.async { [weak self] in
            self?.closeInternal(error: nil)
        }
    }

    private func closeInternal(error: Error?) {
        guard !didClose else { return }
        didClose = true
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        // Fail any pending reads
        for req in pendingReads {
            req.completion(nil, error ?? Self.errorFor("connection closed"))
        }
        pendingReads.removeAll()
        onClose?(error)
    }

    static func errorFor(_ message: String) -> Error {
        NSError(domain: "POSIXTCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
