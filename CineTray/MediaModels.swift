import Foundation
import Network

/// The kinds of media catalogs providers can serve.
enum MediaType: String, CaseIterable, Identifiable, Codable {
    case movies = "Movies"
    case tvShows = "TV Shows"
    case music = "Music"

    var id: String { rawValue }

    /// Display name. The raw value ("TV Shows") stays unchanged because it
    /// is part of saved settings keys and local item IDs.
    var title: String {
        switch self {
        case .movies: "Movies"
        case .tvShows: "Shows"
        case .music: "Music"
        }
    }

    var systemImage: String {
        switch self {
        case .movies: "film"
        case .tvShows: "tv"
        case .music: "music.note"
        }
    }
}

/// A library on a server (or a local media type), as reported by its
/// provider.
struct MediaLibrary: Hashable {
    let id: String
    let name: String
    let type: MediaType
}

/// A row in the menu bar dropdown: one per library, using the server's own
/// library name (libraries with the same name and type on different servers
/// share a row), plus the fixed Playlists and Continue Watching rows. Music
/// libraries get two rows, Artists and Albums.
struct MenuSection: Hashable, Identifiable {
    enum Kind: Hashable {
        case library(MediaType)
        case playlists
        case continueItems
    }

    let id: String
    let title: String
    let kind: Kind
    /// What a music library row lists; nil for every other row.
    var musicTopLevel: MusicTopLevel?

    /// Video playlists; music ones are in `musicPlaylists`.
    static let playlists = MenuSection(id: "playlists", title: "Playlists", kind: .playlists)
    static let musicPlaylists = MenuSection(id: "musicPlaylists", title: "Playlists", kind: .playlists)
    static let continueItems = MenuSection(id: "continueItems", title: "Continue Watching", kind: .continueItems)

    /// The row for libraries called `name` that hold `type`.
    static func library(named name: String, type: MediaType) -> MenuSection {
        MenuSection(id: "library|\(type.rawValue)|\(name.lowercased())", title: name, kind: .library(type))
    }

    /// A music library row listing `topLevel`. With a single music library
    /// the row is just "Artists" or "Albums".
    static func musicLibrary(named name: String, topLevel: MusicTopLevel, showsName: Bool) -> MenuSection {
        MenuSection(
            id: "library|\(MediaType.music.rawValue)|\(name.lowercased())|\(topLevel.rawValue)",
            title: showsName ? "\(name) \(topLevel.title)" : topLevel.title,
            kind: .library(.music),
            musicTopLevel: topLevel
        )
    }

    var mediaType: MediaType? {
        switch kind {
        case .library(let type): type
        case .playlists, .continueItems: nil
        }
    }

    /// Shown in the Music pane of the menu rather than the Video pane.
    var isMusic: Bool {
        mediaType == .music || self == .musicPlaylists
    }

    var systemImage: String {
        switch kind {
        case .library(let type):
            switch musicTopLevel {
            case .artist: "music.mic"
            case .album: "square.stack"
            case nil: type.systemImage
            }
        case .playlists: self == .musicPlaylists ? "music.note.list" : "list.and.film"
        case .continueItems: "clock.arrow.circlepath"
        }
    }

    /// Sections whose tracks play with the inline music overlay. Continue Watching
    /// is included so its grouped album/playlist cells can host the overlay.
    var supportsInlineMusic: Bool {
        switch kind {
        case .library(let type): type == .music
        case .playlists, .continueItems: true
        }
    }

    /// Loading-placeholder height while a section's catalog fetches.
    var loadingHeight: CGFloat {
        switch kind {
        case .library(.music), .playlists: 110
        case .library, .continueItems: 165
        }
    }
}

/// Which backend an item came from; used to route stream resolution and
/// playback reporting.
enum MediaSource: String, Codable, Hashable {
    /// No longer produced (the sample catalog is gone); kept so progress
    /// saved by older builds still decodes instead of wiping Continue Watching.
    case sample
    case plex
    case jellyfin
    case navidrome
    case torrServer
    /// Locally downloaded content, served by LocalMediaProvider.
    case local

    /// The server web app an item can be opened in; nil for local items.
    var webAppName: String? {
        switch self {
        case .plex: "Plex"
        case .jellyfin: "Jellyfin"
        case .navidrome: "Navidrome"
        case .torrServer: "TorrServer"
        case .local, .sample: nil
        }
    }

    /// Whether the server keeps its own watched state and Continue Watching
    /// list, which then wins over CineTray's local progress.
    var keepsWatchState: Bool {
        self == .plex || self == .jellyfin
    }
}

/// Which hierarchy levels expose a download control. Movies always show
/// the control (governed by the master downloads toggle); TV and Music
/// levels are individually opt-in and default to off.
enum DownloadLevel: String, CaseIterable {
    case movie
    case series    // show
    case season
    case episode
    case playlist
    case artist
    case album
    case song      // track

    var kind: MediaKind {
        switch self {
        case .movie: .movie
        case .series: .show
        case .season: .season
        case .episode: .episode
        case .playlist: .playlist
        case .artist: .artist
        case .album: .album
        case .song: .track
        }
    }

    init?(kind: MediaKind) {
        switch kind {
        case .movie: self = .movie
        case .show: self = .series
        case .season: self = .season
        case .episode: self = .episode
        case .playlist: self = .playlist
        case .artist: self = .artist
        case .album: self = .album
        case .track: self = .song
        }
    }
}

/// Player lifecycle states reported to media servers and scrobblers.
enum PlaybackState {
    case started
    case playing
    case paused
    case stopped
}

/// Where an item sits in its hierarchy. Containers expand into a child
/// carousel in the dropdown; leaves open the player.
enum MediaKind: String, Codable, Hashable {
    case movie
    case show
    case season
    case episode
    case artist
    case album
    case track
    case playlist

    var isExpandable: Bool {
        switch self {
        case .show, .season, .artist, .album, .playlist: true
        case .movie, .episode, .track: false
        }
    }
}

// MARK: - Preferences

/// What the TV section lists at its top level.
enum TVTopLevel: String, CaseIterable {
    case series
    case season
}

/// What a music section lists at its top level.
enum MusicTopLevel: String, CaseIterable {
    case artist
    case album

    var title: String {
        switch self {
        case .artist: "Artists"
        case .album: "Albums"
        }
    }
}

/// How to pick the next movie when one finishes.
enum MovieAutoContinue: String, CaseIterable {
    case off
    case inSequence
    case byDirector
    case byLeadActor
}

/// How music continues when a track finishes. `.off` still advances through
/// the album/playlist in order; `.shuffleByArtist` jumps to random tracks by
/// the same artist.
enum MusicAutoContinue: String, CaseIterable {
    case off
    case inSequence
    case shuffleByGenre
}

/// Whether the Continue Watching section lists individual in-progress songs or
/// collapses them into their parent album/playlist.
enum ContinueMusicGrouping: String, CaseIterable {
    case byAlbumPlaylist
    case bySong
}

/// How long unfinished items stay in the Continue Watching section.
enum ContinueTimeout: String, CaseIterable {
    case day = "24h"
    case threeDays = "72h"
    case week = "1w"
    case forever

    var title: String {
        switch self {
        case .day: "24 hours"
        case .threeDays: "72 hours"
        case .week: "1 week"
        case .forever: "Forever"
        }
    }

    /// Nil means never expire.
    var maxAge: TimeInterval? {
        switch self {
        case .day: 24 * 3600
        case .threeDays: 72 * 3600
        case .week: 7 * 24 * 3600
        case .forever: nil
        }
    }
}

/// Size of player window UI elements (volume slider, toolbar items).
enum PlayerUISize: String, CaseIterable {
    case small, medium, large, dynamic

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .dynamic: "Dynamic"
        }
    }
}

/// Music player display mode: inline or popout floating window.
enum PlayerMode: String, CaseIterable {
    case inline, popout

    var title: String {
        switch self {
        case .inline: "Inline"
        case .popout: "Popout"
        }
    }
}

/// Sort order for a library section. Movies and TV offer every case except
/// `byArtist`, which only the Music section shows.
enum LibrarySort: String, CaseIterable {
    case byArtist
    case byTitle
    case byYear
    case byDateAdded
    case byPlays

    var title: String {
        switch self {
        case .byArtist: "Artist"
        case .byTitle: "Title"
        case .byYear: "Year"
        case .byDateAdded: "Date Added"
        case .byPlays: "Plays"
        }
    }

    /// How ascending and descending read for this sort.
    var directionTitles: (ascending: String, descending: String) {
        switch self {
        case .byArtist, .byTitle: ("A to Z", "Z to A")
        case .byYear, .byDateAdded: ("Oldest First", "Newest First")
        case .byPlays: ("Fewest Plays First", "Most Plays First")
        }
    }

    /// The sorts a section offers; Artist only applies to Music.
    static func options(for type: MediaType) -> [LibrarySort] {
        type == .music ? allCases : allCases.filter { $0 != .byArtist }
    }

    /// True when `a` comes before `b`. Items without the value (no year or
    /// date added) go last in either direction.
    func areInOrder(_ a: MediaItem, _ b: MediaItem, descending: Bool) -> Bool {
        switch self {
        case .byArtist: Self.order(a.subtitle ?? a.title, b.subtitle ?? b.title, descending)
        case .byTitle: Self.order(a.title, b.title, descending)
        case .byYear: Self.order(a.sortableYear, b.sortableYear, descending)
        case .byDateAdded: Self.order(a.addedAt, b.addedAt, descending)
        case .byPlays: Self.order(a.playCount ?? 0, b.playCount ?? 0, descending)
        }
    }

    private static func order(_ a: String, _ b: String, _ descending: Bool) -> Bool {
        a.localizedCompare(b) == (descending ? .orderedDescending : .orderedAscending)
    }

    private static func order<T: Comparable>(_ a: T?, _ b: T?, _ descending: Bool) -> Bool {
        switch (a, b) {
        case let (a?, b?): descending ? a > b : a < b
        case (.some, nil): true
        case (nil, _): false
        }
    }
}

/// Ascending or descending order for section sorting.
enum SortDirection: String, CaseIterable {
    case ascending
    case descending
}

// MARK: - Items

/// A single piece of media, source-agnostic.
/// Codable + Hashable so it can be handed to `WindowGroup(for:)` to open a player window.
struct MediaItem: Identifiable, Hashable, Codable {
    var id: String
    var source: MediaSource
    var type: MediaType
    var kind: MediaKind = .movie
    var title: String
    var subtitle: String?
    var posterURL: URL?
    var summary: String?
    /// The container this item was listed under (season for an episode,
    /// album/playlist for a track); lets auto-continue and the music queue
    /// find siblings.
    var parentID: String?
    var parentKind: MediaKind?
    /// Display info for the container above, so a track can rebuild its parent
    /// album/playlist cell in the grouped Continue Watching section without a fetch.
    var parentTitle: String?
    var parentPosterURL: URL?
    /// Source-specific extras (artist IDs, release dates, …) that
    /// auto-continue needs but the UI doesn't.
    var attributes: [String: String] = [:]
    /// Date the item was added to the library. Nil when the backend does not report it.
    var addedAt: Date?
    /// Total play count. Nil when the backend does not report it.
    var playCount: Int?
    /// Whether the server reports this as fully watched (shows and seasons:
    /// every episode). Nil when the backend does not report it.
    var isWatched: Bool?
    /// How far through a partly watched item the server says playback got (0-1).
    var watchedFraction: Double?
    /// Where the server says playback of a partly watched item stopped.
    var resumePositionSeconds: Double?
    /// When the server says this was last played; orders Continue Watching
    /// and decides whether the server's resume point is newer than CineTray's.
    var lastViewedAt: Date?

    /// Release year when the subtitle carries one (used for Trakt matching).
    var year: Int? {
        subtitle.flatMap { Int($0) }
    }

    /// Year for sorting - falls back to the releaseDate attribute when
    /// the subtitle is not a plain year (e.g. for music or TV seasons).
    var sortableYear: Int? {
        year ?? Int(attributes["releaseDate"]?.prefix(4) ?? "")
    }

    /// Globally-unique identity for SwiftUI rendering. `id` alone is a Plex
    /// ratingKey, which can collide across servers; scoping it by source and
    /// originating server keeps `ForEach`/`scrollPosition` identities distinct
    /// when multiple servers each expose the same library type.
    var uniqueID: String {
        let server = attributes["plexServerID"] ?? ""
        return "\(source.rawValue)|\(server)|\(id)"
    }

    /// Carousel cell artwork height: 2:3 portrait for movies/shows/seasons,
    /// 16:9 landscape for episode stills, square for music art.
    var posterHeight: CGFloat {
        switch kind {
        case .episode: 62
        case .artist, .album, .track, .playlist: 110
        case .movie, .show, .season: 165
        }
    }

    /// The show's portrait poster for an episode, which Continue Watching
    /// shows instead of the episode still.
    var showPosterURL: URL? {
        kind == .episode ? attributes["grandparentPosterURL"].flatMap(URL.init(string:)) : nil
    }

    func posterHeight(byShow: Bool) -> CGFloat {
        byShow && showPosterURL != nil ? 165 : posterHeight
    }
}

/// The URLs to try for a server address typed by the user. Without a
/// scheme ("jellyfin.example.com"), HTTPS comes first and plain HTTP
/// second, but only for local network addresses: sign-in sends the
/// password, and on the internet an attacker could make HTTPS fail to get
/// it sent in plain text. An explicit scheme is kept as the only candidate.
func serverURLCandidates(_ input: String) -> [URL] {
    let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let strings = address.contains("://") ? [address] : ["https://\(address)", "http://\(address)"]
    return strings.compactMap(URL.init(string:)).filter { url in
        guard let host = url.host() else { return false }
        return address.contains("://") || url.scheme == "https" || isLocalNetworkHost(host)
    }
}

/// Loopback, private and link-local addresses, `.local` names and
/// single-label names such as "nas".
func isLocalNetworkHost(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") && !host.contains(":") {
        return true
    }
    if let bytes = IPv4Address(host)?.rawValue {
        return bytes[0] == 10 || bytes[0] == 127 || bytes[0] == 172 && (16...31).contains(bytes[1])
            || bytes[0] == 192 && bytes[1] == 168 || bytes[0] == 169 && bytes[1] == 254
    }
    if let address = IPv6Address(host) {
        return address.isLoopback || address.isLinkLocal || address.rawValue[0] & 0xfe == 0xfc
    }
    return false
}

extension URL {
    /// This URL without an `X-Plex-Token` query item.
    var removingPlexToken: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.contains(where: { $0.name == "X-Plex-Token" }) else { return self }
        let kept = items.filter { $0.name != "X-Plex-Token" }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? self
    }
}

extension MediaItem {
    /// A copy with Plex tokens removed from its artwork URLs, for saving.
    /// Older builds put the token in poster URLs, which then landed in
    /// UserDefaults and the download index in plain text.
    var removingPlexTokens: MediaItem {
        var item = self
        item.posterURL = posterURL?.removingPlexToken
        item.parentPosterURL = parentPosterURL?.removingPlexToken
        if let url = attributes["grandparentPosterURL"].flatMap(URL.init(string:)) {
            item.attributes["grandparentPosterURL"] = url.removingPlexToken.absoluteString
        }
        return item
    }
}

// MARK: - Providers

/// Abstracts where media comes from so the UI works identically with the
/// sample catalog, Plex, and Jellyfin.
protocol MediaProvider {
    var source: MediaSource { get }
    /// Stable per server, so library sections can be routed back to it.
    var id: String { get }
    /// The libraries this provider serves; each becomes (part of) a menu section.
    func libraries() async throws -> [MediaLibrary]
    /// The top-level items of one of `libraries()`.
    func items(inLibrary library: MediaLibrary) async throws -> [MediaItem]
    /// Children of a container: a show's seasons, a season's episodes,
    /// an artist's albums, an album's or playlist's tracks.
    func children(of item: MediaItem) async throws -> [MediaItem]
    /// The user's playlists, when the backend has them.
    func playlists() async throws -> [MediaItem]
    /// Deep search: each result is an ancestor chain from the configured
    /// top level down to the matched item (e.g. artist → album → track for
    /// a matched track title), so the dropdown can filter every drill level.
    func deepSearch(_ query: String, type: MediaType) async throws -> [[MediaItem]]
    func streamURL(for item: MediaItem) async throws -> URL
    /// The direct-file download URL for the original media, distinct from
    /// `streamURL` which may return an HLS playlist for transcoding.
    func downloadURL(for item: MediaItem) async throws -> URL
    /// The next movie per the auto-continue criterion, or nil when the
    /// backend can't answer it.
    func nextMovie(after item: MediaItem, by criterion: MovieAutoContinue) async throws -> MediaItem?
    /// A random other track by the same artist, for shuffle auto-continue.
    func randomTrack(sameArtistAs item: MediaItem) async throws -> MediaItem?
    /// The item's page in the server's own web app, or nil when there is none.
    func webURL(for item: MediaItem) async throws -> URL?
    /// The server's own Continue Watching list.
    func continueWatching() async throws -> [MediaItem]
    /// Tells the server where playback is, for its resume points and play counts.
    func reportPlayback(of item: MediaItem, state: PlaybackState, positionSeconds: Double, durationSeconds: Double) async throws
}

extension MediaProvider {
    func playlists() async throws -> [MediaItem] { [] }
    func deepSearch(_ query: String, type: MediaType) async throws -> [[MediaItem]] { [] }
    func downloadURL(for item: MediaItem) async throws -> URL { throw URLError(.unsupportedURL) }
    func nextMovie(after item: MediaItem, by criterion: MovieAutoContinue) async throws -> MediaItem? { nil }
    func randomTrack(sameArtistAs item: MediaItem) async throws -> MediaItem? { nil }
    func webURL(for item: MediaItem) async throws -> URL? { nil }
    func continueWatching() async throws -> [MediaItem] { [] }
    func reportPlayback(of item: MediaItem, state: PlaybackState, positionSeconds: Double, durationSeconds: Double) async throws {}
}

/// Returns true when AVFoundation can decode the file at `url` without
/// transcoding. Network URLs pass, since servers already produce a compatible
/// format, except original files in containers it can't open, which
/// TorrServer serves as they are. Local files are checked by container
/// extension; anything not in the allowlist (e.g. .mkv, .avi) requires the
/// SwiftVLC engine.
func isAVFoundationPlayable(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    guard url.isFileURL else {
        return !["mkv", "avi", "wmv", "ts", "m2ts", "webm", "mpg", "mpeg", "flv", "vob"].contains(ext)
    }
    let supported: Set<String> = [
        // Video containers AVFoundation can open directly
        "mp4", "m4v", "mov",
        // Audio containers AVFoundation handles natively
        "mp3", "m4a", "aac", "flac", "aiff", "wav", "caf",
    ]
    return supported.contains(ext)
}

/// Whether `text` contains `query`, ignoring case, accents, spacing and
/// punctuation ("madmen" finds "Mad Men", "amelie" finds "Amélie"). A query
/// without letters or digits falls back to a plain case-insensitive match.
func searchMatches(_ text: String, query: String) -> Bool {
    func key(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }
    let queryKey = key(query)
    return queryKey.isEmpty ? text.localizedCaseInsensitiveContains(query) : key(text).contains(queryKey)
}

/// Strips sequel numbering and subtitles ("Movie 2", "Movie II: Subtitle")
/// so franchise entries compare equal for In Sequence auto-continue.
func franchiseBaseTitle(_ title: String) -> String {
    var base = title
    if let colon = base.firstIndex(of: ":") {
        base = String(base[..<colon])
    }
    while let last = base.split(separator: " ").last,
          last.allSatisfy({ $0.isNumber }) || last.allSatisfy({ "IVXLC".contains($0) }) && last.count <= 4 {
        base = base.dropLast(last.count).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { return title.lowercased() }
    }
    return base.trimmingCharacters(in: .whitespaces).lowercased()
}

// MARK: - Persistence keys

/// UserDefaults keys for non-secret settings. Tokens and secrets live in
/// the Keychain under `KeychainKeys`.
nonisolated enum SettingsKeys {
    static let useMediaKeys = "useMediaKeys"
    /// JSON-encoded [PlexServer]. `plexServerURL` remains only so older
    /// single-server setups can be migrated by PlexServerStore.
    static let plexServers = "plexServers"
    static let plexServerURL = "plexServerURL"
    static let plexSelectedLibraries = "plexSelectedLibraries"
    static let jellyfinServerURL = "jellyfinServerURL"
    static let jellyfinUserID = "jellyfinUserID"
    static let jellyfinUsername = "jellyfinUsername"
    static let jellyfinSelectedLibraries = "jellyfinSelectedLibraries"
    static let navidromeServerURL = "navidromeServerURL"
    static let navidromeUsername = "navidromeUsername"
    /// Not secret: it only goes with the token in the Keychain.
    static let navidromeSalt = "navidromeSalt"
    /// Set once Connect succeeds; the password is in the Keychain.
    static let torrServerURL = "torrServerURL"
    static let torrServerUsername = "torrServerUsername"

    static let tvTopLevel = "tvTopLevel"
    /// Whether the menu shows the Music pane instead of the Video pane.
    static let menuShowsMusic = "menuShowsMusic"
    static let movieAutoContinue = "movieAutoContinue"
    static let tvAutoContinue = "tvAutoContinue"
    static let musicAutoContinue = "musicAutoContinue"
    static let cacheArtwork = "cacheArtwork"
    static let simpleVisuals = "simpleVisuals"
    static let playbackProgress = "playbackProgress"
    static let continueTimeout = "continueTimeout"
    static let continueMusic = "continueMusic"
    static let downloadsEnabled = "downloadsEnabled"
    static let playerUISize = "playerUISize"
    static let playerMode = "playerMode"
    /// Path of the app that plays video; empty for CineTray's own player.
    static let videoPlayerApp = "videoPlayerApp"
    static let richMedia = "richMedia"
    static let movieSort = "movieSort"
    static let tvSort = "tvSort"
    static let musicSort = "musicSort"
    static let movieSortDirection = "movieSortDirection"
    static let tvSortDirection = "tvSortDirection"
    static let musicSortDirection = "musicSortDirection"

    static func sectionEnabled(_ section: MenuSection) -> String {
        "sectionEnabled_\(section.id)"
    }
    /// Continue Watching opens and closes on its own, independently of the
    /// one-open-at-a-time library sections.
    static let continueExpanded = "continueExpanded"
    /// Menu section ids in the order chosen in Settings > Libraries.
    static let sectionOrder = "sectionOrder"

    static func downloadFolderBookmark(_ type: MediaType) -> String {
        "downloadFolderBookmark_\(type.rawValue)"
    }

    static func downloadFolderPath(_ type: MediaType) -> String {
        "downloadFolderPath_\(type.rawValue)"
    }

    static func downloadLimitGB(_ type: MediaType) -> String {
        "downloadLimitGB_\(type.rawValue)"
    }

    static func downloadLevelEnabled(_ level: DownloadLevel) -> String {
        "downloadLevel_\(level.rawValue)"
    }

    static func libraryFolderBookmark(_ type: MediaType) -> String {
        "libraryFolderBookmark_\(type.rawValue)"
    }

    static func libraryFolderPath(_ type: MediaType) -> String {
        "libraryFolderPath_\(type.rawValue)"
    }

    static let movieLocalFirst = "movieLocalFirst"
    static let tvLocalFirst = "tvLocalFirst"
    static let musicLocalFirst = "musicLocalFirst"
    /// Comma-separated `MusicArtworkSource` raw values turned off in Settings.
    static let disabledMusicArtworkSources = "disabledMusicArtworkSources"
}

/// Keychain item names for secrets.
enum KeychainKeys {
    /// Legacy single-server token; migrated to a per-server item.
    static let plexToken = "plexToken"
    /// plex.tv account token from Sign In With Plex, used for server discovery.
    static let plexAccountToken = "plexAccountToken"

    static func plexServerToken(_ serverID: String) -> String {
        "plexToken_\(serverID)"
    }
    static let jellyfinToken = "jellyfinToken"
    static let navidromeToken = "navidromeToken"
    /// TorrServer only does HTTP Basic auth, so the password itself is kept.
    static let torrServerPassword = "torrServerPassword"
    static let traktClientID = "traktClientID"
    static let traktClientSecret = "traktClientSecret"
    static let traktAccessToken = "traktAccessToken"
    static let traktRefreshToken = "traktRefreshToken"
    static let lastfmAPIKey = "lastfmAPIKey"
    static let lastfmSharedSecret = "lastfmSharedSecret"
    static let lastfmSessionKey = "lastfmSessionKey"
    static let theAudioDBAPIKey = "theAudioDBAPIKey"
    static let discogsToken = "discogsToken"
    /// Same name as the UserDefaults key older builds used, so
    /// KeychainStore.stringMigratingFromDefaults(for:) moves it over.
    static let tmdbAPIKey = "tmdbAPIKey"
}
