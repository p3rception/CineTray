import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PlaybackSettingsView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(SettingsKeys.movieAutoContinue) private var movieAutoContinue = MovieAutoContinue.off.rawValue
    @AppStorage(SettingsKeys.tvAutoContinue) private var tvAutoContinue = false
    @AppStorage(SettingsKeys.musicAutoContinue) private var musicAutoContinue = MusicAutoContinue.off.rawValue
    @AppStorage(SettingsKeys.continueMusic) private var continueMusic = ContinueMusicGrouping.byAlbumPlaylist.rawValue
    @AppStorage(SettingsKeys.continueTimeout) private var continueTimeout = ContinueTimeout.forever.rawValue
    @AppStorage(SettingsKeys.videoPlayerApp) private var videoPlayerApp = ""
    @AppStorage(SettingsKeys.subtitleSize) private var subtitleSize = 1.0

    var body: some View {
        Form {
            Section {
                LabeledContent("Play Video In") {
                    HStack {
                        Text(videoPlayerApp.isEmpty ? "CineTray" : FileManager.default.displayName(atPath: videoPlayerApp))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Choose…", action: chooseVideoPlayer)
                        if !videoPlayerApp.isEmpty {
                            Button("Use CineTray") { videoPlayerApp = "" }
                        }
                    }
                }
                Picker("Subtitle Size", selection: $subtitleSize) {
                    Text("Small").tag(0.75)
                    Text("Medium").tag(1.0)
                    Text("Large").tag(1.35)
                }
            } header: {
                SectionInfoHeader(title: "Video", info: "Another app plays from the beginning, and CineTray can't resume, save progress, scrobble or play the next item for it. Music always plays in CineTray.")
            }

            Section {
                Picker("When a Movie Ends", selection: $movieAutoContinue) {
                    Text("Stop").tag(MovieAutoContinue.off.rawValue)
                    Text("Next in Series").tag(MovieAutoContinue.inSequence.rawValue)
                    Text("Same Director").tag(MovieAutoContinue.byDirector.rawValue)
                    Text("Same Lead Actor").tag(MovieAutoContinue.byLeadActor.rawValue)
                }
            } header: {
                SectionInfoHeader(title: "Movies", info: "Next in Series plays the next movie in the same series. Same Director and Same Lead Actor play that person's next released movie (lead actor needs Plex or Jellyfin).")
            }

            Section("Shows") {
                Toggle("Play Next Episode", isOn: $tvAutoContinue)
            }

            Section {
                // .off and .inSequence both finish the album in order (see
                // AppState.autoContinueItem). The raw values stay so saved
                // settings still decode.
                Picker("When a Song Ends", selection: $musicAutoContinue) {
                    Text("Finish Album").tag(MusicAutoContinue.off.rawValue)
                    Text("In Order").tag(MusicAutoContinue.inSequence.rawValue)
                    Text("Shuffle by Artist").tag(MusicAutoContinue.shuffleByGenre.rawValue)
                }
            } header: {
                SectionInfoHeader(title: "Music", info: "Finish Album and In Order keep playing the album or playlist in order. Shuffle by Artist continues with random songs by the same artist.")
            }

            Section {
                Picker("Group Music", selection: $continueMusic) {
                    Text("By Album or Playlist").tag(ContinueMusicGrouping.byAlbumPlaylist.rawValue)
                    Text("By Song").tag(ContinueMusicGrouping.bySong.rawValue)
                }
                Picker("Keep Items For", selection: $continueTimeout) {
                    ForEach(ContinueTimeout.allCases, id: \.rawValue) { timeout in
                        Text(timeout.title).tag(timeout.rawValue)
                    }
                }
            } header: {
                SectionInfoHeader(title: "Continue Watching", info: "Group Music shows unfinished songs individually, or as their album or playlist. Keep Items For sets how long something you haven't finished stays in Continue Watching.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseVideoPlayer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = "Play Video In This App"
        if panel.runModal() == .OK, let url = panel.url {
            videoPlayerApp = url == Bundle.main.bundleURL ? "" : url.path
        }
    }
}

#if !SWIFT_PACKAGE // Previews need Xcode; SwiftPM builds skip them.
#Preview("Playback") {
    PlaybackSettingsView()
        .environment(AppState())
        .frame(width: 520, height: 560)
}
#endif
