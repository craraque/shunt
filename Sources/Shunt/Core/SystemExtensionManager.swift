import Foundation
import SystemExtensions

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
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }
        return output.split(separator: "\n").contains { line in
            line.contains(Self.extensionBundleIdentifier)
                && line.contains("[activated enabled]")
        }
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
