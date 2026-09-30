import Foundation
import Observation
import AVFoundation
import MediaPlayer
import AppKit

/// Shared app state managing UI sections, drill-down paths, and catalogs.
/// Merges Plex, Jellyfin, Navidrome, TorrServer and local library providers.
@MainActor
@Observable
final class AppState {
    var itemsBySection: [MenuSection: [MediaItem]] = [:]
    var loadingSections: Set<MenuSection> = []
    var errorsBySection: [MenuSection: String] = [:]
    var expandedSection: MenuSection?
    /// Continue Watching stays open alongside whichever library section is
    /// open; expanded by default.
    var isContinueExpanded = UserDefaults.standard.object(forKey: SettingsKeys.continueExpanded) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isContinueExpanded, forKey: SettingsKeys.continueExpanded) }
    }
    var searchText = ""
    /// While active, every section is expanded and filtered live.
    var isSearchActive = false

    /// Drill-down hierarchy per section (e.g., [show, season]). Each gets a child carousel.
    var drillPath: [MenuSection: [MediaItem]] = [:]
    var childrenByItemID: [String: [MediaItem]] = [:]
    var loadingChildrenIDs: Set<String> = []
    var childErrorsByItemID: [String: String] = [:]

    init() {
        PlaybackProgressStore.removeSavedPlexTokens()
        ArtworkCache.removeCredentialEntries()
        setupMediaKeys()
        let playlistFolder = Self.playlistFolder
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            try? FileManager.default.removeItem(at: playlistFolder)
        }
        
        Task {
            await ensureLibrarySections()
            if providers().isEmpty {
                UserDefaults.standard.set("accounts", forKey: "selectedSettingsTab")
                NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    private func setupMediaKeys() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand] {
            handleMediaKey(command) { $0.togglePlayPause() }
        }
        handleMediaKey(center.nextTrackCommand) { $0.skipFromMediaKey(1) }
        handleMediaKey(center.previousTrackCommand) { $0.skipFromMediaKey(-1) }
    }

    /// Routes a media key to `action` while "Use Media Keys" is enabled.
    private func handleMediaKey(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable (AppState) -> Void) {
        command.addTarget { [weak self] _ in
            guard let self, UserDefaults.standard.bool(forKey: SettingsKeys.useMediaKeys) else { return .commandFailed }
            Task { @MainActor in action(self) }
            return .success
        }
    }

    /// Next/previous track: steps through the inline playlist, or asks the
    /// open player window to handle it.
    private func skipFromMediaKey(_ offset: Int) {
        if inlinePlaylist != nil {
            playInlineNeighbor(offset)
        } else {
            let name = offset > 0 ? "CineTray.MediaKeyNext" : "CineTray.MediaKeyPrevious"
            NotificationCenter.default.post(name: NSNotification.Name(name), object: nil)
        }
    }

    /// Short label for the dropdown header, e.g. "Plex + Jellyfin".
    var sourcesDescription: String {
        if isOfflineMode { return "Offline" }
        var names: [String] = []
        for name in serverProviders().compactMap(\.source.webAppName) where !names.contains(name) {
            names.append(name)
        }
        return names.isEmpty ? "No sources" : names.joined(separator: " + ")
    }

    /// The header label for one pane of the menu: only the servers with
    /// music (or video) libraries, e.g. "Navidrome" for the Music pane.
    func sourcesDescription(music: Bool) -> String {
        guard !isOfflineMode, let names = serverNamesByPane[music], !names.isEmpty else { return sourcesDescription }
        return names.joined(separator: " + ")
    }

    // MARK: - Backend configuration

    /// Server settings from UserDefaults and the Keychain. Cached because
    /// Keychain reads are slow and these are needed on every catalog access
    /// and menu redraw. Cleared by resetCatalog(), which every account
    /// change calls. Keeping the PlexConfiguration objects also keeps a
    /// working fallback URL for the rest of the session.
    @ObservationIgnored private var cachedSources: (plex: [PlexConfiguration], jellyfin: JellyfinConfiguration?, navidrome: NavidromeConfiguration?, torrServer: TorrServerConfiguration?)?

    private var sources: (plex: [PlexConfiguration], jellyfin: JellyfinConfiguration?, navidrome: NavidromeConfiguration?, torrServer: TorrServerConfiguration?) {
        if let cachedSources { return cachedSources }
        let loaded = (plex: Self.loadPlexConfigurations(), jellyfin: Self.loadJellyfinConfiguration(), navidrome: Self.loadNavidromeConfiguration(), torrServer: Self.loadTorrServerConfiguration())
        cachedSources = loaded
        let tokens = loaded.plex.flatMap { configuration in
            ([configuration.serverURL] + (configuration.fallbackURLs ?? [])).map { (ArtworkCache.addressKey($0), configuration.token) }
        }
        ArtworkCache.setPlexTokens(Dictionary(tokens, uniquingKeysWith: { first, _ in first }))
        ArtworkCache.setNavidromeAuth(loaded.navidrome.map { (ArtworkCache.addressKey($0.serverURL), $0.authQuery) })
        return loaded
    }

    /// One configuration per connected server that has a usable URL and
    /// token; their catalogs are merged.
    var plexConfigurations: [PlexConfiguration] { sources.plex }

    var jellyfinConfiguration: JellyfinConfiguration? { sources.jellyfin }

    private static func loadPlexConfigurations() -> [PlexConfiguration] {
        PlexServerStore.load().compactMap { server in
            guard let url = URL(string: server.urlString),
                  let token = PlexServerStore.token(for: server.id), !token.isEmpty else {
                return nil
            }
            return PlexConfiguration(
                serverURL: url,
                fallbackURLs: server.fallbackURLStrings?.compactMap(URL.init(string:)),
                token: token,
                serverID: server.id,
                serverName: server.name
            )
        }
    }

    private static func loadJellyfinConfiguration() -> JellyfinConfiguration? {
        let defaults = UserDefaults.standard
        guard let urlString = defaults.string(forKey: SettingsKeys.jellyfinServerURL),
              !urlString.isEmpty,
              // Sign-in saves the working URL; this also covers addresses
              // saved without a scheme by older builds.
              let url = serverURLCandidates(urlString).first,
              let userID = defaults.string(forKey: SettingsKeys.jellyfinUserID), !userID.isEmpty,
              let token = KeychainStore.string(for: KeychainKeys.jellyfinToken), !token.isEmpty else {
            return nil
        }
        return JellyfinConfiguration(serverURL: url, token: token, userID: userID)
    }

    private static func loadNavidromeConfiguration() -> NavidromeConfiguration? {
        let defaults = UserDefaults.standard
        guard let url = defaults.string(forKey: SettingsKeys.navidromeServerURL).flatMap(URL.init(string:)),
              let username = defaults.string(forKey: SettingsKeys.navidromeUsername), !username.isEmpty,
              let salt = defaults.string(forKey: SettingsKeys.navidromeSalt), !salt.isEmpty,
              let token = KeychainStore.string(for: KeychainKeys.navidromeToken), !token.isEmpty else {
            return nil
        }
        return NavidromeConfiguration(serverURL: url, username: username, token: token, salt: salt)
    }

    private static func loadTorrServerConfiguration() -> TorrServerConfiguration? {
        guard let url = UserDefaults.standard.string(forKey: SettingsKeys.torrServerURL).flatMap(URL.init(string:)) else { return nil }
        let username = UserDefaults.standard.string(forKey: SettingsKeys.torrServerUsername) ?? ""
        return TorrServerConfiguration(
            serverURL: url,
            username: username.isEmpty ? nil : username,
            password: KeychainStore.string(for: KeychainKeys.torrServerPassword)
        )
    }

    private func selectedLibraries(forKey key: String) -> Set<String> {
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        return Set(stored.split(separator: ",").map(String.init))
    }

    /// Plex library selections are stored scoped as "serverID:libraryKey"
    /// (keys alone collide across servers); each provider gets its own
    /// entries with the prefix stripped.
    private func selectedPlexLibraries(forServer serverID: String) -> Set<String> {
        Set(selectedLibraries(forKey: SettingsKeys.plexSelectedLibraries).compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0] == serverID else { return nil }
            return String(parts[1])
        })
    }

    // MARK: - Preferences

    var tvTopLevel: TVTopLevel {
        UserDefaults.standard.string(forKey: SettingsKeys.tvTopLevel).flatMap(TVTopLevel.init) ?? .series
    }

    var movieAutoContinue: MovieAutoContinue {
        UserDefaults.standard.string(forKey: SettingsKeys.movieAutoContinue).flatMap(MovieAutoContinue.init) ?? .off
    }

    var tvAutoContinue: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.tvAutoContinue)
    }

    var musicAutoContinue: MusicAutoContinue {
        UserDefaults.standard.string(forKey: SettingsKeys.musicAutoContinue).flatMap(MusicAutoContinue.init) ?? .off
    }

    var continueMusicGrouping: ContinueMusicGrouping {
        UserDefaults.standard.string(forKey: SettingsKeys.continueMusic).flatMap(ContinueMusicGrouping.init) ?? .byAlbumPlaylist
    }

    // Sort preferences are stored (not UserDefaults-computed) so @Observable
    // can track changes and re-render displayedItems reactively without a catalog reload.
    // Movies and TV default to newest additions first.
    var movieSortRaw: String = UserDefaults.standard.string(forKey: SettingsKeys.movieSort) ?? LibrarySort.byDateAdded.rawValue {
        didSet { UserDefaults.standard.set(movieSortRaw, forKey: SettingsKeys.movieSort) }
    }
    var movieSortDirectionRaw: String = UserDefaults.standard.string(forKey: SettingsKeys.movieSortDirection) ?? SortDirection.descending.rawValue {
        didSet { UserDefaults.standard.set(movieSortDirectionRaw, forKey: SettingsKeys.movieSortDirection) }
    }
    var tvSortRaw: String = UserDefaults.standard.string(forKey: SettingsKeys.tvSort) ?? LibrarySort.byDateAdded.rawValue {
        didSet { UserDefaults.standard.set(tvSortRaw, forKey: SettingsKeys.tvSort) }
    }
    var tvSortDirectionRaw: String = UserDefaults.standard.string(forKey: SettingsKeys.tvSortDirection) ?? SortDirection.descending.rawValue {
        didSet { UserDefaults.standard.set(tvSortDirectionRaw, forKey: SettingsKeys.tvSortDirection) }
    }
    var musicSortRaw: String = UserDefaults.standard.string(forKey: SettingsKeys.musicSort) ?? LibrarySort.byTitle.rawValue {
        didSet { UserDefaults.standard.set(musicSortRaw, forKey: SettingsKeys.musicSort) }
    }
    var musicSortDirectionRaw: String = UserDefaults.standard.string(forKey: SettingsKeys.musicSortDirection) ?? SortDirection.ascending.rawValue {
        didSet { UserDefaults.standard.set(musicSortDirectionRaw, forKey: SettingsKeys.musicSortDirection) }
    }
    var movieLocalFirst: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.movieLocalFirst) {
        didSet { UserDefaults.standard.set(movieLocalFirst, forKey: SettingsKeys.movieLocalFirst) }
    }
    var tvLocalFirst: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.tvLocalFirst) {
        didSet { UserDefaults.standard.set(tvLocalFirst, forKey: SettingsKeys.tvLocalFirst) }
    }
    var musicLocalFirst: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.musicLocalFirst) {
        didSet { UserDefaults.standard.set(musicLocalFirst, forKey: SettingsKeys.musicLocalFirst) }
    }

    /// Session-only flag, not persisted. Hides all remote providers when
    /// true; resetCatalog() reloads the sections and whatever is open.
    var isOfflineMode: Bool = false {
        didSet { resetCatalog() }
    }

    /// The sections shown in the dropdown, in the order chosen in Settings >
    /// Libraries: by default Continue Watching (on unless turned off), one per
    /// library, then the video Playlists (off unless turned on) and the music
    /// Playlists (on when there is a music library).
    var enabledSections: [MenuSection] {
        orderableSections.filter { section in
            switch section {
            case .continueItems:
                (isOfflineMode || hasServers)
                    && UserDefaults.standard.object(forKey: SettingsKeys.sectionEnabled(section)) as? Bool ?? true
            case .playlists:
                UserDefaults.standard.bool(forKey: SettingsKeys.sectionEnabled(section))
            case .musicPlaylists:
                librarySections?.contains { $0.mediaType == .music } == true
            default:
                true
            }
        }
    }

    /// Section ids in the user's chosen order; empty until they reorder.
    /// Sections it doesn't mention (a newly added library) follow in their
    /// default order.
    var sectionOrder: [String] = UserDefaults.standard.stringArray(forKey: SettingsKeys.sectionOrder) ?? [] {
        didSet { UserDefaults.standard.set(sectionOrder, forKey: SettingsKeys.sectionOrder) }
    }

    /// Every section that can appear in the menu, shown or not, in menu order.
    var orderableSections: [MenuSection] {
        let sections = [.continueItems] + (librarySections ?? []) + [.playlists, .musicPlaylists]
        let rank = Dictionary(sectionOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        // Stable sort: unranked sections keep their default order, after the ranked ones.
        return sections.enumerated()
            .sorted { (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset) }
            .map(\.element)
    }

    /// Moves a section in the menu order so it takes the place of the one at `destination`.
    func moveSection(from source: Int, to destination: Int) {
        var ids = orderableSections.map(\.id)
        ids.insert(ids.remove(at: source), at: destination)
        // ponytail: ids of libraries not listed right now (server offline) move to the end
        // and lose their place; keep per-id positions if that turns out to annoy.
        sectionOrder = ids + sectionOrder.filter { !ids.contains($0) }
    }

    // MARK: - Library sections

    /// One section per library name and type across all providers, in
    /// provider order. Nil while loading.
    private(set) var librarySections: [MenuSection]?
    /// The servers behind the music (true) and the video (false) libraries,
    /// in provider order.
    private(set) var serverNamesByPane: [Bool: [String]] = [:]
    /// Shown instead of sections when no provider could list its libraries.
    private(set) var librarySectionsError: String?
    /// The provider libraries behind each library section.
    @ObservationIgnored private var sectionLibraries: [MenuSection.ID: [(providerID: String, library: MediaLibrary)]] = [:]
    @ObservationIgnored private var librarySectionsTask: Task<Void, Never>?
    /// Bumped by resetCatalog() so a superseded load discards its results.
    @ObservationIgnored private var librarySectionsGeneration = 0

    /// Loads the library sections once; concurrent callers share the request.
    func ensureLibrarySections() async {
        if librarySections != nil { return }
        let task = librarySectionsTask ?? Task { await loadLibrarySections() }
        librarySectionsTask = task
        await task.value
    }

    private func loadLibrarySections() async {
        let generation = librarySectionsGeneration
        let sources = providers()
        let results = await concurrently(sources) { provider in try await provider.libraries() }
        guard generation == librarySectionsGeneration else { return }

        var sections: [MenuSection] = []
        var mapping: [MenuSection.ID: [(providerID: String, library: MediaLibrary)]] = [:]
        var failures: [String] = []
        var serverNames: [Bool: [String]] = [:]
        let musicLibraryNames = Set(results.flatMap { (try? $0.get()) ?? [] }.filter { $0.type == .music }.map { $0.name.lowercased() })
        for (provider, result) in zip(sources, results) {
            switch result {
            case .success(let libraries):
                for library in libraries {
                    let isMusic = library.type == .music
                    if let name = provider.source.webAppName, serverNames[isMusic]?.contains(name) != true {
                        serverNames[isMusic, default: []].append(name)
                    }
                    let rows = isMusic
                        ? MusicTopLevel.allCases.map { MenuSection.musicLibrary(named: library.name, topLevel: $0, showsName: musicLibraryNames.count > 1) }
                        : [MenuSection.library(named: library.name, type: library.type)]
                    for section in rows {
                        if mapping[section.id] == nil { sections.append(section) }
                        mapping[section.id, default: []].append((provider.id, library))
                    }
                }
            case .failure(let error):
                failures.append("\(provider.source.rawValue): \(error.localizedDescription)")
            }
        }
        sectionLibraries = mapping
        librarySections = sections
        serverNamesByPane = serverNames
        librarySectionsError = sections.isEmpty && !failures.isEmpty ? failures.joined(separator: " • ") : nil
        librarySectionsTask = nil

        // Refill what was open before the sections were (re)loaded.
        if isSearchActive {
            for section in enabledSections { Task { await load(section) } }
        } else if let expandedSection {
            Task { await load(expandedSection) }
        }
    }

    /// Runs `work` for every input at once and returns the results in input
    /// order. Tasks stay on the main actor; their network waits overlap.
    private func concurrently<Input, Output: Sendable>(
        _ inputs: [Input],
        _ work: @escaping @MainActor (Input) async throws -> Output
    ) async -> [Result<Output, Error>] {
        await withTaskGroup(of: (Int, Result<Output, Error>).self) { group in
            for (index, input) in inputs.enumerated() {
                group.addTask { @MainActor in
                    var attempts = 1
                    while true {
                        do {
                            return (index, .success(try await work(input)))
                        } catch let error as URLError where error.code == .notConnectedToInternet && attempts < 4 {
                            // Right after launch, until macOS has settled the Local
                            // Network permission, LAN requests fail as if offline.
                            attempts += 1
                            try? await Task.sleep(for: .seconds(1))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
            }
            var results = [Result<Output, Error>](repeating: .failure(CancellationError()), count: inputs.count)
            for await (index, result) in group { results[index] = result }
            return results
        }
    }

    /// `musicTopLevel` only matters for listing and searching a music
    /// section; everything else (children, streams, playlists) ignores it.
    private func providers(musicTopLevel: MusicTopLevel = .album) -> [any MediaProvider] {
        if isOfflineMode {
            let local = LocalMediaProvider(tvTopLevel: tvTopLevel, musicTopLevel: musicTopLevel, includeDownloads: true)
            return local.hasContent ? [local] : []
        }
        // Local provider runs last so de-duplication in load() can filter its
        // items against server results (server poster wins when both exist).
        let local = LocalMediaProvider(tvTopLevel: tvTopLevel, musicTopLevel: musicTopLevel)
        return serverProviders(musicTopLevel: musicTopLevel) + (local.hasContent ? [local] : [])
    }

    /// Whether any media server is connected, even while Offline Mode hides it.
    var hasServers: Bool { !serverProviders().isEmpty }

    /// One provider per connected server. Adding a server type means adding
    /// it here, to `sources` and to `MediaSource`.
    private func serverProviders(musicTopLevel: MusicTopLevel = .album) -> [any MediaProvider] {
        var result: [any MediaProvider] = []
        for configuration in plexConfigurations {
            result.append(PlexMediaProvider(
                client: PlexClient(config: configuration),
                selectedLibraryKeys: selectedPlexLibraries(forServer: configuration.serverID),
                tvTopLevel: tvTopLevel,
                musicTopLevel: musicTopLevel
            ))
        }
        if let configuration = jellyfinConfiguration {
            result.append(JellyfinMediaProvider(
                client: JellyfinClient(config: configuration),
                selectedLibraryIDs: selectedLibraries(forKey: SettingsKeys.jellyfinSelectedLibraries),
                tvTopLevel: tvTopLevel,
                musicTopLevel: musicTopLevel
            ))
        }
        if let configuration = sources.navidrome {
            result.append(NavidromeMediaProvider(client: NavidromeClient(config: configuration), musicTopLevel: musicTopLevel))
        }
        if let configuration = sources.torrServer {
            result.append(TorrServerMediaProvider(client: TorrServerClient(config: configuration)))
        }
        return result
    }

    /// Resolves an item's provider using its server ID, or falls back to the first matching source.
    private func provider(for item: MediaItem) -> (any MediaProvider)? {
        let candidates = providers().filter { $0.source == item.source }
        if item.source == .plex,
           let serverID = item.attributes[PlexMediaProvider.serverIDAttribute],
           let match = candidates.first(where: { ($0 as? PlexMediaProvider)?.serverID == serverID }) {
            return match
        }
        return candidates.first
    }

    // MARK: - Catalog

    /// When each library section's catalog was last fetched.
    @ObservationIgnored private var sectionFetchedAt: [MenuSection: Date] = [:]

    /// Called each time the menu opens, so changes made elsewhere (watched on
    /// a TV, added to the server) show up without restarting: refreshes
    /// Continue Watching, and in the background every loaded library section
    /// (and its open drill-downs) not fetched in the last two minutes.
    func menuDidOpen() {
        if isContinueExpanded, enabledSections.contains(.continueItems) {
            Task { await load(.continueItems) }
        }
        guard !isFiltering else { return }
        for section in itemsBySection.keys where section.mediaType != nil {
            guard Date.now.timeIntervalSince(sectionFetchedAt[section] ?? .distantPast) >= 120 else { continue }
            sectionFetchedAt[section] = .now // don't start a second refresh while this one runs
            let openParents = drillPath[section] ?? []
            Task {
                await refreshSilently(section)
                for parent in openParents { await refreshChildrenSilently(of: parent) }
            }
        }
    }

    func toggleExpansion(of section: MenuSection) {
        if section == .continueItems {
            isContinueExpanded.toggle()
            if isContinueExpanded { Task { await load(section) } }
            return
        }
        expandedSection = expandedSection == section ? nil : section
        if expandedSection == section {
            Task { await load(section) }
        }
    }

    /// The Continue Watching items to display. In `.byAlbumPlaylist` mode, in-progress
    /// music tracks collapse into their parent album/playlist cell (deduped,
    /// most-recent first); everything else passes through unchanged.
    func continueDisplayItems() -> [MediaItem] {
        let raw = mergedContinueItems()
        guard continueMusicGrouping == .byAlbumPlaylist else { return raw }
        var result: [MediaItem] = []
        var seenContainerIDs = Set<String>()
        for item in raw {
            guard item.type == .music, item.kind == .track,
                  let parentID = item.parentID else {
                result.append(item)
                continue
            }
            guard seenContainerIDs.insert(parentID).inserted else { continue }
            result.append(containerItem(for: item, parentID: parentID))
        }
        return result
    }

    /// The servers' own Continue Watching lists; nil until fetched.
    private var serverContinueItems: [MediaItem]?
    /// When the last complete fetch of `serverContinueItems` started; nil
    /// if a server failed.
    private var serverContinueFetchedAt: Date?

    /// The servers' Continue Watching lists merged with CineTray's progress
    /// store, most recently played first. A server item in the local store
    /// that its server no longer lists (finished or removed elsewhere) is
    /// dropped, unless it was played after the list was fetched. Items the
    /// server lists without a play date (next episodes) are never too old.
    private func mergedContinueItems() -> [MediaItem] {
        let local = PlaybackProgressStore.all()
        let server = serverContinueItems ?? []
        let serverIDs = Set(server.map(\.id))
        let localDates = Dictionary(local.map { ($0.item.id, $0.updatedAt) }, uniquingKeysWith: max)
        var entries = local.filter { entry in
            !serverIDs.contains(entry.item.id)
                && !(entry.item.source.keepsWatchState && entry.updatedAt < serverContinueFetchedAt ?? .distantPast)
        }
        .map { ($0.item, $0.updatedAt) }
        let cutoff = PlaybackProgressStore.cutoff ?? .distantPast
        for item in server {
            let date = max(item.lastViewedAt ?? .distantPast, localDates[item.id] ?? .distantPast)
            if item.lastViewedAt == nil || date >= cutoff { entries.append((item, date)) }
        }
        return entries.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func refreshServerContinueItems() async {
        guard !isOfflineMode else { return }
        let started = Date.now
        let results = await concurrently(providers()) { try await $0.continueWatching() }
        serverContinueItems = results.flatMap { (try? $0.get()) ?? [] }
        serverContinueFetchedAt = results.allSatisfy { (try? $0.get()) != nil } ? started : nil
    }

    /// Synthesises the album/playlist cell that stands in for an in-progress
    /// track in the grouped Continue Watching section.
    private func containerItem(for track: MediaItem, parentID: String) -> MediaItem {
        MediaItem(
            id: parentID,
            source: track.source,
            type: .music,
            kind: track.parentKind ?? .album,
            title: track.parentTitle ?? track.subtitle ?? track.title,
            posterURL: track.parentPosterURL ?? track.posterURL,
            attributes: track.attributes
        )
    }

    /// Resumes a grouped Continue Watching album/playlist: fetches its tracks, finds the
    /// most-recent in-progress one, and starts inline playback of the container
    /// from there (startPlayback seeks music to the saved position).
    func resumeContinueContainer(_ container: MediaItem) async {
        guard let tracks = try? await provider(for: container)?.children(of: container),
              !tracks.isEmpty else { return }
        let inProgress = PlaybackProgressStore.all().first { $0.item.parentID == container.id }
        let resume = inProgress.flatMap { entry in
            tracks.first { $0.id == entry.item.id }
        } ?? inProgress?.item ?? tracks[0]
        await startPlayback(item: resume, inlinePlaylist: tracks)
    }

    func load(_ section: MenuSection, force: Bool = false) async {
        if loadingSections.contains(section) { return }
        // Continue Watching always refreshes: local progress shows at once,
        // then the servers' lists are merged in. The first time, a spinner
        // shows until they arrive, rather than a list that then reshuffles.
        if section == .continueItems {
            if serverContinueItems != nil || isOfflineMode {
                itemsBySection[section] = continueDisplayItems()
            } else {
                loadingSections.insert(section)
            }
            await refreshServerContinueItems()
            loadingSections.remove(section)
            itemsBySection[section] = continueDisplayItems()
            return
        }
        if !force, itemsBySection[section]?.isEmpty == false { return }
        loadingSections.insert(section)
        errorsBySection[section] = nil
        defer { loadingSections.remove(section) }

        let (items, failures) = await fetchCatalog(for: section)
        itemsBySection[section] = items
        sectionFetchedAt[section] = .now
        // Only surface errors when nothing loaded; partial results win.
        errorsBySection[section] = items.isEmpty && !failures.isEmpty ? failures.joined(separator: " • ") : nil
        // Deep-search matches are placed by the section items they belong
        // to, so redo the search once this section's items are known.
        if isSearchActive, !trimmedQuery.isEmpty { scheduleDeepSearch() }
    }

    private func fetchCatalog(for section: MenuSection) async -> (items: [MediaItem], failures: [String]) {
        // Query every source at once; results come back in source order so
        // the merged list is stable.
        let sources: [(provider: any MediaProvider, library: MediaLibrary?)]
        if section.mediaType != nil {
            await ensureLibrarySections()
            let available = providers(musicTopLevel: section.musicTopLevel ?? .album)
            sources = (sectionLibraries[section.id] ?? []).compactMap { entry in
                available.first { $0.id == entry.providerID }.map { ($0, entry.library) }
            }
        } else {
            sources = providers().map { ($0, nil) }
        }
        let results = await concurrently(sources) { source in
            if let library = source.library {
                return try await source.provider.items(inLibrary: library)
            }
            return try await source.provider.playlists().filter { ($0.type == .music) == (section == .musicPlaylists) }
        }

        var serverItems: [MediaItem] = []
        var localItems: [MediaItem] = []
        var failures: [String] = []
        for (source, result) in zip(sources, results) {
            switch result {
            case .success(let sourceItems) where source.provider.source == .local:
                localItems += sourceItems
            case .success(let sourceItems):
                serverItems += sourceItems
            case .failure(let error):
                failures.append("\(source.provider.source.rawValue): \(error.localizedDescription)")
            }
        }
        // De-dupe: local items only appear when no server item with the same
        // id exists. When a server is connected and has the item, its poster
        // gets the green tick via DownloadManager.isDownloaded; the local
        // entry would be a duplicate.
        let serverIDs = Set(serverItems.map(\.id))
        return (serverItems + localItems.filter { !serverIDs.contains($0.id) }, failures)
    }

    /// Re-fetches a loaded section without the spinner, keeping the current
    /// items if any source fails.
    private func refreshSilently(_ section: MenuSection) async {
        guard itemsBySection[section] != nil, !loadingSections.contains(section) else { return }
        let (items, failures) = await fetchCatalog(for: section)
        guard failures.isEmpty else { return }
        itemsBySection[section] = items
        sectionFetchedAt[section] = .now
    }

    /// Re-fetches a cached drill-down (a show's seasons, a season's episodes) in place.
    private func refreshChildrenSilently(of container: MediaItem) async {
        guard childrenByItemID[container.id] != nil,
              let children = try? await provider(for: container)?.children(of: container) else { return }
        childrenByItemID[container.id] = children
        // Close an open level whose item is gone.
        for (section, path) in drillPath {
            if let index = path.firstIndex(where: { $0.id == container.id }), index + 1 < path.count,
               !children.contains(where: { $0.id == path[index + 1].id }) {
                drillPath[section] = Array(path.prefix(through: index))
            }
        }
    }

    /// After a server video stops, its watched state (and its season's and
    /// show's) may have changed, so Continue Watching, the loaded sections of
    /// that type and the cached drill-downs containing it are re-fetched.
    /// Waits briefly so Plex has processed the final timeline report.
    private func refreshAfterPlayback(of item: MediaItem) {
        guard item.source.keepsWatchState, item.type != .music else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if itemsBySection[.continueItems] != nil { await load(.continueItems) }
            for section in itemsBySection.keys where section.mediaType == item.type {
                await refreshSilently(section)
            }
            let containerIDs = [item.parentID, item.attributes["grandparentRatingKey"]].compactMap { $0 }
            for parents in drillPath.values {
                for parent in parents where containerIDs.contains(parent.id) {
                    await refreshChildrenSilently(of: parent)
                }
            }
        }
    }

    /// Bumped whenever the connected Plex servers (or their tokens) change,
    /// so the Libraries tab can reload without reopening.
    private(set) var serverConfigurationVersion = 0

    /// Called by Settings after adding/removing servers or editing tokens.
    func plexServersChanged() {
        serverConfigurationVersion += 1
        resetCatalog()
    }

    /// Clears cached catalogs, e.g. after backend settings change.
    func resetCatalog() {
        cachedSources = nil
        librarySectionsGeneration += 1
        librarySectionsTask = nil
        librarySections = nil
        librarySectionsError = nil
        sectionLibraries = [:]
        Task { await ensureLibrarySections() }
        itemsBySection = [:]
        errorsBySection = [:]
        drillPath = [:]
        childrenByItemID = [:]
        childErrorsByItemID = [:]
        serverContinueItems = nil
        serverContinueFetchedAt = nil
        sectionFetchedAt = [:]
    }

    // MARK: - Search

    /// Deep-search results: matched top-level items per section, plus the
    /// filtered children for each matched ancestor (shown in drill levels
    /// while the search is active).
    private(set) var deepSearchItems: [MenuSection: [MediaItem]] = [:]
    private(set) var deepSearchChildren: [String: [MediaItem]] = [:]
    private var deepSearchTask: Task<Void, Never>?

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// True while a query is typed: the menu then shows only the sections
    /// with matches, all expanded.
    var isFiltering: Bool {
        isSearchActive && !trimmedQuery.isEmpty
    }

    /// True while the server-side deep search for the current query runs.
    private(set) var isDeepSearching = false

    /// Whether search results may still arrive: a catalog is still loading
    /// or the deep search is running.
    var isSearchPending: Bool {
        isDeepSearching || librarySections == nil || enabledSections.contains { section in
            loadingSections.contains(section) || itemsBySection[section] == nil
        }
    }

    /// Loads every catalog in the background so typing filters across
    /// everything at once. Sections expand only once there is a query.
    func activateSearch() {
        guard !isSearchActive else { return }
        isSearchActive = true
        for section in enabledSections {
            Task { await load(section) }
        }
    }

    func deactivateSearch() {
        isSearchActive = false
        searchText = ""
        isDeepSearching = false
        deepSearchTask?.cancel()
        deepSearchItems = [:]
        deepSearchChildren = [:]
    }

    /// Kicks off a debounced backend search that matches titles anywhere in
    /// the hierarchy (tracks, episodes) and maps them back to their
    /// top-level ancestors.
    func scheduleDeepSearch() {
        deepSearchTask?.cancel()
        let query = trimmedQuery
        guard !query.isEmpty else {
            deepSearchItems = [:]
            deepSearchChildren = [:]
            isDeepSearching = false
            return
        }
        isDeepSearching = true
        deepSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            var newItems: [MenuSection: [MediaItem]] = [:]
            var newChildren: [String: [MediaItem]] = [:]
            let sections = enabledSections.filter { $0.mediaType != nil }
            // Search once per media type (music once per top level, since the
            // chains start at the artist or the album), then place each match
            // in the library section whose items contain its top-level ancestor.
            for mediaType in MediaType.allCases {
                for topLevel in Set(sections.filter { $0.mediaType == mediaType }.map(\.musicTopLevel)) {
                    let candidates = sections.filter { $0.mediaType == mediaType && $0.musicTopLevel == topLevel }.map { section in
                        (section, Set(itemsBySection[section]?.map(\.id) ?? []))
                    }
                    var chains: [[MediaItem]] = []
                    for provider in providers(musicTopLevel: topLevel ?? .album) {
                        chains += (try? await provider.deepSearch(query, type: mediaType)) ?? []
                    }
                    for chain in chains {
                        guard let top = chain.first,
                              let section = candidates.first(where: { $0.1.contains(top.id) })?.0 else { continue }
                        if !(newItems[section] ?? []).contains(where: { $0.id == top.id }) {
                            newItems[section, default: []].append(top)
                        }
                        for (parent, child) in zip(chain, chain.dropFirst())
                        where !(newChildren[parent.id] ?? []).contains(where: { $0.id == child.id }) {
                            newChildren[parent.id, default: []].append(child)
                        }
                    }
                }
            }
            // Drop stale results if the query moved on while we searched.
            guard !Task.isCancelled, trimmedQuery == query else { return }
            deepSearchItems = newItems
            deepSearchChildren = newChildren
            isDeepSearching = false
        }
    }

    /// The items to show for a section: the full catalog normally, or -
    /// while searching - direct title/subtitle matches merged with the
    /// ancestors of deep matches. Nil when the catalog hasn't loaded yet.
    /// Items are ordered by the current sort preference for the section.
    func displayedItems(for section: MenuSection) -> [MediaItem]? {
        guard let items = itemsBySection[section] else { return nil }
        let query = trimmedQuery
        var result: [MediaItem]
        if isSearchActive, !query.isEmpty {
            var merged = items.filter { item in
                searchMatches(item.title, query: query)
                    || item.subtitle.map { searchMatches($0, query: query) } ?? false
            }
            for deep in deepSearchItems[section] ?? [] where !merged.contains(where: { $0.id == deep.id }) {
                merged.append(deep)
            }
            result = merged
        } else {
            result = items
        }
        return sortedItems(result, for: section)
    }

    private func sortedItems(_ items: [MediaItem], for section: MenuSection) -> [MediaItem] {
        let sortRaw: String, directionRaw: String, applyLocalFirst: Bool
        switch section.mediaType {
        case .movies: (sortRaw, directionRaw, applyLocalFirst) = (movieSortRaw, movieSortDirectionRaw, movieLocalFirst)
        case .tvShows: (sortRaw, directionRaw, applyLocalFirst) = (tvSortRaw, tvSortDirectionRaw, tvLocalFirst)
        case .music: (sortRaw, directionRaw, applyLocalFirst) = (musicSortRaw, musicSortDirectionRaw, musicLocalFirst)
        case nil: return items
        }
        let sort = LibrarySort(rawValue: sortRaw) ?? .byTitle
        let descending = SortDirection(rawValue: directionRaw) == .descending
        var sorted = items.sorted { a, b in
            sort.areInOrder(a, b, descending: descending)
        }
        if applyLocalFirst {
            let downloadedIDs = section.mediaType.flatMap { DownloadManager.shared.downloadedIDs[$0] } ?? []
            if !downloadedIDs.isEmpty {
                let locals = sorted.filter { downloadedIDs.contains($0.id) }
                let remotes = sorted.filter { !downloadedIDs.contains($0.id) }
                sorted = locals + remotes
            }
        }
        return sorted
    }

    /// Children shown in a drill level: the search-filtered subset while a
    /// query is active (when the backend matched below this container),
    /// otherwise the full cached children.
    func displayedChildren(of item: MediaItem) -> [MediaItem]? {
        if isSearchActive, !trimmedQuery.isEmpty, let filtered = deepSearchChildren[item.id] {
            return filtered
        }
        return childrenByItemID[item.id]
    }

    // MARK: - Drill-down (show → seasons → episodes, artist → albums → tracks)

    /// Expands a container into a child carousel, or collapses it (and any
    /// deeper levels) when it's already open. Selecting a sibling swaps the
    /// levels below it.
    func toggleDrill(_ item: MediaItem, in section: MenuSection) {
        var path = drillPath[section] ?? []
        if let index = path.firstIndex(where: { $0.id == item.id }) {
            path.removeSubrange(index...)
        } else if let parentIndex = path.firstIndex(where: { parent in
            childrenByItemID[parent.id]?.contains { $0.id == item.id } ?? false
        }) {
            path = Array(path.prefix(parentIndex + 1)) + [item]
            loadChildrenIfNeeded(of: item)
        } else {
            // Top-level selection replaces the whole path.
            path = [item]
            loadChildrenIfNeeded(of: item)
        }
        drillPath[section] = path
    }

    /// The selected child at the level below `parent`, for highlighting.
    func drilledChildID(under parent: MediaItem, in section: MenuSection) -> String? {
        guard let path = drillPath[section],
              let index = path.firstIndex(where: { $0.id == parent.id }),
              path.indices.contains(index + 1) else {
            return nil
        }
        return path[index + 1].id
    }

    func loadChildrenIfNeeded(of item: MediaItem) {
        // Search results already carry their filtered children.
        if isSearchActive, !trimmedQuery.isEmpty, deepSearchChildren[item.id] != nil { return }
        guard childrenByItemID[item.id] == nil, !loadingChildrenIDs.contains(item.id) else { return }
        loadingChildrenIDs.insert(item.id)
        childErrorsByItemID[item.id] = nil
        Task {
            defer { loadingChildrenIDs.remove(item.id) }
            do {
                guard let provider = provider(for: item) else {
                    throw URLError(.resourceUnavailable)
                }
                childrenByItemID[item.id] = try await provider.children(of: item)
            } catch {
                childErrorsByItemID[item.id] = error.localizedDescription
            }
        }
    }

    func streamURL(for item: MediaItem) async throws -> URL {
        // Prefer locally downloaded copy so playback works offline and avoids
        // a network stream for content already on disk.
        if let localURL = DownloadManager.shared.localURL(for: item) {
            return localURL
        }
        guard let provider = provider(for: item) else {
            throw URLError(.resourceUnavailable)
        }
        return try await provider.streamURL(for: item)
    }

    /// The item's page in its server's web app (Plex Web or Jellyfin), or
    /// nil for local items or when the server can't be reached.
    func webURL(for item: MediaItem) async -> URL? {
        try? await provider(for: item)?.webURL(for: item)
    }

    /// Opens the item's page in its server's web app, or beeps when the
    /// server can't be reached.
    func openInWebApp(_ item: MediaItem) {
        Task {
            if let url = await webURL(for: item) {
                NSWorkspace.shared.open(url)
            } else {
                NSSound.beep()
            }
        }
    }

    /// The app chosen in Settings > Playback for video, or nil for CineTray's own player.
    var externalVideoPlayer: URL? {
        UserDefaults.standard.string(forKey: SettingsKeys.videoPlayerApp).flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
    }

    /// Hands the item's stream to another app. That app starts from the
    /// beginning and CineTray can't follow it, so there is no resume, progress,
    /// scrobbling or auto-continue.
    func play(_ item: MediaItem, in app: URL) {
        Task {
            do {
                let readsPlaylists = NSWorkspace.shared.urlsForApplications(toOpen: .m3uPlaylist).contains { $0.path == app.path }
                // Players that read playlists (VLC, IINA) read any container,
                // so they get the original file with every subtitle and audio
                // track; the stream converted for AVPlayer can lose them (Plex
                // keeps none). QuickTime Player needs that stream.
                var url = if readsPlaylists, DownloadManager.shared.localURL(for: item) == nil, let provider = provider(for: item) {
                    try await provider.originalFileURL(for: item)
                } else {
                    try await streamURL(for: item)
                }
                if !url.isFileURL, readsPlaylists {
                    url = try Self.playlist(for: item, streaming: url)
                }
                try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// A one-entry M3U playlist, so players that read one (VLC, IINA) show
    /// the title instead of the stream URL with its token, and list the
    /// playlist rather than that URL in their recent items. Only the latest
    /// playlist is kept, and none after CineTray quits, since its URL
    /// carries the token.
    private static func playlist(for item: MediaItem, streaming url: URL) throws -> URL {
        let folder = playlistFolder
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: item.title.replacing(/[\/:]/, with: "-") + ".m3u")
        // A line break in a server title would start another playlist entry.
        let title = item.title.replacing(/[\r\n]/, with: " ")
        try "#EXTM3U\n#EXTINF:-1,\(title)\n\(url.absoluteString)\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static let playlistFolder = URL.temporaryDirectory.appending(path: "CineTray Playback")

    func downloadURL(for item: MediaItem) async throws -> URL {
        guard let provider = provider(for: item) else {
            throw URLError(.resourceUnavailable)
        }
        return try await provider.downloadURL(for: item)
    }

    /// All playable (non-expandable) descendants of a container, fetched by
    /// recursing through the provider's children hierarchy. Used by
    /// DownloadManager to expand a container download into individual files.
    func playableDescendants(of item: MediaItem) async -> [MediaItem] {
        guard item.kind.isExpandable else { return [item] }
        guard let provider = provider(for: item) else { return [] }
        do {
            let children = try await provider.children(of: item)
            var leaves: [MediaItem] = []
            for child in children {
                leaves += await playableDescendants(of: child)
            }
            return leaves
        } catch {
            return []
        }
    }

    /// Returns all playable (non-expandable) descendants of a container, each paired
    /// with its ancestor chain (outermost container first). Used by DownloadManager
    /// to build hierarchical file paths that mirror the Plex/CineTray library hierarchy.
    func downloadLeaves(of item: MediaItem, ancestors: [MediaItem] = []) async -> [(item: MediaItem, ancestors: [MediaItem])] {
        guard item.kind.isExpandable else { return [(item, ancestors)] }
        guard let provider = provider(for: item) else { return [] }
        do {
            let children = try await provider.children(of: item)
            var results: [(MediaItem, [MediaItem])] = []
            for child in children {
                results += await downloadLeaves(of: child, ancestors: ancestors + [item])
            }
            return results
        } catch {
            return []
        }
    }

    // MARK: - Queue & auto-continue

    /// The item's siblings within its container, fetching (and caching) them
    /// if the drill-down hasn't already.
    func siblings(of item: MediaItem) async -> [MediaItem]? {
        guard let parentID = item.parentID else { return nil }
        if let cached = childrenByItemID[parentID] { return cached }
        let parentStub = MediaItem(
            id: parentID,
            source: item.source,
            type: item.type,
            kind: item.parentKind ?? (item.kind == .episode ? .season : .album),
            title: ""
        )
        let fetched = try? await provider(for: item)?.children(of: parentStub)
        if let fetched { childrenByItemID[parentID] = fetched }
        return fetched
    }

    /// The remaining items after `item` in its container - the music
    /// window's "Up Next" queue.
    func upcomingQueue(after item: MediaItem) async -> [MediaItem] {
        guard let siblings = await siblings(of: item),
              let index = siblings.firstIndex(where: { $0.id == item.id }) else {
            return []
        }
        return Array(siblings.dropFirst(index + 1))
    }

    /// What to play next when `item` finishes, per the Playback preferences.
    /// Nil means stop.
    func autoContinueItem(after item: MediaItem) async -> MediaItem? {
        switch item.type {
        case .movies:
            guard movieAutoContinue != .off else { return nil }
            return try? await provider(for: item)?.nextMovie(after: item, by: movieAutoContinue)
        case .tvShows:
            guard tvAutoContinue, item.kind == .episode else { return nil }
            return await nextSibling(after: item)
        case .music:
            guard item.kind == .track else { return nil }
            switch musicAutoContinue {
            case .off:
                // "Off" still finishes the album/playlist in order.
                return await nextSibling(after: item)
            case .inSequence:
                return await nextSibling(after: item)
            case .shuffleByGenre:
                return try? await provider(for: item)?.randomTrack(sameArtistAs: item)
            }
        }
    }

    /// The next item in the same container (next episode in a season, next
    /// track on an album/playlist).
    private func nextSibling(after item: MediaItem) async -> MediaItem? {
        guard let siblings = await siblings(of: item),
              let index = siblings.firstIndex(where: { $0.id == item.id }),
              siblings.indices.contains(index + 1) else {
            return nil
        }
        return siblings[index + 1]
    }

    // MARK: - Playback reporting

    /// Fans playback state out to the local Continue Watching store, the item's
    /// server (resume position) and, on transitions, to Trakt (movies) and
    /// Last.fm (music).
    func reportPlayback(item: MediaItem, state: PlaybackState, positionSeconds: Double, durationSeconds: Double) {
        PlaybackProgressStore.update(item: item, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
        if state == .stopped { refreshAfterPlayback(of: item) }
        if itemsBySection[.continueItems] != nil {
            itemsBySection[.continueItems] = continueDisplayItems()
        }

        updateNowPlayingInfo(item: item, state: state, positionSeconds: positionSeconds, durationSeconds: durationSeconds)

        guard item.source != .sample, item.source != .local else { return }
        Task {
            try? await provider(for: item)?.reportPlayback(
                of: item,
                state: state,
                positionSeconds: positionSeconds,
                durationSeconds: durationSeconds
            )

            // Scrobblers only care about transitions, not periodic progress.
            guard state != .playing else { return }
            let progressPercent = durationSeconds > 0 ? positionSeconds / durationSeconds * 100 : 0
            await scrobble(item: item, state: state, progressPercent: progressPercent)
        }
    }

    private func updateNowPlayingInfo(item: MediaItem, state: PlaybackState, positionSeconds: Double, durationSeconds: Double) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.useMediaKeys) else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }

        if state == .stopped {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = item.title
        if let subtitle = item.subtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionSeconds
        if durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = state == .playing ? 1.0 : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state == .playing ? .playing : .paused
    }

    private func scrobble(item: MediaItem, state: PlaybackState, progressPercent: Double) async {
        switch item.type {
        case .movies, .tvShows:
            guard let token = KeychainStore.string(for: KeychainKeys.traktAccessToken), !token.isEmpty,
                  let media = Self.traktMedia(for: item) else { return }
            let client = TraktClient()
            do {
                try await client.scrobble(state: state, media: media, progressPercent: progressPercent, accessToken: token)
            } catch TraktError.unauthorized {
                guard let refreshToken = KeychainStore.string(for: KeychainKeys.traktRefreshToken) else { return }
                if let (newAccess, newRefresh) = try? await TraktClient.refreshAccessToken(refreshToken) {
                    KeychainStore.set(newAccess, for: KeychainKeys.traktAccessToken)
                    KeychainStore.set(newRefresh, for: KeychainKeys.traktRefreshToken)
                    try? await client.scrobble(state: state, media: media, progressPercent: progressPercent, accessToken: newAccess)
                }
            } catch {
                // Scrobble errors are silently ignored.
            }
        case .music:
            // Scrobble once, when playback ends past the halfway mark.
            guard state == .stopped, progressPercent > 50,
                  let sessionKey = KeychainStore.string(for: KeychainKeys.lastfmSessionKey), !sessionKey.isEmpty,
                  let artist = item.subtitle else {
                return
            }
            try? await LastFMClient().scrobble(artist: artist, track: item.title, sessionKey: sessionKey)
        }
    }

    /// What Trakt matches a scrobble on: a movie by title and year, an
    /// episode by its show's title and the "S1E3" code every source puts in
    /// the subtitle. Nil when an episode lacks either.
    private static func traktMedia(for item: MediaItem) -> [String: Any]? {
        if item.type == .movies {
            var movie: [String: Any] = ["title": item.title]
            if let year = item.year { movie["year"] = year }
            return ["movie": movie]
        }
        guard item.kind == .episode, let show = item.attributes["grandparentTitle"], !show.isEmpty,
              let code = item.subtitle?.wholeMatch(of: /S(\d+)E(\d+)/),
              let season = Int(code.1), let number = Int(code.2) else { return nil }
        return ["show": ["title": show], "episode": ["season": season, "number": number]]
    }

    // MARK: - Local Library refresh (indexing + metadata scraping)

    /// Scans each library folder, indexes newly dropped files so they are
    /// playable, and fetches cover art / metadata from the music artwork
    /// sources, Trakt and TMDb for items that don't have it yet. Idempotent: items that already
    /// have a posterURL are not re-scraped.
    func refreshLocalLibrary() async {
        let tmdbKey = KeychainStore.stringMigratingFromDefaults(for: KeychainKeys.tmdbAPIKey)

        let tmdb = tmdbKey.map { TMDbClient(apiKey: $0) }
        let trakt = TraktClient()
        // Every track of an album asks for the same cover; MusicBrainz alone
        // allows one request per second.
        var musicArtwork: [String: URL?] = [:]

        for type in MediaType.allCases {
            guard let folder = DownloadManager.resolvedLibraryFolder(for: type) else { continue }
            let scanned = LocalLibraryScanner(type: type, folder: folder).scan()
            let existingByID: [String: DownloadIndexEntry] = {
                var d: [String: DownloadIndexEntry] = [:]
                for e in DownloadManager.libraryIndexedEntries(for: type) { d[e.item.id] = e }
                return d
            }()

            var enriched: [DownloadIndexEntry] = []
            for entry in scanned {
                // Preserve already-scraped items without hitting the network again.
                if let existing = existingByID[entry.item.id], existing.item.posterURL != nil {
                    enriched.append(existing)
                    continue
                }

                var item = entry.item
                switch type {
                case .music:
                    let artist = item.kind == .artist ? item.title : item.subtitle ?? ""
                    let album = item.kind == .album ? item.title : item.parentTitle ?? ""
                    let key = "\(artist)\n\(album)"
                    if let cached = musicArtwork[key] {
                        item.posterURL = cached
                    } else {
                        item.posterURL = await MusicArtworkSource.imageURL(artist: artist, album: album)
                        musicArtwork[key] = item.posterURL
                    }
                case .movies:
                    var tmdbID: Int?
                    tmdbID = await trakt.searchMovie(title: item.title, year: item.year)?.tmdbID
                    if tmdbID == nil, let t = tmdb {
                        tmdbID = await t.searchMovie(title: item.title, year: item.year)?.tmdbID
                    }
                    if let id = tmdbID, let t = tmdb,
                       let path = await t.moviePosterPath(tmdbID: id) {
                        item.posterURL = TMDbClient.posterURL(path: path)
                    }
                case .tvShows:
                    // Derive the show title from the filename path: first component
                    // is the show folder (e.g. "Breaking Bad/Season 1/S01E01.mkv").
                    let showTitle: String = entry.filename.map { f in
                        String(f.split(separator: "/").first ?? "")
                    } ?? item.title
                    var tmdbID: Int?
                    tmdbID = await trakt.searchShow(title: showTitle)?.tmdbID
                    if tmdbID == nil, let t = tmdb {
                        tmdbID = await t.searchTV(title: showTitle)?.tmdbID
                    }
                    if let id = tmdbID, let t = tmdb,
                       let path = await t.tvPosterPath(tmdbID: id) {
                        item.posterURL = TMDbClient.posterURL(path: path)
                    }
                }
                enriched.append(DownloadIndexEntry(item: item, filename: entry.filename))
            }

            DownloadManager.mergeLibraryIndex(enriched, for: type)
        }

        resetCatalog()
    }

    // MARK: - Playback service (shared audio engine for inline and popout modes)

    var currentItem: MediaItem?
    var player: AVPlayer?
    /// SwiftVLC bridge for local files in containers AVFoundation can't decode (e.g. .mkv).
    /// Exactly one of `player` and `vlcBridge` is non-nil during a session.
    private(set) var vlcBridge: VLCPlayerBridge?
    var isPlaying = false
    var currentTime: Double = 0
    var totalDuration: Double = 0
    var isScrubbing = false
    /// Seconds to show video subtitles later (negative: earlier), for the current item.
    var subtitleOffset: Double = 0 {
        didSet { vlcBridge?.setSubtitleDelay(subtitleOffset) }
    }
    /// Subtitles of the AVPlayer video, which CineTray draws itself.
    private(set) var subtitleCues: SubtitleCues?
    var volume: Float = 1.0
    /// Non-nil error message to display in the player window when a session fails.
    var playbackError: String?
    /// The item of the latest `startPlayback`, which `playbackError` refers
    /// to; `currentItem` is already nil once playback has failed.
    private(set) var lastStartedItem: MediaItem?
    /// Ordered track list backing the active inline (menu-bar carousel)
    /// session; nil when playback belongs to a player window.
    private(set) var inlinePlaylist: [MediaItem]?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    /// Bumped whenever a session starts or stops so async work from a
    /// superseded session can detect it should bail out.
    private var playbackGeneration = 0
    private var endObservationTask: Task<Void, Never>?
    /// Notification posted by the SwiftVLC event watcher when playback ends
    /// naturally; PlayerView.watchForPlaybackEnd listens for it.
    static let vlcPlaybackEndedNotification = NSNotification.Name("CineTray.VLCPlaybackEnded")

    /// True when either engine is active and ready for transport controls.
    var hasActivePlayer: Bool { player != nil || vlcBridge != nil }

    /// Set by "Play from Beginning": the next start of this item ignores its
    /// resume point.
    var startOverItemID: String?

    /// Where to start `item`: the more recent of CineTray's saved position and
    /// the server's resume point (which may come from another device).
    private func resumePosition(for item: MediaItem) -> Double? {
        let local = PlaybackProgressStore.entry(forItemID: item.id)
        let position = if let local, local.updatedAt >= item.lastViewedAt ?? .distantPast {
            local.positionSeconds
        } else {
            item.resumePositionSeconds
        }
        return position.flatMap { $0 > 5 ? $0 : nil }
    }

    func startPlayback(item: MediaItem, inlinePlaylist: [MediaItem]? = nil) async {
        let resume = startOverItemID == item.id ? nil : resumePosition(for: item)
        startOverItemID = nil
        playbackGeneration += 1
        let generation = playbackGeneration
        tearDownPlayer()
        currentItem = item
        lastStartedItem = item
        subtitleOffset = 0
        playbackError = nil
        self.inlinePlaylist = inlinePlaylist
        do {
            let vlcPlayback = DownloadManager.shared.localURL(for: item) == nil && item.type != .music
                ? try await provider(for: item)?.vlcPlayback(for: item) : nil
            let url = if let vlcPlayback { vlcPlayback.file } else { try await streamURL(for: item) }
            // Another session started (or the window closed) while the
            // stream URL resolved; playing now would leave orphaned audio.
            guard generation == playbackGeneration else { return }

            if vlcPlayback == nil, isAVFoundationPlayable(url) {
                // ── AVPlayer path (streaming + compatible local files) ──────────
                let newPlayer = AVPlayer(url: url)
                newPlayer.volume = volume
                player = newPlayer

                if let resume {
                    await newPlayer.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
                newPlayer.play()
                reportPlayback(item: item, state: .started, positionSeconds: 0, durationSeconds: 0)

                var lastReport = Date.distantPast
                timeObserver = newPlayer.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                    queue: .main
                ) { [weak self] time in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        guard let self, let player = self.player else { return }
                        self.totalDuration = self.duration(of: player)
                        if !self.isScrubbing {
                            self.currentTime = time.seconds
                        }
                        if player.timeControlStatus == .playing, Date.now.timeIntervalSince(lastReport) >= 15 {
                            let dur = self.totalDuration
                            self.reportPlayback(
                                item: item,
                                state: .playing,
                                positionSeconds: time.seconds,
                                durationSeconds: dur
                            )
                            lastReport = .now
                        }
                    }
                }

                statusObservation = newPlayer.observe(\.timeControlStatus, options: [.old, .new]) { [weak self] _, _ in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        guard let self, let player = self.player else { return }
                        self.isPlaying = player.timeControlStatus == .playing
                        let state: PlaybackState? = switch player.timeControlStatus {
                        case .playing: .playing
                        case .paused: .paused
                        default: nil
                        }
                        if let state {
                            self.reportPlayback(
                                item: item,
                                state: state,
                                positionSeconds: player.currentTime().seconds,
                                durationSeconds: self.duration(of: player)
                            )
                        }
                    }
                }

                // A stream AVPlayer can't open never leaves the loading state
                // on its own; only the item's status reports the failure.
                itemStatusObservation = newPlayer.currentItem?.observe(\.status, options: .initial) { [weak self] playerItem, _ in
                    guard playerItem.status == .failed else { return }
                    let message = playerItem.error?.localizedDescription ?? "Playback failed"
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.playbackGeneration else { return }
                        self.stopPlayback()
                        self.playbackError = message
                    }
                }

                // Inline sessions have no player window watching for track end,
                // so the engine advances through the playlist itself.
                if inlinePlaylist != nil, let playerItem = newPlayer.currentItem {
                    endObservationTask = Task { @MainActor [weak self] in
                        for await _ in NotificationCenter.default.notifications(
                            named: AVPlayerItem.didPlayToEndTimeNotification,
                            object: playerItem
                        ) {
                            break
                        }
                        guard let self, !Task.isCancelled,
                              generation == self.playbackGeneration else { return }
                        self.handleInlineTrackEnd()
                    }
                }

                if item.type != .music, let playerItem = newPlayer.currentItem {
                    let cues = SubtitleCues()
                    playerItem.add(cues.output)
                    subtitleCues = cues
                    cues.group = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible)
                }
            } else {
                // ── SwiftVLC path (files AVFoundation can't decode, e.g. .mkv, and Jellyfin subtitle files) ──
                await startVLCBridgePlayback(vlcPlayback ?? VLCPlayback(file: url), item: item, inlinePlaylist: inlinePlaylist, resumeAt: resume, generation: generation)
            }
        } catch {
            if generation == playbackGeneration {
                currentItem = nil
                playbackError = error.localizedDescription
            }
        }
    }

    /// Starts the SwiftVLC engine for a file whose container AVFoundation
    /// cannot play, or that has subtitle files to add. Kept separate so the
    /// AVPlayer path above stays readable.
    @MainActor
    private func startVLCBridgePlayback(
        _ playback: VLCPlayback,
        item: MediaItem,
        inlinePlaylist: [MediaItem]?,
        resumeAt: Double?,
        generation: Int
    ) async {
        guard generation == playbackGeneration else { return }
        let bridge = VLCPlayerBridge()
        vlcBridge = bridge
        // Store the URL for deferred play - VLCVideoPlayerView.onAppear calls
        // playPending() once its NSView is attached to the window hierarchy.
        // Calling play() before VideoView appears causes libVLC's video output
        // module to crash with "cannot create video output window without NSApplication".
        bridge.setPending(playback)
        try? bridge.setVolume(volume)
        reportPlayback(item: item, state: .started, positionSeconds: 0, durationSeconds: 0)

        // Poll the bridge's @Observable mirrors every 400 ms to sync transport state
        // and detect end-of-item. libVLC often never emits a raw lengthChanged event,
        // so polling the Player's native properties is the reliable path.
        endObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastReport = Date.distantPast
            var wasPlaying = false
            // libVLC can only seek once the media is open.
            var pendingResume = resumeAt
            while !Task.isCancelled, generation == self.playbackGeneration {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, generation == self.playbackGeneration else { break }

                if let resume = pendingResume, bridge.isSeekable, bridge.durationSeconds > 0 {
                    try? bridge.seek(toSeconds: resume)
                    pendingResume = nil
                }

                let duration = bridge.durationSeconds
                let time = bridge.currentTimeSeconds
                let playing = bridge.isPlaying

                self.totalDuration = duration
                if !self.isScrubbing { self.currentTime = time }

                if playing != wasPlaying {
                    self.isPlaying = playing
                    let state: PlaybackState = playing ? .playing : .paused
                    self.reportPlayback(item: item, state: state,
                                        positionSeconds: time, durationSeconds: duration)
                    wasPlaying = playing
                } else if playing, Date.now.timeIntervalSince(lastReport) >= 15 {
                    self.reportPlayback(item: item, state: .playing,
                                        positionSeconds: time, durationSeconds: duration)
                    lastReport = .now
                }

                if bridge.didReachEnd {
                    if inlinePlaylist != nil {
                        self.handleInlineTrackEnd()
                    } else {
                        NotificationCenter.default.post(
                            name: AppState.vlcPlaybackEndedNotification, object: nil
                        )
                    }
                    return
                }

                if bridge.isError {
                    self.stopPlayback()
                    self.playbackError = "Playback failed"
                    return
                }
            }
        }
    }

    func togglePlayPause() {
        if let player {
            isPlaying ? player.pause() : player.play()
        } else {
            vlcBridge?.togglePlayPause()
        }
    }

    func seek(to seconds: Double) {
        if let player {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        } else {
            try? vlcBridge?.seek(toSeconds: seconds)
        }
    }

    func setVolume(_ newVolume: Float) {
        volume = max(0, min(1, newVolume))
        player?.volume = volume
        try? vlcBridge?.setVolume(volume)
    }

    /// Plays the playlist item `offset` positions from the current track in
    /// the active inline session (+1 = next, -1 = previous).
    func playInlineNeighbor(_ offset: Int) {
        guard let playlist = inlinePlaylist,
              let currentItem,
              let index = playlist.firstIndex(where: { $0.id == currentItem.id }),
              playlist.indices.contains(index + offset) else { return }
        let target = playlist[index + offset]
        Task {
            await startPlayback(item: target, inlinePlaylist: playlist)
        }
    }

    /// Whether the active inline session has a track `offset` positions from
    /// the current one (enables/disables the overlay's skip buttons).
    func hasInlineNeighbor(_ offset: Int) -> Bool {
        guard let playlist = inlinePlaylist,
              let currentItem,
              let index = playlist.firstIndex(where: { $0.id == currentItem.id }) else { return false }
        return playlist.indices.contains(index + offset)
    }

    private func handleInlineTrackEnd() {
        guard let playlist = inlinePlaylist, let finished = currentItem else { return }
        stopPlayback(atEnd: true)
        guard let index = playlist.firstIndex(where: { $0.id == finished.id }),
              playlist.indices.contains(index + 1) else { return }
        Task {
            await startPlayback(item: playlist[index + 1], inlinePlaylist: playlist)
        }
    }

    func stopPlayback(atEnd: Bool = false) {
        playbackGeneration += 1
        if let player, let currentItem {
            let dur = duration(of: player)
            reportPlayback(
                item: currentItem,
                state: .stopped,
                positionSeconds: atEnd ? dur : player.currentTime().seconds,
                durationSeconds: dur
            )
        } else if let currentItem {
            let pos = atEnd ? totalDuration : currentTime
            reportPlayback(item: currentItem, state: .stopped,
                           positionSeconds: pos, durationSeconds: totalDuration)
        }
        tearDownPlayer()
        currentItem = nil
        inlinePlaylist = nil
    }

    /// Stops playback only if `item` still owns the engine - a stale window
    /// closing must not kill a session another player has since started.
    func stopPlayback(if item: MediaItem) {
        guard currentItem?.id == item.id else { return }
        stopPlayback()
    }

    private func tearDownPlayer() {
        endObservationTask?.cancel()
        endObservationTask = nil
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation = nil
        itemStatusObservation = nil
        player?.pause()
        player = nil
        vlcBridge?.stop()
        vlcBridge = nil
        subtitleCues = nil
        isPlaying = false
        currentTime = 0
        totalDuration = 0
    }

    private func duration(of player: AVPlayer) -> Double {
        let s = player.currentItem?.duration.seconds ?? 0
        return s.isFinite ? s : 0
    }
}
