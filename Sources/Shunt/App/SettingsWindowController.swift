import AppKit
import SwiftUI

/// Owns the single Settings window. SwiftUI's `Settings` scene integrates
/// poorly with `LSUIElement=true` apps (the window silently fails to come
/// forward), so we host the SwiftUI hierarchy inside a plain NSWindow.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private convenience init() {
        let content = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: content)
        window.title = "Shunt Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 520))
        window.contentMinSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        window.delegate = self
    }

    func show() {
        // LSUIElement=true starts us in .accessory activation policy which
        // prevents windows from becoming key. Bump to .regular while the
        // window is visible; windowWillClose flips us back.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
