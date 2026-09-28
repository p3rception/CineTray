import CryptoKit
import Foundation

struct NavidromeConfiguration {
    var serverURL: URL
    var username: String
    /// Subsonic token auth: md5(password + salt), stored instead of the password.
    var token: String
    var salt: String

    /// Subsonic accepts credentials only as query items, never as a header.
    var authQuery: [URLQueryItem] {
        [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "QuPi"),
            URLQueryItem(name: "f", value: "json"),
        ]
    }
}

/// Minimal Subsonic API client for Navidrome. Music only.
struct NavidromeClient {
    let config: NavidromeConfiguration

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A new random salt and the token that goes with it.
    static func credentials(password: String) -> (token: String, salt: String) {
        let salt = UUID().uuidString.replacing("-", with: "").lowercased()
        let digest = Insecure.MD5.hash(data: Data((password + salt).utf8))
        return (digest.map { String(format: "%02x", $0) }.joined(), salt)
    }

    private func url(_ method: String, _ query: [URLQueryItem] = []) -> URL {
        config.serverURL.appending(path: "/rest/\(method)").appending(queryItems: query + config.authQuery)
    }

    private struct Envelope<Body: Decodable>: Decodable {
        let body: Body
        enum CodingKeys: String, CodingKey { case body = "subsonic-response" }
    }

    private struct Status: Decodable {
        struct Failure: Decodable { let message: String? }
        let status: String
        let error: Failure?
    }

    private func get<Body: Decodable>(_ method: String, _ query: [URLQueryItem] = [], as _: Body.Type) async throws -> Body {
        let (data, response) = try await URLSession.shared.data(from: url(method, query))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        // Errors, wrong credentials included, arrive with HTTP 200.
        let status = try JSONDecoder().decode(Envelope<Status>.self, from: data).body
        guard status.status == "ok" else {
            throw ServerError(message: status.error?.message ?? "The server reported an error.")
        }
        return try JSONDecoder().decode(Envelope<Body>.self, from: data).body
    }

    /// Checks the server address and credentials.
    func ping() async throws {
        _ = try await get("ping", as: Status.self)
    }

    // MARK: - Catalog

    private struct Artist: Decodable {
        let id: String
        let name: String
        let coverArt: String?
        let album: [Album]?
    }

    private struct Album: Decodable {
        let id: String
        let name: String
        let artist: String?
        let artistId: String?
        let coverArt: String?
        let year: Int?
        let created: String?
        let playCount: Int?
        let song: [Song]?
    }

    private struct Song: Decodable {
        let id: String
        let title: String
        let artist: String?
        let artistId: String?
        let album: String?
        let albumId: String?
        let coverArt: String?
        let suffix: String?
        let path: String?
        let year: Int?
        let created: String?
        let playCount: Int?
    }

    func libraries() async throws -> [MediaLibrary] {
        struct Body: Decodable {
            struct Folder: Decodable { let id: Int; let name: String? }
            struct Folders: Decodable { let musicFolder: [Folder]? }
            let musicFolders: Folders
        }
        return try await get("getMusicFolders", as: Body.self).musicFolders.musicFolder?.map {
            MediaLibrary(id: String($0.id), name: $0.name ?? MediaType.music.title, type: .music)
        } ?? []
    }

    func items(inLibrary libraryID: String, musicTopLevel: MusicTopLevel) async throws -> [MediaItem] {
        let folder = URLQueryItem(name: "musicFolderId", value: libraryID)
        if musicTopLevel == .artist {
            struct Body: Decodable {
                struct Index: Decodable { let artist: [Artist]? }
                struct Artists: Decodable { let index: [Index]? }
                let artists: Artists
            }
            let index = try await get("getArtists", [folder], as: Body.self).artists.index ?? []
            return index.flatMap { $0.artist ?? [] }.map(artistItem)
        }
        struct Body: Decodable {
            struct List: Decodable { let album: [Album]? }
            let albumList2: List
        }
        // 500 is the most one page may hold. ponytail: capped at 100,000 albums.
        var albums: [Album] = []
        for offset in stride(from: 0, to: 100_000, by: 500) {
            let page = try await get("getAlbumList2", [
                folder,
                URLQueryItem(name: "type", value: "alphabeticalByName"),
                URLQueryItem(name: "size", value: "500"),
                URLQueryItem(name: "offset", value: String(offset)),
            ], as: Body.self).albumList2.album ?? []
            albums += page
            if page.count < 500 { break }
        }
        return albums.map { albumItem($0, parent: nil) }
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        switch item.kind {
        case .artist:
            struct Body: Decodable { let artist: Artist }
            let artist = try await get("getArtist", [URLQueryItem(name: "id", value: item.id)], as: Body.self).artist
            return (artist.album ?? []).map { albumItem($0, parent: item) }
        case .album:
            struct Body: Decodable { let album: Album }
            let album = try await get("getAlbum", [URLQueryItem(name: "id", value: item.id)], as: Body.self).album
            return (album.song ?? []).map { trackItem($0, parent: item) }
        case .playlist:
            struct Body: Decodable {
                struct Playlist: Decodable { let entry: [Song]? }
                let playlist: Playlist
            }
            let playlist = try await get("getPlaylist", [URLQueryItem(name: "id", value: item.id)], as: Body.self).playlist
            return (playlist.entry ?? []).map { trackItem($0, parent: item) }
        default:
            return []
        }
    }

    func playlists() async throws -> [MediaItem] {
        struct Body: Decodable {
            struct Playlist: Decodable { let id: String; let name: String; let comment: String?; let coverArt: String? }
            struct Playlists: Decodable { let playlist: [Playlist]? }
            let playlists: Playlists
        }
        return try await get("getPlaylists", as: Body.self).playlists.playlist?.map {
            MediaItem(id: $0.id, source: .navidrome, type: .music, kind: .playlist, title: $0.name,
                      posterURL: coverArtURL($0.coverArt), summary: $0.comment)
        } ?? []
    }

    /// Search results as ancestor chains down to the match, as the other
    /// providers return them.
    func deepSearch(_ query: String, musicTopLevel: MusicTopLevel) async throws -> [[MediaItem]] {
        struct Body: Decodable {
            struct Result: Decodable { let artist: [Artist]?; let album: [Album]?; let song: [Song]? }
            let searchResult3: Result
        }
        let result = try await get("search3", [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: "20"),
            URLQueryItem(name: "albumCount", value: "20"),
            URLQueryItem(name: "songCount", value: "50"),
        ], as: Body.self).searchResult3

        func artist(id: String?, name: String?) -> MediaItem? {
            guard musicTopLevel == .artist, let id, let name else { return nil }
            return MediaItem(id: id, source: .navidrome, type: .music, kind: .artist, title: name)
        }
        let artists = musicTopLevel == .artist ? (result.artist ?? []).map { [artistItem($0)] } : []
        let albums = (result.album ?? []).map { album in
            let artist = artist(id: album.artistId, name: album.artist)
            return (artist.map { [$0] } ?? []) + [albumItem(album, parent: artist)]
        }
        let songs = (result.song ?? []).compactMap { song -> [MediaItem]? in
            guard let albumID = song.albumId else { return nil }
            let artist = artist(id: song.artistId, name: song.artist)
            let album = MediaItem(id: albumID, source: .navidrome, type: .music, kind: .album,
                                  title: song.album ?? "Album", subtitle: song.artist,
                                  posterURL: coverArtURL(song.coverArt),
                                  parentID: artist?.id, parentKind: artist?.kind)
            return (artist.map { [$0] } ?? []) + [album, trackItem(song, parent: album)]
        }
        return artists + albums + songs
    }

    /// A random other track by the same artist, from one of their albums.
    func randomTrack(sameArtistAs item: MediaItem) async throws -> MediaItem? {
        struct Body: Decodable { let song: Song }
        let song = try await get("getSong", [URLQueryItem(name: "id", value: item.id)], as: Body.self).song
        guard let artistID = song.artistId else { return nil }
        let artist = MediaItem(id: artistID, source: .navidrome, type: .music, kind: .artist, title: song.artist ?? "")
        guard let album = try await children(of: artist).randomElement() else { return nil }
        return try await children(of: album).filter { $0.id != item.id }.randomElement()
    }

    // MARK: - Items

    private func artistItem(_ artist: Artist) -> MediaItem {
        MediaItem(id: artist.id, source: .navidrome, type: .music, kind: .artist, title: artist.name,
                  posterURL: coverArtURL(artist.coverArt))
    }

    private func albumItem(_ album: Album, parent: MediaItem?) -> MediaItem {
        MediaItem(
            id: album.id,
            source: .navidrome,
            type: .music,
            kind: .album,
            title: album.name,
            // Under an artist the year says more than the artist's name again.
            subtitle: parent == nil ? album.artist : album.year.map(String.init),
            posterURL: coverArtURL(album.coverArt),
            parentID: parent?.id,
            parentKind: parent?.kind,
            parentTitle: parent?.title,
            parentPosterURL: parent?.posterURL,
            attributes: ["releaseDate": album.year.map(String.init) ?? ""],
            addedAt: Self.date(album.created),
            playCount: album.playCount
        )
    }

    private func trackItem(_ song: Song, parent: MediaItem) -> MediaItem {
        MediaItem(
            id: song.id,
            source: .navidrome,
            type: .music,
            kind: .track,
            title: song.title,
            subtitle: song.artist,
            posterURL: coverArtURL(song.coverArt),
            parentID: parent.id,
            parentKind: parent.kind,
            parentTitle: parent.title,
            parentPosterURL: parent.posterURL,
            attributes: [
                "releaseDate": song.year.map(String.init) ?? "",
                "originalPath": song.path ?? "",
                "suffix": song.suffix?.lowercased() ?? "",
                "albumID": song.albumId ?? "",
            ],
            addedAt: Self.date(song.created),
            playCount: song.playCount
        )
    }

    /// ponytail: keeps date and time and drops fractions and zone; close enough for sorting by date added.
    private static func date(_ string: String?) -> Date? {
        string.flatMap { try? Date(String($0.prefix(19)) + "Z", strategy: .iso8601) }
    }

    /// Cover art URLs are saved (settings, download indexes), so they carry
    /// no credentials; `ArtworkCache.request(for:)` adds them when loading.
    private func coverArtURL(_ id: String?) -> URL? {
        id.map {
            config.serverURL.appending(path: "/rest/getCoverArt").appending(queryItems: [
                URLQueryItem(name: "id", value: $0),
                URLQueryItem(name: "size", value: "600"),
            ])
        }
    }

    // MARK: - Playback

    /// Containers play their first track (e.g. an album picked in search).
    func streamURL(for item: MediaItem) async throws -> URL {
        var track = item
        while track.kind != .track {
            guard let first = try await children(of: track).first else { throw URLError(.resourceUnavailable) }
            track = first
        }
        // AVPlayer can't play Ogg, Opus or WMA, so the server converts those to MP3.
        let playable: Set = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "aif", "aiff"]
        let format = playable.contains(track.attributes["suffix"] ?? "") ? "raw" : "mp3"
        return url("stream", [URLQueryItem(name: "id", value: track.id), URLQueryItem(name: "format", value: format)])
    }

    func downloadURL(itemID: String) -> URL {
        url("download", [URLQueryItem(name: "id", value: itemID)])
    }

    /// The item's page in the Navidrome web app; a track opens its album.
    func webURL(for item: MediaItem) -> URL? {
        let page: (String, String?) = switch item.kind {
        case .artist: ("artist", item.id)
        case .album: ("album", item.id)
        case .playlist: ("playlist", item.id)
        case .track: ("album", item.attributes["albumID"])
        default: ("", nil)
        }
        guard let id = page.1, !id.isEmpty,
              var components = URLComponents(url: config.serverURL.appending(path: "/app/"), resolvingAgainstBaseURL: false)
        else { return nil }
        components.fragment = "/\(page.0)/\(id)/show"
        return components.url
    }

    /// Now Playing when a track starts, and a play (play count, history, the
    /// server's own Last.fm forwarding) when it stops past the halfway mark.
    func reportPlayback(itemID: String, state: PlaybackState, positionSeconds: Double, durationSeconds: Double) async throws {
        let submission: Bool
        switch state {
        case .started: submission = false
        case .stopped where durationSeconds > 0 && positionSeconds > durationSeconds / 2: submission = true
        default: return
        }
        _ = try await get("scrobble", [
            URLQueryItem(name: "id", value: itemID),
            URLQueryItem(name: "submission", value: String(submission)),
        ], as: Status.self)
    }
}

struct NavidromeMediaProvider: MediaProvider {
    let client: NavidromeClient
    var musicTopLevel: MusicTopLevel = .album

    var source: MediaSource { .navidrome }
    var id: String { "navidrome" }

    func libraries() async throws -> [MediaLibrary] {
        try await client.libraries()
    }

    func items(inLibrary library: MediaLibrary) async throws -> [MediaItem] {
        try await client.items(inLibrary: library.id, musicTopLevel: musicTopLevel)
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        try await client.children(of: item)
    }

    func playlists() async throws -> [MediaItem] {
        try await client.playlists()
    }

    func deepSearch(_ query: String, type: MediaType) async throws -> [[MediaItem]] {
        type == .music ? try await client.deepSearch(query, musicTopLevel: musicTopLevel) : []
    }

    func streamURL(for item: MediaItem) async throws -> URL {
        try await client.streamURL(for: item)
    }

    func downloadURL(for item: MediaItem) async throws -> URL {
        client.downloadURL(itemID: item.id)
    }

    func randomTrack(sameArtistAs item: MediaItem) async throws -> MediaItem? {
        try await client.randomTrack(sameArtistAs: item)
    }

    func webURL(for item: MediaItem) async throws -> URL? {
        client.webURL(for: item)
    }

    func reportPlayback(of item: MediaItem, state: PlaybackState, positionSeconds: Double, durationSeconds: Double) async throws {
        try await client.reportPlayback(itemID: item.id, state: state, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
    }
}
