import Foundation
import Combine

/// Cross-component navigation for the Settings window. Anything that wants
/// to deep-link into a specific tab (e.g. the menubar popover's "Edit Rules"
/// item) sets `requestedTab` here; SettingsView observes the property and
/// switches `selection` when it changes, then clears the request.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()

    @Published var requestedTab: SidebarItem? = nil

    private init() {}

    func request(_ tab: SidebarItem) {
        requestedTab = tab
    }
}
