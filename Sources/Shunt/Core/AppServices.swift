import Foundation
import ShuntCore

/// Shared container for the long-lived services the UI needs to reach.
/// `AppDelegate` creates these once at launch and the rest of the code
/// accesses them through `.shared`.
final class AppServices {
    static let shared = AppServices()

    let extensionManager = SystemExtensionManager()
    let proxyManager = ProxyManager()
    let settingsStore = SettingsStore()

    private init() {}
}
