import SwiftUI

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Shunt")
                .font(.system(size: 28, weight: .semibold))

            VStack(spacing: 2) {
                Text("Version \(appVersion) (build \(appBuild))")
                Text("Made by Cesar Araque")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Text("Per-app network routing for macOS. Send traffic from selected apps through a configurable SOCKS5 upstream, leaving everything else on your normal network.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 6)

            Spacer()
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }
}
