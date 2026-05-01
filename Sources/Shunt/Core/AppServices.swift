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
    let launcherEngine = UpstreamLauncherEngine()

    /// Shared flow stream — both MonitorTab and the menubar popover read it.
    /// MainActor-isolated, so dereference from MainActor contexts.
    @MainActor
    let flowMonitor = FlowMonitor()

    private init() {}
}
