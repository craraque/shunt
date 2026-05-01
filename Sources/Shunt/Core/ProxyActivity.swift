import Foundation
import SwiftUI
import ShuntCore

/// Shared "Shunt is doing something" signal plus live per-entry state for
/// the upstream launcher. Observers (menu-bar icon, General tab toggle,
/// Upstream-tab entry rows) drive the "working…" indicators + `N/M ready`
/// counters off this object.
///
/// Kept as a tiny @MainActor singleton (same pattern as `ActiveTheme`) so
/// it can be written from `ProxyManager`'s async tasks and read from
/// SwiftUI views + `AppDelegate`.
@MainActor
final class ProxyActivity: ObservableObject {
    static let shared = ProxyActivity()

    /// Broadly: "Shunt is starting or stopping something right now."
    @Published private(set) var busy: Bool = false

    /// Live per-entry state keyed by entry UUID. Populated while a launcher
    /// run is in flight and retained while entries remain in `.running` so
    /// the Upstream tab can show the count. Cleared on `end()`.
    @Published private(set) var entries: [UUID: EntryProgress] = [:]

    struct EntryProgress {
        var stageIndex: Int
        var entryName: String
        var state: UpstreamLauncherEngine.EntryState
        var ownedByUs: Bool
        var detail: String?
        var lastUpdated: Date
    }

    private init() {}

    // MARK: - Busy lifecycle

    func begin() {
        guard !busy else { return }
        busy = true
        notify()
    }

    func end() {
        guard busy else { return }
        busy = false
        notify()
    }

    // MARK: - Entry progress

    /// Consume one `UpstreamLauncherEngine.Event` and update the in-memory
    /// snapshot. Safe to call from any context — hops to the main actor.
    func record(_ event: UpstreamLauncherEngine.Event) {
        entries[event.entryID] = EntryProgress(
            stageIndex: event.stageIndex,
            entryName: event.entryName,
            state: event.state,
            ownedByUs: event.ownedByUs,
            detail: event.detail,
            lastUpdated: event.timestamp
        )
        notify()
    }

    /// Number of entries currently in `.running`. Drives the "N/M ready"
    /// counter in the UI.
    var runningCount: Int {
        entries.values.filter {
            if case .running = $0.state { return true }
            return false
        }.count
    }

    /// Seed the entries table with the configured launcher so the Upstream
    /// tab can render `0/M` before any engine event fires. Called at the
    /// top of `enable()`.
    func seed(from launcher: UpstreamLauncher) {
        var next: [UUID: EntryProgress] = [:]
        for (stageIdx, stage) in launcher.stages.enumerated() {
            for entry in stage.entries where entry.enabled {
                next[entry.id] = EntryProgress(
                    stageIndex: stageIdx,
                    entryName: entry.name,
                    state: .idle,
                    ownedByUs: false,
                    detail: nil,
                    lastUpdated: Date()
                )
            }
        }
        entries = next
        notify()
    }

    /// Clear progress. Called on disable completion or tunnel teardown.
    func reset() {
        entries.removeAll()
        notify()
    }

    /// Optimistic UI flip: mark an entry as `ownedByUs=true` immediately
    /// after the user pressed "Reclaim", so the inline state pill stops
    /// showing the "external" link badge. The engine has its own copy of
    /// ownership; this just keeps the UI from lagging behind.
    func markReclaimed(entryID: UUID) {
        guard var progress = entries[entryID] else { return }
        progress.ownedByUs = true
        entries[entryID] = progress
        notify()
    }

    /// Posted on each state transition. AppDelegate subscribes here because
    /// it observes from AppKit code that can't easily participate in
    /// SwiftUI's @Published plumbing.
    static let changedNotification = Notification.Name("ShuntProxyActivityChanged")

    private func notify() {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }
}
