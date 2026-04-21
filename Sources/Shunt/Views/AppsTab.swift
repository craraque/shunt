import SwiftUI
import AppKit
import ShuntCore

struct AppsTab: View {
    @ObservedObject var model: SettingsViewModel
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Text("Apps listed here will have their outbound traffic routed through the configured upstream proxy. All other apps use your normal network.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])

            List(selection: $selection) {
                ForEach($model.settings.managedApps) { $app in
                    AppRow(app: $app) {
                        model.save()
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Button {
                    pickApp()
                } label: {
                    Label("Add from Applications…", systemImage: "plus")
                }

                Button {
                    addManualEntry()
                } label: {
                    Label("Add by Bundle ID", systemImage: "plus.rectangle")
                }

                Spacer()

                Button {
                    if let id = selection {
                        model.removeApp(id: id)
                        selection = nil
                    }
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection == nil)
            }
            .padding(10)
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "Select an app to route through Shunt"
        if panel.runModal() == .OK, let url = panel.url {
            if let info = model.importAppBundle(at: url) {
                model.addApp(bundleID: info.bundleID, displayName: info.name, appPath: url.path)
            } else {
                model.lastError = "Couldn't read bundle info from \(url.lastPathComponent)"
            }
        }
    }

    private func addManualEntry() {
        model.addApp(bundleID: "", displayName: "New entry", appPath: nil)
        if let last = model.settings.managedApps.last {
            selection = last.id
        }
    }
}

private struct AppRow: View {
    @Binding var app: ManagedApp
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Display name", text: $app.displayName, onCommit: onCommit)
                    .textFieldStyle(.plain)
                    .font(.body)
                TextField("com.example.app", text: $app.bundleID, onCommit: onCommit)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $app.enabled)
                .labelsHidden()
                .onChange(of: app.enabled) { _, _ in onCommit() }
        }
        .padding(.vertical, 4)
    }

    private var icon: some View {
        Group {
            if let path = app.appPath, FileManager.default.fileExists(atPath: path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
    }
}
