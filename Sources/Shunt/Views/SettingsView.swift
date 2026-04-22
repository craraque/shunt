import SwiftUI

struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gauge.with.needle") }

            AppsTab(model: model)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }

            UpstreamTab(model: model)
                .tabItem { Label("Upstream", systemImage: "arrow.up.right") }

            AdvancedTab(model: model)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 520)
        .tint(.signalAmber)
        .onAppear { model.reload() }
    }
}
