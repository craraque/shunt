import Foundation
import SystemExtensions
import AppKit
import ShuntCore

struct SystemExtensionHealth: Equatable {
    let active: SystemExtensionSnapshot?
    let bundled: SystemExtensionVersion?
    let minimumRequiredBuild: Int?
    let status: SystemExtensionCompatibilityStatus

    var activeDisplay: String { active?.displayString ?? "not installed" }
    var bundledDisplay: String { bundled?.displayString ?? "missing" }

    var detail: String {
        switch status {
        case .compatible:
            return "Active \(activeDisplay) · Bundled \(bundledDisplay)"
        case .updateAvailable:
            return "Active \(activeDisplay) · Bundled \(bundledDisplay)"
        case .updateRequired:
            return "Active \(activeDisplay) is below required build \(minimumRequiredBuild.map(String.init) ?? bundledDisplay)."
        case .awaitingUserApproval:
            return "Approve Shunt Proxy in System Settings to finish updating to \(bundledDisplay)."
        case .restartRequired:
            return "macOS is waiting for a restart before the old extension can be removed."
        case .notInstalled:
            return "Install or activate the bundled extension \(bundledDisplay)."
        case .bundledMissing:
            return "The app bundle does not contain ShuntProxy.systemextension."
        case .unknown:
            return "Could not inspect System Extension state."
        }
    }
}

final class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate {
    static let extensionBundleIdentifier = "com.craraque.shunt.proxy"

    /// Best-effort installed/active status for UI display.
    ///
    /// `NETransparentProxyManager.connection.status == .invalid` only means the
    /// transparent-proxy configuration/profile is not saved yet; it does *not*
    /// mean the System Extension is absent. Use `systemextensionsctl list` for
    /// the actual sysext activation state so the General tab doesn't say "not
    /// installed" while macOS already reports `[activated enabled]`.
    static func isActivatedInSystemExtensions() -> Bool {
        systemExtensionsListOutput()?.split(separator: "\n").contains { line in
            line.contains(Self.extensionBundleIdentifier)
                && line.contains("[activated enabled]")
        } ?? false
    }

    static func currentHealth() -> SystemExtensionHealth {
        let active = systemExtensionsListOutput().flatMap {
            SystemExtensionSnapshot.parse(
                fromSystemExtensionsOutput: $0,
                bundleIdentifier: Self.extensionBundleIdentifier
            )
        }
        let bundled = bundledExtensionVersion()
        let minimumRequiredBuild = Bundle.main.object(forInfoDictionaryKey: "ShuntMinimumRequiredExtensionBuild") as? Int
        let status = SystemExtensionCompatibility.evaluate(
            active: active,
            bundled: bundled,
            minimumRequiredBuild: minimumRequiredBuild
        )
        return SystemExtensionHealth(
            active: active,
            bundled: bundled,
            minimumRequiredBuild: minimumRequiredBuild,
            status: status
        )
    }

    static func openSystemExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    private static func systemExtensionsListOutput() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        process.arguments = ["list"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.error("systemextensionsctl list failed: \(error.localizedDescription)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func bundledExtensionVersion() -> SystemExtensionVersion? {
        let infoURL = Bundle.main.bundleURL
            .appending(path: "Contents/Library/SystemExtensions")
            .appending(path: "\(Self.extensionBundleIdentifier).systemextension")
            .appending(path: "Contents/Info.plist")
        guard let bundle = Bundle(url: infoURL.deletingLastPathComponent().deletingLastPathComponent()) else {
            return nil
        }
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let short, let build else { return nil }
        return SystemExtensionVersion(shortVersion: short, build: build)
    }

    var onActivationSuccess: (() -> Void)?
    var onRequestFinished: ((OSSystemExtensionRequest.Result) -> Void)?
    var onRequestFailed: ((Error) -> Void)?

    func activate() {
        Log.info("Submitting activation request for \(Self.extensionBundleIdentifier)")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        Log.info("Submitting deactivation request for \(Self.extensionBundleIdentifier)")
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        Log.info("Replacing \(existing.bundleVersion) → \(ext.bundleVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Log.info("Extension needs user approval in System Settings → Privacy & Security")
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Log.info("Extension request finished: result=\(result.rawValue)")
        if result == .completed {
            onActivationSuccess?()
        }
        onRequestFinished?(result)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Log.error("Extension request failed: \(error.localizedDescription)")
        onRequestFailed?(error)
    }
}
