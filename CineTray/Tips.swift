import SwiftUI
import TipKit

// The first-run tour: TipKit tips in Settings and the menu, remembered by
// TipKit once seen or done. Views show them only while
// SettingsKeys.showsTour is on, which CineTray sets when it starts with
// nothing set up, so existing users aren't shown what they already use.
// Not TipKit rules: the Command Line Tools lack the @Parameter and #Rule
// macro plugin.

struct ConnectServerTip: Tip {
    var title: Text { Text("Connect a server") }
    var message: Text? { Text("Sign in to Plex or connect Jellyfin. Your libraries then appear in the menu.") }
    var image: Image? { Image(systemName: "server.rack") }
}

struct LibrariesReadyTip: Tip {
    var title: Text { Text("Your libraries are ready") }
    var message: Text? { Text("Click the CineTray icon in the menu bar to browse them.") }
    var image: Image? { Image(systemName: "menubar.arrow.up.rectangle") }
}

struct LocalFolderTip: Tip {
    var title: Text { Text("Add your own media") }
    var message: Text? { Text("Choose a folder, and its movies, shows or music join your libraries.") }
    var image: Image? { Image(systemName: "folder.fill") }
}

struct DownloadsTip: Tip {
    var title: Text { Text("Watch offline") }
    var message: Text? { Text("Turn on downloads, choose a folder, then click Download on a poster.") }
    var image: Image? { Image(systemName: "arrow.down.circle.fill") }
}

struct VideoPlayerTip: Tip {
    var title: Text { Text("Choose a video player") }
    var message: Text? { Text("Play videos in IINA, VLC or another app. Only CineTray itself resumes and saves your progress.") }
    var image: Image? { Image(systemName: "play.rectangle.fill") }
}
