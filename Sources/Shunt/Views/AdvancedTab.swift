import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShuntCore

struct AdvancedTab: View {
    @ObservedObject var model: SettingsViewModel
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @Environment(\.shuntTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private let store = AppServices.shared.settingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Advanced")
                    .font(.shuntTitle1)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        label: "Backup",
                        icon: "tray.and.arrow.up",
                        tooltip: "Export the full settings (rules, upstream, theme) as JSON. Import replaces current settings with the file's contents."
                    )
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Button("Export Settings…") { exportSettings() }
                                .buttonStyle(.borderedProminent)
                                .tint(theme.accent(for: scheme))
                            Button("Import Settings…") { importSettings() }
                        }
                        Text("Export saves your managed apps and upstream proxy config as a JSON file. Import replaces current settings with the contents of the file.")
                            .font(.shuntCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let msg = statusMessage {
                    HStack(spacing: 6) {
                        Image(systemName: statusIsError ? "exclamationmark.triangle" : "checkmark")
                            .foregroundStyle(statusIsError ? .orange : theme.statusActive(for: scheme))
                        Text(msg)
                            .font(.shuntCaption)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        label: "Troubleshooting",
                        icon: "wrench.and.screwdriver",
                        tooltip: "Open the App Group container to inspect the live settings file or copy it between machines."
                    )
                    Button("Reveal Settings File in Finder") {
                        revealSettingsFile()
                    }
                    Text("The settings file lives in the App Group container. Useful for diagnostics or copying config between devices.")
                        .font(.shuntCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
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
}
