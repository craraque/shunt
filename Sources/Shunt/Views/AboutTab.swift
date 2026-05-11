import SwiftUI

struct AboutTab: View {
    @Environment(\.shuntTheme) private var theme
    @StateObject private var checker = UpdateChecker.shared
    @StateObject private var installer = UpdateInstaller.shared
    @State private var showingError: String?

    var body: some View {
        ZStack {
            LiquidCard(
                theme: theme,
                cornerRadius: 18,
                padding: EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24),
                strong: true
            ) {
                ZStack {
                    AccentBloom(theme: theme, diameter: 360, opacity: 0.18)
                        .offset(y: -40)

                    VStack(spacing: 14) {
                        Spacer(minLength: 0)

                        ShuntLogo(size: 108, theme: theme)

                        Text("shunt")
                            .font(.system(size: 32, weight: .medium, design: .default))
                            .tracking(-0.96)
                            .foregroundStyle(.white)
                            .padding(.top, 4)

                        LiquidPill(
                            text: "Version \(Self.appVersion) · build \(Self.appBuild)",
                            kind: .neutral,
                            theme: theme
                        )

                        Text("Per-app network routing for macOS. Send traffic from selected apps through a configurable SOCKS5 upstream — leave everything else on your normal network.")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.62))
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .padding(.top, 4)
                            .frame(maxWidth: 420)

                        updaterSection
                            .padding(.top, 8)
                            .frame(maxWidth: 480)

                        HStack(spacing: 8) {
                            Button("Release notes") {
                                NSWorkspace.shared.open(URL(string: "https://github.com/craraque/shunt/releases")!)
                            }
                            .buttonStyle(.bordered)
                            Button("Acknowledgements") {
                                NSWorkspace.shared.open(URL(string: "https://github.com/craraque/shunt/blob/main/THIRD_PARTY.md")!)
                            }
                            .buttonStyle(.bordered)
                            updaterPrimaryButton
                        }
                        .padding(.top, 12)

                        Spacer(minLength: 0)

                        Text("MADE BY CESAR ARAQUE")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.36))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Updater UI

    @ViewBuilder
    private var updaterSection: some View {
        switch (checker.lastOutcome, installer.phase) {
        case (_, .downloading(let p)):
            updaterStatusRow(
                icon: "arrow.down.circle",
                text: String(format: "Downloading update… %d%%", Int(p * 100))
            )
        case (_, .verifying):
            updaterStatusRow(icon: "checkmark.shield", text: "Verifying signature…")
        case (_, .installing):
            updaterStatusRow(icon: "tray.and.arrow.down", text: "Installing update…")
        case (_, .relaunching):
            updaterStatusRow(icon: "arrow.up.right.square", text: "Relaunching Shunt…")
        case (_, .failed(let msg)):
            updaterStatusRow(icon: "exclamationmark.triangle.fill",
                             text: msg, color: .orange)
        case (.failed(let reason)?, _):
            updaterStatusRow(icon: "exclamationmark.triangle",
                             text: reason, color: .orange)
        case (.upToDate(let v)?, _):
            updaterStatusRow(icon: "checkmark.circle.fill",
                             text: "You're on the latest release (v\(v)).",
                             color: theme.statusActive(for: .dark))
        case (.available(let release)?, _):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(theme.accentDark)
                    Text("Update available — Shunt \(release.version)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                }
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(release.notes)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 90)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.glass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.edge, lineWidth: 0.5)
            )
        case (nil, .idle):
            EmptyView()
        }
    }

    private func updaterStatusRow(icon: String, text: String, color: Color = .white.opacity(0.7)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer()
        }
    }

    @ViewBuilder
    private var updaterPrimaryButton: some View {
        switch (checker.lastOutcome, installer.phase) {
        case (.available(let release)?, .idle):
            Button {
                Task { await installer.install(release: release) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.app")
                    Text("Install update")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accentDark)
        case (_, .downloading), (_, .verifying), (_, .installing), (_, .relaunching):
            Button {} label: {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accentDark)
            .disabled(true)
        default:
            Button {
                Task { _ = await checker.checkNow() }
            } label: {
                HStack(spacing: 4) {
                    if checker.inFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(checker.inFlight ? "Checking…" : "Check for updates")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accentDark)
            .disabled(checker.inFlight)
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }
}
