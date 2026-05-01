import AppKit
import SwiftUI

/// Owns the single Settings window. SwiftUI's `Settings` scene integrates
/// poorly with `LSUIElement=true` apps (the window silently fails to come
/// forward), so we host the SwiftUI hierarchy inside a plain NSWindow.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private convenience init() {
        let content = NSHostingController(rootView: SettingsView())
        // Transparent NSHostingController background so the SwiftUI
        // LiquidWindowMaterial layer is what the user sees, not the
        // controller's default opaque chrome.
        content.view.wantsLayer = true
        content.view.layer?.backgroundColor = NSColor.clear.cgColor

        let window = NSWindow(contentViewController: content)
        window.title = "Shunt Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 920, height: 620))
        window.contentMinSize = NSSize(width: 920, height: 620)
        window.isReleasedWhenClosed = false

        // Liquid glass: window itself transparent so the embedded
        // NSVisualEffectView is what renders the material. Title bar floats
        // over content (full-size content view) and shows no chrome — we
        // get the traffic lights, the title is rendered by the system.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear

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
