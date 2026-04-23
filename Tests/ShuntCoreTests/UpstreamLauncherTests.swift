import XCTest
@testable import ShuntCore

final class UpstreamLauncherTests: XCTestCase {

    // MARK: - Defaults

    func testEmptyIsNoOp() {
        let launcher = UpstreamLauncher.empty
        XCTAssertTrue(launcher.stages.isEmpty)
        XCTAssertTrue(launcher.allEntries.isEmpty)
    }

    func testSettingsDefaultLauncherIsEmpty() {
        let settings = ShuntSettings()
        XCTAssertTrue(settings.launcher.stages.isEmpty)
    }

    func testEntryDefaults() {
        let entry = UpstreamLauncherEntry()
        XCTAssertTrue(entry.enabled)
        XCTAssertEqual(entry.probeIntervalSeconds, 2)
        XCTAssertEqual(entry.startTimeoutSeconds, 60)
        XCTAssertEqual(entry.healthProbe, .portOpen)
        XCTAssertNil(entry.stopCommand)
    }

    // MARK: - allEntries flattens stages in order

    func testAllEntriesPreservesOrder() {
        let e1 = UpstreamLauncherEntry(name: "a")
        let e2 = UpstreamLauncherEntry(name: "b")
        let e3 = UpstreamLauncherEntry(name: "c")
        let launcher = UpstreamLauncher(stages: [
            UpstreamLauncherStage(name: "S1", entries: [e1, e2]),
            UpstreamLauncherStage(name: "S2", entries: [e3]),
        ])
        XCTAssertEqual(launcher.allEntries.map(\.name), ["a", "b", "c"])
    }

    // MARK: - Codable: absent field on decode → .empty

    func testDecodingV2JSONWithoutLauncherFieldProducesEmptyLauncher() throws {
        // A settings file written before Phase 3f shipped: no "launcher" key.
        let json = """
        {
          "schemaVersion": 2,
          "managedApps": [],
          "upstream": { "host": "10.0.0.1", "port": 1080 },
          "rules": [],
          "themeID": "filament"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ShuntSettings.self, from: json)
        XCTAssertTrue(decoded.launcher.stages.isEmpty)
        XCTAssertEqual(decoded.upstream.host, "10.0.0.1")
    }

    func testDecodingV1JSONProducesEmptyLauncherAndMigratedRules() throws {
        let json = """
        {
          "managedApps": [
            { "id": "00000000-0000-0000-0000-000000000001",
              "bundleID": "com.apple.Safari",
              "displayName": "Safari",
              "enabled": true }
          ],
          "upstream": { "host": "127.0.0.1", "port": 1080 }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ShuntSettings.self, from: json)
        XCTAssertEqual(decoded.schemaVersion, 2) // migrated
        XCTAssertEqual(decoded.rules.count, 1)   // one rule derived per app
        XCTAssertTrue(decoded.launcher.stages.isEmpty)
    }

    // MARK: - Codable: round trip populated launcher

    func testCodableRoundTripPopulatedLauncher() throws {
        let entry1 = UpstreamLauncherEntry(
            name: "Tart VM",
            startCommand: "tart run --no-graphics mac-zscaler-test",
            stopCommand: "tart stop mac-zscaler-test",
            healthProbe: .egressDiffersFromDirect(probeURL: HealthProbe.defaultProbeURL),
            startTimeoutSeconds: 90
        )
        let entry2 = UpstreamLauncherEntry(
            name: "Post-start",
            startCommand: "/usr/local/bin/post-tunnel-hook.sh",
            healthProbe: .portOpen
        )
        let launcher = UpstreamLauncher(stages: [
            UpstreamLauncherStage(name: "VM", entries: [entry1]),
            UpstreamLauncherStage(name: "Hooks", entries: [entry2]),
        ])

        var settings = ShuntSettings()
        settings.launcher = launcher

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ShuntSettings.self, from: encoded)

        XCTAssertEqual(decoded.launcher, launcher)
        XCTAssertEqual(decoded.launcher.stages[0].entries[0].name, "Tart VM")
        XCTAssertEqual(decoded.launcher.stages[0].entries[0].startTimeoutSeconds, 90)
        XCTAssertEqual(decoded.launcher.allEntries.count, 2)
    }

    // MARK: - HealthProbe codable per case

    func testHealthProbeCodablePortOpen() throws {
        try assertProbeRoundTrip(.portOpen)
    }

    func testHealthProbeCodableSocks5Handshake() throws {
        try assertProbeRoundTrip(.socks5Handshake)
    }

    func testHealthProbeCodableEgressCidrMatch() throws {
        try assertProbeRoundTrip(.egressCidrMatch(
            cidr: "136.226.0.0/16",
            probeURL: URL(string: "https://ifconfig.me/ip")!
        ))
    }

    func testHealthProbeCodableEgressDiffersFromDirect() throws {
        try assertProbeRoundTrip(.egressDiffersFromDirect(
            probeURL: URL(string: "https://api.ipify.org/")!
        ))
    }

    private func assertProbeRoundTrip(_ probe: HealthProbe, file: StaticString = #file, line: UInt = #line) throws {
        let wrapped = UpstreamLauncherEntry(healthProbe: probe)
        let data = try JSONEncoder().encode(wrapped)
        let back = try JSONDecoder().decode(UpstreamLauncherEntry.self, from: data)
        XCTAssertEqual(back.healthProbe, probe, file: file, line: line)
    }
}
