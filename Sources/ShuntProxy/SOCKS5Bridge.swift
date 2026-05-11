import Foundation
import NetworkExtension
import ShuntCore
import os

/// Bridges a single NEAppProxyTCPFlow through a SOCKS5 proxy via a POSIX socket.
final class SOCKS5Bridge {
    private let flow: NEAppProxyTCPFlow
    private let socksHost: String
    private let socksPort: UInt16
    private let bindInterface: String?
    private let username: String
    private let password: String
    private let remoteHost: String
    private let remotePort: UInt16
    private let logger: Logger
    private let socket: POSIXTCPClient

    var onFinish: (() -> Void)?
    private var didFinish = false
    private let finishLock = NSLock()

    private var hasAuth: Bool {
        !username.isEmpty && !password.isEmpty
    }

    init(
        flow: NEAppProxyTCPFlow,
        socksHost: String,
        socksPort: UInt16,
        bindInterface: String?,
        username: String = "",
        password: String = "",
        remoteHost: String,
        remotePort: UInt16,
        logger: Logger
    ) {
        self.flow = flow
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.bindInterface = bindInterface
        self.username = username
        self.password = password
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
        // bindInterface uses explicit interface binding to avoid NECP default-interface scoping when the upstream lives on a virtual
        // bridge unreachable via the primary NIC (e.g. Parallels ). Nil =
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
        // Advertise no-auth + user/pass when we have credentials, else
        // just no-auth. Server picks one method via the reply byte.
        let greeting: Data = hasAuth
            ? Data([0x05, 0x02, 0x00, 0x02])    // VER, NMETHODS=2, methods: 00 + 02
            : Data([0x05, 0x01, 0x00])           // VER, NMETHODS=1, method: 00
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
            guard let data, data.count == 2, data[0] == 0x05 else {
                self.logger.error("greeting rejected (bad version)")
                self.closeAll()
                return
            }
            switch data[1] {
            case 0x00:
                // No-auth — proceed straight to CONNECT.
                self.sendConnect()
            case 0x02:
                // User/pass — RFC 1929 subnegotiation.
                guard self.hasAuth else {
                    self.logger.error("server requires user/pass but no credentials set")
                    self.closeAll()
                    return
                }
                self.sendUserPassAuth()
            case 0xFF:
                self.logger.error("server rejected all methods (no acceptable auth)")
                self.closeAll()
            default:
                self.logger.error("server picked unsupported method 0x\(String(format: "%02X", data[1]))")
                self.closeAll()
            }
        }
    }

    /// RFC 1929 user/pass subnegotiation:
    ///   Request:  01 ULEN UNAME PLEN PASSWD
    ///   Response: 01 STATUS    (00 = ok)
    private func sendUserPassAuth() {
        let userBytes = Array(username.utf8)
        let passBytes = Array(password.utf8)
        guard userBytes.count <= 255, passBytes.count <= 255 else {
            logger.error("user/pass too long for SOCKS5 auth")
            closeAll()
            return
        }
        var packet = Data()
        packet.append(0x01)                          // subnegotiation version
        packet.append(UInt8(userBytes.count))
        packet.append(contentsOf: userBytes)
        packet.append(UInt8(passBytes.count))
        packet.append(contentsOf: passBytes)
        socket.write(packet) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("auth write: \(error.localizedDescription, privacy: .public)")
                self.closeAll()
                return
            }
            self.recvUserPassReply()
        }
    }

    private func recvUserPassReply() {
        socket.read(minimum: 2, maximum: 2) { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.logger.error("auth read: \(error.localizedDescription, privacy: .public)")
                self.closeAll()
                return
            }
            guard let data, data.count == 2, data[0] == 0x01, data[1] == 0x00 else {
                self.logger.error("auth rejected by upstream (status=0x\(String(format: "%02X", data?.last ?? 0xFF)))")
                self.closeAll()
                return
            }
            self.sendConnect()
        }
    }

    private func sendConnect() {
        var packet = Data([0x05, 0x01, 0x00])
        do {
            packet.append(try SOCKS5AddressEncoder.encodeAddress(host: remoteHost))
        } catch {
            logger.error("invalid SOCKS5 destination \(self.remoteHost, privacy: .public): \(error.localizedDescription, privacy: .public)")
            closeAll()
            return
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

    func close() {
        closeAll()
    }

    private func closeAll() {
        socket.close()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)

        finishLock.lock()
        let shouldNotify = !didFinish
        didFinish = true
        finishLock.unlock()

        if shouldNotify {
            onFinish?()
        }
    }
}
