import SwiftUI

struct PlaybackSettingsView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(SettingsKeys.movieAutoContinue) private var movieAutoContinue = MovieAutoContinue.off.rawValue
    @AppStorage(SettingsKeys.tvAutoContinue) private var tvAutoContinue = false
    @AppStorage(SettingsKeys.musicAutoContinue) private var musicAutoContinue = MusicAutoContinue.off.rawValue
    @AppStorage(SettingsKeys.continueMusic) private var continueMusic = ContinueMusicGrouping.byAlbumPlaylist.rawValue
    @AppStorage(SettingsKeys.continueTimeout) private var continueTimeout = ContinueTimeout.forever.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Auto-Continue Movie", selection: $movieAutoContinue) {
                    Text("Off").tag(MovieAutoContinue.off.rawValue)
                    Text("In Sequence").tag(MovieAutoContinue.inSequence.rawValue)
                    Text("By Director").tag(MovieAutoContinue.byDirector.rawValue)
                    Text("By Lead Actor").tag(MovieAutoContinue.byLeadActor.rawValue)
                }
                Toggle("Auto-Continue TV", isOn: $tvAutoContinue)
                Picker("Auto-Continue Music", selection: $musicAutoContinue) {
                    Text("Off").tag(MusicAutoContinue.off.rawValue)
                    Text("By Release Date").tag(MusicAutoContinue.inSequence.rawValue)
                    Text("By Genre").tag(MusicAutoContinue.shuffleByGenre.rawValue)
                }
                .pickerStyle(.segmented)
                Picker("Continue Music", selection: $continueMusic) {
                    Text("By Album / Playlist").tag(ContinueMusicGrouping.byAlbumPlaylist.rawValue)
                    Text("By Song").tag(ContinueMusicGrouping.bySong.rawValue)
                }
                .pickerStyle(.segmented)
                Picker("Continue Timeout", selection: $continueTimeout) {
                    ForEach(ContinueTimeout.allCases, id: \.rawValue) { timeout in
                        Text(timeout.title).tag(timeout.rawValue)
                    }
                }
            } header: {
                SectionInfoHeader(title: "Playback", info: "In Sequence plays the next movie in the same series; By Director / By Lead Actor plays that person's next released movie (lead actor requires Plex or Jellyfin). Auto-Continue TV plays the next episode. Music \"Off\" still finishes the album in order; Shuffle by Artist continues with random tracks by the same artist. Continue Music chooses whether the Continue Watching section lists individual in-progress songs or collapses them into their album/playlist. Continue Timeout controls how long unfinished items stay in the Continue Watching section.")
            }
        }
        .formStyle(.grouped)
    }
}

#if !SWIFT_PACKAGE // Previews need Xcode; SwiftPM builds skip them.
#Preview("Playback") {
    PlaybackSettingsView()
        .environment(AppState())
        .frame(width: 520, height: 560)
}
#endif
