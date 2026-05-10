import Foundation

/// Convenience builder for the production Tart + guest-VPN topology where the
/// guest owns the VPN/SOCKS egress and exposes it to Shunt through an SSH
/// remote forward on host loopback.
///
/// The generated launcher entry runs on the host and asks Tart to execute the
/// SSH client in the VM:
///
/// ```text
/// tart exec <vm> ssh -N -R 127.0.0.1:<hostPort>:127.0.0.1:<guestSocksPort> ...
/// ```
///
/// Shunt itself then uses `127.0.0.1:<hostPort>` as the upstream, avoiding the
/// direct host→guest path that VPN clients can break with asymmetric routing.
public struct TartReverseTunnelPreset: Hashable, Sendable {
    public var vmName: String
    public var hostBridgeIP: String
    public var sshUser: String
    public var hostPort: UInt16
    public var guestSocksPort: UInt16
    public var sshIdentityPath: String
    public var probeURL: URL

    public init(
        vmName: String,
        hostBridgeIP: String,
        sshUser: String = "admin",
        hostPort: UInt16 = 1080,
        guestSocksPort: UInt16 = 1080,
        sshIdentityPath: String = "/Users/admin/.ssh/id_shunttunnel",
        probeURL: URL = HealthProbe.defaultProbeURL
    ) {
        self.vmName = vmName
        self.hostBridgeIP = hostBridgeIP
        self.sshUser = sshUser
        self.hostPort = hostPort
        self.guestSocksPort = guestSocksPort
        self.sshIdentityPath = sshIdentityPath
        self.probeURL = probeURL
    }

    /// Host-side upstream Shunt should use once the reverse tunnel is running.
    public var upstream: UpstreamProxy {
        UpstreamProxy(
            host: "127.0.0.1",
            port: hostPort,
            bindInterface: nil,
            username: "",
            password: "",
            useRemoteDNS: true
        )
    }

    /// One-stage launcher that starts the remote forward and waits until SOCKS
    /// egress differs from the host's direct egress before enabling the tunnel.
    public var launcher: UpstreamLauncher {
        let entry = UpstreamLauncherEntry(
            name: "\(vmName) → localhost:\(hostPort)",
            startCommand: startCommand,
            stopCommand: nil,
            healthProbe: .egressDiffersFromDirect(probeURL: probeURL),
            probeIntervalSeconds: 2,
            startTimeoutSeconds: 90,
            externalPolicy: .neverReclaim
        )
        return UpstreamLauncher(stages: [
            UpstreamLauncherStage(name: "Tart reverse tunnel", entries: [entry])
        ])
    }

    /// Full command suitable for `UpstreamLauncherEntry.startCommand`.
    public var startCommand: String {
        [
            "tart exec \(Self.shellQuote(vmName))",
            "ssh -N",
            "-R 127.0.0.1:\(hostPort):127.0.0.1:\(guestSocksPort)",
            "-o IdentitiesOnly=yes",
            "-i \(Self.shellQuote(sshIdentityPath))",
            "-o ServerAliveInterval=15",
            "-o ServerAliveCountMax=3",
            "-o ExitOnForwardFailure=yes",
            "-o StrictHostKeyChecking=accept-new",
            "\(Self.shellQuote(sshUser))@\(Self.shellQuote(hostBridgeIP))"
        ].joined(separator: " ")
    }

    /// POSIX-safe single-quote wrapper for shell command arguments.
    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safeScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if value.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
