import XCTest
@testable import ShuntCore

final class TartReverseTunnelPresetTests: XCTestCase {
    func testPresetUsesHostLoopbackUpstreamAndEgressProbe() throws {
        let preset = TartReverseTunnelPreset(
            vmName: "tahoe-base",
            hostBridgeIP: "192.168.64.1",
            hostPort: 1080,
            guestSocksPort: 1080,
            sshIdentityPath: "/Users/admin/.ssh/id_shunttunnel"
        )

        XCTAssertEqual(preset.upstream, UpstreamProxy(host: "127.0.0.1", port: 1080, bindInterface: nil, useRemoteDNS: true))
        XCTAssertEqual(preset.launcher.stages.count, 1)
        XCTAssertEqual(preset.launcher.stages.first?.name, "Tart reverse tunnel")

        let entry = try XCTUnwrap(preset.launcher.stages.first?.entries.first)
        XCTAssertEqual(entry.name, "tahoe-base → localhost:1080")
        XCTAssertTrue(entry.startCommand.contains("tart exec tahoe-base"))
        XCTAssertTrue(entry.startCommand.contains("-R 127.0.0.1:1080:127.0.0.1:1080"))
        XCTAssertTrue(entry.startCommand.contains("-o IdentitiesOnly=yes"))
        XCTAssertTrue(entry.startCommand.contains("-i /Users/admin/.ssh/id_shunttunnel"))
        XCTAssertTrue(entry.startCommand.contains("-o StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(entry.startCommand.contains("admin@192.168.64.1"))
        XCTAssertNil(entry.stopCommand)
        XCTAssertEqual(entry.externalPolicy, .neverReclaim)
        XCTAssertEqual(entry.startTimeoutSeconds, 90)
        XCTAssertEqual(entry.probeIntervalSeconds, 2)
        XCTAssertEqual(entry.healthProbe, .egressDiffersFromDirect(probeURL: HealthProbe.defaultProbeURL))
    }

    func testPresetShellQuotesUnsafeArguments() {
        let preset = TartReverseTunnelPreset(
            vmName: "vm name; rm -rf /",
            hostBridgeIP: "192.168.64.1",
            sshUser: "admin user",
            sshIdentityPath: "/tmp/key with spaces"
        )

        XCTAssertTrue(preset.launcher.stages[0].entries[0].startCommand.contains("'vm name; rm -rf /'"))
        XCTAssertTrue(preset.launcher.stages[0].entries[0].startCommand.contains("-i '/tmp/key with spaces'"))
        XCTAssertTrue(preset.launcher.stages[0].entries[0].startCommand.contains("'admin user'@192.168.64.1"))
    }
}
