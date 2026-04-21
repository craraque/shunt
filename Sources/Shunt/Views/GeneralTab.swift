import SwiftUI
import NetworkExtension

struct GeneralTab: View {
    @ObservedObject var model: SettingsViewModel
    @State private var extensionState: String = "unknown"
    @State private var proxyEnabled: Bool = false
    @State private var statusTimer: Timer?
    @State private var busy = false

    private let services = AppServices.shared

    var body: some View {
        Form {
            Section("Extension") {
                LabeledContent("System extension") {
                    Text(extensionState).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Activate") {
                        services.extensionManager.activate()
                    }
                    Button("Deactivate") {
                        services.extensionManager.deactivate()
                    }
                }
            }

            Section("Proxy") {
                LabeledContent("Enabled") {
                    Toggle("", isOn: $proxyEnabled)
                        .labelsHidden()
                        .disabled(busy)
                        .onChange(of: proxyEnabled) { _, newValue in
                            busy = true
                            if newValue {
                                services.proxyManager.enable()
                            } else {
                                Task { await services.proxyManager.disable() }
                            }
                            // Optimistic — refresh will reconcile
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                refreshStatus()
                                busy = false
                            }
                        }
                }
                Text("Changes to Apps or Upstream take effect the next time you re-enable the proxy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("About this version") {
                LabeledContent("Version", value: Self.appVersion)
                LabeledContent("Build", value: Self.appBuild)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshStatus()
            statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                refreshStatus()
            }
        }
        .onDisappear {
            statusTimer?.invalidate()
            statusTimer = nil
        }
    }

    private func refreshStatus() {
        Task { @MainActor in
            let raw = await services.proxyManager.statusRaw()
            extensionState = Self.describe(statusRaw: raw)
            proxyEnabled = raw == 2 || raw == 3 || raw == 4
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

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }
}
