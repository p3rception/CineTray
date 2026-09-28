import Foundation

struct TorrServerConfiguration {
    var serverURL: URL
    /// HTTP Basic credentials, for servers started with --httpauth.
    var username: String?
    var password: String?
}

/// Client for TorrServer (github.com/YouROK/TorrServer), which streams the
/// files of torrents over HTTP. Movies and shows only.
struct TorrServerClient {
    let config: TorrServerConfiguration

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Torrent: Decodable {
        let hash: String
        let title: String
        let category: String?
        let poster: String?
        let data: String?
        let timestamp: Double?
        /// Only present while the torrent is active on the server.
        let file_stats: [File]?
    }

    struct File: Decodable {
        /// 1-based, in path order.
        let id: Int
        let path: String
        let length: Int64?
    }

    /// What a torrent's `data` may hold: the file list TorrServer saves when
    /// `data` was empty, or the TMDB entry Lampa stores when it adds a torrent.
    struct Metadata: Decodable {
        struct Files: Decodable { let Files: [File]? }
        struct TMDB: Decodable {
            let id: Int?
            let title: String?
            let name: String?
            let release_date: String?
            let first_air_date: String?
            let overview: String?
            let poster_path: String?
        }
        let TorrServer: Files?
        let movie: TMDB?
    }

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        let url = config.serverURL.appending(path: path)
        var request = URLRequest(url: query.isEmpty ? url : url.appending(queryItems: query))
        if let username = config.username, let password = config.password {
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func load<Body: Decodable>(_ request: URLRequest, as _: Body.Type) async throws -> Body {
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return try JSONDecoder().decode(Body.self, from: data)
        case 401: throw ServerError(message: "Wrong username or password.")
        default: throw URLError(.badServerResponse)
        }
    }

    func torrents() async throws -> [Torrent] {
        var request = request("torrents")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"action":"list"}"#.utf8)
        return try await load(request, as: [Torrent].self)
    }

    /// The torrent's files. Asking the server makes it join the swarm, which
    /// can take seconds, so a list it already has is used first.
    func files(of torrent: Torrent) async throws -> [File] {
        if let files = torrent.file_stats ?? Self.metadata(of: torrent)?.TorrServer?.Files, !files.isEmpty {
            return files
        }
        let status = try await load(
            request("stream", query: [URLQueryItem(name: "link", value: torrent.hash), URLQueryItem(name: "stat", value: nil)]),
            as: Torrent.self
        )
        return status.file_stats ?? []
    }

    /// Needs no credentials: TorrServer plays any torrent in its list without
    /// them. The file name in the path gives the player the container type.
    func streamURL(hash: String, fileID: Int, path: String) -> URL {
        let name = path.split(separator: "/").last.map(String.init) ?? "video"
        return config.serverURL.appending(path: "stream/\(name)").appending(queryItems: [
            URLQueryItem(name: "link", value: hash),
            URLQueryItem(name: "index", value: String(fileID)),
            URLQueryItem(name: "play", value: nil),
        ])
    }

    static func metadata(of torrent: Torrent) -> Metadata? {
        // Arbitrary JSON set by whichever client added the torrent; anything
        // else is simply not metadata.
        torrent.data.flatMap { try? JSONDecoder().decode(Metadata.self, from: Data($0.utf8)) }
    }
}

/// MediaProvider backed by TorrServer. Torrents become movies, or episodes
/// grouped into one show per TMDB id or cleaned-up title, with season and
/// episode numbers taken from the file names.
struct TorrServerMediaProvider: MediaProvider {
    let client: TorrServerClient

    var source: MediaSource { .torrServer }
    var id: String { "torrserver" }

    private static let videoExtensions: Set = ["mkv", "mp4", "m4v", "mov", "avi", "wmv", "ts", "m2ts", "webm", "mpg", "mpeg", "flv", "vob"]

    /// "Movies" and "Shows", like the local library, so they merge with a
    /// server library of the same name.
    func libraries() async throws -> [MediaLibrary] {
        let types = Set(try await catalog().map(\.item.type))
        return [MediaType.movies, .tvShows].filter(types.contains).map { MediaLibrary(id: $0.rawValue, name: $0.title, type: $0) }
    }

    func items(inLibrary library: MediaLibrary) async throws -> [MediaItem] {
        try await catalog().map(\.item).filter { $0.type == library.type }
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        switch item.kind {
        case .show:
            var seasons: [MediaItem] = []
            for episode in try await episodes(ofShow: item.id) where !seasons.contains(where: { $0.id == episode.parentID }) {
                seasons.append(MediaItem(
                    id: episode.parentID ?? "",
                    source: .torrServer,
                    type: .tvShows,
                    kind: .season,
                    title: episode.parentTitle ?? "",
                    posterURL: episode.parentPosterURL,
                    parentID: item.id,
                    parentKind: .show,
                    parentTitle: item.title,
                    parentPosterURL: item.posterURL
                ))
            }
            return seasons
        case .season:
            // Season ids are "<show id>|<number>"; auto-continue asks with an
            // id-only stub, so the id must be enough.
            guard let bar = item.id.lastIndex(of: "|") else { return [] }
            return try await episodes(ofShow: String(item.id[..<bar])).filter { $0.parentID == item.id }
        default:
            return []
        }
    }

    func streamURL(for item: MediaItem) async throws -> URL {
        if item.kind == .episode, let dash = item.id.lastIndex(of: "-"),
           let fileID = Int(item.id[item.id.index(after: dash)...]), let path = item.attributes["originalPath"] {
            return client.streamURL(hash: String(item.id[..<dash]), fileID: fileID, path: path)
        }
        guard item.kind == .movie, let torrent = try await client.torrents().first(where: { $0.hash == item.id }) else {
            throw URLError(.resourceUnavailable)
        }
        let videos = try await client.files(of: torrent).filter(Self.isVideo)
        guard let file = videos.max(by: { ($0.length ?? 0) < ($1.length ?? 0) }) else {
            throw URLError(.resourceUnavailable)
        }
        return client.streamURL(hash: torrent.hash, fileID: file.id, path: file.path)
    }

    /// TorrServer serves the original file, with Range support.
    func downloadURL(for item: MediaItem) async throws -> URL {
        try await streamURL(for: item)
    }

    /// TorrServer's web app has no page per torrent, only its list.
    func webURL(for item: MediaItem) async throws -> URL? {
        client.config.serverURL
    }

    // MARK: - Catalog

    /// Every movie and show, each with the torrents behind it, newest first.
    private func catalog() async throws -> [(item: MediaItem, torrents: [TorrServerClient.Torrent])] {
        let torrents = try await client.torrents().sorted { ($0.timestamp ?? 0) > ($1.timestamp ?? 0) }
        var result: [(item: MediaItem, torrents: [TorrServerClient.Torrent])] = []
        for torrent in torrents {
            let tmdb = TorrServerClient.metadata(of: torrent)?.movie
            guard let type = Self.mediaType(of: torrent, tmdb: tmdb) else { continue }
            let title = tmdb?.title ?? tmdb?.name ?? Self.cleanTitle(torrent.title)
            let key = tmdb?.id.map { "tmdb\($0)" } ?? title.lowercased()
            let id = type == .movies ? torrent.hash : "show:\(key)"
            // A release without TMDB data joins the show with its title.
            if let index = result.firstIndex(where: { $0.item.id == id || type == .tvShows && $0.item.kind == .show && $0.item.title.lowercased() == title.lowercased() }) {
                result[index].torrents.append(torrent)
                continue
            }
            let date = tmdb?.release_date ?? tmdb?.first_air_date
            let year = date.flatMap { Int($0.prefix(4)) } ?? torrent.title.firstMatch(of: (/\b(?:19|20)\d{2}\b/).wordBoundaryKind(.simple)).flatMap { Int($0.output) }
            let poster = torrent.poster.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                ?? tmdb?.poster_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") }
            result.append((MediaItem(
                id: id,
                source: .torrServer,
                type: type,
                kind: type == .movies ? .movie : .show,
                title: title,
                subtitle: year.map(String.init),
                posterURL: poster,
                summary: tmdb?.overview,
                addedAt: torrent.timestamp.map { Date(timeIntervalSince1970: $0) }
            ), [torrent]))
        }
        return result
    }

    /// Categories are TorrServer's own ("movie", "tv", "music", "other");
    /// torrents added without one (Lampa) are sorted by their metadata or title.
    private static func mediaType(of torrent: TorrServerClient.Torrent, tmdb: TorrServerClient.Metadata.TMDB?) -> MediaType? {
        switch torrent.category ?? "" {
        case "movie": .movies
        case "tv": .tvShows
        case "": tmdb?.first_air_date != nil || seasonNumber(in: torrent.title) != nil ? .tvShows : .movies
        default: nil
        }
    }

    /// "The.Matrix.1999.1080p.BluRay" becomes "The Matrix": the name ends at
    /// the first year, season or resolution tag. The regexes here use simple
    /// word boundaries; Unicode ones don't break between "Matrix.1999".
    private static func cleanTitle(_ title: String) -> String {
        let end = title.firstMatch(of: (/[\s._\-\[(]+(?:[Ss]\d{1,2}|[Ss]eason\s*\d|(?:19|20)\d{2}\b|\d{3,4}p\b)/).wordBoundaryKind(.simple))?.range.lowerBound ?? title.endIndex
        let name = title[..<end].replacing(/[._]/, with: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? title : name
    }

    private static func seasonNumber(in text: String) -> Int? {
        (text.firstMatch(of: (/\b[Ss](\d{1,2})(?:[Ee]\d|\b)/).wordBoundaryKind(.simple))?.output.1 ?? text.firstMatch(of: /[Ss]eason\s*(\d{1,2})/)?.output.1)
            .flatMap { Int($0) }
    }

    /// "Show.S01E02.mkv", "Show s1.e2.mkv" or "Show 1x02.mkv".
    private static func episodeNumber(in name: String) -> (season: Int, episode: Int)? {
        if let match = name.firstMatch(of: /[Ss](\d{1,2})[ ._\-]?[Ee](\d{1,3})/) ?? name.firstMatch(of: (/\b(\d{1,2})x(\d{2,3})\b/).wordBoundaryKind(.simple)),
           let season = Int(match.output.1), let episode = Int(match.output.2) {
            return (season, episode)
        }
        return nil
    }

    private static func isVideo(_ file: TorrServerClient.File) -> Bool {
        videoExtensions.contains((file.path as NSString).pathExtension.lowercased())
    }

    /// The show's episodes across all its torrents, in season and episode
    /// order. When two torrents have the same episode, the newest wins.
    private func episodes(ofShow showID: String) async throws -> [MediaItem] {
        guard let entry = try await catalog().first(where: { $0.item.id == showID }) else { return [] }
        let (show, torrents, client) = (entry.item, entry.torrents, client)
        let results = await withTaskGroup(of: (Int, Result<[TorrServerClient.File], Error>).self) { group in
            for (index, torrent) in torrents.enumerated() {
                group.addTask { @MainActor in
                    do { return (index, .success(try await client.files(of: torrent))) } catch { return (index, .failure(error)) }
                }
            }
            var results = [Result<[TorrServerClient.File], Error>](repeating: .success([]), count: torrents.count)
            for await (index, result) in group { results[index] = result }
            return results
        }
        // Torrents the server can't reach are left out, unless that is all of them.
        if case .failure(let error) = results.first, results.allSatisfy({ (try? $0.get()) == nil }) { throw error }

        var episodes: [(season: Int, episode: Int, item: MediaItem)] = []
        for (torrent, result) in zip(torrents, results) {
            let videos = ((try? result.get()) ?? []).filter(Self.isVideo).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            // ponytail: files without S01E02-style numbers are numbered in path
            // order within the torrent's season; parse "01. Title.mkv" if that misplaces packs.
            var unnumbered = 0
            for file in videos {
                let number = Self.episodeNumber(in: file.path) ?? {
                    unnumbered += 1
                    return (Self.seasonNumber(in: torrent.title) ?? 1, unnumbered)
                }()
                guard !episodes.contains(where: { $0.season == number.season && $0.episode == number.episode }) else { continue }
                let seasonTitle = number.season == 0 ? "Specials" : "Season \(number.season)"
                episodes.append((number.season, number.episode, MediaItem(
                    id: "\(torrent.hash)-\(file.id)",
                    source: .torrServer,
                    type: .tvShows,
                    kind: .episode,
                    title: "Episode \(number.episode)",
                    subtitle: "S\(number.season)E\(number.episode)",
                    posterURL: show.posterURL,
                    parentID: "\(showID)|\(number.season)",
                    parentKind: .season,
                    parentTitle: seasonTitle,
                    parentPosterURL: show.posterURL,
                    attributes: [
                        "originalPath": file.path,
                        "grandparentTitle": show.title,
                        "grandparentRatingKey": showID,
                        "grandparentPosterURL": show.posterURL?.absoluteString ?? "",
                    ]
                )))
            }
        }
        return episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }.map(\.item)
    }
}
