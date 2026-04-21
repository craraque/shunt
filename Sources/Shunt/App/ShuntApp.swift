import SwiftUI

@main
struct ShuntApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app lives as a menu-bar utility (LSUIElement=true). We do not
        // use SwiftUI's Settings scene because it does not cooperate with
        // LSUIElement — SettingsWindowController manages the window directly.
        // An empty Settings scene is left in place only so ⌘, from any other
        // context is consumed; the AppDelegate menu delivers the real action.
        Settings { EmptyView() }
    }
}
