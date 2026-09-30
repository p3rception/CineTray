import SwiftUI

/// The dropdown shown when the menu bar icon is clicked: a row per enabled
/// section, each expanding into a horizontal poster carousel with drill-down
/// levels. Typing in the search field expands the sections with matches and
/// filters all catalogs as you type.
struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appearsActive) private var appearsActive

    private let downloadManager = DownloadManager.shared

    @FocusState private var searchFocused: Bool
    @AppStorage("carouselVisibleCount") private var carouselVisibleCount = 3
    @AppStorage(SettingsKeys.playerMode) private var playerMode = PlayerMode.popout.rawValue
    @AppStorage(SettingsKeys.menuShowsMusic) private var showsMusic = false

    private var contentWidth: CGFloat {
        MediaCarouselView.carouselWidth(for: carouselVisibleCount) + 24
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            let activeDownloads = downloadManager.downloadingItems
            if !activeDownloads.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                            .frame(width: 20)
                        Text("Downloading")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    
                    MediaCarouselView(
                        items: activeDownloads,
                        selectedID: nil,
                        isCompact: true,
                        onSelect: { item in
                            if !item.kind.isExpandable { openPlayer(for: item) }
                        }
                    )
                    .padding(.bottom, 10)
                }
                Divider()
            }

            if appState.librarySections == nil {
                ProgressView("Loading libraries…")
                    .controlSize(.small)
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                Divider()
            } else if let error = appState.librarySectionsError {
                VStack(spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Retry") { appState.resetCatalog() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                Divider()
            }

            // Filtered and sorted once per redraw, shared by the match check,
            // the count and the carousel.
            let pane = musicPane
            let sections = appState.enabledSections.filter { section in
                pane.map { section == .continueItems || section.isMusic == $0 } ?? true
            }
            let itemsBySection = Dictionary(uniqueKeysWithValues: sections.map { ($0, visibleItems(for: $0)) })
            // While a query is typed, show only the sections with matches.
            let shown = appState.isFiltering
                ? sections.filter { itemsBySection[$0]??.isEmpty == false }
                : sections
            ForEach(shown) { section in
                self.section(for: section, items: itemsBySection[section] ?? nil)
                if section != shown.last {
                    Divider()
                }
            }
            if appState.isFiltering {
                searchStatus(hasResults: !shown.isEmpty)
            }
        }
        .frame(width: contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        // True each time the menu opens (onAppear can fire only once for a
        // MenuBarExtra window).
        .onChange(of: appearsActive, initial: true) { _, active in
            guard active else { return }
            appState.menuDidOpen()
            // Ready to type; set on the next run loop turn, once the window is key.
            Task { searchFocused = true }
        }
        .onChange(of: searchFocused) {
            if searchFocused {
                withAnimation(.snappy(duration: 0.2)) { appState.activateSearch() }
            } else if appState.searchText.isEmpty {
                withAnimation(.snappy(duration: 0.2)) { appState.deactivateSearch() }
            }
        }
    }

    // MARK: - Header

    /// True when there are both video and music libraries, so the menu splits
    /// them into a Video and a Music pane.
    private var hasPanes: Bool {
        let libraries = appState.librarySections ?? []
        return libraries.contains { $0.mediaType == .music } && libraries.contains { $0.mediaType != .music }
    }

    /// Whether the Music pane is shown, or nil when every section is: there
    /// are no panes, or a search shows matches from both.
    private var musicPane: Bool? {
        hasPanes && !appState.isFiltering ? showsMusic : nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            if hasPanes {
                paneSwitch
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Label("CineTray", systemImage: "play.square.stack")
                        .font(.headline)
                    Text(appState.sourcesDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            searchField
            Button("Offline Mode", systemImage: "airplane") {
                appState.isOfflineMode.toggle()
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .foregroundStyle(appState.isOfflineMode ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .help(appState.isOfflineMode ? "Disable Offline Mode" : "Enable Offline Mode")
            Button("Settings", systemImage: "gearshape") {
                openSettings()
                NSApplication.shared.activate()
                dismiss()
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .help("Settings")
            Button("Quit CineTray", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .help("Quit CineTray")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The header title names the pane shown; clicking it switches to the other.
    private var paneSwitch: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showsMusic.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Label(showsMusic ? "Music" : "Video", systemImage: showsMusic ? "music.note" : "film")
                        .font(.headline)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(appState.sourcesDescription(music: showsMusic))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(appState.isFiltering)
        .help(showsMusic ? "Show Video" : "Show Music")
        .accessibilityLabel(showsMusic ? "Music" : "Video")
        .accessibilityHint(showsMusic ? "Switches to Video" : "Switches to Music")
    }

    private var searchField: some View {
        @Bindable var appState = appState
        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search", text: $appState.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand {
                    searchFocused = false
                    withAnimation(.snappy(duration: 0.2)) { appState.deactivateSearch() }
                }
            if !appState.searchText.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    appState.searchText = ""
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .font(.caption)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: .infinity)
        .onChange(of: appState.searchText) {
            if !appState.searchText.isEmpty {
                withAnimation(.snappy(duration: 0.2)) { appState.activateSearch() }
            }
            appState.scheduleDeepSearch()
        }
    }

    // MARK: - Filter Helper
    
    /// Filters items for a section, taking offline mode into account.
    private func visibleItems(for section: MenuSection) -> [MediaItem]? {
        let pane = musicPane
        return appState.displayedItems(for: section)?.filter { item in
            guard section == .continueItems else { return true }
            return (!appState.isOfflineMode || downloadManager.isDownloaded(item))
                && pane.map { (item.type == .music) == $0 } ?? true
        }
    }

    // MARK: - Sections

    private func isExpanded(_ section: MenuSection) -> Bool {
        appState.isFiltering
            || appState.expandedSection == section
            || (section == .continueItems && appState.isContinueExpanded)
    }

    /// One row under the search results: a spinner while results may still
    /// arrive, otherwise a single note when nothing matched.
    @ViewBuilder
    private func searchStatus(hasResults: Bool) -> some View {
        Group {
            if appState.isSearchPending {
                ProgressView("Searching…")
                    .controlSize(.small)
            } else if !hasResults {
                Text("No matches for \"\(appState.searchText)\"")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func section(for section: MenuSection, items: [MediaItem]?) -> some View {
        // The sort menu sits between the title and the count, so the row is
        // two buttons around it rather than one button containing a menu.
        HStack(spacing: 6) {
            Button { toggleRow(section) } label: {
                HStack {
                    Image(systemName: section.systemImage)
                        .frame(width: 20)
                    Text(section == .continueItems && musicPane == true ? "Continue Listening" : section.title)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(items.map { "\($0.count) items" } ?? "")
            if section.mediaType != nil, isExpanded(section) {
                sortMenu(for: section)
            }
            Button { toggleRow(section) } label: {
                HStack {
                    if let count = items?.count {
                        Text("\(count)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded(section) ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Same action as the title button, which VoiceOver already reads.
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        if isExpanded(section) {
            sectionContent(for: section, items: items)
                .padding(.bottom, 10)
        }
    }

    private func toggleRow(_ section: MenuSection) {
        // Rows are static headers while search results are shown.
        guard !appState.isFiltering else { return }
        withAnimation(.snappy(duration: 0.2)) {
            appState.toggleExpansion(of: section)
        }
    }

    /// Small sort button for an open Movies, Shows or Music row.
    private func sortMenu(for section: MenuSection) -> some View {
        @Bindable var appState = appState
        let sort: Binding<String>, direction: Binding<String>
        let type = section.mediaType ?? .movies
        switch type {
        case .movies: (sort, direction) = ($appState.movieSortRaw, $appState.movieSortDirectionRaw)
        case .tvShows: (sort, direction) = ($appState.tvSortRaw, $appState.tvSortDirectionRaw)
        case .music: (sort, direction) = ($appState.musicSortRaw, $appState.musicSortDirectionRaw)
        }
        let labels = (LibrarySort(rawValue: sort.wrappedValue) ?? .byTitle).directionTitles
        return Menu {
            Picker("Sort By", selection: sort) {
                ForEach(LibrarySort.options(for: type), id: \.self) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: direction) {
                Text(labels.ascending).tag(SortDirection.ascending.rawValue)
                Text(labels.descending).tag(SortDirection.descending.rawValue)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort \(section.title)")
        .accessibilityLabel("Sort \(section.title)")
    }

    @ViewBuilder
    private func sectionContent(for section: MenuSection, items: [MediaItem]?) -> some View {
        if appState.loadingSections.contains(section) {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .frame(height: section.loadingHeight)
        } else if let error = appState.errorsBySection[section] {
            VStack(spacing: 6) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Retry") {
                    Task { await appState.load(section, force: true) }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            
        } else if let items, !items.isEmpty {
            MediaCarouselView(
                items: items,
                selectedID: appState.currentItem?.id ?? appState.drillPath[section]?.first?.id,
                navigationStep: playerMode == PlayerMode.inline.rawValue ? 1 : nil,
                nowPlayingItem: (section.supportsInlineMusic && playerMode == PlayerMode.inline.rawValue) ? appState.currentItem : nil,
                isPlaying: appState.isPlaying,
                presentsEpisodesByShow: section == .continueItems,
                onPlayPause: appState.togglePlayPause,
                onPrevious: { appState.playInlineNeighbor(-1) },
                onNext: { appState.playInlineNeighbor(1) }
            ) { item in
                handleSelection(of: item, in: section, within: items)
            }
            inlinePlaybackError(in: section, items: items)
            ForEach(appState.drillPath[section] ?? [], id: \.id) { parent in
                drillLevel(for: parent, in: section)
            }
        } else {
            Text(section == .continueItems
                 ? (appState.isOfflineMode ? "No downloaded items in progress." : "Nothing in progress. Items you stop partway through, here or in Plex or Jellyfin, appear here.")
                 : "Nothing here yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    /// Inline playback has no window to show a failure in, so the error
    /// appears under the carousel holding the track (or, in Continue, its album).
    @ViewBuilder
    private func inlinePlaybackError(in section: MenuSection, items: [MediaItem]) -> some View {
        if section.supportsInlineMusic, playerMode == PlayerMode.inline.rawValue,
           let error = appState.playbackError,
           let failed = appState.lastStartedItem, failed.type == .music,
           items.contains(where: { $0.id == failed.id || (section == .continueItems && $0.id == failed.parentID) }) {
            Label("\(failed.title): \(error)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
        }
    }

    private func handleSelection(of item: MediaItem, in section: MenuSection, within items: [MediaItem]) {
        if section == .continueItems, item.type == .music, item.kind.isExpandable,
           playerMode == PlayerMode.inline.rawValue {
            Task { await appState.resumeContinueContainer(item) }
            return
        }
        if item.kind.isExpandable {
            withAnimation(.snappy(duration: 0.2)) {
                appState.toggleDrill(item, in: section)
            }
        } else if item.type == .music && playerMode == PlayerMode.inline.rawValue {
            let playlist = items.filter { !$0.kind.isExpandable }
            Task {
                await appState.startPlayback(item: item, inlinePlaylist: playlist)
            }
        } else {
            openPlayer(for: item)
        }
    }

    private func openPlayer(for item: MediaItem) {
        if item.type != .music, let app = appState.externalVideoPlayer {
            appState.play(item, in: app)
        } else {
            openWindow(id: item.type == .music ? "music-player" : "video-player", value: item)
            NSApplication.shared.activate()
        }
        dismiss()
    }

    private func drillLevelTitle(for parent: MediaItem) -> String {
        if appState.tvTopLevel == .season, parent.kind == .season {
            let seriesName = parent.parentTitle ?? parent.subtitle
            if let seriesName {
                return "\(seriesName) - \(parent.title)"
            }
        }
        return parent.title
    }

    @ViewBuilder
    private func drillLevel(for parent: MediaItem, in section: MenuSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(drillLevelTitle(for: parent), systemImage: "arrow.turn.down.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            if appState.loadingChildrenIDs.contains(parent.id) {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .frame(height: 60)
            } else if let error = appState.childErrorsByItemID[parent.id] {
                VStack(spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Retry") { appState.loadChildrenIfNeeded(of: parent) }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else if let children = appState.displayedChildren(of: parent)?.filter({ !appState.isOfflineMode || downloadManager.isDownloaded($0) }), !children.isEmpty {
                MediaCarouselView(
                    items: children,
                    selectedID: appState.drilledChildID(under: parent, in: section),
                    navigationStep: playerMode == PlayerMode.inline.rawValue ? 1 : nil,
                    nowPlayingItem: (section.supportsInlineMusic && playerMode == PlayerMode.inline.rawValue) ? appState.currentItem : nil,
                    isPlaying: appState.isPlaying,
                    onPlayPause: appState.togglePlayPause,
                    onPrevious: { appState.playInlineNeighbor(-1) },
                    onNext: { appState.playInlineNeighbor(1) }
                ) { child in
                    handleSelection(of: child, in: section, within: children)
                }
                inlinePlaybackError(in: section, items: children)
            } else {
                Text("No items found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .padding(.top, 6)
    }
}
