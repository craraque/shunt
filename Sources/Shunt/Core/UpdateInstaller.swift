import AppKit
import Foundation

/// Downloads, verifies, and installs a Shunt update from a GitHub release.
///
/// Pipeline:
///   1. Download the .dmg to a sandboxed cache dir with progress reporting.
///   2. Verify the .dmg's codesign signature + Apple notarization (`spctl`).
///   3. Mount the DMG read-only.
///   4. Verify the inner Shunt.app's Developer ID team matches `6NSZVJU6BP`.
///   5. Hand off to a small shell installer script that:
///        - waits for the running Shunt to exit,
///        - replaces /Applications/Shunt.app with the new bundle,
///        - relaunches Shunt,
///        - unmounts + cleans up.
///
/// Failure modes are surfaced via `phase` so the UI can show a clear status.
@MainActor
final class UpdateInstaller: ObservableObject {

    enum Phase: Equatable {
        case idle
        case downloading(progress: Double)   // 0.0 … 1.0
        case verifying
        case installing
        case relaunching
        case failed(String)
    }

    static let shared = UpdateInstaller()

    @Published private(set) var phase: Phase = .idle

    /// Pinned Developer ID team. Any update whose .app reports a different
    /// TeamIdentifier is rejected, even if codesign reports valid — this is
    /// our defence against a notarized-but-attacker-controlled binary.
    private let expectedTeamID = "6NSZVJU6BP"
    private let expectedBundleID = "com.craraque.shunt"

    private init() {}

    // MARK: - Public entry point

    /// Run the full pipeline. Resolves on success after launching the new
    /// app (which causes the current process to be terminated by the
    /// installer script). On failure, leaves `phase` set to `.failed(...)`.
    func install(release: UpdateChecker.Release) async {
        do {
            phase = .downloading(progress: 0)
            let dmgURL = try await downloadDMG(from: release.dmgURL,
                                               expectedSize: release.dmgSize)
            phase = .verifying
            try verifyDMG(at: dmgURL)
            let mountPoint = try await mountDMG(at: dmgURL)
            defer { Task { try? await detach(mountPoint: mountPoint) } }

            let appURL = mountPoint.appendingPathComponent("Shunt.app")
            try verifyApp(at: appURL)

            phase = .installing
            try await stageAndSwap(newAppURL: appURL)

            phase = .relaunching
            // The shell script we spawned in `stageAndSwap` will terminate
            // us; this line is reached only on dev-mode short circuit.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Download

    private func downloadDMG(from url: URL, expectedSize: Int64) async throws -> URL {
        let cacheDir = try cacheDirectory()
        let dest = cacheDir.appendingPathComponent("Shunt-update.dmg")
        try? FileManager.default.removeItem(at: dest)

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: dest.path) else {
            throw UpdateError.downloadFailed("Cannot open download file for writing")
        }
        defer { try? handle.close() }

        var written: Int64 = 0
        let total = expectedSize > 0 ? expectedSize : (response.expectedContentLength)
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 {
                    let p = Double(written) / Double(total)
                    self.phase = .downloading(progress: min(max(p, 0), 1))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            self.phase = .downloading(progress: 1.0)
        }
        return dest
    }

    private func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base
            .appendingPathComponent("com.craraque.shunt")
            .appendingPathComponent("Updates")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Verify

    private func verifyDMG(at url: URL) throws {
        // Two checks: (1) codesign must validate, and (2) spctl must accept
        // it for the "open" disposition (notarized + Gatekeeper-approved).
        let cs = try shellOut("/usr/bin/codesign",
                              args: ["--verify", "--strict", url.path])
        guard cs.exit == 0 else {
            throw UpdateError.verifyFailed("DMG codesign invalid: \(cs.stderr)")
        }
        let spc = try shellOut("/usr/sbin/spctl",
                               args: ["-a", "-t", "open", "--context", "context:primary-signature", url.path])
        guard spc.exit == 0 else {
            throw UpdateError.verifyFailed("DMG not notarized / Gatekeeper rejected: \(spc.stderr)")
        }
    }

    private func verifyApp(at url: URL) throws {
        // Codesign on the .app inside the DMG.
        let cs = try shellOut("/usr/bin/codesign",
                              args: ["--verify", "--deep", "--strict", url.path])
        guard cs.exit == 0 else {
            throw UpdateError.verifyFailed("App codesign invalid: \(cs.stderr)")
        }
        // Pin to our team identifier + bundle ID.
        let info = try shellOut("/usr/bin/codesign",
                                args: ["-dv", url.path])
        // codesign prints to stderr.
        let dump = info.stderr
        guard dump.contains("TeamIdentifier=\(expectedTeamID)") else {
            throw UpdateError.verifyFailed("Wrong team identifier — refusing to install.")
        }
        guard dump.contains("Identifier=\(expectedBundleID)") else {
            throw UpdateError.verifyFailed("Wrong bundle identifier — refusing to install.")
        }
    }

    // MARK: - Mount / detach

    private func mountDMG(at dmg: URL) async throws -> URL {
        let mountPoint = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ShuntUpdate-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let r = try shellOut("/usr/bin/hdiutil",
                             args: ["attach",
                                    "-readonly",
                                    "-nobrowse",
                                    "-mountpoint", mountPoint.path,
                                    dmg.path])
        guard r.exit == 0 else {
            throw UpdateError.installFailed("hdiutil attach failed: \(r.stderr)")
        }
        return mountPoint
    }

    private func detach(mountPoint: URL) async throws {
        _ = try? shellOut("/usr/bin/hdiutil",
                          args: ["detach", "-force", mountPoint.path])
        try? FileManager.default.removeItem(at: mountPoint)
    }

    // MARK: - Stage + relaunch

    private func stageAndSwap(newAppURL: URL) async throws {
        // Copy the new .app into a staging dir we own, so the installer
        // script can do the swap without depending on the DMG mount.
        let stage = try cacheDirectory().appendingPathComponent("staging")
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let stagedApp = stage.appendingPathComponent("Shunt.app")
        try FileManager.default.copyItem(at: newAppURL, to: stagedApp)

        // Remove any quarantine xattr the OS may have added during download
        // — the bundle is freshly verified, we don't want a spurious
        // first-launch prompt after relaunch.
        _ = try? shellOut("/usr/bin/xattr",
                          args: ["-cr", stagedApp.path])

        // Write the install script and exec it detached. It waits for the
        // current Shunt process to die (via `wait $PARENT_PID` style) and
        // then replaces /Applications/Shunt.app + relaunches.
        let script = """
        #!/bin/bash
        set -e
        STAGED='\(stagedApp.path)'
        TARGET='/Applications/Shunt.app'
        PARENT_PID='\(ProcessInfo.processInfo.processIdentifier)'

        # Wait for Shunt to exit. We intentionally don't kill it ourselves —
        # the foreground app calls NSApp.terminate() right after spawning us.
        for i in $(seq 1 30); do
            if ! kill -0 "$PARENT_PID" 2>/dev/null; then break; fi
            sleep 0.5
        done
        # Belt-and-suspenders: if it's still alive after 15 s, force quit.
        kill -0 "$PARENT_PID" 2>/dev/null && kill -TERM "$PARENT_PID" 2>/dev/null || true
        sleep 1

        rm -rf "$TARGET"
        cp -R "$STAGED" "$TARGET"
        xattr -cr "$TARGET" || true

        # Relaunch the new app. `open` returns immediately; the new Shunt
        # boots and starts polling its own status.
        open "$TARGET"
        """

        let scriptURL = stage.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: scriptURL.path)

        // Detach the script from our process group so it survives our
        // termination. Use `nohup` + & so the script stays alive past
        // NSApp.terminate.
        let detachedTask = Process()
        detachedTask.executableURL = URL(fileURLWithPath: "/bin/bash")
        detachedTask.arguments = ["-c",
                                  "nohup '\(scriptURL.path)' >/tmp/shunt-update.log 2>&1 &"]
        try detachedTask.run()
        // We don't wait — give the OS a moment, then quit ourselves so the
        // installer's `kill -0` loop sees us go away.
        try await Task.sleep(nanoseconds: 600_000_000)
        NSApp.terminate(nil)
    }

    // MARK: - Shell helper

    private struct ShellResult { let exit: Int32; let stdout: String; let stderr: String }

    private func shellOut(_ path: String, args: [String]) throws -> ShellResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        return ShellResult(
            exit: task.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

enum UpdateError: LocalizedError {
    case downloadFailed(String)
    case verifyFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let s): return "Download failed: \(s)"
        case .verifyFailed(let s): return "Update rejected: \(s)"
        case .installFailed(let s): return "Install failed: \(s)"
        }
    }
}
