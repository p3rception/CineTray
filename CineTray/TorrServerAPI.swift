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
        let torrent_size: Int64?
        /// Only in `stat` answers; MatriX.145 leaves it out of the list.
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
            let original_title: String?
            let original_name: String?
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

    /// File lists fetched this session. A torrent's files never change.
    private static var fetchedFiles: [String: [File]] = [:]

    /// The file list known without waking the torrent: fetched earlier, in
    /// `file_stats`, or saved by TorrServer in `data`.
    static func knownFiles(of torrent: Torrent) -> [File]? {
        (fetchedFiles[torrent.hash] ?? torrent.file_stats ?? metadata(of: torrent)?.TorrServer?.Files).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The torrent's files. Asking the server wakes an idle torrent, and it
    /// answers only once it has found peers: up to 90 seconds, then a 500.
    func files(of torrent: Torrent) async throws -> [File] {
        if let files = Self.knownFiles(of: torrent) { return files }
        var request = request("stream", query: [URLQueryItem(name: "link", value: torrent.hash), URLQueryItem(name: "stat", value: nil)])
        // The server keeps looking for peers after we stop waiting, so a
        // retry a minute later finds the files.
        request.timeoutInterval = 20
        let notReady = ServerError(message: "TorrServer is still looking for peers for this release. Try again in a minute.")
        do {
            guard let files = try await load(request, as: Torrent.self).file_stats, !files.isEmpty else { throw notReady }
            Self.fetchedFiles[torrent.hash] = files
            return files
        } catch let error as URLError where error.code == .timedOut || error.code == .badServerResponse {
            throw notReady
        }
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
            guard let torrents = try await catalog().first(where: { $0.item.id == item.id })?.torrents else { return [] }
            // Asking for a torrent's files wakes it, which can take a minute.
            // Seasons come from known file lists and titles; any other release
            // gets a card of its own and is woken only when opened.
            let unknown = torrents.filter { TorrServerClient.knownFiles(of: $0) == nil }
            let known = await episodes(of: torrents.filter { TorrServerClient.knownFiles(of: $0) != nil }, show: item).episodes.map(\.season)
            let seasons = Set(known + unknown.compactMap { Self.seasons(in: $0.title) }.joined()).sorted()
            func card(_ key: String, _ title: String, _ subtitle: String? = nil) -> MediaItem {
                MediaItem(
                    id: "\(item.id)|\(key)",
                    source: .torrServer,
                    type: .tvShows,
                    kind: .season,
                    title: title,
                    subtitle: subtitle,
                    posterURL: item.posterURL,
                    parentID: item.id,
                    parentKind: .show,
                    parentTitle: item.title,
                    parentPosterURL: item.posterURL
                )
            }
            return seasons.map { card(String($0), $0 == 0 ? "Specials" : "Season \($0)") }
                + unknown.filter { Self.seasons(in: $0.title) == nil }.map { torrent in
                    card(torrent.hash,
                         torrent.timestamp.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? "Release",
                         torrent.torrent_size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
                }
        case .season:
            // Season ids are "<show id>|<number>", or "<show id>|<hash>" for a
            // release card; auto-continue asks with an id-only stub, so the id
            // must be enough.
            guard let bar = item.id.lastIndex(of: "|"),
                  let entry = try await catalog().first(where: { $0.item.id == item.id[..<bar] }) else { return [] }
            let key = String(item.id[item.id.index(after: bar)...])
            let number = Int(key)
            let torrents = entry.torrents.filter { torrent in
                number.map { TorrServerClient.knownFiles(of: torrent) != nil || Self.seasons(in: torrent.title)?.contains($0) == true } ?? (torrent.hash == key)
            }
            let (episodes, error) = await episodes(of: torrents, show: entry.item)
            let season = episodes.filter { number == nil || $0.season == number }
            if season.isEmpty, let error { throw error }
            return season.map(\.item)
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
        let torrents = try await client.torrents()
            .sorted { ($0.timestamp ?? 0) > ($1.timestamp ?? 0) }
            .map { (torrent: $0, tmdb: TorrServerClient.metadata(of: $0)?.movie) }
        var result: [(item: MediaItem, torrents: [TorrServerClient.Torrent])] = []
        // The local and original titles of the shows with TMDB data.
        var showNames: [String: Set<String>] = [:]
        // Releases with TMDB data first, so a release without it can join
        // its show by name.
        for (torrent, tmdb) in torrents.filter({ $0.tmdb?.id != nil }) + torrents.filter({ $0.tmdb?.id == nil }) {
            let tmdbNames = [tmdb?.title, tmdb?.name, tmdb?.original_title, tmdb?.original_name].compactMap { $0 }
            let names = tmdbNames.isEmpty ? Self.names(in: torrent.title) : tmdbNames
            let lowercasedNames = Set(names.map { $0.lowercased() })
            if tmdb?.id == nil, ["", "tv"].contains(torrent.category ?? "") {
                let matches = showNames.keys.filter { !showNames[$0, default: []].isDisjoint(with: lowercasedNames) }
                // Only an unambiguous name: two shows may share one.
                if matches.count == 1, let index = result.firstIndex(where: { $0.item.id == matches[0] }) {
                    result[index].torrents.append(torrent)
                    continue
                }
            }
            guard let type = Self.mediaType(of: torrent, tmdb: tmdb) else { continue }
            let title = names.first ?? torrent.title
            let id = type == .movies ? torrent.hash : "show:\(tmdb?.id.map { "tmdb\($0)" } ?? title.lowercased())"
            if let index = result.firstIndex(where: { $0.item.id == id }) {
                result[index].torrents.append(torrent)
                continue
            }
            if type == .tvShows, tmdb?.id != nil { showNames[id] = lowercasedNames }
            let date = tmdb?.release_date ?? tmdb?.first_air_date
            let year = date.flatMap { Int($0.prefix(4)) } ?? torrent.title.firstMatch(of: (/\b(?:19|20)\d{2}\b/).wordBoundaryKind(.simple)).flatMap { Int($0.output) }
            // Web addresses only: a file:// poster would be read from disk.
            let poster = torrent.poster.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
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
        for index in result.indices {
            result[index].torrents.sort { ($0.timestamp ?? 0) > ($1.timestamp ?? 0) }
            result[index].item.addedAt = result[index].torrents.first?.timestamp.map { Date(timeIntervalSince1970: $0) }
        }
        return result
    }

    /// Categories are TorrServer's own ("movie", "tv", "music", "other");
    /// torrents added without one (Lampa) are sorted by their metadata or title.
    private static func mediaType(of torrent: TorrServerClient.Torrent, tmdb: TorrServerClient.Metadata.TMDB?) -> MediaType? {
        switch torrent.category ?? "" {
        case "movie": .movies
        case "tv": .tvShows
        case "": tmdb?.first_air_date != nil || seasons(in: torrent.title) != nil ? .tvShows : .movies
        default: nil
        }
    }

    /// The titles in a release name. Russian releases name the show in each
    /// language, "Ричер (Сезон 2) / Reacher / S2E1-8", so each part is one.
    private static func names(in title: String) -> [String] {
        title.split(separator: " / ").compactMap { part in
            let name = cleanTitle(String(part.replacing(/\[[^\]]*\]/, with: "").split(separator: /\s[(\[]/).first ?? ""))
            return name.isEmpty ? nil : name
        }
    }

    /// "The.Matrix.1999.1080p.BluRay" becomes "The Matrix": the name ends at
    /// the first year, season or resolution tag. The regexes here use simple
    /// word boundaries; Unicode ones don't break between "Matrix.1999".
    private static func cleanTitle(_ title: String) -> String {
        let end = title.firstMatch(of: (/[\s._\-\[(]+(?:[Ss]\d{1,2}|[Ss]eason\s*\d|(?:19|20)\d{2}\b|\d{3,4}p\b)/).wordBoundaryKind(.simple))?.range.lowerBound ?? title.endIndex
        let name = title[..<end].replacing(/[._]/, with: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? title.trimmingCharacters(in: .whitespaces) : name
    }

    /// "S02", "Season 2", "5 сезон", "Сезон: 5", or a pack: "S01-S04",
    /// "1-4 сезон". Russian names put episodes after the season: "5 сезон:
    /// 1-5 серии".
    private static func seasons(in text: String) -> ClosedRange<Int>? {
        guard let match = text.firstMatch(of: (/\b(\d{1,2})(?:\s*[-–]\s*(\d{1,2}))?\s*[Сс]езон/).wordBoundaryKind(.simple))
                ?? text.firstMatch(of: (/\b(?:[Ss]|[Ss]easons?[\s:]*|[Сс]езоны?[\s:]*)(\d{1,2})(?:\s*[-–]\s*[Ss]?(\d{1,2})(?!\s*[Сс]ери))?(?:[Ee]\d|\b)/).wordBoundaryKind(.simple)),
              let first = Int(match.output.1) else { return nil }
        return first...max(first, match.output.2.flatMap { Int($0) } ?? first)
    }

    /// "Show.S01E02.mkv", "Show s1.e2.mkv" or "Show 1x02.mkv".
    private static func episodeNumber(in name: String) -> (season: Int, episode: Int)? {
        if let match = name.firstMatch(of: /[Ss](\d{1,2})[ ._\-]?[Ee](\d{1,3})/) ?? name.firstMatch(of: (/\b(\d{1,2})x(\d{2,3})\b/).wordBoundaryKind(.simple)),
           let season = Int(match.output.1), let episode = Int(match.output.2) {
            return (season, episode)
        }
        return nil
    }

    /// Episode numbers of files named without one, from the part of the name
    /// that differs between them: "The Devil Judge 05.mp4" or "05-й
    /// выпуск.mkv" is episode 5.
    private static func numbersByName(_ paths: [String]) -> [String: Int] {
        let names = paths.map { Array(($0 as NSString).lastPathComponent) }
        guard let first = names.first, names.count > 1 else { return [:] }
        func shared(_ names: [[Character]]) -> Int {
            names.dropFirst().reduce(names[0].count) { count, name in zip(names[0], name).prefix(count).prefix { $0 == $1 }.count }
        }
        // Stop before shared digits, so "Show 12" and "Show 13" keep the 1.
        var head = shared(names), tail = shared(names.map { Array($0.reversed()) })
        while head > 0, first[head - 1].isNumber { head -= 1 }
        while tail > 0, first[first.count - tail].isNumber { tail -= 1 }
        var numbers: [String: Int] = [:]
        for (path, name) in zip(paths, names) where head <= name.count - tail {
            numbers[path] = Int(String(name[head..<(name.count - tail)]))
        }
        return numbers
    }

    private static func isVideo(_ file: TorrServerClient.File) -> Bool {
        videoExtensions.contains((file.path as NSString).pathExtension.lowercased())
    }

    /// The episodes in the torrents' files, in season and episode order. When
    /// two torrents have the same episode, the newest wins. Torrents the server
    /// can't list yet are left out, with the first such error.
    private func episodes(of torrents: [TorrServerClient.Torrent], show: MediaItem) async -> (episodes: [(season: Int, episode: Int, item: MediaItem)], error: Error?) {
        let client = client
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

        var episodes: [(season: Int, episode: Int, item: MediaItem)] = []
        var firstError: Error?
        for (torrent, result) in zip(torrents, results) {
            let files: [TorrServerClient.File]
            switch result {
            case .success(let list): files = list
            case .failure(let error): firstError = firstError ?? error; continue
            }
            // A sample or trailer would take the slot of the episode it is cut from.
            let videos = files.filter { Self.isVideo($0) && !$0.path.contains((/(?i)\b(?:sample|trailer|extras|bonus|featurettes?)\b/).wordBoundaryKind(.simple)) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let byName = Self.numbersByName(videos.map(\.path).filter { Self.episodeNumber(in: $0) == nil })
            // ponytail: files with no number at all are numbered in path order.
            let season = Self.seasons(in: torrent.title)?.lowerBound ?? 1
            var unnumbered = 0
            for file in videos {
                let number = Self.episodeNumber(in: file.path) ?? byName[file.path].map { (season, $0) } ?? {
                    unnumbered += 1
                    return (season, unnumbered)
                }()
                guard !episodes.contains(where: { $0.season == number.season && $0.episode == number.episode }) else { continue }
                episodes.append((number.season, number.episode, MediaItem(
                    id: "\(torrent.hash)-\(file.id)",
                    source: .torrServer,
                    type: .tvShows,
                    kind: .episode,
                    title: "Episode \(number.episode)",
                    subtitle: "S\(number.season)E\(number.episode)",
                    posterURL: show.posterURL,
                    parentID: "\(show.id)|\(number.season)",
                    parentKind: .season,
                    parentTitle: number.season == 0 ? "Specials" : "Season \(number.season)",
                    parentPosterURL: show.posterURL,
                    attributes: [
                        "originalPath": file.path,
                        "grandparentTitle": show.title,
                        "grandparentRatingKey": show.id,
                        "grandparentPosterURL": show.posterURL?.absoluteString ?? "",
                    ]
                )))
            }
        }
        return (episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }, firstError)
    }
}
