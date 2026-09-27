import SwiftUI

struct SettingsView: View {
    @AppStorage("selectedSettingsTab") private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag("accounts")
            LibrariesSettingsView()
                .tabItem { Label("Libraries", systemImage: "books.vertical") }
                .tag("libraries")
            VisualsSettingsView()
                .tabItem { Label("Visuals", systemImage: "slider.horizontal.3") }
                .tag("visuals")
            PlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.circle") }
                .tag("playback")
            DataSettingsView()
                .tabItem { Label("Data", systemImage: "externaldrive") }
                .tag("data")
        }
        .frame(width: 520, height: 560)
        .onAppear { AppWindowActivation.windowOpened() }
        .onDisappear { AppWindowActivation.windowClosed() }
    }
}

#if !SWIFT_PACKAGE // Previews need Xcode; SwiftPM builds skip them.
#Preview("Settings") {
    SettingsView()
        .environment(AppState())
}
#endif
