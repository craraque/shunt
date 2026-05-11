import AppKit
import SwiftUI
import ShuntCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusTimer: Timer?

    // Liquid-glass popover that hangs from the menubar glyph. Implemented as
    // a borderless NSPanel (rather than NSPopover) so we can present a fully
    // translucent surface with rounded corners — NSPopover's chrome is fixed.
    private var panel: NSPanel!
    private var panelOutsideClickMonitor: Any?
    private let popoverModel = MenubarPopoverModel()

    // Most recently observed state, used to decide how to render the menubar.
    private var proxyStatusRaw: Int = 0  // NEVPNStatus rawValue
    private var extensionActivated: Bool = false

    private var extensionManager: SystemExtensionManager { AppServices.shared.extensionManager }
    private var proxyManager: ProxyManager { AppServices.shared.proxyManager }
    private var settingsStore: SettingsStore { AppServices.shared.settingsStore }

    private var themeObserver: NSObjectProtocol?

    /// Entries we've already shown the "Manage existing instance?" alert for
    /// in this app session — keeps us from re-prompting after a probe glitch
    /// or a quick toggle off/on. Cleared on app relaunch.
    private var promptedExternalEntries = Set<UUID>()
    /// Serializes prompts so two simultaneous external detections don't stack
    /// modal alerts on top of each other. Latest wins; the user sees one
    /// dialog at a time.
    private var promptInFlight = false
    /// Phase 6c — set when the user clicked the toggle off mid-enable and
    /// chose "Wait, then disable". Honoured the next time `refreshStatus`
    /// observes `statusRaw == .connected`.
    private var pendingDisableAfterEnable: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments

        if args.contains("--seed-test-settings") {
            let seed = ShuntSettings(
                managedApps: [
                    ManagedApp(bundleID: "com.craraque.shunt.test", displayName: "ShuntTest", enabled: true),
                    ManagedApp(bundleID: "com.apple.Safari", displayName: "Safari", enabled: true),
                    ManagedApp(bundleID: "com.apple.Terminal", displayName: "Terminal", enabled: false)
                ],
                upstream: UpstreamProxy(host: "127.0.0.1", port: 1080, bindInterface: nil)
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

        // Start the shared FlowMonitor so the menubar popover and the Monitor
        // tab can both read live CLAIM events.
        AppServices.shared.flowMonitor.start()

        // Re-render the menu-bar icon when the user switches themes OR
        // when macOS switches effective appearance (light ↔ dark). The
        // routing icon is non-template, so the system won't retint its
        // rails automatically — we must re-paint explicitly.
        themeObserver = NotificationCenter.default.addObserver(
            forName: .init("ShuntActiveThemeChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.renderStatusIcon()
            BundleIconUpdater.applyForCurrentTheme()
        }
        // Initial paint of the bundle icon. Done after the status item is
        // up so first-launch ordering is: window/popover ready → bundle icon
        // updated. macOS will reflect the new icon in Finder / Login Items
        // / system dialogs from this point on.
        BundleIconUpdater.applyForCurrentTheme()
        NotificationCenter.default.addObserver(
            forName: ProxyActivity.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.renderStatusIcon()
            self?.maybePromptForExternalReclaim()
        }
        NSApp.addObserver(
            self,
            forKeyPath: "effectiveAppearance",
            options: [.new],
            context: nil
        )
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

        // Build the popover content (SwiftUI hosted).
        let content = MenubarPopoverView(
            model: popoverModel,
            onMasterToggle: { [weak self] enable in
                self?.handleMasterToggle(enable)
            },
            onOpenSettings: { [weak self] in
                self?.hidePanel()
                SettingsNavigation.shared.request(.general)
                self?.showSettings()
            },
            onReloadTunnel: { [weak self] in
                guard let self else { return }
                // Don't hide the panel — the inline ↻ spinner is the user's
                // feedback that the request landed. Hide-on-click would
                // also kill the spinner before it ever appeared.
                self.popoverModel.isReloadingTunnel = true
                self.proxyManager.reloadTunnel { [weak self] _ in
                    Task { @MainActor in
                        self?.popoverModel.isReloadingTunnel = false
                    }
                }
            },
            onShowMonitor: { [weak self] in
                self?.hidePanel()
                SettingsNavigation.shared.request(.monitor)
                self?.showSettings()
            },
            onShowRules: { [weak self] in
                self?.hidePanel()
                SettingsNavigation.shared.request(.rules)
                self?.showSettings()
            },
            onAbout: { [weak self] in
                self?.hidePanel()
                SettingsNavigation.shared.request(.about)
                self?.showSettings()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        // Borderless NSPanel — clear background so the SwiftUI view paints
        // its own liquid glass material. Rounded corners on the contentView.
        let panelRect = NSRect(x: 0, y: 0, width: 360, height: 420)
        panel = NSPanel(
            contentRect: panelRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: content)
        host.frame = panelRect
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.masksToBounds = true
        panel.contentView = host

        // Click on the menubar button toggles the panel.
        if let button = statusItem.button {
            button.action = #selector(togglePanel(_:))
            button.target = self
        }

        renderStatusIcon()
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        // Resize panel to its content's natural size (the SwiftUI view fits
        // its content; we match the panel frame).
        if let host = panel.contentView as? NSHostingView<MenubarPopoverView> {
            host.layoutSubtreeIfNeeded()
            let intrinsic = host.fittingSize
            if intrinsic.width > 0 && intrinsic.height > 0 {
                let newSize = NSSize(width: max(360, intrinsic.width),
                                     height: max(220, intrinsic.height))
                panel.setContentSize(newSize)
                host.frame = NSRect(origin: .zero, size: newSize)
            }
        }

        // Anchor the panel under the menubar button, slightly indented from
        // the right edge of the button so the visual "lives below the icon".
        let buttonScreenFrame = buttonWindow.convertToScreen(button.frame)
        let panelW = panel.frame.width
        let x = buttonScreenFrame.midX - panelW / 2
        // 6 pt gap between menubar and panel top
        let y = buttonScreenFrame.minY - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        // Close on outside click — global monitor catches clicks anywhere
        // outside our windows; local monitor catches clicks inside our own
        // process (e.g. user clicks the menubar button again — we ignore
        // that because togglePanel handles it).
        if panelOutsideClickMonitor == nil {
            panelOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.hidePanel()
            }
        }
    }

    private func hidePanel() {
        if panel?.isVisible == true {
            panel.orderOut(nil)
        }
        if let mon = panelOutsideClickMonitor {
            NSEvent.removeMonitor(mon)
            panelOutsideClickMonitor = nil
        }
    }

    private func handleMasterToggle(_ enable: Bool) {
        // Phase 6c — if a transition is already in flight, the user clicked
        // the toggle a second time. Don't silently issue a competing command;
        // ask what they meant.
        let isBusy = ProxyActivity.shared.busy
            || (proxyStatusRaw == 2 || proxyStatusRaw == 4 || proxyStatusRaw == 5)
        if isBusy {
            presentMidFlightToggleAlert(requestedEnable: enable)
            return
        }

        if enable {
            proxyManager.enable()
        } else {
            Task { await proxyManager.disable() }
        }
    }

    /// Phase 6c — surfaces an alert with three options when the user clicks
    /// the master toggle while Shunt is already in a transitional state.
    /// `requestedEnable` is the *new* desired state (true = they tried to
    /// turn it on, false = off). The alert text adapts to the direction of
    /// the request and the current operation in flight.
    private func presentMidFlightToggleAlert(requestedEnable: Bool) {
        // Don't stack alerts.
        guard !promptInFlight else { return }
        promptInFlight = true

        let alert = NSAlert()
        let liveDesc = popoverModel.workingDescription ?? "Shunt is in a transitional state"
        let goingUp = (proxyStatusRaw == 2)
            || ProxyActivity.shared.entries.values.contains {
                if case .starting = $0.state { return true }
                return false
            }

        if goingUp && !requestedEnable {
            alert.messageText = "Shunt is bringing the tunnel up"
            alert.informativeText = """
            \(liveDesc)

            Disabling now will cancel the in-flight enable, kill any launcher entries Shunt started, and run their stop commands. Already-running externals (those marked “alwaysReclaim”) will also be stopped.

            What would you like to do?
            """
            alert.addButton(withTitle: "Cancel and tear down")     // .alertFirstButtonReturn
            alert.addButton(withTitle: "Wait, then disable")        // .alertSecondButtonReturn
            alert.addButton(withTitle: "Keep enabling")             // .alertThirdButtonReturn
            alert.alertStyle = .warning
        } else if !goingUp && requestedEnable {
            alert.messageText = "Shunt is shutting the tunnel down"
            alert.informativeText = """
            \(liveDesc)

            Re-enabling now will wait for the disable to complete and then start fresh. Or you can let it finish and act later.
            """
            alert.addButton(withTitle: "Cancel disable, re-enable")
            alert.addButton(withTitle: "Wait, then re-enable")
            alert.addButton(withTitle: "Keep disabling")
            alert.alertStyle = .informational
        } else {
            // Same-direction click during the same transition (e.g. user
            // hammered the toggle on twice). Just dismiss.
            promptInFlight = false
            return
        }

        let response = alert.runModal()
        promptInFlight = false

        if goingUp && !requestedEnable {
            switch response {
            case .alertFirstButtonReturn:
                Log.info("toggle mid-flight: cancel and tear down")
                pendingDisableAfterEnable = false
                popoverModel.disableQueued = false
                Task { await self.proxyManager.disable() }
            case .alertSecondButtonReturn:
                Log.info("toggle mid-flight: queue disable for after enable")
                pendingDisableAfterEnable = true
                popoverModel.disableQueued = true
            default:
                Log.info("toggle mid-flight: keep enabling")
            }
        } else if !goingUp && requestedEnable {
            switch response {
            case .alertFirstButtonReturn:
                Log.info("toggle mid-flight: cancel disable + re-enable")
                // No clean "abort disable" today; let it finish and re-enable
                // immediately after via a one-shot polling task.
                queueReEnableAfterDisable()
            case .alertSecondButtonReturn:
                Log.info("toggle mid-flight: queue re-enable for after disable")
                queueReEnableAfterDisable()
            default:
                Log.info("toggle mid-flight: keep disabling")
            }
        }
    }

    /// Polls `proxyStatusRaw` for up to 60 s waiting for `disconnected`,
    /// then fires `enable()`. Used by 6c when the user changed their mind
    /// mid-disable.
    private func queueReEnableAfterDisable() {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if self.proxyStatusRaw == 1 { // disconnected
                    Log.info("queued re-enable: tunnel down — enabling now")
                    self.proxyManager.enable()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            Log.info("queued re-enable: timed out waiting for disconnect")
        }
    }

    private func renderStatusIcon() {
        guard let button = statusItem.button else { return }
        let theme = ActiveTheme.shared.current
        if proxyIsRouting {
            stopPulse()
            button.image = MenubarIcons.routing(theme: theme)
        } else if proxyIsWorking {
            startPulseIfNeeded()
            button.image = MenubarIcons.pending(theme: theme, ledAlpha: currentPulseAlpha())
        } else {
            stopPulse()
            button.image = MenubarIcons.idle()
        }
    }

    // MARK: - Pending-state pulse

    /// Timer that drives the LED fade while Shunt is in the "working" state.
    /// Ticks every 80 ms; each tick advances a phase and re-renders the
    /// menubar icon with a new alpha computed from a sine wave.
    private var pulseTimer: Timer?
    private var pulsePhase: CGFloat = 0

    private func startPulseIfNeeded() {
        guard pulseTimer == nil else { return }
        pulsePhase = 0
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickPulse()
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulsePhase = 0
    }

    private func tickPulse() {
        // ~1.4 s per full cycle: 2π / (0.08 s × tickScale) — tickScale = 0.36
        pulsePhase += 0.36
        renderStatusIcon()
    }

    /// Map sine wave [-1, 1] → [0.35, 1.0] for a visibly pulsing LED that
    /// never fully disappears (user can still locate the icon).
    private func currentPulseAlpha() -> CGFloat {
        let s = sin(pulsePhase)
        return 0.675 + s * 0.325
    }

    private var proxyIsRouting: Bool {
        // NEVPNStatus: 0=invalid, 1=disconnected, 2=connecting, 3=connected, 4=reasserting, 5=disconnecting
        proxyStatusRaw == 3
    }

    /// True while Shunt is in a transient state the user should see as
    /// "working": launcher prereqs starting/stopping, or the NE tunnel
    /// connecting / reasserting / disconnecting.
    private var proxyIsWorking: Bool {
        ProxyActivity.shared.busy
            || proxyStatusRaw == 2   // connecting
            || proxyStatusRaw == 4   // reasserting
            || proxyStatusRaw == 5   // disconnecting
    }

    private func refreshStatus() {
        Task { @MainActor in
            let raw = await proxyManager.statusRaw()
            self.proxyStatusRaw = raw
            self.extensionActivated = raw != 0

            // Mirror state into the popover model so the SwiftUI content
            // updates while the popover is open (or has cached state ready
            // for the next open).
            let s = settingsStore.load()
            popoverModel.statusRaw = raw
            popoverModel.upstreamHost = s.upstream.host
            popoverModel.upstreamPort = s.upstream.port
            popoverModel.upstreamBindInterface = s.upstream.bindInterface
            popoverModel.theme = ActiveTheme.shared.current

            // Pull live flow data from the shared FlowMonitor.
            let monitor = AppServices.shared.flowMonitor
            let now = Date()
            let active = monitor.connections.values.filter { $0.isActive(at: now) }.count
            popoverModel.connectionCount = active
            popoverModel.routedCount = monitor.routedCount
            popoverModel.directCount = monitor.directCount
            if let last = monitor.connectionsSorted.first {
                popoverModel.lastClaimBundle = last.bundleID
                popoverModel.lastClaimTarget = "\(last.host):\(last.port)"
            } else {
                popoverModel.lastClaimBundle = nil
                popoverModel.lastClaimTarget = nil
            }

            // Phase 6a/b — mirror the live work state into the popover model.
            let activity = ProxyActivity.shared
            let isLauncherBusy = activity.busy
            let isTunnelTransitioning = (raw == 2 || raw == 4 || raw == 5)
            popoverModel.isWorking = isLauncherBusy || isTunnelTransitioning
                || popoverModel.isReloadingTunnel
            popoverModel.workingDescription = describeWorkInFlight(
                statusRaw: raw,
                activity: activity
            )

            // 6c — if we have a deferred disable queued and the tunnel just
            // reached `connected`, fire it now. Run on next runloop so the
            // current refresh completes first.
            if pendingDisableAfterEnable, raw == 3 {
                pendingDisableAfterEnable = false
                popoverModel.disableQueued = false
                Log.info("queued disable: tunnel up — disabling now")
                Task { @MainActor in
                    await self.proxyManager.disable()
                }
            }

            renderStatusIcon()
        }
    }

    /// Phase 6b — produces the user-visible "what is Shunt doing right now?"
    /// string. Priority: launcher entries > NE tunnel transitions > nil.
    private func describeWorkInFlight(
        statusRaw: Int,
        activity: ProxyActivity
    ) -> String? {
        // 1) Look at the most-recently-updated entry not yet running.
        let entries = activity.entries.values.sorted { $0.lastUpdated > $1.lastUpdated }
        for entry in entries {
            switch entry.state {
            case .starting:
                return "Starting \(entry.entryName)…"
            case .stopping:
                return "Stopping \(entry.entryName)…"
            case .failed(let reason):
                return "\(entry.entryName) failed: \(reason)"
            case .running, .stopped, .idle:
                continue
            }
        }
        // 2) Fall back to the NE tunnel state.
        switch statusRaw {
        case 2: return "Connecting tunnel…"
        case 4: return "Reconnecting tunnel…"
        case 5: return "Disconnecting tunnel…"
        default: return nil
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

    // MARK: - Ask-prompt for already-running externals

    /// Walk current launcher entries and, for any that are running, externally
    /// owned, and configured with `externalPolicy == .ask`, surface an NSAlert
    /// asking the user whether Shunt should manage the instance. Persists the
    /// answer to settings (alwaysReclaim / neverReclaim) and reclaims live
    /// ownership in the engine when the user says yes.
    private func maybePromptForExternalReclaim() {
        guard !promptInFlight else { return }
        let activity = ProxyActivity.shared
        let settings = settingsStore.load()

        // Build a stage-index map so we can show the user where this entry
        // lives in their launcher config.
        var entriesByID: [UUID: (stageID: UUID, entry: UpstreamLauncherEntry)] = [:]
        for stage in settings.launcher.stages {
            for entry in stage.entries {
                entriesByID[entry.id] = (stage.id, entry)
            }
        }

        for (entryID, progress) in activity.entries {
            guard case .running = progress.state else { continue }
            guard !progress.ownedByUs else { continue }
            guard !promptedExternalEntries.contains(entryID) else { continue }
            guard let (stageID, entry) = entriesByID[entryID] else { continue }
            guard entry.externalPolicy == .ask else { continue }
            // Only worth prompting if the user has authored a stop command —
            // otherwise reclaim does nothing useful.
            guard !(entry.stopCommand?.isEmpty ?? true) else {
                promptedExternalEntries.insert(entryID)
                continue
            }
            promptedExternalEntries.insert(entryID)
            promptInFlight = true
            presentReclaimAlert(stageID: stageID, entry: entry)
            // Only present one prompt per pass; the next ProxyActivity tick
            // will pick up the next entry that needs attention.
            return
        }
    }

    private func presentReclaimAlert(stageID: UUID, entry: UpstreamLauncherEntry) {
        let alert = NSAlert()
        alert.messageText = "“\(entry.name)” is already running"
        alert.informativeText = """
        Shunt found this launcher entry already up before it started the tunnel.

        Should Shunt manage its lifecycle now (running the stop command on Disable, suspending or stopping the underlying daemon)?

        You can change this anytime in Settings → Upstream → Launcher → entry → When already running.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Yes, manage it")
        alert.addButton(withTitle: "No, leave it alone")

        let response = alert.runModal()
        promptInFlight = false

        let chosen: LauncherExternalPolicy
        switch response {
        case .alertFirstButtonReturn:
            chosen = .alwaysReclaim
        default:
            chosen = .neverReclaim
        }

        // Persist the answer so we never ask again for this entry.
        var settings = settingsStore.load()
        if let sIdx = settings.launcher.stages.firstIndex(where: { $0.id == stageID }),
           let eIdx = settings.launcher.stages[sIdx].entries.firstIndex(where: { $0.id == entry.id }) {
            settings.launcher.stages[sIdx].entries[eIdx].externalPolicy = chosen
            try? settingsStore.save(settings)
        }

        // If they chose to manage, reclaim live ownership so the next Disable
        // actually runs the stop command.
        if chosen == .alwaysReclaim {
            ProxyActivity.shared.markReclaimed(entryID: entry.id)
            Task {
                await AppServices.shared.launcherEngine.reclaim(entryID: entry.id)
            }
        }
    }

    /// Kept as public (non-@objc) so the General tab's "Manage" buttons can
    /// still drive extension lifecycle. Removed from the menubar (too big a
    /// footgun for a menu click); promoted to GUI-only.
    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    // Re-render the menubar icon when macOS switches light/dark appearance.
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey : Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "effectiveAppearance" {
            Task { @MainActor in
                self.renderStatusIcon()
            }
        }
    }
}
