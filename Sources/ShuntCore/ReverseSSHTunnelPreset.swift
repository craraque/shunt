import Foundation

/// Convenience builder for VM/container/remote-host topologies where the SOCKS5
/// server is not directly reachable from the host, but that environment can SSH
/// back to the host and publish the SOCKS port on host loopback with `ssh -R`.
///
/// Shunt itself uses `127.0.0.1:<hostPort>` as the upstream. The launcher command
/// is intentionally editable: production can use Parallels, a plain SSH command,
/// launchd, or an already-running external tunnel; Tart is only the development
/// wrapper used by the default example.
public struct ReverseSSHTunnelPreset: Hashable, Sendable {
    public var launcherName: String
    public var commandPrefix: String
    public var hostBridgeIP: String
    public var sshUser: String
    public var hostPort: UInt16
    public var remoteSocksPort: UInt16
    public var sshIdentityPath: String
    public var probeURL: URL

    public init(
        launcherName: String = "SSH reverse tunnel",
        commandPrefix: String = "tart exec tahoe-base",
        hostBridgeIP: String = "192.168.64.1",
        sshUser: String = "admin",
        hostPort: UInt16 = 1080,
        remoteSocksPort: UInt16 = 1080,
        sshIdentityPath: String = "/Users/admin/.ssh/id_shunttunnel",
        probeURL: URL = HealthProbe.defaultProbeURL
    ) {
        self.launcherName = launcherName
        self.commandPrefix = commandPrefix
        self.hostBridgeIP = hostBridgeIP
        self.sshUser = sshUser
        self.hostPort = hostPort
        self.remoteSocksPort = remoteSocksPort
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
            name: "Host localhost:\(hostPort) ⇠ remote SOCKS:\(remoteSocksPort)",
            startCommand: startCommand,
            stopCommand: nil,
            healthProbe: .egressDiffersFromDirect(probeURL: probeURL),
            probeIntervalSeconds: 2,
            startTimeoutSeconds: 90,
            externalPolicy: .neverReclaim
        )
        return UpstreamLauncher(stages: [
            UpstreamLauncherStage(name: launcherName, entries: [entry])
        ])
    }

    /// Full command suitable for `UpstreamLauncherEntry.startCommand`.
    ///
    /// `commandPrefix` is evaluated before `ssh`. Examples:
    /// - `tart exec tahoe-base` for this development VM.
    /// - `prlctl exec <vm>` or an equivalent wrapper for Parallels.
    /// - empty string when the command already runs in the remote environment.
    public var startCommand: String {
        var parts: [String] = []
        let trimmedPrefix = commandPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrefix.isEmpty {
            parts.append(trimmedPrefix)
        }
        parts.append(contentsOf: [
            "ssh -N",
            "-R 127.0.0.1:\(hostPort):127.0.0.1:\(remoteSocksPort)",
            "-o IdentitiesOnly=yes",
            "-i \(Self.shellQuote(sshIdentityPath))",
            "-o ServerAliveInterval=15",
            "-o ServerAliveCountMax=3",
            "-o ExitOnForwardFailure=yes",
            "-o StrictHostKeyChecking=accept-new",
            "\(Self.shellQuote(sshUser))@\(Self.shellQuote(hostBridgeIP))"
        ])
        return parts.joined(separator: " ")
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
