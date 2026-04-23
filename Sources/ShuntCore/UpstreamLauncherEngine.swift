import Foundation
import Darwin

/// Serialisable slice of engine state persisted across process restarts so
/// that a fresh Shunt process can reclaim ownership of prereq processes it
/// spawned in a previous session. Without this, every rebuild/relaunch
/// demoted our own Tart instance to "pre-existing" on the next Enable.
private struct OwnershipRecord: Codable {
    /// `entryID.uuidString → pid`
    var owned: [String: Int32]
}

/// Orchestrates the upstream launcher: stages run sequentially, entries within
/// a stage run in parallel. Each entry probes health first (idempotency); if
/// already healthy, it's tagged `alreadyRunning` and never spawned. On any
/// entry failure, the engine rolls back stages it started (in reverse order),
/// killing only processes it spawned itself.
public actor UpstreamLauncherEngine {

    public enum EntryState: Equatable, Sendable {
        case idle
        case starting
        case running
        case failed(String)
        case stopping
        case stopped
    }

    public struct Event: Sendable {
        public let stageIndex: Int
        public let entryID: UUID
        public let entryName: String
        public let state: EntryState
        public let ownedByUs: Bool
        public let detail: String?
        public let timestamp: Date
    }

    public struct EntryFailure: Error, LocalizedError {
        public let stageIndex: Int
        public let entryID: UUID
        public let entryName: String
        public let reason: String
        public var errorDescription: String? {
            "Launcher entry “\(entryName)” (stage \(stageIndex + 1)) failed: \(reason)"
        }
    }

    private struct Runtime {
        var state: EntryState = .idle
        var pid: pid_t?
        var ownedByUs: Bool = false
    }

    public typealias EventHandler = @Sendable (Event) -> Void

    private var runtimes: [UUID: Runtime] = [:]
    /// The launcher config we were last asked to `startAll`. Kept so `stopAll`
    /// can iterate stages in reverse order even if the caller forgets to pass
    /// it. Cleared on successful stopAll.
    private var lastLauncher: UpstreamLauncher?
    /// Handle to an in-flight `startAll`. `stopAll` cancels this before
    /// proceeding so a Disable click mid-startAll doesn't let the launcher
    /// finish spawning a process it was about to bring up. Cleared when
    /// startAll returns (success or failure).
    private var inFlightStartTask: Task<Void, Error>?

    /// App Group container file that survives process restarts. Only
    /// entries we spawned are written here; `stopAll` clears the file.
    private static let ownershipFileName = "launcher-ownership.v1.json"

    public init() {}

    // MARK: - Cross-process ownership persistence

    private var ownershipFileURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.craraque.shunt"
        ) else { return nil }
        return container.appendingPathComponent(Self.ownershipFileName)
    }

    /// Read the last-persisted ownership record. Entries whose PIDs are no
    /// longer alive are dropped at read time so callers never reclaim a
    /// ghost process.
    private func loadPersistedOwnership() -> [UUID: pid_t] {
        guard let url = ownershipFileURL,
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(OwnershipRecord.self, from: data)
        else { return [:] }
        var live: [UUID: pid_t] = [:]
        for (key, pid) in record.owned {
            guard let uuid = UUID(uuidString: key) else { continue }
            if kill(pid, 0) == 0 {
                live[uuid] = pid
            }
        }
        return live
    }

    /// Snapshot currently-owned runtimes to disk. Called after any mutation
    /// that adds/removes an owned entry so a crash or force-quit doesn't
    /// lose ownership.
    private func persistOwnership() {
        guard let url = ownershipFileURL else { return }
        var owned: [String: Int32] = [:]
        for (id, rt) in runtimes where rt.ownedByUs {
            guard let pid = rt.pid else { continue }
            owned[id.uuidString] = pid
        }
        let record = OwnershipRecord(owned: owned)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Remove the persisted record entirely. Called when stopAll finishes
    /// tearing down everything we owned.
    private func clearPersistedOwnership() {
        guard let url = ownershipFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Public API

    /// Runs each stage sequentially. On success, all entries reach
    /// `.running`. On any failure, entries we started are rolled back and
    /// `EntryFailure` is thrown.
    ///
    /// Guarantees:
    /// - **Cancellable.** If `stopAll` is invoked while this call is still
    ///   polling, the in-flight work is cancelled; spawned processes are
    ///   reaped; no new processes are created after the cancel point.
    /// - **Idempotent.** If this is called twice in a row with the same
    ///   `launcher` and all entries are still healthy (verified with a fresh
    ///   probe), the second call returns immediately without touching
    ///   existing processes or tracked state.
    public func startAll(
        launcher: UpstreamLauncher,
        upstream: UpstreamProxy,
        onEvent: EventHandler? = nil
    ) async throws {
        // (A) Cancel any previous in-flight startAll and wait for it to unwind.
        // This must happen before the idempotency check — we don't want two
        // startAll pipelines racing probes on the same runtimes.
        if let inflight = inFlightStartTask {
            inflight.cancel()
            _ = try? await inflight.value
            inFlightStartTask = nil
        }

        // (B) Idempotency short-circuit: if the previously-started launcher is
        // identical to this one AND all its entries still probe healthy, the
        // new call is a no-op. This protects against rapid Enable double-clicks
        // or a re-Enable after a brief disable that left the prereqs running.
        if let last = lastLauncher,
           last == launcher,
           await allEntriesStillHealthy(in: launcher, upstream: upstream) {
            return
        }

        // (C) Otherwise: full reset. Stop anything we previously owned, clear
        // runtimes, then run stages fresh inside a tracked Task so stopAll
        // can cancel mid-flight.
        await internalStopAll(launcher: lastLauncher, onEvent: nil)
        runtimes.removeAll()
        lastLauncher = launcher

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.runAllStages(launcher: launcher, upstream: upstream, onEvent: onEvent)
        }
        inFlightStartTask = task
        defer { inFlightStartTask = nil }
        try await task.value
    }

    /// Body of a fresh start. Pulled out so the cancellable `Task` can call it.
    private func runAllStages(
        launcher: UpstreamLauncher,
        upstream: UpstreamProxy,
        onEvent: EventHandler?
    ) async throws {
        for (stageIdx, stage) in launcher.stages.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            do {
                try await runStage(stage, stageIndex: stageIdx, upstream: upstream, onEvent: onEvent)
            } catch {
                await internalStopAll(launcher: launcher, onEvent: onEvent)
                throw error
            }
        }
    }

    /// Runs one fresh probe per enabled entry. Used only by the idempotency
    /// short-circuit at the top of `startAll`.
    private func allEntriesStillHealthy(
        in launcher: UpstreamLauncher,
        upstream: UpstreamProxy
    ) async -> Bool {
        for entry in launcher.allEntries where entry.enabled {
            guard let rt = runtimes[entry.id] else { return false }
            guard rt.state == .running else { return false }
            let probe = await LauncherProbes.run(entry.healthProbe, upstream: upstream)
            if !probe.ok { return false }
        }
        return true
    }

    /// Stops entries we started, in reverse stage order, in parallel within
    /// each stage. Pre-existing (external) processes are left alone.
    ///
    /// If `startAll` is currently in flight (e.g. the user toggled Disable
    /// mid-enable), it is cancelled first so its probes unwind and it does
    /// not continue spawning processes after this call returns.
    public func stopAll(
        launcher: UpstreamLauncher? = nil,
        onEvent: EventHandler? = nil
    ) async {
        if let inflight = inFlightStartTask {
            inflight.cancel()
            _ = try? await inflight.value
            inFlightStartTask = nil
        }
        await internalStopAll(launcher: launcher, onEvent: onEvent)
    }

    /// Stop body without the in-flight cancellation preamble. Called from
    /// inside `startAll` (where we already own the Task) and from `stopAll`
    /// after cancellation has completed.
    private func internalStopAll(
        launcher: UpstreamLauncher? = nil,
        onEvent: EventHandler? = nil
    ) async {
        let target = launcher ?? lastLauncher
        guard let stages = target?.stages, !stages.isEmpty else {
            // No layout to order by — fire SIGTERM to anything we own.
            // `hadOwned` guards the persistence wipe: on a cold startup
            // with an empty in-memory runtimes, this branch is taken with
            // nothing to kill, and wiping the file here would prevent the
            // upcoming `runEntry` from reclaiming a prior-session PID.
            let hadOwned = runtimes.values.contains { $0.ownedByUs }
            for (id, rt) in runtimes where rt.ownedByUs {
                guard let pid = rt.pid else { continue }
                _ = gracefulTerminate(pid: pid)
                runtimes[id]?.state = .stopped
            }
            runtimes.removeAll()
            lastLauncher = nil
            if hadOwned { clearPersistedOwnership() }
            return
        }

        for (stageIdxReversed, stage) in stages.enumerated().reversed() {
            await withTaskGroup(of: Void.self) { group in
                for entry in stage.entries {
                    guard let rt = runtimes[entry.id], rt.ownedByUs, let pid = rt.pid else {
                        continue
                    }
                    let stopCommand = entry.stopCommand
                    let stageIdx = stageIdxReversed
                    group.addTask {
                        await self.emit(onEvent,
                                        stageIdx: stageIdx, entry: entry,
                                        state: .stopping, ownedByUs: true,
                                        detail: nil)
                        await self.stop(entry: entry, pid: pid, stopCommand: stopCommand)
                        await self.markStopped(entryID: entry.id)
                        await self.emit(onEvent,
                                        stageIdx: stageIdx, entry: entry,
                                        state: .stopped, ownedByUs: true,
                                        detail: nil)
                    }
                }
            }
        }

        runtimes.removeAll()
        lastLauncher = nil
        clearPersistedOwnership()
    }

    /// Current snapshot of engine state, keyed by entry ID. For UI consumption.
    public func snapshot() -> [UUID: (state: EntryState, ownedByUs: Bool)] {
        runtimes.mapValues { ($0.state, $0.ownedByUs) }
    }

    // MARK: - Stage + entry execution

    private func runStage(
        _ stage: UpstreamLauncherStage,
        stageIndex: Int,
        upstream: UpstreamProxy,
        onEvent: EventHandler?
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in stage.entries where entry.enabled {
                group.addTask {
                    try await self.runEntry(entry, stageIndex: stageIndex, upstream: upstream, onEvent: onEvent)
                }
            }
            try await group.waitForAll()
        }
    }

    private func runEntry(
        _ entry: UpstreamLauncherEntry,
        stageIndex: Int,
        upstream: UpstreamProxy,
        onEvent: EventHandler?
    ) async throws {
        // 0. Cooperate with cancellation before we do any work, and again
        //    before any state mutation that would be hard to unwind.
        if Task.isCancelled { throw CancellationError() }

        // 1. Idempotency probe: if already healthy, decide ownership by
        //    consulting the persisted record from prior sessions. A PID we
        //    previously spawned that's still alive → reclaim as ours; any
        //    other "already healthy" case → genuinely external.
        let initial = await LauncherProbes.run(entry.healthProbe, upstream: upstream)
        if Task.isCancelled { throw CancellationError() }
        if initial.ok {
            let persisted = loadPersistedOwnership()
            if let reclaimedPID = persisted[entry.id] {
                runtimes[entry.id] = Runtime(state: .running, pid: reclaimedPID, ownedByUs: true)
                persistOwnership()
                emit(onEvent, stageIdx: stageIndex, entry: entry,
                     state: .running, ownedByUs: true,
                     detail: "reclaimed pid=\(reclaimedPID) from prior session; \(initial.detail)")
                return
            }
            runtimes[entry.id] = Runtime(state: .running, pid: nil, ownedByUs: false)
            emit(onEvent, stageIdx: stageIndex, entry: entry,
                 state: .running, ownedByUs: false,
                 detail: "already healthy: \(initial.detail)")
            return
        }

        // 2. Spawn the start command via a login shell so user PATH resolves.
        //    Check cancellation one more time — the initial probe's failure
        //    isn't useful if the caller already asked us to stop.
        if Task.isCancelled { throw CancellationError() }
        let pid: pid_t
        do {
            pid = try spawnStart(entry)
        } catch {
            let reason = "spawn failed: \(error.localizedDescription)"
            runtimes[entry.id] = Runtime(state: .failed(reason), pid: nil, ownedByUs: false)
            emit(onEvent, stageIdx: stageIndex, entry: entry,
                 state: .failed(reason), ownedByUs: false, detail: nil)
            throw EntryFailure(stageIndex: stageIndex, entryID: entry.id,
                               entryName: entry.name, reason: reason)
        }

        runtimes[entry.id] = Runtime(state: .starting, pid: pid, ownedByUs: true)
        persistOwnership()
        emit(onEvent, stageIdx: stageIndex, entry: entry,
             state: .starting, ownedByUs: true, detail: "spawned pid=\(pid)")

        // 3. Poll health until ready or timeout. Cooperate with cancellation.
        let deadline = ContinuousClock.now.advanced(by: .seconds(entry.startTimeoutSeconds))
        let interval = UInt64(max(1, entry.probeIntervalSeconds)) * 1_000_000_000
        var lastDetail = initial.detail

        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(nanoseconds: interval)
            } catch {
                // Cancelled mid-sleep. Clean up and bail.
                _ = gracefulTerminate(pid: pid)
                runtimes[entry.id]?.state = .stopped
                throw error
            }
            if Task.isCancelled {
                _ = gracefulTerminate(pid: pid)
                runtimes[entry.id]?.state = .stopped
                throw CancellationError()
            }
            let result = await LauncherProbes.run(entry.healthProbe, upstream: upstream)
            lastDetail = result.detail
            if result.ok {
                runtimes[entry.id]?.state = .running
                emit(onEvent, stageIdx: stageIndex, entry: entry,
                     state: .running, ownedByUs: true, detail: result.detail)
                return
            }
        }

        // Timed out. Kill the process we spawned — we own its cleanup even on failure.
        _ = gracefulTerminate(pid: pid)
        let reason = "timeout after \(entry.startTimeoutSeconds)s; last probe: \(lastDetail)"
        runtimes[entry.id]?.state = .failed(reason)
        emit(onEvent, stageIdx: stageIndex, entry: entry,
             state: .failed(reason), ownedByUs: true, detail: nil)
        throw EntryFailure(stageIndex: stageIndex, entryID: entry.id,
                           entryName: entry.name, reason: reason)
    }

    private func spawnStart(_ entry: UpstreamLauncherEntry) throws -> pid_t {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", entry.startCommand]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        return task.processIdentifier
    }

    // MARK: - Stop

    private func stop(entry: UpstreamLauncherEntry, pid: pid_t, stopCommand: String?) async {
        if let stopCommand, !stopCommand.isEmpty {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-l", "-c", stopCommand]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch {
                // Fall back to signal if the stop command couldn't spawn.
                _ = gracefulTerminate(pid: pid)
                return
            }
            task.waitUntilExit()
            // Best-effort: if the original pid is still alive after the stop
            // command, SIGTERM + grace + SIGKILL it.
            if kill(pid, 0) == 0 {
                _ = gracefulTerminate(pid: pid)
            }
        } else {
            _ = gracefulTerminate(pid: pid)
        }
    }

    /// SIGTERM, 10s grace, SIGKILL if still alive.
    @discardableResult
    private func gracefulTerminate(pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return true } // already gone
        _ = kill(pid, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 { return true }
            usleep(200_000) // 200ms
        }
        _ = kill(pid, SIGKILL)
        return kill(pid, 0) != 0
    }

    private func markStopped(entryID: UUID) {
        runtimes[entryID]?.state = .stopped
    }

    // MARK: - Events

    private func emit(
        _ handler: EventHandler?,
        stageIdx: Int,
        entry: UpstreamLauncherEntry,
        state: EntryState,
        ownedByUs: Bool,
        detail: String?
    ) {
        guard let handler else { return }
        handler(Event(
            stageIndex: stageIdx,
            entryID: entry.id,
            entryName: entry.name,
            state: state,
            ownedByUs: ownedByUs,
            detail: detail,
            timestamp: Date()
        ))
    }
}
