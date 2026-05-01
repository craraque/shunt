import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShuntCore

struct AdvancedTab: View {
    @ObservedObject var model: SettingsViewModel
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @Environment(\.shuntTheme) private var theme

    private let store = AppServices.shared.settingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Advanced")
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.65)
                        .foregroundStyle(.white)
                    Text("Export, import, and inspect the live settings store.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.62))
                }

                LiquidSectionLabel(text: "Backup", theme: theme)
                LiquidCard(theme: theme) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Button {
                                exportSettings()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "tray.and.arrow.up")
                                    Text("Export Settings…")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accentDark)

                            Button {
                                importSettings()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "tray.and.arrow.down")
                                    Text("Import Settings…")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("Export saves your rules, upstream proxy config, and launcher entries as a JSON file. Import replaces current settings with the contents of the file.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let msg = statusMessage {
                    HStack(spacing: 8) {
                        Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(statusIsError ? .orange : theme.signal)
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(statusIsError
                                  ? Color.orange.opacity(0.10)
                                  : theme.signal.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(statusIsError
                                          ? Color.orange.opacity(0.28)
                                          : theme.signal.opacity(0.30),
                                          lineWidth: 0.5)
                    )
                }

                LiquidSectionLabel(text: "Troubleshooting", theme: theme)
                LiquidCard(theme: theme) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Button {
                                revealSettingsFile()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "magnifyingglass")
                                    Text("Reveal Settings File")
                                }
                            }
                            .buttonStyle(.bordered)

                            Button {
                                exportDiagnosticBundle()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "shippingbox")
                                    Text("Export Diagnostic Bundle")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("The settings file lives in the App Group container. The diagnostic bundle ZIPs settings + recent provider logs for filing issues.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                LiquidSectionLabel(text: "Reset", theme: theme)
                LiquidCard(theme: theme) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restore defaults")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                            Text("Resets rules, upstream, and launcher entries. Theme is preserved.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineSpacing(2)
                        }
                        Spacer()
                        Button {
                            confirmRestoreDefaults()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Reset")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HHmm"
            return f.string(from: Date())
        }()
        panel.nameFieldStringValue = "Shunt Settings \(stamp).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.exportJSON(model.settings)
            try data.write(to: url)
            statusMessage = "Exported to \(url.lastPathComponent)"
            statusIsError = false
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported = try store.importJSON(data)
            model.settings = imported
            model.save()
            statusMessage = "Imported \(imported.managedApps.count) app(s)"
            statusIsError = false
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    private func revealSettingsFile() {
        if let url = try? store.fileURL() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func exportDiagnosticBundle() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HHmm"
            return f.string(from: Date())
        }()
        panel.nameFieldStringValue = "Shunt Diagnostics \(stamp).zip"
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        // Stage everything in a temp dir, then ditto to a zip.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("shunt-diag-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 1. Export settings JSON
        if let data = try? store.exportJSON(model.settings) {
            try? data.write(to: tmp.appendingPathComponent("settings.json"))
        }

        // 2. Capture last 1h of os_log for the Shunt subsystem
        let logFile = tmp.appendingPathComponent("shunt-provider.log")
        let logTask = Process()
        logTask.launchPath = "/usr/bin/log"
        logTask.arguments = [
            "show",
            "--predicate", "subsystem BEGINSWITH \"com.craraque.shunt\"",
            "--info",
            "--last", "1h"
        ]
        if let logFh = try? FileHandle(forWritingTo: logFile) {
            logTask.standardOutput = logFh
        } else {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            if let logFh = try? FileHandle(forWritingTo: logFile) {
                logTask.standardOutput = logFh
            }
        }
        try? logTask.run()
        logTask.waitUntilExit()

        // 3. README inside the bundle
        let readme = """
        Shunt Diagnostic Bundle — \(stamp)
        ====================================
        settings.json        — exported user settings (rules, upstream, launcher)
        shunt-provider.log   — last 1h of os_log lines from com.craraque.shunt*

        File this with bug reports.
        """
        try? readme.data(using: .utf8)?
            .write(to: tmp.appendingPathComponent("README.txt"))

        // 4. ditto to zip
        let zipTask = Process()
        zipTask.launchPath = "/usr/bin/ditto"
        zipTask.arguments = ["-c", "-k", "--keepParent", tmp.path, outURL.path]
        try? zipTask.run()
        zipTask.waitUntilExit()

        if zipTask.terminationStatus == 0 {
            statusMessage = "Diagnostic bundle saved to \(outURL.lastPathComponent)"
            statusIsError = false
        } else {
            statusMessage = "Bundle export failed (ditto exited \(zipTask.terminationStatus))"
            statusIsError = true
        }
    }

    private func confirmRestoreDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore default settings?"
        alert.informativeText = "This resets rules, upstream proxy config, and launcher entries to their defaults. Your active theme is preserved. The proxy will be disabled."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Build a minimal default settings, preserving theme via ActiveTheme.
        var defaults = ShuntSettings.empty
        // Disable any running proxy first.
        Task {
            await AppServices.shared.proxyManager.disable()
            await MainActor.run {
                model.settings = defaults
                model.save()
                statusMessage = "Defaults restored — proxy disabled."
                statusIsError = false
            }
        }
        _ = defaults  // silence warning when async closure captures it
    }
}
