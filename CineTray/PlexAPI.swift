import Foundation
import Network
import VideoToolbox

final class PlexConfiguration {
    var serverURL: URL
    var fallbackURLs: [URL]?
    var token: String
    /// Stable identifier for the server (plex.tv clientIdentifier, a UUID
    /// for manually added servers, or "legacy" for a migrated setup); used
    /// to route items back to the server they came from.
    var serverID: String
    var serverName: String
    /// Every known address, in preference order. Unlike `serverURL` it never
    /// changes, so a connection check always considers all of them.
    let candidateURLs: [URL]
    /// The shared connection check and the network generation it ran for.
    /// See `PlexClient.ensureConnection`.
    var connectionCheck: Task<URL?, Never>?
    var connectionCheckGeneration = -1

    init(serverURL: URL, fallbackURLs: [URL]? = nil, token: String, serverID: String = "", serverName: String = "") {
        self.serverURL = serverURL
        self.fallbackURLs = fallbackURLs
        var seen = Set<URL>()
        self.candidateURLs = ([serverURL] + (fallbackURLs ?? [])).filter { seen.insert($0).inserted }
        self.token = token
        self.serverID = serverID
        self.serverName = serverName
    }
}

/// Counts network changes (Wi-Fi to hotspot, VPN on or off), so the next
/// Plex request after one re-checks which server address answers instead
/// of waiting for a stale one to time out.
final class NetworkChangeMonitor {
    static let shared = NetworkChangeMonitor()

    private(set) var generation = 0

    private init() {
        Task { for await _ in NWPathMonitor() { generation += 1 } }
    }
}

/// URLSession drops Authorization when a server redirects to another
/// address, but keeps custom headers, so the Plex token and the Radarr and
/// Sonarr API key are dropped here.
nonisolated final class PlexTokenRedirectGuard: NSObject, URLSessionTaskDelegate {
    static let shared = PlexTokenRedirectGuard()

    // The async variant of this method crashes the Swift 6.3 compiler in its Objective-C thunk.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        var request = request
        if let from = response.url, let to = request.url, ArtworkCache.addressKey(from) != ArtworkCache.addressKey(to) {
            request.setValue(nil, forHTTPHeaderField: "X-Plex-Token")
            request.setValue(nil, forHTTPHeaderField: "X-Api-Key")
        }
        completionHandler(request)
    }
}

/// A connected Plex server. The list lives in UserDefaults; each server's
/// token is a separate Keychain item so no secrets are stored alongside.
enum PlexError: LocalizedError {
    case unauthorized
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Plex rejected the sign-in token. Reconnect the server in Settings > Accounts."
        case .http(let status): "The Plex server returned an error (HTTP \(status))."
        }
    }
}

struct PlexServer: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var urlString: String
    var fallbackURLStrings: [String]?
}

/// Persistence for the connected-server list, including migration of the
/// older single-server settings (plexServerURL + Keychain plexToken).
enum PlexServerStore {
    private static let legacyID = "legacy"

    static func load() -> [PlexServer] {
        if let data = UserDefaults.standard.data(forKey: SettingsKeys.plexServers) {
            return (try? JSONDecoder().decode([PlexServer].self, from: data)) ?? []
        }
        return migrateLegacyServer()
    }

    static func save(_ servers: [PlexServer]) {
        let data = (try? JSONEncoder().encode(servers)) ?? Data("[]".utf8)
        UserDefaults.standard.set(data, forKey: SettingsKeys.plexServers)
    }

    static func token(for serverID: String) -> String? {
        KeychainStore.string(for: KeychainKeys.plexServerToken(serverID))
    }

    static func setToken(_ token: String?, for serverID: String) {
        KeychainStore.set(token, for: KeychainKeys.plexServerToken(serverID))
    }

    /// Makes `url` the server's primary address after the saved one failed,
    /// keeping the old primary as the first fallback, so the next launch
    /// doesn't wait for the dead address to time out again.
    static func promote(_ url: URL, forServer id: String) {
        var servers = load()
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        let old = servers[index].urlString
        let new = url.absoluteString
        guard old != new else { return }
        servers[index].urlString = new
        servers[index].fallbackURLStrings = [old] + (servers[index].fallbackURLStrings ?? []).filter { $0 != new && $0 != old }
        save(servers)
    }

    /// Removes a server and its Keychain token.
    static func remove(_ serverID: String) {
        save(load().filter { $0.id != serverID })
        setToken(nil, for: serverID)
    }

    /// Converts a pre-multi-server setup into a single "legacy" entry,
    /// moving the token into a per-server Keychain item and scoping the
    /// existing library selections to the migrated server.
    private static func migrateLegacyServer() -> [PlexServer] {
        let defaults = UserDefaults.standard
        guard let urlString = defaults.string(forKey: SettingsKeys.plexServerURL), !urlString.isEmpty,
              let token = KeychainStore.stringMigratingFromDefaults(for: KeychainKeys.plexToken),
              !token.isEmpty else {
            return []
        }
        let server = PlexServer(
            id: legacyID,
            name: URL(string: urlString)?.host() ?? "Plex Server",
            urlString: urlString
        )
        save([server])
        setToken(token, for: legacyID)
        if let selected = defaults.string(forKey: SettingsKeys.plexSelectedLibraries), !selected.isEmpty {
            let scoped = selected.split(separator: ",").map { "\(legacyID):\($0)" }
            defaults.set(scoped.joined(separator: ","), forKey: SettingsKeys.plexSelectedLibraries)
        }
        defaults.removeObject(forKey: SettingsKeys.plexServerURL)
        KeychainStore.set(nil, for: KeychainKeys.plexToken)
        return [server]
    }
}

struct PlexLibrary: Identifiable, Hashable, Codable {
    let key: String
    let title: String
    /// Plex library type: "movie", "show", or "artist".
    let type: String

    var id: String { key }

    var mediaType: MediaType? {
        switch type {
        case "movie": .movies
        case "show": .tvShows
        case "artist": .music
        default: nil
        }
    }
}

/// Minimal Plex Media Server client. Requests JSON via the Accept header and
/// authenticates with an X-Plex-Token (pasted directly or obtained through
/// the plex.tv PIN link flow below).
struct PlexClient {
    static let clientIdentifier = "CineTrayMenuBar"
    static let productName = "CineTray"

    let config: PlexConfiguration

    // MARK: - Server requests

    private func fetchData(path: String, query: [URLQueryItem] = []) async throws -> (Data, URLResponse) {
        try await ensureConnection()
        do {
            return try await fetchData(from: config.serverURL, path: path, query: query)
        } catch let error as URLError where error.code != .cancelled {
            // The address stopped answering without a network change (server
            // offline or moved): re-check, and retry if another one answers.
            let failedURL = config.serverURL
            try await ensureConnection(force: true)
            guard config.serverURL != failedURL else { throw error }
            return try await fetchData(from: config.serverURL, path: path, query: query)
        }
    }

    private func fetchData(from baseURL: URL, path: String, query: [URLQueryItem]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path).appending(queryItems: query))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(Self.productName, forHTTPHeaderField: "X-Plex-Product")
        let result = try await URLSession.shared.data(for: request, delegate: PlexTokenRedirectGuard.shared)
        // The server answered, so an HTTP error is final: the other
        // addresses reach the same server.
        try Self.validate(result.1)
        return result
    }

    /// Points `config.serverURL` at the first address that answers. Runs on
    /// first use, after a network change, or when forced; concurrent requests
    /// share one check. Trying addresses one by one meant waiting ~60 s per
    /// unreachable LAN address when away from home.
    private func ensureConnection(force: Bool = false) async throws {
        let generation = NetworkChangeMonitor.shared.generation
        if force || config.connectionCheck == nil || config.connectionCheckGeneration != generation {
            config.connectionCheckGeneration = generation
            config.connectionCheck = Task { [candidates = config.candidateURLs] in
                await Self.firstReachableURL(among: candidates)
            }
        }
        guard let url = await config.connectionCheck?.value else {
            config.connectionCheck = nil // check again on the next request
            throw URLError(.cannotConnectToHost)
        }
        if url != config.serverURL {
            config.serverURL = url
            PlexServerStore.promote(url, forServer: config.serverID)
        }
    }

    /// HTTP addresses are tried only when no HTTPS one answers: every request
    /// carries the token, and on a LAN plain HTTP would otherwise win the race,
    /// since the server's certificate doesn't match its raw IP address.
    private static func firstReachableURL(among urls: [URL]) async -> URL? {
        let secure = urls.filter { $0.scheme == "https" }
        if let url = await firstAnswering(secure) { return url }
        return await firstAnswering(urls.filter { $0.scheme != "https" })
    }

    /// Asks every address at once for /identity (no token needed, so nothing
    /// sensitive is sent) with a 3 s timeout, and returns the first to answer.
    private static func firstAnswering(_ urls: [URL]) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            for url in urls {
                group.addTask {
                    let request = URLRequest(url: url.appending(path: "/identity"), timeoutInterval: 3)
                    guard let (_, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return url
                }
            }
            for await url in group {
                if let url {
                    group.cancelAll()
                    return url
                }
            }
            return nil
        }
    }

    /// Turns non-2xx responses into readable errors instead of letting them
    /// surface later as JSON decoding failures.
    private static func validate(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) else { return }
        throw status == 401 ? PlexError.unauthorized : PlexError.http(status)
    }

    func libraries() async throws -> [PlexLibrary] {
        struct Response: Decodable {
            struct Container: Decodable { let Directory: [PlexLibrary]? }
            let MediaContainer: Container
        }
        let (data, _) = try await fetchData(path: "/library/sections")
        return try JSONDecoder().decode(Response.self, from: data).MediaContainer.Directory ?? []
    }

    private struct Tag: Decodable {
        let id: Int?
        let tag: String?
    }

    private struct MediaInfo: Decodable {
        struct Part: Decodable {
            let key: String?
            let container: String?
            let file: String?
        }
        let container: String?
        let videoCodec: String?
        let audioCodec: String?
        let Part: [Part]?
    }

    private struct Metadata: Decodable {
        let ratingKey: String
        let title: String
        let type: String?
        let year: Int?
        let index: Int?
        let parentIndex: Int?
        let leafCount: Int?
        let viewedLeafCount: Int?
        let parentTitle: String?
        let parentRatingKey: String?
        let parentThumb: String?
        let grandparentTitle: String?
        let grandparentRatingKey: String?
        let grandparentThumb: String?
        let thumb: String?
        let composite: String?
        let playlistType: String?
        let summary: String?
        let originallyAvailableAt: String?
        let addedAt: Int?
        let viewCount: Int?
        let viewOffset: Int?
        let duration: Int?
        let lastViewedAt: Int?
        let librarySectionID: Int?
        let Director: [Tag]?
        let Role: [Tag]?
        let Collection: [Tag]?
        let Media: [MediaInfo]?
    }

    private struct MetadataResponse: Decodable {
        struct Container: Decodable { let Metadata: [Metadata]? }
        let MediaContainer: Container
    }

    /// Adds the watched state Plex reports: shows and seasons are watched once
    /// every episode is; movies and episodes carry a resume point or a play
    /// count. Music isn't tracked.
    private static func withWatchState(_ item: MediaItem, from entry: Metadata) -> MediaItem {
        var item = item
        item.lastViewedAt = entry.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        switch entry.type {
        case "show", "season":
            if let leafCount = entry.leafCount, leafCount > 0 {
                item.isWatched = entry.viewedLeafCount == leafCount
            }
        case "movie", "episode":
            if let offset = entry.viewOffset, offset > 0, let duration = entry.duration, duration > 0 {
                item.resumePositionSeconds = Double(offset) / 1000
                item.watchedFraction = min(Double(offset) / Double(duration), 1)
            } else {
                item.isWatched = (entry.viewCount ?? 0) > 0
            }
        default:
            break
        }
        return item
    }

    /// Plex numeric metadata types for /all queries.
    private static func plexType(for type: MediaType, tvTopLevel: TVTopLevel, musicTopLevel: MusicTopLevel) -> (query: String, kind: MediaKind) {
        switch type {
        case .movies: ("1", .movie)
        case .tvShows: tvTopLevel == .season ? ("3", .season) : ("2", .show)
        case .music: musicTopLevel == .artist ? ("8", .artist) : ("9", .album)
        }
    }

    func items(inLibrary key: String, type: MediaType, tvTopLevel: TVTopLevel, musicTopLevel: MusicTopLevel) async throws -> [MediaItem] {
        let (typeQuery, kind) = Self.plexType(for: type, tvTopLevel: tvTopLevel, musicTopLevel: musicTopLevel)
        let (data, _) = try await fetchData(path: "/library/sections/\(key)/all", query: [URLQueryItem(name: "type", value: typeQuery)])
        let metadata = try JSONDecoder().decode(MetadataResponse.self, from: data).MediaContainer.Metadata ?? []
        return metadata.map { entry in
            Self.withWatchState(MediaItem(
                id: entry.ratingKey,
                source: .plex,
                type: type,
                kind: kind,
                // Season top level shows "Show - Season N" context via subtitle.
                title: entry.title,
                subtitle: entry.parentTitle ?? entry.grandparentTitle ?? entry.year.map(String.init),
                posterURL: entry.thumb.map(imageURL(thumbPath:)),
                summary: entry.summary,
                // For season top-level display, carry parent (show) context so artwork
                // downloads can place the show poster next to the show folder.
                parentID: kind == .season ? entry.parentRatingKey : nil,
                parentKind: kind == .season ? .show : nil,
                parentTitle: kind == .season ? entry.parentTitle : nil,
                parentPosterURL: kind == .season ? entry.parentThumb.map(imageURL(thumbPath:)) : nil,
                attributes: [
                    "releaseDate": entry.originallyAvailableAt ?? "",
                    "grandparentTitle": entry.grandparentTitle ?? "",
                    "originalPath": entry.Media?.first?.Part?.first?.file ?? "",
                    "year": entry.year.map(String.init) ?? "" // Recoverable offline
                ],
                addedAt: entry.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                playCount: entry.viewCount
            ), from: entry)
        }
    }

    /// Direct children of a container: a show's seasons, a season's episodes,
    /// an album's tracks, or a playlist's mixed items.
    func children(of item: MediaItem) async throws -> [MediaItem] {
        // Playlists live outside the library hierarchy.
        let path = item.kind == .playlist
            ? "/playlists/\(item.id)/items"
            : "/library/metadata/\(item.id)/children"
        let (data, _) = try await fetchData(path: path)
        let metadata = try JSONDecoder().decode(MetadataResponse.self, from: data).MediaContainer.Metadata ?? []
        return metadata.compactMap { childItem(from: $0, parent: item) }
    }

    private func childItem(from entry: Metadata, parent item: MediaItem) -> MediaItem? {
        let kind: MediaKind? = switch entry.type {
        case "movie": .movie
        case "season": .season
        case "episode": .episode
        case "album": .album
        case "track": .track
        default: nil
        }
        guard let kind else { return nil }
        // Playlists mix media types, so derive each child's type.
        let childType: MediaType = switch kind {
        case .movie: .movies
        case .season, .episode: .tvShows
        case .album, .track: .music
        default: item.type
        }
        let subtitle: String? = switch kind {
        case .season: entry.leafCount.map { "\($0) episodes" }
        case .episode: entry.index.map { index in
            entry.parentIndex.map { "S\($0)E\(index)" } ?? "Episode \(index)"
        }
        case .album: entry.year.map(String.init)
        case .movie: entry.year.map(String.init)
        default: entry.grandparentTitle
        }
        return Self.withWatchState(MediaItem(
            id: entry.ratingKey,
            source: .plex,
            type: childType,
            kind: kind,
            title: entry.title,
            subtitle: subtitle,
            posterURL: entry.thumb.map(imageURL(thumbPath:)) ?? item.posterURL,
            summary: entry.summary,
            parentID: item.id,
            parentKind: item.kind,
            parentTitle: item.title,
            // Build parentPosterURL fresh using the current serverURL so it
            // remains valid even if config.serverURL changed (fallback selected)
            // since the parent item's posterURL was first constructed.
            parentPosterURL: entry.parentThumb.map(imageURL(thumbPath:)) ?? item.posterURL,
            attributes: [
                "originalPath": entry.Media?.first?.Part?.first?.file ?? "",
                "grandparentTitle": entry.grandparentTitle ?? "",
                "parentIndex": entry.parentIndex.map(String.init) ?? "",
                "grandparentRatingKey": entry.grandparentRatingKey ?? "",
                "grandparentPosterURL": entry.grandparentThumb.map(imageURL(thumbPath:))?.absoluteString ?? "",
                "year": entry.year.map(String.init) ?? "" // Recoverable offline
            ]
        ), from: entry)
    }

    /// The server's playlists (audio and video).
    func playlists() async throws -> [MediaItem] {
        let (data, _) = try await fetchData(path: "/playlists")
        let metadata = try JSONDecoder().decode(MetadataResponse.self, from: data).MediaContainer.Metadata ?? []
        return metadata.filter { $0.type == "playlist" }.map { entry in
            MediaItem(
                id: entry.ratingKey,
                source: .plex,
                type: entry.playlistType == "video" ? .movies : .music,
                kind: .playlist,
                title: entry.title,
                subtitle: entry.leafCount.map { "\($0) items" },
                posterURL: (entry.composite ?? entry.thumb).map(imageURL(thumbPath:)),
                summary: entry.summary
            )
        }
    }

    // MARK: - Deep search

    /// Server-wide search mapped to ancestor chains (artist → album → track,
    /// show → season → episode) per the configured top levels.
    func deepSearch(_ query: String, type: MediaType, tvTopLevel: TVTopLevel, musicTopLevel: MusicTopLevel) async throws -> [[MediaItem]] {
        let (data, _) = try await fetchData(
            path: "/search",
            query: [URLQueryItem(name: "query", value: query)]
        )
        let metadata = try JSONDecoder().decode(MetadataResponse.self, from: data).MediaContainer.Metadata ?? []

        func ancestor(key: String?, title: String?, thumb: String?, kind: MediaKind, type: MediaType, parent: MediaItem? = nil) -> MediaItem? {
            guard let key, let title else { return nil }
            return MediaItem(
                id: key,
                source: .plex,
                type: type,
                kind: kind,
                title: title,
                posterURL: thumb.map(imageURL(thumbPath:)),
                parentID: parent?.id,
                parentKind: parent?.kind
            )
        }

        return metadata.compactMap { entry -> [MediaItem]? in
            switch (entry.type, type) {
            case ("movie", .movies):
                return [movieItem(from: entry)]
            case ("show", .tvShows) where tvTopLevel == .series:
                return ancestor(key: entry.ratingKey, title: entry.title, thumb: entry.thumb, kind: .show, type: .tvShows).map { [$0] }
            case ("season", .tvShows):
                let show = tvTopLevel == .series
                    ? ancestor(key: entry.parentRatingKey, title: entry.parentTitle, thumb: entry.parentThumb, kind: .show, type: .tvShows)
                    : nil
                guard let season = ancestor(key: entry.ratingKey, title: entry.title, thumb: entry.thumb, kind: .season, type: .tvShows, parent: show) else { return nil }
                return (show.map { [$0] } ?? []) + [season]
            case ("episode", .tvShows):
                let show = tvTopLevel == .series
                    ? ancestor(key: entry.grandparentRatingKey, title: entry.grandparentTitle, thumb: entry.grandparentThumb, kind: .show, type: .tvShows)
                    : nil
                guard let season = ancestor(key: entry.parentRatingKey, title: entry.parentTitle, thumb: entry.parentThumb ?? entry.grandparentThumb, kind: .season, type: .tvShows, parent: show),
                      let episode = ancestor(key: entry.ratingKey, title: entry.title, thumb: entry.thumb, kind: .episode, type: .tvShows, parent: season) else { return nil }
                return (show.map { [$0] } ?? []) + [season, episode]
            case ("artist", .music) where musicTopLevel == .artist:
                return ancestor(key: entry.ratingKey, title: entry.title, thumb: entry.thumb, kind: .artist, type: .music).map { [$0] }
            case ("album", .music):
                let artist = musicTopLevel == .artist
                    ? ancestor(key: entry.parentRatingKey, title: entry.parentTitle, thumb: entry.parentThumb, kind: .artist, type: .music)
                    : nil
                guard let album = ancestor(key: entry.ratingKey, title: entry.title, thumb: entry.thumb, kind: .album, type: .music, parent: artist) else { return nil }
                return (artist.map { [$0] } ?? []) + [album]
            case ("track", .music):
                let artist = musicTopLevel == .artist
                    ? ancestor(key: entry.grandparentRatingKey, title: entry.grandparentTitle, thumb: entry.grandparentThumb, kind: .artist, type: .music)
                    : nil
                guard let album = ancestor(key: entry.parentRatingKey, title: entry.parentTitle, thumb: entry.parentThumb ?? entry.grandparentThumb, kind: .album, type: .music, parent: artist),
                      let track = ancestor(key: entry.ratingKey, title: entry.title, thumb: entry.thumb, kind: .track, type: .music, parent: album) else { return nil }
                return (artist.map { [$0] } ?? []) + [album, track]
            default:
                return nil
            }
        }
    }

    // MARK: - Continue Watching

    /// Plex's Continue Watching list (movies and episodes in progress, plus
    /// the next episode of shows being watched), or On Deck on servers
    /// without that hub. Limited to `libraryKeys` unless empty.
    func continueWatching(inLibraries libraryKeys: Set<String>) async throws -> [MediaItem] {
        let data: Data
        do {
            data = try await fetchData(path: "/hubs/continueWatching/items").0
        } catch PlexError.http(404) {
            data = try await fetchData(path: "/library/onDeck").0
        }
        let metadata = try JSONDecoder().decode(MetadataResponse.self, from: data).MediaContainer.Metadata ?? []
        return metadata.compactMap { entry in
            if !libraryKeys.isEmpty, let section = entry.librarySectionID, !libraryKeys.contains(String(section)) {
                return nil
            }
            switch entry.type {
            case "movie":
                return movieItem(from: entry)
            case "episode":
                // Listed outside its season, so give it the season as parent,
                // as children(of:) does: next-episode and downloads work the same.
                guard let seasonKey = entry.parentRatingKey else { return nil }
                let season = MediaItem(
                    id: seasonKey, source: .plex, type: .tvShows, kind: .season,
                    title: entry.parentTitle ?? "",
                    posterURL: (entry.parentThumb ?? entry.grandparentThumb).map(imageURL(thumbPath:))
                )
                return childItem(from: entry, parent: season)
            default:
                return nil
            }
        }
    }

    // MARK: - Auto-continue queries

    private func metadata(forRatingKey key: String) async throws -> Metadata? {
        let (data, _) = try await fetchData(path: "/library/metadata/\(key)")
        return try JSONDecoder().decode(MetadataResponse.self, from: data).MediaContainer.Metadata?.first
    }

    private func movieItem(from entry: Metadata) -> MediaItem {
        Self.withWatchState(MediaItem(
            id: entry.ratingKey,
            source: .plex,
            type: .movies,
            kind: .movie,
            title: entry.title,
            subtitle: entry.year.map(String.init),
            posterURL: entry.thumb.map(imageURL(thumbPath:)),
            summary: entry.summary,
            attributes: [
                "releaseDate": entry.originallyAvailableAt ?? "",
                "originalPath": entry.Media?.first?.Part?.first?.file ?? "",
                "year": entry.year.map(String.init) ?? "" // Recoverable offline
            ]
        ), from: entry)
    }

    /// Movies matching a library filter (collection/director/actor tag),
    /// sorted by release date.
    private func movies(inSection section: Int, filter: URLQueryItem) async throws -> [MediaItem] {
        let (data, _) = try await fetchData(
            path: "/library/sections/\(section)/all",
            query: [URLQueryItem(name: "type", value: "1"), filter]
        )
        let metadata = try JSONDecoder().decode(MetadataResponse.self, from: data).MediaContainer.Metadata ?? []
        return metadata.map(movieItem(from:))
            .sorted { ($0.attributes["releaseDate"] ?? "") < ($1.attributes["releaseDate"] ?? "") }
    }

    /// Picks the next movie per the criterion, using the item's full
    /// metadata (collections, director, cast) and library-wide tag filters.
    func nextMovie(after item: MediaItem, by criterion: MovieAutoContinue) async throws -> MediaItem? {
        guard criterion != .off,
              let meta = try await metadata(forRatingKey: item.id),
              let section = meta.librarySectionID else {
            return nil
        }
        let currentDate = meta.originallyAvailableAt ?? ""

        var candidates: [MediaItem] = []
        switch criterion {
        case .off:
            return nil
        case .inSequence:
            if let collection = meta.Collection?.first?.id {
                candidates = try await movies(inSection: section, filter: URLQueryItem(name: "collection", value: String(collection)))
            } else {
                // No Plex collection - fall back to the franchise title heuristic.
                let all = try await movies(inSection: section, filter: URLQueryItem(name: "sort", value: "titleSort"))
                let base = franchiseBaseTitle(item.title)
                candidates = all.filter { franchiseBaseTitle($0.title) == base }
            }
        case .byDirector:
            guard let director = meta.Director?.first?.id else { return nil }
            candidates = try await movies(inSection: section, filter: URLQueryItem(name: "director", value: String(director)))
        case .byLeadActor:
            guard let actor = meta.Role?.first?.id else { return nil }
            candidates = try await movies(inSection: section, filter: URLQueryItem(name: "actor", value: String(actor)))
        }

        candidates.removeAll { $0.id == item.id }
        return candidates.first { ($0.attributes["releaseDate"] ?? "") > currentDate } ?? candidates.first
    }

    /// A random other track by the same artist (via the track's grandparent).
    func randomTrack(sameArtistAs item: MediaItem) async throws -> MediaItem? {
        guard let meta = try await metadata(forRatingKey: item.id),
              let artistKey = meta.grandparentRatingKey else {
            return nil
        }
        let (data, _) = try await fetchData(path: "/library/metadata/\(artistKey)/allLeaves")
        let tracks = try JSONDecoder().decode(MetadataResponse.self, from: data).MediaContainer.Metadata ?? []
        guard let pick = tracks.filter({ $0.ratingKey != item.id }).randomElement() else { return nil }
        return MediaItem(
            id: pick.ratingKey,
            source: .plex,
            type: .music,
            kind: .track,
            title: pick.title,
            subtitle: pick.grandparentTitle,
            posterURL: pick.thumb.map(imageURL(thumbPath:)) ?? item.posterURL,
            summary: pick.summary
        )
    }

    /// Poster art scaled server-side by Plex's photo transcoder.
    func imageURL(thumbPath: String) -> URL {
        config.serverURL.appending(path: "/photo/:/transcode").appending(queryItems: [
            URLQueryItem(name: "width", value: "400"),
            URLQueryItem(name: "height", value: "600"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "url", value: thumbPath),
            // No token here: these URLs are saved (Continue list, download
            // index). ArtworkCache sends the token as a header instead.
        ])
    }

    // MARK: - Playback

    /// AVFoundation has no software AV1 decoder; Apple silicon gained the
    /// hardware decoder with the M3 generation. VideoToolbox answers the
    /// "is this an M3 or newer" question directly, without parsing chip names.
    static let supportsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    private static let directPlayVideoCodecs: Set<String> = {
        var codecs: Set<String> = ["h264", "hevc", "h265", "mpeg4"]
        if supportsAV1 { codecs.insert("av1") }
        return codecs
    }()
    private static let directPlayAudioCodecs: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac", "flac", "pcm"]
    /// Containers AVFoundation can stream over HTTP - notably not mkv.
    private static let directPlayVideoContainers: Set<String> = ["mp4", "mov", "m4v"]
    private static let directPlayAudioContainers: Set<String> = ["mp3", "mp4", "m4a", "flac", "aiff", "wav", "caf"]

    /// The item's page in the Plex Web app hosted by the server itself, so it
    /// also works for servers that aren't signed in to plex.tv. The link
    /// needs the server's machine identifier, which manually added servers
    /// don't store, so it is asked for here.
    func webURL(ratingKey: String) async throws -> URL {
        struct Identity: Decodable {
            struct Container: Decodable { let machineIdentifier: String }
            let MediaContainer: Container
        }
        let (data, _) = try await fetchData(path: "/identity")
        let machineID = try JSONDecoder().decode(Identity.self, from: data).MediaContainer.machineIdentifier
        var components = URLComponents(url: config.serverURL.appending(path: "/web/index.html"), resolvingAgainstBaseURL: false)
        components?.fragment = "!/server/\(machineID)/details?key=%2Flibrary%2Fmetadata%2F\(ratingKey)"
        guard let url = components?.url else { throw URLError(.badURL) }
        return url
    }

    /// Original-file download URL: resolves the part key from metadata and
    /// appends `download=1` so the server treats it as an attachment.
    func downloadFileURL(ratingKey: String) async -> URL? {
        guard let media = (try? await metadata(forRatingKey: ratingKey))?.Media?.first,
              let part = media.Part?.first,
              let partKey = part.key else { return nil }
        return config.serverURL.appending(path: partKey).appending(queryItems: [
            URLQueryItem(name: "download", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: config.token),
        ])
    }

    /// The original file, for players that read any container (IINA, VLC).
    func originalFileURL(ratingKey: String) async throws -> URL {
        guard let partKey = try await metadata(forRatingKey: ratingKey)?.Media?.first?.Part?.first?.key else {
            throw URLError(.resourceUnavailable)
        }
        return directFileURL(partKey: partKey)
    }

    /// The original file, streamed as-is with no server-side processing.
    private func directFileURL(partKey: String) -> URL {
        config.serverURL.appending(path: partKey)
            .appending(queryItems: [URLQueryItem(name: "X-Plex-Token", value: config.token)])
    }

    /// Direct-plays the original video file when AVFoundation can handle its
    /// container and codecs (AV1 needs the M3-or-newer hardware decoder);
    /// anything else falls back to the universal HLS stream, where the server
    /// remuxes compatible codecs and only transcodes what it must.
    func videoStreamURL(ratingKey: String) async throws -> URL {
        if let media = (try? await metadata(forRatingKey: ratingKey))?.Media?.first,
           let part = media.Part?.first, let partKey = part.key,
           Self.directPlayVideoContainers.contains((part.container ?? media.container ?? "").lowercased()),
           Self.directPlayVideoCodecs.contains((media.videoCodec ?? "").lowercased()),
           Self.directPlayAudioCodecs.contains((media.audioCodec ?? "").lowercased()) {
            return directFileURL(partKey: partKey)
        }
        return try hlsStreamURL(ratingKey: ratingKey)
    }

    /// Same decision for music: direct-play the original track unless its
    /// container/codec needs the server's MP3 fallback.
    func trackStreamURL(ratingKey: String) async throws -> URL {
        if let media = (try? await metadata(forRatingKey: ratingKey))?.Media?.first,
           let part = media.Part?.first, let partKey = part.key,
           Self.directPlayAudioContainers.contains((part.container ?? media.container ?? "").lowercased()),
           Self.directPlayAudioCodecs.contains((media.audioCodec ?? "").lowercased()) {
            return directFileURL(partKey: partKey)
        }
        return try audioStreamURL(ratingKey: ratingKey)
    }

    /// URLComponents.queryItems leaves "&" in values unescaped, which would
    /// splinter the client-profile directives below into bogus query params,
    /// so the query is percent-encoded by hand.
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return allowed
    }()

    private static func encodedQuery(_ items: [URLQueryItem]) -> String {
        items.map { item in
            let name = item.name.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? item.name
            let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
            return "\(name)=\(value)"
        }
        .joined(separator: "&")
    }

    /// Universal HLS stream for files that can't direct-play (e.g. mkv).
    /// directStream lets the server remux compatible video/audio without
    /// re-encoding; codecs outside the advertised profile get transcoded
    /// to H.264/AAC.
    func hlsStreamURL(ratingKey: String) throws -> URL {
        var components = URLComponents(
            url: config.serverURL.appending(path: "/video/:/transcode/universal/start.m3u8"),
            resolvingAgainstBaseURL: false
        )
        let session = UUID().uuidString
        var videoCodecs = "h264,hevc"
        if Self.supportsAV1 { videoCodecs += ",av1" }
        components?.percentEncodedQuery = Self.encodedQuery([
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "hasMDE", value: "1"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "videoQuality", value: "100"),
            URLQueryItem(name: "videoResolution", value: "4096x2160"),
            URLQueryItem(name: "maxVideoBitrate", value: "200000"),
            URLQueryItem(name: "subtitles", value: "burn"),
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: session),
            URLQueryItem(
                name: "X-Plex-Client-Profile-Extra",
                // fMP4 segments (container=mp4): AVFoundation only renders
                // HEVC/AV1 video in HLS from fMP4, not mpegts - with mpegts
                // the audio plays but the video track never appears.
                value: "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=\(videoCodecs)&audioCodec=aac,mp3)"
            ),
            // "Generic" matches a stock server client profile; unknown platform
            // names (e.g. "macOS") make the transcoder 400 the whole request.
            URLQueryItem(name: "X-Plex-Platform", value: "Generic"),
            URLQueryItem(name: "X-Plex-Device", value: "Mac"),
            URLQueryItem(name: "X-Plex-Product", value: Self.productName),
            URLQueryItem(name: "X-Plex-Token", value: config.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: Self.clientIdentifier),
        ])
        guard let url = components?.url else { throw URLError(.badURL) }
        return url
    }

    /// Universal audio transcode to MP3, the fallback for track codecs
    /// AVFoundation can't play. The explicit music transcode target tells
    /// the server what to produce - without it, an unrecognized client
    /// gets an error instead of a stream.
    func audioStreamURL(ratingKey: String) throws -> URL {
        var components = URLComponents(
            url: config.serverURL.appending(path: "/music/:/transcode/universal/start.mp3"),
            resolvingAgainstBaseURL: false
        )
        let session = UUID().uuidString
        components?.percentEncodedQuery = Self.encodedQuery([
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "http"),
            URLQueryItem(name: "hasMDE", value: "1"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "0"),
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: session),
            URLQueryItem(
                name: "X-Plex-Client-Profile-Extra",
                value: "add-transcode-target(type=musicProfile&context=streaming&protocol=http&container=mp3&audioCodec=mp3)"
            ),
            // Same profile-name requirement as the video transcoder above.
            URLQueryItem(name: "X-Plex-Platform", value: "Generic"),
            URLQueryItem(name: "X-Plex-Product", value: Self.productName),
            URLQueryItem(name: "X-Plex-Token", value: config.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: Self.clientIdentifier),
        ])
        guard let url = components?.url else { throw URLError(.badURL) }
        return url
    }

    /// Reports playback position so on-deck/resume state stays in sync.
    func reportTimeline(ratingKey: String, state: PlaybackState, positionSeconds: Double, durationSeconds: Double) async throws {
        let stateValue = switch state {
        case .started, .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        }
        let query = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: stateValue),
            URLQueryItem(name: "time", value: String(Int(positionSeconds * 1000))),
            URLQueryItem(name: "duration", value: String(Int(durationSeconds * 1000))),
        ]
        _ = try await fetchData(path: "/:/timeline", query: query)
    }

    func setWatched(ratingKey: String, _ watched: Bool) async throws {
        _ = try await fetchData(path: watched ? "/:/scrobble" : "/:/unscrobble", query: [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
        ])
    }

    // MARK: - plex.tv PIN link flow

    struct PIN: Decodable {
        let id: Int
        let code: String
        let authToken: String?
    }

    private static func plexTVRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://plex.tv\(path)")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        return request
    }

    /// Step 1: create a PIN. The user enters its code at https://plex.tv/link.
    /// Non-strong pins are the short 4-character codes that page expects
    /// (strong pins are long codes for the app.plex.tv/auth OAuth flow).
    static func requestPIN() async throws -> PIN {
        let (data, response) = try await URLSession.shared.data(
            for: plexTVRequest(path: "/api/v2/pins", method: "POST")
        )
        try validate(response)
        return try JSONDecoder().decode(PIN.self, from: data)
    }

    /// Step 2: poll until `authToken` is non-nil, meaning the PIN was linked.
    static func checkPIN(id: Int) async throws -> PIN {
        let (data, response) = try await URLSession.shared.data(
            for: plexTVRequest(path: "/api/v2/pins/\(id)", method: "GET")
        )
        try validate(response)
        return try JSONDecoder().decode(PIN.self, from: data)
    }

    /// The plex.tv account a token belongs to, shown in Settings > Accounts.
    struct Account: Decodable {
        let username: String
        let email: String?
    }

    static func account(token: String) async throws -> Account {
        var request = plexTVRequest(path: "/api/v2/user", method: "GET")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(Account.self, from: data)
    }

    /// Lists servers visible to a plex.tv account token. Each resource
    /// carries its own access token (the right token for shared servers),
    /// so discovered servers can be connected without any manual entry.
    /// Prefers a local connection when available.
    static func discoverServers(accountToken: String) async throws -> [PlexDiscoveredServer] {
        struct Resource: Decodable {
            struct Connection: Decodable {
                let uri: String
                let local: Bool
                let address: String
                let port: Int
                let networkProtocol: String
                /// Missing from older server responses.
                let relay: Bool?
                var isRelay: Bool { relay ?? false }

                enum CodingKeys: String, CodingKey {
                    case uri, local, address, port, relay
                    case networkProtocol = "protocol"
                }
            }
            let name: String
            let provides: String
            let clientIdentifier: String
            let accessToken: String?
            let connections: [Connection]?
        }
        var request = plexTVRequest(path: "/api/v2/resources?includeHttps=1", method: "GET")
        request.setValue(accountToken, forHTTPHeaderField: "X-Plex-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let resources = try JSONDecoder().decode([Resource].self, from: data)
        return resources
            .filter { $0.provides.contains("server") }
            .compactMap { resource in
                // Sort: local non-relay first, then remote non-relay, then relay last.
                let sorted = (resource.connections ?? []).sorted {
                    if $0.local != $1.local { return $0.local }
                    if $0.isRelay != $1.isRelay { return !$0.isRelay }
                    return false
                }
                // For each connection emit the direct-IP URL before the plex.direct URI,
                // with relay last. Every request carries the Plex token, so plain HTTP
                // is allowed only for local connections, and even there after https.
                var seen = Set<String>()
                var validURLs: [URL] = []
                for connection in sorted {
                    if !connection.isRelay, !connection.address.isEmpty {
                        for scheme in connection.local ? ["https", "http"] : ["https"] {
                            if let url = URL(string: "\(scheme)://\(connection.address):\(connection.port)"),
                               seen.insert(url.absoluteString).inserted {
                                validURLs.append(url)
                            }
                        }
                    }
                    if let uriURL = URL(string: connection.uri),
                       connection.local || uriURL.scheme?.lowercased() == "https",
                       seen.insert(uriURL.absoluteString).inserted {
                        validURLs.append(uriURL)
                    }
                }
                guard !validURLs.isEmpty else { return nil }
                return PlexDiscoveredServer(
                    clientIdentifier: resource.clientIdentifier,
                    name: resource.name,
                    connections: validURLs,
                    accessToken: resource.accessToken
                )
            }
    }
}

/// A server reachable by the signed-in plex.tv account, as reported by
/// /api/v2/resources.
struct PlexDiscoveredServer: Identifiable, Hashable {
    let clientIdentifier: String
    let name: String
    let connections: [URL]
    let accessToken: String?

    var id: String { clientIdentifier }
}

/// MediaProvider backed by a real Plex server, restricted to the libraries
/// selected in Settings (or all libraries when none are selected).
struct PlexMediaProvider: MediaProvider {
    let client: PlexClient
    let selectedLibraryKeys: Set<String>
    var tvTopLevel: TVTopLevel = .series
    var musicTopLevel: MusicTopLevel = .album

    var source: MediaSource { .plex }

    var serverID: String { client.config.serverID }

    /// Attribute key carrying the originating server's ID, so AppState can
    /// route an item back to the right provider when several Plex servers
    /// are connected.
    static let serverIDAttribute = "plexServerID"

    private func tagged(_ item: MediaItem) -> MediaItem {
        var item = item
        item.attributes[Self.serverIDAttribute] = serverID
        return item
    }

    var id: String { "plex:\(serverID)" }

    func libraries() async throws -> [MediaLibrary] {
        try await client.libraries().compactMap { library in
            guard let type = library.mediaType,
                  selectedLibraryKeys.isEmpty || selectedLibraryKeys.contains(library.key) else { return nil }
            return MediaLibrary(id: library.key, name: library.title, type: type)
        }
    }

    func items(inLibrary library: MediaLibrary) async throws -> [MediaItem] {
        try await client.items(
            inLibrary: library.id,
            type: library.type,
            tvTopLevel: tvTopLevel,
            musicTopLevel: musicTopLevel
        ).map(tagged)
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        try await client.children(of: item).map(tagged)
    }

    func playlists() async throws -> [MediaItem] {
        try await client.playlists().map(tagged)
    }

    func deepSearch(_ query: String, type: MediaType) async throws -> [[MediaItem]] {
        try await client.deepSearch(query, type: type, tvTopLevel: tvTopLevel, musicTopLevel: musicTopLevel)
            .map { $0.map(tagged) }
    }

    func streamURL(for item: MediaItem) async throws -> URL {
        return try await item.kind == .track
            ? client.trackStreamURL(ratingKey: item.id)
            : client.videoStreamURL(ratingKey: item.id)
    }

    func originalFileURL(for item: MediaItem) async throws -> URL {
        try await client.originalFileURL(ratingKey: item.id)
    }

    func downloadURL(for item: MediaItem) async throws -> URL {
        guard let url = await client.downloadFileURL(ratingKey: item.id) else {
            throw URLError(.badURL)
        }
        return url
    }

    func nextMovie(after item: MediaItem, by criterion: MovieAutoContinue) async throws -> MediaItem? {
        try await client.nextMovie(after: item, by: criterion).map(tagged)
    }

    func webURL(for item: MediaItem) async throws -> URL? {
        try await client.webURL(ratingKey: item.id)
    }

    func randomTrack(sameArtistAs item: MediaItem) async throws -> MediaItem? {
        try await client.randomTrack(sameArtistAs: item).map(tagged)
    }

    func continueWatching() async throws -> [MediaItem] {
        try await client.continueWatching(inLibraries: selectedLibraryKeys).map(tagged)
    }

    func reportPlayback(of item: MediaItem, state: PlaybackState, positionSeconds: Double, durationSeconds: Double) async throws {
        try await client.reportTimeline(ratingKey: item.id, state: state, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
    }

    func setWatched(_ item: MediaItem, _ watched: Bool) async throws {
        try await client.setWatched(ratingKey: item.id, watched)
    }
}
