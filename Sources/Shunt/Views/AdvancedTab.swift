import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShuntCore

struct AdvancedTab: View {
    @ObservedObject var model: SettingsViewModel
    @State private var statusMessage: String?

    private let store = AppServices.shared.settingsStore

    var body: some View {
        Form {
            Section("Backup") {
                HStack {
                    Button("Export Settings…") { exportSettings() }
                    Button("Import Settings…") { importSettings() }
                }
                Text("Export saves your managed apps and upstream proxy config as a JSON file. Import replaces current settings with the contents of the file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let status = statusMessage {
                Section { Text(status).font(.footnote) }
            }

            Section("Troubleshooting") {
                Button("Reveal Settings File in Finder") {
                    revealSettingsFile()
                }
                Text("The settings file lives in the App Group container and is used as a backup of what the app is storing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Shunt Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.exportJSON(model.settings)
            try data.write(to: url)
            statusMessage = "Exported to \(url.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
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
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func revealSettingsFile() {
        if let url = try? store.fileURL() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
