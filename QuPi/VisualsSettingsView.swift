import SwiftUI

/// Menu and player appearance, the optional Playlists/Continue Watching sections, navigation (what
/// shows list at their top level) and sorting.
struct VisualsSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("carouselVisibleCount") private var visibleCount = 3
    @AppStorage(SettingsKeys.tvTopLevel) private var tvTopLevel = TVTopLevel.series.rawValue
    @AppStorage(SettingsKeys.sectionEnabled(.playlists)) private var sectionPlaylists = false
    @AppStorage(SettingsKeys.sectionEnabled(.continueItems)) private var sectionContinue = true
    @AppStorage(SettingsKeys.simpleVisuals) private var simpleVisuals = false
    @AppStorage(SettingsKeys.richMedia) private var richMedia = false
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
                Toggle("Show Posters", isOn: Binding(get: { !simpleVisuals }, set: { simpleVisuals = !$0 }))
                Toggle("Rich Media (Descriptions, Bios and more)", isOn: $richMedia)
            } header: {
                SectionInfoHeader(title: "Menu", info: "With Show Posters off, the menu skips artwork entirely and shows compact text boxes instead. Rich Media adds an info button (bottom-left of posters) that shows descriptions, bios, and synopses on demand - hover tooltips will no longer show them automatically.")
            }

            Section {
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
                SectionInfoHeader(title: "Player", info: "Player UI Size sets the size of the player window's toolbar buttons; Dynamic follows the system text size. Music Player plays music inside the menu (Inline) or in its own window (Popout).")
            }

            Section {
                Toggle("Continue Watching", isOn: $sectionContinue)
                Toggle("Video Playlists", isOn: $sectionPlaylists)
            } header: {
                SectionInfoHeader(title: "Sections", info: "The menu shows one section per server library, named as on the server; choose which libraries to include, and the order of all sections, in the Libraries tab. Video Playlists shows your Plex and Jellyfin video playlists; music playlists are always in the Music pane. Continue Watching lists anything you stopped partway through, and resumes it where you left off.")
            }

            Section {
                Picker("Shows Top Level", selection: $tvTopLevel) {
                    Text("Series").tag(TVTopLevel.series.rawValue)
                    Text("Season").tag(TVTopLevel.season.rawValue)
                }
                .pickerStyle(.segmented)
            } header: {
                SectionInfoHeader(title: "Navigation", info: "Series lists shows that drill into seasons, then episodes; Season lists every season directly.")
            }
            sortSection("Movie Sorting", type: .movies, sort: $appState.movieSortRaw,
                        direction: $appState.movieSortDirectionRaw, localFirst: $appState.movieLocalFirst)
            sortSection("Show Sorting", type: .tvShows, sort: $appState.tvSortRaw,
                        direction: $appState.tvSortDirectionRaw, localFirst: $appState.tvLocalFirst)
            sortSection("Music Sorting", type: .music, sort: $appState.musicSortRaw,
                        direction: $appState.musicSortDirectionRaw, localFirst: $appState.musicLocalFirst)
        }
        .formStyle(.grouped)
        .onChange(of: tvTopLevel) { appState.resetCatalog() }
    }

    /// Sort field, order and Downloaded First for one media type. Order
    /// labels follow the field ("Newest First" for dates, "A to Z" for titles).
    private func sortSection(_ title: String, type: MediaType, sort: Binding<String>,
                             direction: Binding<String>, localFirst: Binding<Bool>) -> some View {
        let labels = (LibrarySort(rawValue: sort.wrappedValue) ?? .byTitle).directionTitles
        return Section {
            Picker("Sort By", selection: sort) {
                ForEach(LibrarySort.options(for: type), id: \.self) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            Picker("Order", selection: direction) {
                Text(labels.ascending).tag(SortDirection.ascending.rawValue)
                Text(labels.descending).tag(SortDirection.descending.rawValue)
            }
            Toggle("Downloaded First", isOn: localFirst)
        } header: {
            SectionInfoHeader(title: title, info: "Date Added and Plays need server data and may not be available for every item. Downloaded First puts downloaded and local files before everything else.")
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
