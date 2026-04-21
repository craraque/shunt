import Foundation
import SystemExtensions

final class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate {
    static let extensionBundleIdentifier = "com.craraque.shunt.proxy"

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
