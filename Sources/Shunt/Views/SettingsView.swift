import SwiftUI

struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gear") }

            AppsTab(model: model)
                .tabItem { Label("Apps", systemImage: "app.badge") }

            UpstreamTab(model: model)
                .tabItem { Label("Upstream", systemImage: "arrow.up.right.square") }

            AdvancedTab(model: model)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
        .onAppear { model.reload() }
    }
}
