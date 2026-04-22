import AppKit
import SwiftUI
import ShuntCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusTimer: Timer?

    private var extensionStatusItem: NSMenuItem!
    private var proxyStatusItem: NSMenuItem!
    private var enableItem: NSMenuItem!
    private var disableItem: NSMenuItem!

    // Most recently observed state, used to decide how to render the menubar.
    private var proxyStatusRaw: Int = 0  // NEVPNStatus rawValue
    private var extensionActivated: Bool = false

    private var extensionManager: SystemExtensionManager { AppServices.shared.extensionManager }
    private var proxyManager: ProxyManager { AppServices.shared.proxyManager }
    private var settingsStore: SettingsStore { AppServices.shared.settingsStore }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments

        if args.contains("--seed-test-settings") {
            let seed = ShuntSettings(
                managedApps: [
                    ManagedApp(bundleID: "com.craraque.shunt.test", displayName: "ShuntTest", enabled: true),
                    ManagedApp(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams", enabled: true),
                    ManagedApp(bundleID: "com.microsoft.Outlook", displayName: "Microsoft Outlook", enabled: true)
                ],
                upstream: UpstreamProxy(host: "10.211.55.5", port: 1080, bindInterface: "bridge100")
            )
            do {
                try settingsStore.save(seed)
                Log.info("seeded test settings (\(seed.managedApps.count) apps) — exiting")
            } catch {
                Log.error("seed save failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        if args.contains("--remove-config") {
            Log.info("--remove-config flag present")
            proxyManager.removeConfig {
                if args.contains("--deactivate") {
                    self.runDeactivateAndExit()
                } else {
                    Log.info("remove-config done — exiting")
                    NSApp.terminate(nil)
                }
            }
            return
        }

        if args.contains("--deactivate") {
            Log.info("--deactivate flag present")
            runDeactivateAndExit()
            return
        }

        setupStatusItem()
        Log.info("Shunt launched")
        refreshStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }

        if args.contains("--auto-enable") {
            extensionManager.onActivationSuccess = { [weak self] in
                Log.info("Activation success callback — enabling proxy")
                self?.enableProxy()
            }
        }
        if args.contains("--auto-activate") {
            Log.info("--auto-activate flag present, submitting activation request")
            extensionManager.activate()
        }
    }

    // MARK: - Menubar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()

        extensionStatusItem = NSMenuItem(title: "Extension: …", action: nil, keyEquivalent: "")
        extensionStatusItem.isEnabled = false
        menu.addItem(extensionStatusItem)

        proxyStatusItem = NSMenuItem(title: "Proxy: …", action: nil, keyEquivalent: "")
        proxyStatusItem.isEnabled = false
        menu.addItem(proxyStatusItem)

        menu.addItem(.separator())

        menu.addItem(makeItem("Activate Extension", action: #selector(activateExtension)))
        menu.addItem(makeItem("Deactivate Extension", action: #selector(deactivateExtension)))
        menu.addItem(.separator())

        enableItem = makeItem("Enable Proxy", action: #selector(enableProxyMenu))
        disableItem = makeItem("Disable Proxy", action: #selector(disableProxyMenu))
        menu.addItem(enableItem)
        menu.addItem(disableItem)
        menu.addItem(.separator())

        menu.addItem(makeItem("Settings…", action: #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Shunt", action: #selector(NSApplication.terminate(_:)), key: "q"))

        statusItem.menu = menu
        renderStatusIcon()
    }

    private func renderStatusIcon() {
        guard let button = statusItem.button else { return }
        button.image = proxyIsRouting ? MenubarIcons.routing() : MenubarIcons.idle()
    }

    private var proxyIsRouting: Bool {
        // NEVPNStatus: 0=invalid, 1=disconnected, 2=connecting, 3=connected, 4=reasserting, 5=disconnecting
        proxyStatusRaw == 3
    }

    private func refreshStatus() {
        Task { @MainActor in
            let raw = await proxyManager.statusRaw()
            self.proxyStatusRaw = raw
            self.extensionActivated = raw != 0

            extensionStatusItem.title = "Extension: \(self.extensionActivated ? "activated" : "not installed")"
            proxyStatusItem.title = "Proxy: \(Self.describe(statusRaw: raw))"
            enableItem.isEnabled = raw != 3 && raw != 2
            disableItem.isEnabled = raw == 3 || raw == 2 || raw == 4

            renderStatusIcon()
        }
    }

    private static func describe(statusRaw: Int) -> String {
        switch statusRaw {
        case 0: return "not configured"
        case 1: return "disconnected"
        case 2: return "connecting"
        case 3: return "routing"
        case 4: return "reconnecting"
        case 5: return "disconnecting"
        default: return "unknown (\(statusRaw))"
        }
    }

    private func runDeactivateAndExit() {
        extensionManager.onRequestFinished = { _ in
            Log.info("deactivate done — exiting")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        extensionManager.onRequestFailed = { _ in
            Log.info("deactivate failed — exiting")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        extensionManager.deactivate()
    }

    private func enableProxy() {
        proxyManager.enable()
    }

    @objc private func enableProxyMenu() { enableProxy() }
    @objc private func disableProxyMenu() { Task { await proxyManager.disable() } }

    private func makeItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func activateExtension() {
        extensionManager.activate()
    }

    @objc private func deactivateExtension() {
        extensionManager.deactivate()
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }
}
