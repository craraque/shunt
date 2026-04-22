import SwiftUI
import AppKit
import ShuntCore

struct AppsTab: View {
    @ObservedObject var model: SettingsViewModel
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Apps")
                    .font(.shuntTitle1)
                Text("Apps listed here have their outbound traffic routed through the configured upstream. All others use the host network.")
                    .font(.shuntBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 16)

            // App list card
            ScrollView {
                VStack(spacing: 0) {
                    if model.settings.managedApps.isEmpty {
                        EmptyAppsState()
                            .padding(.vertical, 40)
                    } else {
                        ForEach($model.settings.managedApps) { $app in
                            AppRow(app: $app, isSelected: selection == app.id) {
                                model.save()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selection = app.id }
                            if app.id != model.settings.managedApps.last?.id {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.shuntSeparator, lineWidth: 1)
                )
            }
            .padding(.horizontal, 28)

            // Action bar
            HStack(spacing: 8) {
                Button {
                    pickApp()
                } label: {
                    Label("Add from Applications…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.signalAmber)

                Button {
                    addManualEntry()
                } label: {
                    Label("Add by Bundle ID", systemImage: "plus.rectangle")
                }

                Spacer()

                Button(role: .destructive) {
                    if let id = selection {
                        model.removeApp(id: id)
                        selection = nil
                    }
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection == nil)
            }
            .padding(16)
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

// MARK: - App row

private struct AppRow: View {
    @Binding var app: ManagedApp
    let isSelected: Bool
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Display name", text: $app.displayName, onCommit: onCommit)
                    .textFieldStyle(.plain)
                    .font(.shuntLabelStrong)
                TextField("com.example.app", text: $app.bundleID, onCommit: onCommit)
                    .textFieldStyle(.plain)
                    .font(.shuntMonoData)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(kind: app.enabled ? .active : .idle)

            Toggle("", isOn: $app.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.signalAmber)
                .onChange(of: app.enabled) { _, _ in onCommit() }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.signalAmber.opacity(0.1) : .clear)
    }

    @ViewBuilder
    private var icon: some View {
        if let path = app.appPath, FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay(
                    Image(systemName: "app.dashed")
                        .foregroundStyle(.secondary)
                )
        }
    }
}

private struct EmptyAppsState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No apps configured")
                .font(.shuntLabelStrong)
                .foregroundStyle(.secondary)
            Text("Add an app to route its traffic through the upstream.")
                .font(.shuntCaption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
