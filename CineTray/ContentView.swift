import SwiftUI
import AppKit

/// CineTray: Menu bar media player.
/// Dropdown shows poster carousels; selecting items opens a player window.
@main struct MyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var appState = AppState()

    init() {
        // Set here rather than with LSUIElement: an app launched as a UI
        // element and switched to .regular later isn't activated by clicks on
        // its windows until its Dock icon is clicked.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: Bindable(appState).showsMenuBarIcon) {
            MenuBarContentView()
                .environment(appState)
        } label: {
            MenuBarLabel(hasUpdate: appState.availableUpdate != nil)
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

    /// The menu bar draws SF Symbols as monochrome templates, so the blue
    /// icon is a non-template image.
    fileprivate static let updateIcon: NSImage? = {
        // One color per layer; with fewer, the stack layers aren't drawn.
        // Default size, as for the template icon: larger gets clipped on 22 pt menu bars.
        let configuration = NSImage.SymbolConfiguration(paletteColors: Array(repeating: .controlAccentColor, count: 3))
        let image = NSImage(systemSymbolName: "play.square.stack", accessibilityDescription: "CineTray, update available")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }()
}

/// Opening CineTray again from Spotlight, Finder or Launchpad opens
/// Settings, the way in when the menu bar icon is hidden: behind the notch,
/// in a full menu bar, or not allowed in System Settings > Menu Bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            NotificationCenter.default.post(name: MenuBarLabel.openSettingsRequest, object: nil)
        }
        return true
    }
}

/// The menu bar icon. Also opens Settings for AppDelegate: openSettings is
/// only available to views, and showSettingsWindow: no longer opens the
/// Settings scene. The label stays alive while the menu is closed.
private struct MenuBarLabel: View {
    static let openSettingsRequest = Notification.Name("CineTrayOpenSettings")

    let hasUpdate: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if hasUpdate, let icon = MyApp.updateIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "play.square.stack")
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: Self.openSettingsRequest) {
                openSettings()
                NSApplication.shared.activate()
            }
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
