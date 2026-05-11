import XCTest
@testable import ShuntCore

final class SystemExtensionCompatibilityTests: XCTestCase {
    func testParsesActiveExtensionVersionFromSystemextensionsctlLine() throws {
        let output = """
        enabled active teamID bundleID (version) name [state]
        * * 6NSZVJU6BP com.craraque.shunt.proxy (0.4.0/7) Shunt Proxy [activated enabled]
        """

        let snapshot = SystemExtensionSnapshot.parse(
            fromSystemExtensionsOutput: output,
            bundleIdentifier: "com.craraque.shunt.proxy"
        )

        XCTAssertEqual(snapshot?.version, SystemExtensionVersion(shortVersion: "0.4.0", build: "7"))
        XCTAssertEqual(snapshot?.state, .activatedEnabled)
    }

    func testParserPrefersEnabledExtensionOverPendingUninstallLine() throws {
        let output = """
        \t*\t6NSZVJU6BP\tcom.craraque.shunt.proxy (0.4.4/16)\tShunt Proxy\t[activated enabled]
        \t\t6NSZVJU6BP\tcom.craraque.shunt.proxy (0.4.0/7)\tShunt Proxy\t[terminated waiting to uninstall on reboot]
        """

        let snapshot = SystemExtensionSnapshot.parse(
            fromSystemExtensionsOutput: output,
            bundleIdentifier: "com.craraque.shunt.proxy"
        )

        XCTAssertEqual(snapshot?.version, SystemExtensionVersion(shortVersion: "0.4.4", build: "16"))
        XCTAssertEqual(snapshot?.state, .activatedEnabled)
    }

    func testStatusReportsAwaitingUserApprovalWhenReplacementIsWaiting() throws {
        let output = """
        \t*\t6NSZVJU6BP\tcom.craraque.shunt.proxy (0.4.4/16)\tShunt Proxy\t[activated waiting for user]
        \t\t6NSZVJU6BP\tcom.craraque.shunt.proxy (0.4.0/7)\tShunt Proxy\t[terminated waiting to uninstall on reboot]
        """
        let snapshot = SystemExtensionSnapshot.parse(
            fromSystemExtensionsOutput: output,
            bundleIdentifier: "com.craraque.shunt.proxy"
        )

        XCTAssertEqual(snapshot?.version, SystemExtensionVersion(shortVersion: "0.4.4", build: "16"))
        XCTAssertEqual(snapshot?.state, .activatedWaitingForUser)
        XCTAssertEqual(
            SystemExtensionCompatibility.evaluate(
                active: snapshot,
                bundled: SystemExtensionVersion(shortVersion: "0.4.4", build: "16"),
                minimumRequiredBuild: 16
            ),
            .awaitingUserApproval
        )
    }

    func testStatusRequiresRebootWhenOnlyTerminatedUninstallLineRemains() throws {
        let output = """
        \t\t6NSZVJU6BP\tcom.craraque.shunt.proxy (0.4.0/7)\tShunt Proxy\t[terminated waiting to uninstall on reboot]
        """
        let snapshot = SystemExtensionSnapshot.parse(
            fromSystemExtensionsOutput: output,
            bundleIdentifier: "com.craraque.shunt.proxy"
        )

        XCTAssertEqual(snapshot?.state, .terminatedWaitingToUninstallOnReboot)
        XCTAssertEqual(
            SystemExtensionCompatibility.evaluate(
                active: snapshot,
                bundled: SystemExtensionVersion(shortVersion: "0.4.4", build: "16"),
                minimumRequiredBuild: 16
            ),
            .restartRequired
        )
    }

    func testStatusReportsNotInstalledWhenNoActiveExtensionExists() throws {
        XCTAssertEqual(
            SystemExtensionCompatibility.evaluate(
                active: nil as SystemExtensionSnapshot?,
                bundled: SystemExtensionVersion(shortVersion: "0.4.1", build: "9"),
                minimumRequiredBuild: 9
            ),
            .notInstalled
        )
    }

    func testStatusRequiresUpdateWhenActiveBuildIsBelowMinimumRequiredBuild() throws {
        XCTAssertEqual(
            SystemExtensionCompatibility.evaluate(
                active: SystemExtensionSnapshot(version: .init(shortVersion: "0.4.0", build: "7"), state: .activatedEnabled),
                bundled: SystemExtensionVersion(shortVersion: "0.4.1", build: "9"),
                minimumRequiredBuild: 9
            ),
            .updateRequired
        )
    }

    func testStatusReportsAvailableWhenBundledIsNewerButActiveStillMeetsMinimum() throws {
        XCTAssertEqual(
            SystemExtensionCompatibility.evaluate(
                active: SystemExtensionSnapshot(version: .init(shortVersion: "0.4.0", build: "7"), state: .activatedEnabled),
                bundled: SystemExtensionVersion(shortVersion: "0.4.1", build: "9"),
                minimumRequiredBuild: 7
            ),
            .updateAvailable
        )
    }

    func testStatusIsCompatibleWhenActiveEqualsBundledAndMeetsMinimum() throws {
        XCTAssertEqual(
            SystemExtensionCompatibility.evaluate(
                active: SystemExtensionSnapshot(version: .init(shortVersion: "0.4.1", build: "9"), state: .activatedEnabled),
                bundled: SystemExtensionVersion(shortVersion: "0.4.1", build: "9"),
                minimumRequiredBuild: 9
            ),
            .compatible
        )
    }
}
