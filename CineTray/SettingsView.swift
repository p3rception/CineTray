import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage(SettingsKeys.selectedSettingsTab) private var selectedTab = "general"

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
        // Fixed width, adjustable height, like System Settings; each tab's
        // Form scrolls when it doesn't fit.
        .frame(width: 520)
        .frame(minHeight: 400, idealHeight: 760, maxHeight: .infinity)
        .background(ResizableWindow())
        .onAppear { AppWindowActivation.windowOpened() }
        .onDisappear { AppWindowActivation.windowClosed() }
    }
}

extension View {
    /// Grouped forms draw text fields without a border, so an empty one looks
    /// like a plain label. A hairline under the input marks it as editable.
    /// Put the field in a LabeledContent; its own label is only for VoiceOver.
    func underlinedField() -> some View {
        labelsHidden()
            .textFieldStyle(.plain)
            .padding(.bottom, 3)
            .overlay(alignment: .bottom) { Rectangle().fill(.tertiary).frame(height: 1) }
    }
}

/// The Settings scene's window ignores .windowResizability, so this reaches
/// the hosting NSWindow and makes it resizable; the frame above keeps the
/// width fixed.
private struct ResizableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowHook() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowHook: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.styleMask.insert(.resizable)
        }
    }
}

#if !SWIFT_PACKAGE // Previews need Xcode; SwiftPM builds skip them.
#Preview("Settings") {
    SettingsView()
        .environment(AppState())
}
#endif
