import XCTest
import Darwin
@testable import ShuntCore

final class UpstreamLauncherEngineTests: XCTestCase {

    // MARK: - No-op paths

    func testEmptyLauncherIsNoOp() async throws {
        let engine = UpstreamLauncherEngine()
        try await engine.startAll(launcher: .empty, upstream: UpstreamProxy())
        let snap = await engine.snapshot()
        XCTAssertTrue(snap.isEmpty)
    }

    func testStopAllOnFreshEngineIsSafe() async {
        let engine = UpstreamLauncherEngine()
        await engine.stopAll()
        let snap = await engine.snapshot()
        XCTAssertTrue(snap.isEmpty)
    }

    // MARK: - Idempotency: already-healthy entry skips spawn

    func testAlreadyHealthyEntryMarkedAsExternal() async throws {
        let (fd, port) = try openLoopbackListener()
        defer { close(fd) }

        let entry = UpstreamLauncherEntry(
            name: "pre-existing",
            startCommand: "false", // would fail if we actually spawned
            healthProbe: .portOpen,
            probeIntervalSeconds: 1,
            startTimeoutSeconds: 5
        )
        let launcher = UpstreamLauncher(stages: [
            UpstreamLauncherStage(name: "S1", entries: [entry])
        ])
        let upstream = UpstreamProxy(host: "127.0.0.1", port: port)

        let engine = UpstreamLauncherEngine()
        try await engine.startAll(launcher: launcher, upstream: upstream)

        let snap = await engine.snapshot()
        XCTAssertEqual(snap[entry.id]?.state, .running)
        XCTAssertEqual(snap[entry.id]?.ownedByUs, false)
    }

    // MARK: - Timeout: start command never makes probe pass

    func testTimeoutFailsAndThrows() async throws {
        // Pick an unused port (open briefly then close to get a free one).
        let (fd, port) = try openLoopbackListener()
        close(fd) // port freed; nothing listens anymore

        let entry = UpstreamLauncherEntry(
            name: "will-timeout",
            startCommand: "/bin/sleep 10", // spawns, but nothing opens the probe port
            healthProbe: .portOpen,
            probeIntervalSeconds: 1,
            startTimeoutSeconds: 2
        )
        let launcher = UpstreamLauncher(stages: [
            UpstreamLauncherStage(name: "S1", entries: [entry])
        ])
        let upstream = UpstreamProxy(host: "127.0.0.1", port: port)

        let engine = UpstreamLauncherEngine()
        do {
            try await engine.startAll(launcher: launcher, upstream: upstream)
            XCTFail("Expected EntryFailure; startAll succeeded unexpectedly.")
        } catch let failure as UpstreamLauncherEngine.EntryFailure {
            XCTAssertEqual(failure.stageIndex, 0)
            XCTAssertEqual(failure.entryID, entry.id)
            XCTAssertTrue(failure.reason.contains("timeout"), "reason was: \(failure.reason)")
        }

        // After rollback, nothing should remain in runtimes.
        let snap = await engine.snapshot()
        XCTAssertTrue(snap.isEmpty)
    }

    // MARK: - Snapshot visibility after stopAll

    func testStopAllClearsRuntimes() async throws {
        let (fd, port) = try openLoopbackListener()
        defer { close(fd) }

        let entry = UpstreamLauncherEntry(
            name: "external-up",
            startCommand: "false",
            healthProbe: .portOpen,
            probeIntervalSeconds: 1,
            startTimeoutSeconds: 5
        )
        let launcher = UpstreamLauncher(stages: [
            UpstreamLauncherStage(name: "S1", entries: [entry])
        ])
        let engine = UpstreamLauncherEngine()
        try await engine.startAll(
            launcher: launcher,
            upstream: UpstreamProxy(host: "127.0.0.1", port: port)
        )
        let before = await engine.snapshot()
        XCTAssertEqual(before.count, 1)

        await engine.stopAll(launcher: launcher)
        let after = await engine.snapshot()
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: - Idempotent re-entry

    func testSecondStartAllWithSameConfigShortCircuits() async throws {
        let (fd, port) = try openLoopbackListener()
        defer { close(fd) }

        let entry = UpstreamLauncherEntry(
            name: "pre",
            startCommand: "false",
            healthProbe: .portOpen,
            probeIntervalSeconds: 1,
            startTimeoutSeconds: 5
        )
        let launcher = UpstreamLauncher(stages: [
            UpstreamLauncherStage(name: "S1", entries: [entry])
        ])
        let upstream = UpstreamProxy(host: "127.0.0.1", port: port)

        let engine = UpstreamLauncherEngine()

        // First call: probe passes, runtime marked alreadyRunning (owned=false)
        try await engine.startAll(launcher: launcher, upstream: upstream)
        let snapBefore = await engine.snapshot()
        XCTAssertEqual(snapBefore[entry.id]?.state, .running)
        XCTAssertEqual(snapBefore[entry.id]?.ownedByUs, false)

        // Second call with same config + upstream + still healthy: must short-
        // circuit without touching runtimes. If it didn't short-circuit, the
        // destructive internalStopAll would clear runtimes before running the
        // stages again, and the new probe would re-populate them — but the
        // result is the same state, so we can't distinguish via snapshot alone.
        // Instead, we verify that calling startAll 50 times in a row completes
        // quickly (short-circuit) as opposed to re-probing 50 times serially
        // (would take 50 × ~0.1s = 5+ s). A single path is <100ms.
        let start = ContinuousClock.now
        for _ in 0..<10 {
            try await engine.startAll(launcher: launcher, upstream: upstream)
        }
        let elapsed = ContinuousClock.now - start
        // 10 short-circuits each re-probe once; port-open probe is sub-100ms
        // per call, so all 10 should land under ~2 s. If we regressed and the
        // engine tore down + respawned each time, it'd be much slower.
        XCTAssertLessThan(elapsed, .seconds(3), "startAll chain took \(elapsed) — idempotent short-circuit likely regressed")

        // State is still populated correctly.
        let snapAfter = await engine.snapshot()
        XCTAssertEqual(snapAfter[entry.id]?.state, .running)
    }

    // MARK: - Cancellation: stopAll mid-startAll

    func testStopAllCancelsInFlightStartAll() async throws {
        // Pick an unused port: open briefly, close, use the port number.
        let (fd, port) = try openLoopbackListener()
        close(fd) // nothing listens now

        // Entry that will never pass the probe (port is closed, start cmd
        // just sleeps). Timeout is long so the loop stays alive for the
        // duration of the test.
        let entry = UpstreamLauncherEntry(
            name: "slow",
            startCommand: "/bin/sleep 30",
            healthProbe: .portOpen,
            probeIntervalSeconds: 1,
            startTimeoutSeconds: 30
        )
        let launcher = UpstreamLauncher(stages: [
            UpstreamLauncherStage(name: "S1", entries: [entry])
        ])
        let upstream = UpstreamProxy(host: "127.0.0.1", port: port)

        let engine = UpstreamLauncherEngine()

        // Kick off startAll and let it reach the polling loop (spawn happens
        // after the initial failed probe).
        let startTask = Task {
            try await engine.startAll(launcher: launcher, upstream: upstream)
        }

        // Give it time to spawn the sleep process and enter the poll loop.
        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 s

        // Now mid-flight call stopAll — must cancel the startAll, kill the
        // spawned /bin/sleep, and return promptly.
        let stopStart = ContinuousClock.now
        await engine.stopAll(launcher: launcher)
        let stopElapsed = ContinuousClock.now - stopStart

        // stopAll should finish within a couple seconds — it cancels the
        // in-flight task, which then unwinds through the sleep + probe and
        // reaps the spawned process. Pre-fix, stopAll returned immediately
        // but startAll kept running in the background. Now stopAll blocks
        // on the cancellation unwind.
        XCTAssertLessThan(stopElapsed, .seconds(5),
                          "stopAll took too long to cancel in-flight startAll: \(stopElapsed)")

        // The original startAll Task should now surface a failure —
        // either CancellationError (preferred, clean) or EntryFailure (if
        // the race put us past the cancellation checkpoint).
        do {
            try await startTask.value
            XCTFail("startAll should have thrown after stopAll cancelled it")
        } catch is CancellationError {
            // Preferred outcome.
        } catch is UpstreamLauncherEngine.EntryFailure {
            // Acceptable fallback if cancellation hit after runEntry wrote
            // a .failed state but before the Task.sleep throw propagated.
        }

        // Runtimes should be empty — stopAll cleans them up.
        let snap = await engine.snapshot()
        XCTAssertTrue(snap.isEmpty, "runtimes not cleared after stopAll; got \(snap)")
    }

    // MARK: - Custom probes

    func testExplicitTCPProbeIgnoresGlobalUpstream() async throws {
        let (fd, port) = try openLoopbackListener()
        defer { close(fd) }

        let result = await LauncherProbes.run(
            .tcpConnect(host: "127.0.0.1", port: port),
            upstream: UpstreamProxy(host: "127.0.0.1", port: port &+ 1)
        )

        XCTAssertTrue(result.ok, "expected explicit TCP probe to pass; got \(result.detail)")
    }

    func testCommandExitZeroProbe() async throws {
        let ok = await LauncherProbes.run(
            .commandExitZero(command: "/usr/bin/true"),
            upstream: UpstreamProxy()
        )
        XCTAssertTrue(ok.ok, "expected true command probe to pass; got \(ok.detail)")

        let fail = await LauncherProbes.run(
            .commandExitZero(command: "/usr/bin/false"),
            upstream: UpstreamProxy()
        )
        XCTAssertFalse(fail.ok, "expected false command probe to fail")
    }

    func testHealthProbeCodableRoundTripForCustomProbes() throws {
        let probes: [HealthProbe] = [
            .tcpConnect(host: "192.0.2.10", port: 22),
            .socks5HandshakeAt(host: "127.0.0.1", port: 1080),
            .commandExitZero(command: "/usr/local/bin/prlctl exec \"macOS\" /usr/bin/true"),
        ]
        let data = try JSONEncoder().encode(probes)
        let decoded = try JSONDecoder().decode([HealthProbe].self, from: data)
        XCTAssertEqual(decoded, probes)
    }

    // MARK: - Helpers

    /// Bind a TCP socket to `127.0.0.1:0` (kernel picks port) and start
    /// listening. Returns the fd and the resolved port. Caller owns `close(fd)`.
    private func openLoopbackListener() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian // 127.0.0.1

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: "test", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed: \(String(cString: strerror(errno)))"])
        }
        guard listen(fd, 128) == 0 else {
            close(fd)
            throw NSError(domain: "test", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }

        // Drain the accept queue in the background so repeated TCP connects
        // from probes don't fill the backlog and start stalling. When the
        // listener fd is closed at test teardown, accept() returns -1 and
        // this loop exits naturally.
        DispatchQueue.global(qos: .background).async {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { return }
                Darwin.close(client)
            }
        }

        var storedAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &storedAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard getResult == 0 else {
            close(fd)
            throw NSError(domain: "test", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "getsockname() failed"])
        }
        let port = UInt16(bigEndian: storedAddr.sin_port)
        return (fd, port)
    }
}
