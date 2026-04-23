import Foundation
import SwiftUI
import ShuntCore

/// Holds the user's selected theme. Kept as a single source of truth shared
/// between SettingsView (which writes to it via the Themes tab) and the menu
/// bar icon (which re-tints when the theme changes).
///
/// The theme id is persisted in `ShuntSettings.themeID` so it survives
/// export/import and lives in the App Group container alongside the rest of
/// the user's settings.
@MainActor
final class ActiveTheme: ObservableObject {
    static let shared = ActiveTheme()

    @Published private(set) var current: ShuntTheme

    private init() {
        let settings = AppServices.shared.settingsStore.load()
        self.current = ShuntTheme.byID(settings.themeID)
    }

    /// Switch to the given theme and persist the choice. Notifies observers
    /// so the settings window + menu bar icon re-render in sync.
    func select(_ theme: ShuntTheme) {
        guard theme.id != current.id else { return }
        current = theme
        var settings = AppServices.shared.settingsStore.load()
        settings.themeID = theme.id
        try? AppServices.shared.settingsStore.save(settings)
        NotificationCenter.default.post(name: .init("ShuntActiveThemeChanged"), object: nil)
    }
}
