import XCTest

final class NetworkExtensionPackagingTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testProxyInfoPlistUsesAppProxyProviderClassKey() throws {
        let plistURL = repoRoot.appending(path: "Resources/ShuntProxy-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let networkExtension = try XCTUnwrap(plist["NetworkExtension"] as? [String: Any])
        let providerClasses = try XCTUnwrap(networkExtension["NEProviderClasses"] as? [String: String])

        XCTAssertEqual(providerClasses["com.apple.networkextension.app-proxy"], "ShuntProxy.ShuntProxyProvider")
        XCTAssertNil(providerClasses["com.apple.networkextension.transparent-proxy"])
    }

    func testDeveloperIDEntitlementsUseAppProxySystemExtensionValue() throws {
        for relativePath in ["Resources/Shunt.entitlements", "Resources/ShuntProxy.entitlements"] {
            let url = repoRoot.appending(path: relativePath)
            let data = try Data(contentsOf: url)
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], relativePath)
            let values = try XCTUnwrap(
                plist["com.apple.developer.networking.networkextension"] as? [String],
                relativePath
            )

            XCTAssertTrue(values.contains("app-proxy-provider-systemextension"), relativePath)
            XCTAssertFalse(values.contains("transparent-proxy-systemextension"), relativePath)
        }
    }
}
