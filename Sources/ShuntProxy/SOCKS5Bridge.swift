import Foundation
import NetworkExtension
import os

/// Bridges a single NEAppProxyTCPFlow through a SOCKS5 proxy via a POSIX socket.
final class SOCKS5Bridge {
    private let flow: NEAppProxyTCPFlow
    private let socksHost: String
    private let socksPort: UInt16
    private let bindInterface: String?
    private let remoteHost: String
    private let remotePort: UInt16
    private let logger: Logger
    private let socket: POSIXTCPClient

    var onFinish: (() -> Void)?
    private var didFinish = false

    init(
        flow: NEAppProxyTCPFlow,
        socksHost: String,
        socksPort: UInt16,
        bindInterface: String?,
        remoteHost: String,
        remotePort: UInt16,
        logger: Logger
    ) {
        self.flow = flow
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.bindInterface = bindInterface
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.logger = logger
        self.socket = POSIXTCPClient(logger: logger)
        self.socket.onClose = { [weak self] error in
            guard let self else { return }
            self.logger.info("socket onClose err=\(error?.localizedDescription ?? "nil", privacy: .public)")
            self.closeAll()
        }
    }

    func start() {
        logger.info("bridge.start → \(self.remoteHost, privacy: .public):\(self.remotePort, privacy: .public) via socks \(self.socksHost, privacy: .public):\(self.socksPort, privacy: .public)")
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("flow.open failed: \(error.localizedDescription, privacy: .public)")
                self.closeAll()
                return
            }
            self.connectSocks()
        }
    }

    private func connectSocks() {
        // bindInterface bypasses NECP scoping when the upstream lives on a virtual
        // bridge unreachable via the primary NIC (e.g. Parallels bridge100). Nil =
        // use the host's default routing table.
        socket.connect(host: socksHost, port: socksPort, bindInterface: bindInterface) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("socks connect failed: \(error.localizedDescription, privacy: .public)")
                self.closeAll()
                return
            }
            self.sendGreeting()
        }
    }

    private func sendGreeting() {
        let greeting = Data([0x05, 0x01, 0x00])
        socket.write(greeting) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("greeting write: \(error.localizedDescription, privacy: .public)")
                self.closeAll()
                return
            }
            self.recvGreetingReply()
        }
    }

    private func recvGreetingReply() {
        socket.read(minimum: 2, maximum: 2) { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.logger.error("greeting read: \(error.localizedDescription, privacy: .public)")
                self.closeAll()
                return
            }
            guard let data, data.count == 2, data[0] == 0x05, data[1] == 0x00 else {
                self.logger.error("greeting rejected")
                self.closeAll()
                return
            }
            self.sendConnect()
        }
    }

    private func sendConnect() {
        var packet = Data([0x05, 0x01, 0x00])
        if let ipv4 = Self.parseIPv4(remoteHost) {
            packet.append(0x01)
            packet.append(contentsOf: ipv4)
        } else {
            packet.append(0x03)
            let utf8 = Array(remoteHost.utf8)
            guard utf8.count <= 255 else {
                logger.error("hostname too long: \(self.remoteHost, privacy: .public)")
                closeAll()
                return
            }
            packet.append(UInt8(utf8.count))
            packet.append(contentsOf: utf8)
        }
        packet.append(UInt8(remotePort >> 8))
        packet.append(UInt8(remotePort & 0xFF))

        socket.write(packet) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("CONNECT write: \(error.localizedDescription, privacy: .public)")
                self.closeAll()
                return
            }
            self.recvConnectReplyHeader()
        }
    }

    private func recvConnectReplyHeader() {
        socket.read(minimum: 4, maximum: 4) { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.logger.error("CONNECT reply read: \(error.localizedDescription, privacy: .public)")
                self.closeAll()
                return
            }
            guard let data, data.count == 4, data[0] == 0x05 else {
                self.logger.error("CONNECT reply malformed")
                self.closeAll()
                return
            }
            guard data[1] == 0x00 else {
                self.logger.error("CONNECT rejected rep=\(data[1])")
                self.closeAll()
                return
            }
            switch data[3] {
            case 0x01: self.drainConnectReply(addrBytes: 4)
            case 0x04: self.drainConnectReply(addrBytes: 16)
            case 0x03:
                self.socket.read(minimum: 1, maximum: 1) { [weak self] data, _ in
                    guard let self, let len = data?.first else { self?.closeAll(); return }
                    self.drainConnectReply(addrBytes: Int(len))
                }
            default:
                self.logger.error("CONNECT reply unknown ATYP \(data[3])")
                self.closeAll()
            }
        }
    }

    private func drainConnectReply(addrBytes: Int) {
        let remaining = addrBytes + 2
        socket.read(minimum: remaining, maximum: remaining) { [weak self] _, _ in
            guard let self else { return }
            self.logger.info("socks connected through to \(self.remoteHost, privacy: .public):\(self.remotePort, privacy: .public), pumping")
            self.pumpFlowToSocks()
            self.pumpSocksToFlow()
        }
    }

    private func pumpFlowToSocks() {
        flow.readData { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.logger.debug("flow read: \(error.localizedDescription, privacy: .public)")
                self.closeAll()
                return
            }
            guard let data, !data.isEmpty else {
                self.socket.close()
                return
            }
            self.socket.write(data) { [weak self] error in
                guard let self else { return }
                if error != nil { self.closeAll(); return }
                self.pumpFlowToSocks()
            }
        }
    }

    private func pumpSocksToFlow() {
        socket.read(minimum: 1, maximum: 65536) { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.logger.debug("sock read: \(error.localizedDescription, privacy: .public)")
                self.closeAll()
                return
            }
            guard let data, !data.isEmpty else {
                self.flow.closeReadWithError(nil)
                return
            }
            self.flow.write(data) { [weak self] error in
                guard let self else { return }
                if error != nil { self.closeAll(); return }
                self.pumpSocksToFlow()
            }
        }
    }

    private func closeAll() {
        socket.close()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        if !didFinish {
            didFinish = true
            onFinish?()
        }
    }

    static func parseIPv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var out = [UInt8]()
        for p in parts {
            guard let n = UInt8(p) else { return nil }
            out.append(n)
        }
        return out
    }
}
