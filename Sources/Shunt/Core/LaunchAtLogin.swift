import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` to register/unregister Shunt
/// as a Login Item. SMAppService persists state itself — there is no setting
/// in `ShuntSettings`; views read `LaunchAtLogin.shared.isEnabled` directly.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var isEnabled: Bool = false
    @Published var lastError: String?

    private init() {
        refresh()
    }

    /// Pull the current status from the system. Call this on view appear so
    /// the UI reflects the truth even if the user toggled state via System
    /// Settings → General → Login Items in the meantime.
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled)
    }

    /// Set the desired state. Synchronous on the SMAppService side — calls
    /// `register()` / `unregister()` and updates `isEnabled` to reflect the
    /// new status. Errors land in `lastError`.
    func set(_ desired: Bool) {
        do {
            if desired {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
