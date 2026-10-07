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
    @AppStorage(SettingsKeys.carouselVisibleCount) private var carouselVisibleCount = 3
    @AppStorage(SettingsKeys.playerMode) private var playerMode = PlayerMode.popout.rawValue
    @AppStorage(SettingsKeys.menuShowsMusic) private var showsMusic = false
    @AppStorage(SettingsKeys.radarrURL) private var radarrURL = ""
    @AppStorage(SettingsKeys.sonarrURL) private var sonarrURL = ""
    @AppStorage(SettingsKeys.seerrURL) private var seerrURL = ""
    @State private var showsCalendar = false
    @State private var copiedUpgradeCommand = false

    private var contentWidth: CGFloat {
        MediaCarouselView.carouselWidth(for: carouselVisibleCount) + 24
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let update = appState.availableUpdate {
                updateNotice(update)
                Divider()
            }

            if showsCalendar && hasCalendar {
                ReleaseCalendarView()
            } else {
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
                    self.section(for: section, items: itemsBySection[section] ?? nil, in: shown)
                    if section != shown.last {
                        Divider()
                    }
                }
                if appState.isFiltering {
                    searchStatus(hasResults: !shown.isEmpty)
                    if !seerrURL.isEmpty, !appState.isOfflineMode, musicPane != true {
                        SeerrSearchRow(query: appState.searchText.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        .frame(width: contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        // True each time the menu opens (onAppear can fire only once for a
        // MenuBarExtra window).
        .onChange(of: appearsActive, initial: true) { _, active in
            guard active else { return }
            appState.menuDidOpen()
            copiedUpgradeCommand = false
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
        .tourOverlay(onNext: [.settings: showSettings])
        .onChange(of: appState.tourStep) {
            // The posters step needs an open row to point at.
            if appState.tourStep == .posters, !appState.enabledSections.contains(where: isExpanded),
               let first = appState.enabledSections.first(where: { section in
                   musicPane.map { section == .continueItems || section.isMusic == $0 } ?? true
               }) {
                withAnimation(.snappy(duration: 0.2)) { appState.toggleExpansion(of: first) }
            }
        }
    }

    private func showSettings() {
        if appState.tourStep == .settings { appState.moveTour(by: 1) }
        openSettings()
        NSApplication.shared.activate()
        dismiss()
    }

    // MARK: - Update notice

    /// Homebrew installs copy the upgrade command; others open the release page.
    private func updateNotice(_ version: String) -> some View {
        HStack(spacing: 8) {
            Button {
                if appState.isHomebrewInstall {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew upgrade cinetray", forType: .string)
                    copiedUpgradeCommand = true
                } else if let url = URL(string: "https://github.com/p3rception/CineTray/releases/latest") {
                    NSWorkspace.shared.open(url)
                    dismiss()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copiedUpgradeCommand ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    Text("CineTray \(version) is available")
                        .fontWeight(.semibold)
                    Spacer(minLength: 4)
                    Text(appState.isHomebrewInstall
                         ? (copiedUpgradeCommand ? "Copied, paste in Terminal" : "Copy brew upgrade")
                         : "Download")
                }
                .font(.system(size: 12))
                .foregroundStyle(.tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                // Darkened with black on top of the glass: a dark tint color
                // drifts toward green once the glass blends it.
                .background(.black.opacity(0.3), in: .capsule)
                .glassEffect(.regular.tint(.accentColor.opacity(0.18)).interactive(), in: .capsule)
                .overlay(Capsule().strokeBorder(.tint.opacity(0.5), lineWidth: 1))
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help(appState.isHomebrewInstall ? "Copies brew upgrade cinetray. Paste it in Terminal to update." : "Opens the release on GitHub")

            Button("Dismiss", systemImage: "xmark") {
                withAnimation(.snappy(duration: 0.2)) { appState.dismissUpdate() }
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .help("Hide until the next version")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        guard hasPanes else { return nil }
        return appState.isFiltering ? appState.searchMusicPane : showsMusic
    }

    private var hasCalendar: Bool {
        !radarrURL.isEmpty || !sonarrURL.isEmpty
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
            // The 24 pt targets carry their own padding, so the glyphs keep
            // their usual 10 pt gaps.
            HStack(spacing: 2) {
                if hasCalendar {
                    headerButton("Release Calendar", systemImage: "calendar", isOn: showsCalendar) {
                        withAnimation(.snappy(duration: 0.2)) { showsCalendar.toggle() }
                    }
                    .help(showsCalendar ? "Hide Release Calendar" : "Show Release Calendar")
                }
                headerButton("Offline Mode", systemImage: "airplane", isOn: appState.isOfflineMode) {
                    appState.isOfflineMode.toggle()
                }
                .help(appState.isOfflineMode ? "Disable Offline Mode" : "Enable Offline Mode")
                .tourAnchor(.offline)
                headerButton("Settings", systemImage: "gearshape", action: showSettings)
                .help("Settings")
                .tourAnchor(.settings)
                .keyboardShortcut(",")
                headerButton("Quit CineTray", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
                .help("Quit CineTray")
                .keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// An icon button with a 24 pt click target (the HIG minimum is 20). A
    /// toggle (isOn not nil) also marks its on state with a background, so
    /// the state doesn't rest on the accent color alone.
    private func headerButton(_ title: String, systemImage: String, isOn: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .background(.quaternary.opacity(isOn == true ? 1 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn.map { $0 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary) } ?? AnyShapeStyle(.primary))
        .accessibilityAddTraits(isOn == true ? .isSelected : [])
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
            if hasPanes, appState.isFiltering {
                Divider()
                    .frame(height: 12)
                    .padding(.horizontal, 3)
                searchScopeButton(music: false)
                searchScopeButton(music: true)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .tourAnchor(.search)
        .frame(maxWidth: .infinity)
        .onChange(of: appState.searchText) {
            // The field has focus whenever the menu is open, so a space typed
            // into it while empty plays or pauses inline music instead.
            if appState.searchText == " ", playerMode == PlayerMode.inline.rawValue,
               appState.currentItem?.type == .music {
                appState.searchText = ""
                appState.togglePlayPause()
                return
            }
            if !appState.searchText.isEmpty {
                withAnimation(.snappy(duration: 0.2)) {
                    showsCalendar = false
                    appState.activateSearch()
                }
            }
            appState.scheduleDeepSearch()
        }
    }

    /// Each kind turns on and off on its own. Turning off the only kind on
    /// switches to the other, since a search needs at least one.
    private func searchScopeButton(music: Bool) -> some View {
        let title = music ? "Music" : "Video"
        let isOn = appState.searchMusicPane.map { $0 == music } ?? true
        let isOnly = appState.searchMusicPane == music
        return Button {
            withAnimation(.snappy(duration: 0.2)) { appState.searchMusicPane = isOn ? !music : nil }
        } label: {
            Label(title, systemImage: music ? "music.note" : "film")
                .labelStyle(.iconOnly)
                .font(.caption)
                .frame(width: 20, height: 18)
                .background(.quaternary.opacity(isOn ? 1 : 0), in: .rect(cornerRadius: 4))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
        .help(isOnly ? "Search \(music ? "Video" : "Music") Instead" : isOn ? "Leave Out \(title)" : "Include \(title)")
        .accessibilityLabel("Search \(title)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
    private func section(for section: MenuSection, items: [MediaItem]?, in shown: [MenuSection]) -> some View {
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
            .accessibilityValue([items.map { "\($0.count) items" }, isExpanded(section) ? "expanded" : "collapsed"]
                .compactMap { $0 }.joined(separator: ", "))
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
        .tourAnchor(section == shown.first ? .browse : nil)

        if isExpanded(section) {
            sectionContent(for: section, items: items)
                .padding(.bottom, 10)
                .tourAnchor(section == shown.first(where: isExpanded) ? .posters : nil)
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
                nowPlayingItem: (section.supportsInlineMusic && playerMode == PlayerMode.inline.rawValue) ? appState.currentItem : nil,
                isPlaying: appState.isPlaying,
                presentsEpisodesByShow: section == .continueItems,
                marksSongs: section != .continueItems,
                onPlayPause: appState.togglePlayPause,
                onPrevious: { appState.playInlineNeighbor(-1) },
                onNext: { appState.playInlineNeighbor(1) }
            ) { item in
                handleSelection(of: item, in: section, within: items)
            }
            inlinePlaybackError(in: section, items: items)
            inlineQueue(in: section, items: items)
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

    /// Up Next for inline playback, under the carousel holding the track (or,
    /// in Continue, its album).
    @ViewBuilder
    private func inlineQueue(in section: MenuSection, items: [MediaItem]) -> some View {
        if appState.showsInlineQueue, section.supportsInlineMusic, playerMode == PlayerMode.inline.rawValue,
           let current = appState.currentItem, current.type == .music,
           items.contains(where: { $0.id == current.id || (section == .continueItems && $0.id == current.parentID) }) {
            let queue = appState.upNext
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Label("Up Next", systemImage: "arrow.turn.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        appState.setShuffled(!appState.isShuffled)
                    } label: {
                        Image(systemName: "shuffle")
                            .foregroundStyle(appState.isShuffled ? Color.accentColor : .primary)
                    }
                    .help(appState.isShuffled ? "Shuffle On" : "Shuffle Off")
                    .accessibilityLabel("Shuffle")
                    .accessibilityValue(appState.isShuffled ? "On" : "Off")
                    Button {
                        appState.repeatMode = appState.repeatMode.next
                    } label: {
                        Image(systemName: appState.repeatMode.symbol)
                            .foregroundStyle(appState.repeatMode == .off ? .primary : Color.accentColor)
                    }
                    .help(appState.repeatMode.title)
                    .accessibilityLabel("Repeat")
                    .accessibilityValue(appState.repeatMode.title)
                    if !queue.isEmpty {
                        Button("Clear") { appState.setUpNext([]) }
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                if queue.isEmpty {
                    Text("End of the queue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    UpNextList(queue: queue, onPick: { appState.playInlineNeighbor($0 + 1) }, onEdit: appState.setUpNext)
                        .frame(height: CGFloat(min(queue.count, 5)) * UpNextList.rowHeight)
                }
            }
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
                await appState.playInline(item, in: playlist)
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
                    nowPlayingItem: (section.supportsInlineMusic && playerMode == PlayerMode.inline.rawValue) ? appState.currentItem : nil,
                    isPlaying: appState.isPlaying,
                    onPlayPause: appState.togglePlayPause,
                    onPrevious: { appState.playInlineNeighbor(-1) },
                    onNext: { appState.playInlineNeighbor(1) }
                ) { child in
                    handleSelection(of: child, in: section, within: children)
                }
                inlinePlaybackError(in: section, items: children)
                inlineQueue(in: section, items: children)
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
