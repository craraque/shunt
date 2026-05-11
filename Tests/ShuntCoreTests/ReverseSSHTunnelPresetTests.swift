import XCTest
@testable import ShuntCore

final class ReverseSSHTunnelPresetTests: XCTestCase {
    func testPresetUsesHostLoopbackUpstreamAndEgressProbe() throws {
        let preset = ReverseSSHTunnelPreset(
            commandPrefix: "tart exec tahoe-base",
            hostBridgeIP: "192.168.64.1",
            hostPort: 1080,
            remoteSocksPort: 1080,
            sshIdentityPath: "/tmp/id_shunt_tunnel"
        )

        XCTAssertEqual(preset.upstream, UpstreamProxy(host: "127.0.0.1", port: 1080, bindInterface: nil, useRemoteDNS: true))
        XCTAssertEqual(preset.launcher.stages.count, 1)
        XCTAssertEqual(preset.launcher.stages.first?.name, "SSH reverse tunnel")

        let entry = try XCTUnwrap(preset.launcher.stages.first?.entries.first)
        XCTAssertEqual(entry.name, "Host localhost:1080 ⇠ remote SOCKS:1080")
        XCTAssertTrue(entry.startCommand.contains("tart exec tahoe-base"))
        XCTAssertTrue(entry.startCommand.contains("ssh -N"))
        XCTAssertTrue(entry.startCommand.contains("-R 127.0.0.1:1080:127.0.0.1:1080"))
        XCTAssertTrue(entry.startCommand.contains("-o IdentitiesOnly=yes"))
        XCTAssertTrue(entry.startCommand.contains("-i /tmp/id_shunt_tunnel"))
        XCTAssertTrue(entry.startCommand.contains("-o StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(entry.startCommand.contains("admin@192.168.64.1"))
        XCTAssertNil(entry.stopCommand)
        XCTAssertEqual(entry.externalPolicy, .neverReclaim)
        XCTAssertEqual(entry.startTimeoutSeconds, 90)
        XCTAssertEqual(entry.probeIntervalSeconds, 2)
        XCTAssertEqual(entry.healthProbe, .egressDiffersFromDirect(probeURL: HealthProbe.defaultProbeURL))
    }

    func testPresetCanGeneratePlainSSHCommandWithoutTartOrParallelsWrapper() {
        let preset = ReverseSSHTunnelPreset(
            commandPrefix: "",
            hostBridgeIP: "10.37.129.1",
            sshUser: "tunnel",
            hostPort: 2080,
            remoteSocksPort: 1080,
            sshIdentityPath: "/Users/alice/.ssh/shunt_tunnel"
        )

        let command = preset.launcher.stages[0].entries[0].startCommand
        XCTAssertTrue(command.hasPrefix("ssh -N -R 127.0.0.1:2080:127.0.0.1:1080"))
        XCTAssertFalse(command.contains("tart exec"))
        XCTAssertTrue(command.contains("tunnel@10.37.129.1"))
    }

    func testPresetShellQuotesUnsafeArguments() {
        let preset = ReverseSSHTunnelPreset(
            commandPrefix: "tart exec 'vm name; rm -rf /'",
            hostBridgeIP: "host ip",
            sshUser: "admin user",
            sshIdentityPath: "/tmp/key with spaces"
        )

        let command = preset.launcher.stages[0].entries[0].startCommand
        XCTAssertTrue(command.contains("tart exec 'vm name; rm -rf /'"))
        XCTAssertTrue(command.contains("-i '/tmp/key with spaces'"))
        XCTAssertTrue(command.contains("'admin user'@'host ip'"))
    }
}
