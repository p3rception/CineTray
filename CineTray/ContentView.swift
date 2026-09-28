import SwiftUI
import AppKit

/// CineTray: Menu bar media player.
/// Dropdown shows poster carousels; selecting items opens a player window.
@main struct MyApp: App {
    @State private var appState = AppState()

    init() {
        // Set here rather than with LSUIElement: an app launched as a UI
        // element and switched to .regular later isn't activated by clicks on
        // its windows until its Dock icon is clicked.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(appState)
        } label: {
            Image(systemName: "play.square.stack")
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Player", id: "video-player", for: MediaItem.self) { $item in
            // Non-optional binding so auto-continue can swap the played item.
            if let itemBinding = Binding($item) {
                PlayerView(item: itemBinding)
                    .environment(appState)
            }
        }
        .defaultSize(width: 780, height: 460)

        // Music gets its own vertical mini-player window.
        WindowGroup("Music", id: "music-player", for: MediaItem.self) { $item in
            if let itemBinding = Binding($item) {
                PlayerView(item: itemBinding)
                    .environment(appState)
            }
        }
        .defaultSize(width: 340, height: 660)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// CineTray is a menu bar app (.accessory), so its windows get no app menus
/// and none of their shortcuts (Full Screen, Hide, Close). While a player
/// or the Settings window is open it becomes a regular app with a Dock icon,
/// and goes back to menu bar only when the last one closes.
enum AppWindowActivation {
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        guard openWindows == 1 else { return }
        NSApplication.shared.setActivationPolicy(.regular)
        // The policy change deactivates CineTray until it is processed, so
        // activating right away leaves the window inactive (gray switches,
        // no keyboard focus). Activate on the next run loop turn instead.
        Task { NSApplication.shared.activate() }
    }

    static func windowClosed() {
        openWindows = max(openWindows - 1, 0)
        guard openWindows == 0 else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
