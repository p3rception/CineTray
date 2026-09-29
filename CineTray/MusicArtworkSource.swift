import Foundation

/// Where Local Library music gets album covers and artist photos. Sources are
/// tried in declaration order; each can be turned off in Settings > Accounts.
enum MusicArtworkSource: String, CaseIterable, Identifiable {
    case deezer, musicBrainz, lastfm, theAudioDB, discogs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deezer: "Deezer"
        case .musicBrainz: "MusicBrainz"
        case .lastfm: "Last.fm"
        case .theAudioDB: "TheAudioDB"
        case .discogs: "Discogs"
        }
    }

    static var enabled: [Self] {
        let disabled = (UserDefaults.standard.string(forKey: SettingsKeys.disabledMusicArtworkSources) ?? "")
            .split(separator: ",").map(String.init)
        return allCases.filter { !disabled.contains($0.rawValue) }
    }

    /// The album cover from the first enabled source that has one, falling
    /// back to a photo of the artist.
    static func imageURL(artist: String, album: String) async -> URL? {
        guard !artist.isEmpty else { return nil }
        let sources = enabled
        if !album.isEmpty {
            for source in sources {
                if let url = await source.imageURL(artist: artist, album: album) { return url }
            }
        }
        for source in sources {
            if let url = await source.imageURL(artist: artist, album: nil) { return url }
        }
        return nil
    }

    /// Album cover when `album` is given, otherwise an artist photo. Web
    /// addresses only: a file:// URL in a response would be read from disk.
    private func imageURL(artist: String, album: String?) async -> URL? {
        let url = switch self {
        case .deezer: await deezer(artist: artist, album: album)
        case .musicBrainz: await musicBrainz(artist: artist, album: album)
        case .lastfm: await lastfm(artist: artist, album: album)
        case .theAudioDB: await theAudioDB(artist: artist, album: album)
        case .discogs: await discogs(artist: artist, album: album)
        }
        return url.flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
    }

    private func deezer(artist: String, album: String?) async -> URL? {
        struct Response: Decodable {
            struct Result: Decodable { let name: String?; let coverXl: String?; let pictureXl: String? }
            let data: [Result]
        }
        let response = if let album {
            await fetch(Response.self, "https://api.deezer.com/search/album",
                        query: ["q": "artist:\"\(Self.phrase(artist))\" album:\"\(Self.phrase(album))\"", "limit": "1"])
        } else {
            // A field search ranks tribute bands first; a plain one ranks by popularity.
            await fetch(Response.self, "https://api.deezer.com/search/artist", query: ["q": artist, "limit": "5"])
        }
        let match = album != nil
            ? response?.data.first
            : response?.data.first { $0.name?.localizedCaseInsensitiveCompare(artist) == .orderedSame }
        guard let match, let image = match.coverXl ?? match.pictureXl,
              // Deezer leaves the image hash empty ("/artist//1000x1000-...") when it has none.
              !image.contains("//1000x1000") else { return nil }
        return URL(string: image)
    }

    /// MusicBrainz has no artist photos; album covers come from the Cover Art Archive.
    private func musicBrainz(artist: String, album: String?) async -> URL? {
        guard let album else { return nil }
        struct Search: Decodable {
            struct ReleaseGroup: Decodable { let id: String; let score: Int }
            let releaseGroups: [ReleaseGroup]
            enum CodingKeys: String, CodingKey { case releaseGroups = "release-groups" }
        }
        struct CoverArt: Decodable {
            struct Image: Decodable { let front: Bool; let image: String; let thumbnails: [String: String] }
            let images: [Image]
        }
        // MusicBrainz blocks clients that send more than one request per second.
        // ponytail: fixed pause; fine for the sequential Local Library refresh.
        try? await Task.sleep(for: .seconds(1))
        guard let search = await fetch(Search.self, "https://musicbrainz.org/ws/2/release-group/", query: [
            "query": "artist:\"\(Self.phrase(artist))\" AND releasegroup:\"\(Self.phrase(album))\"",
            "fmt": "json",
            "limit": "1",
        ]),
              // Search is fuzzy; a low score is usually a different album.
              let group = search.releaseGroups.first, group.score >= 90,
              let art = await fetch(CoverArt.self, "https://coverartarchive.org/release-group/\(group.id)", query: [:]),
              let front = art.images.first(where: \.front) else { return nil }
        return URL(string: front.thumbnails["500"] ?? front.thumbnails["large"] ?? front.image)
    }

    private func lastfm(artist: String, album: String?) async -> URL? {
        if let album {
            return await LastFMClient().albumInfo(artist: artist, album: album)?.imageURL
        }
        return await LastFMClient().artistImageURL(artist: artist)
    }

    private func theAudioDB(artist: String, album: String?) async -> URL? {
        struct Response: Decodable {
            struct Result: Decodable { let strAlbumThumb: String?; let strArtistThumb: String? }
            let album: [Result]?
            let artists: [Result]?
        }
        // "123" is TheAudioDB's public free key; a paid key raises the rate limit.
        let key = KeychainStore.string(for: KeychainKeys.theAudioDBAPIKey) ?? "123"
        let base = "https://www.theaudiodb.com/api/v1/json/\(key)/"
        let response = if let album {
            await fetch(Response.self, base + "searchalbum.php", query: ["s": artist, "a": album])
        } else {
            await fetch(Response.self, base + "search.php", query: ["s": artist])
        }
        let result = response?.album?.first ?? response?.artists?.first
        return (result?.strAlbumThumb ?? result?.strArtistThumb).flatMap(URL.init(string:))
    }

    private func discogs(artist: String, album: String?) async -> URL? {
        guard let token = KeychainStore.string(for: KeychainKeys.discogsToken) else { return nil }
        struct Response: Decodable {
            struct Result: Decodable { let coverImage: String? }
            let results: [Result]
        }
        let query = if let album {
            ["artist": artist, "release_title": album, "type": "release", "per_page": "1"]
        } else {
            ["q": artist, "type": "artist", "per_page": "1"]
        }
        guard let image = await fetch(Response.self, "https://api.discogs.com/database/search", query: query,
                                      headers: ["Authorization": "Discogs token=\(token)"])?.results.first?.coverImage,
              // Discogs answers with a blank spacer image when it has none.
              !image.hasSuffix("spacer.gif") else { return nil }
        return URL(string: image)
    }

    /// Search phrases are quoted, so quotes and backslashes in names would end them early.
    private static func phrase(_ text: String) -> String {
        text.filter { $0 != "\"" && $0 != "\\" }
    }

    // MusicBrainz and Discogs reject requests without an identifying User-Agent.
    private static let userAgent = "CineTray/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") ( https://github.com/p3rception/CineTray )"

    /// A missing image is not an error worth reporting, so failures become nil.
    private func fetch<T: Decodable>(_ type: T.Type, _ url: String, query: [String: String],
                                     headers: [String: String] = [:]) async -> T? {
        guard var components = URLComponents(string: url) else { return nil }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        guard let (data, response) = try? await URLSession.uncached.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(T.self, from: data)
    }
}
