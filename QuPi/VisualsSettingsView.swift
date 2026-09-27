import SwiftUI

/// Appearance, the optional Playlists/Continue Watching sections, navigation (what
/// shows and music list at their top level) and sorting.
struct VisualsSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("carouselVisibleCount") private var visibleCount = 3
    @AppStorage(SettingsKeys.tvTopLevel) private var tvTopLevel = TVTopLevel.series.rawValue
    @AppStorage(SettingsKeys.musicTopLevel) private var musicTopLevel = MusicTopLevel.album.rawValue
    @AppStorage(SettingsKeys.sectionEnabled(.playlists)) private var sectionPlaylists = false
    @AppStorage(SettingsKeys.sectionEnabled(.continueItems)) private var sectionContinue = true
    @AppStorage(SettingsKeys.simpleVisuals) private var simpleVisuals = false
    @AppStorage(SettingsKeys.richMedia) private var richMedia = false
    @AppStorage(SettingsKeys.continueTimeout) private var continueTimeout = ContinueTimeout.forever.rawValue
    @AppStorage(SettingsKeys.playerUISize) private var playerUISize = PlayerUISize.medium.rawValue
    @AppStorage(SettingsKeys.playerMode) private var playerMode = PlayerMode.popout.rawValue
    var body: some View {
        @Bindable var appState = appState
        Form {
            Section {
                Picker("Carousel Items", selection: $visibleCount) {
                    ForEach(3...6, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                Toggle("Simple Visuals", isOn: $simpleVisuals)
                Toggle("Rich Media (Descriptions, Bios and more)", isOn: $richMedia)
                Picker("Player UI Size", selection: $playerUISize) {
                    ForEach(PlayerUISize.allCases, id: \.rawValue) { size in
                        Text(size.title).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Music Player", selection: $playerMode) {
                    ForEach(PlayerMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                SectionInfoHeader(title: "Appearance", info: "Simple Visuals skips artwork entirely and shows compact text boxes instead. Rich Media adds an info button (bottom-left of posters) that shows descriptions, bios, and synopses on demand - hover tooltips will no longer show them automatically. Player UI Size sets the size of the player window's toolbar buttons; Dynamic follows the system text size. Music Player switches between Inline or Popout.")
            }

            Section {
                Toggle("Playlists", isOn: $sectionPlaylists)
                Toggle("Continue Watching", isOn: $sectionContinue)
            } header: {
                SectionInfoHeader(title: "Sections", info: "The menu shows one section per server library, named as on the server; choose which libraries to include in the Libraries tab. Playlists shows your Plex/Jellyfin playlists. Continue Watching lists anything you stopped partway through, and resumes it where you left off.")
            }

            Section {
                Picker("Shows Top Level", selection: $tvTopLevel) {
                    Text("Series").tag(TVTopLevel.series.rawValue)
                    Text("Season").tag(TVTopLevel.season.rawValue)
                }
                .pickerStyle(.segmented)
                Picker("Music Top Level", selection: $musicTopLevel) {
                    Text("Artist").tag(MusicTopLevel.artist.rawValue)
                    Text("Album").tag(MusicTopLevel.album.rawValue)
                }
                .pickerStyle(.segmented)
            } header: {
                SectionInfoHeader(title: "Navigation", info: "Series lists shows that drill into seasons, then episodes; Season lists every season directly. Artist lists artists that drill into albums, then tracks; Album lists albums directly.")
            }
            Section {
                sortRow("Movies", type: .movies, sort: $appState.movieSortRaw,
                        direction: $appState.movieSortDirectionRaw, localFirst: $appState.movieLocalFirst)
                sortRow("Shows", type: .tvShows, sort: $appState.tvSortRaw,
                        direction: $appState.tvSortDirectionRaw, localFirst: $appState.tvLocalFirst)
                sortRow("Music", type: .music, sort: $appState.musicSortRaw,
                        direction: $appState.musicSortDirectionRaw, localFirst: $appState.musicLocalFirst)
            } header: {
                SectionInfoHeader(title: "Sorting", info: "Choose how each section is ordered. Date Added and Plays require server data and may not be available for all items. Local First floats downloaded files to the front of the list.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: tvTopLevel) { appState.resetCatalog() }
        .onChange(of: musicTopLevel) { appState.resetCatalog() }
    }

    /// Sort field, order and Local First for one section. Order labels
    /// follow the field ("Newest First" for dates, "A to Z" for titles).
    @ViewBuilder
    private func sortRow(_ label: String, type: MediaType, sort: Binding<String>,
                         direction: Binding<String>, localFirst: Binding<Bool>) -> some View {
        let labels = (LibrarySort(rawValue: sort.wrappedValue) ?? .byTitle).directionTitles
        LabeledContent(label) {
            HStack {
                Picker("", selection: sort) {
                    ForEach(LibrarySort.options(for: type), id: \.self) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Toggle("Local First", isOn: localFirst)
            }
        }
        HStack {
            Spacer()
            Picker("", selection: direction) {
                Text(labels.ascending).tag(SortDirection.ascending.rawValue)
                Text(labels.descending).tag(SortDirection.descending.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

#if !SWIFT_PACKAGE // Previews need Xcode; SwiftPM builds skip them.
#Preview("Visuals") {
    VisualsSettingsView()
        .environment(AppState())
        .frame(width: 520, height: 560)
}
#endif
