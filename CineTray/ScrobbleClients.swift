import Foundation
import CryptoKit

// MARK: - Trakt

/// Trakt.tv client using OAuth browser-redirect flow. Credentials are embedded
/// in Secrets.swift (gitignored); only the user's access and refresh tokens
/// live in the Keychain.
struct TraktClient {
    private static let baseURL = URL(string: "https://api.trakt.tv")!

    // MARK: - OAuth

    /// The authorization URL to open in ASWebAuthenticationSession.
    static var authorizeURL: URL {
        var components = URLComponents(string: "https://trakt.tv/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: TraktSecrets.clientID),
            URLQueryItem(name: "redirect_uri", value: TraktSecrets.redirectURI),
        ]
        return components.url!
    }

    /// Exchanges an authorization code for an access + refresh token pair.
    static func exchangeCode(_ code: String) async throws -> (accessToken: String, refreshToken: String) {
        struct Response: Decodable {
            let accessToken: String
            let refreshToken: String
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
            }
        }
        let (data, status) = try await TraktClient().post(path: "/oauth/token", body: [
            "code": code,
            "client_id": TraktSecrets.clientID,
            "client_secret": TraktSecrets.clientSecret,
            "redirect_uri": TraktSecrets.redirectURI,
            "grant_type": "authorization_code",
        ])
        guard status == 200 else { throw URLError(.badServerResponse) }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.accessToken, response.refreshToken)
    }

    /// Exchanges a refresh token for a new access + refresh token pair.
    static func refreshAccessToken(_ refreshToken: String) async throws -> (accessToken: String, refreshToken: String) {
        struct Response: Decodable {
            let accessToken: String
            let refreshToken: String
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
            }
        }
        let (data, status) = try await TraktClient().post(path: "/oauth/token", body: [
            "refresh_token": refreshToken,
            "client_id": TraktSecrets.clientID,
            "client_secret": TraktSecrets.clientSecret,
            "redirect_uri": TraktSecrets.redirectURI,
            "grant_type": "refresh_token",
        ])
        guard status == 200 else { throw URLError(.badServerResponse) }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.accessToken, response.refreshToken)
    }

    // MARK: - Search (for Local Library metadata scraping)

    struct TraktMovieMatch {
        let tmdbID: Int
        let title: String
        let year: Int?
    }

    struct TraktShowMatch {
        let tmdbID: Int
        let title: String
    }

    /// Searches Trakt for a movie; returns the first match with a TMDb ID.
    func searchMovie(title: String, year: Int?) async -> TraktMovieMatch? {
        struct Result: Decodable {
            struct Movie: Decodable {
                let title: String
                let year: Int?
                let ids: IDs
                struct IDs: Decodable { let tmdb: Int? }
            }
            let movie: Movie?
        }
        var query: [String: String] = ["query": title]
        if let year { query["years"] = "\(year)" }
        guard let data = try? await get(path: "/search/movie", query: query) else { return nil }
        guard let results = try? JSONDecoder().decode([Result].self, from: data),
              let first = results.first(where: { $0.movie?.ids.tmdb != nil }),
              let movie = first.movie, let tmdbID = movie.ids.tmdb else { return nil }
        return TraktMovieMatch(tmdbID: tmdbID, title: movie.title, year: movie.year)
    }

    /// Searches Trakt for a TV show; returns the first match with a TMDb ID.
    func searchShow(title: String) async -> TraktShowMatch? {
        struct Result: Decodable {
            struct Show: Decodable {
                let title: String
                let ids: IDs
                struct IDs: Decodable { let tmdb: Int? }
            }
            let show: Show?
        }
        guard let data = try? await get(path: "/search/show", query: ["query": title]) else { return nil }
        guard let results = try? JSONDecoder().decode([Result].self, from: data),
              let first = results.first(where: { $0.show?.ids.tmdb != nil }),
              let show = first.show, let tmdbID = show.ids.tmdb else { return nil }
        return TraktShowMatch(tmdbID: tmdbID, title: show.title)
    }

    // MARK: - Scrobble

    /// Scrobbles a movie by title/year match. TV scrobbling needs episode-level
    /// identity, which the carousel doesn't track yet.
    /// Throws `TraktError.unauthorized` when the access token has expired.
    func scrobble(state: PlaybackState, title: String, year: Int?, progressPercent: Double, accessToken: String) async throws {
        let action = switch state {
        case .started, .playing: "start"
        case .paused: "pause"
        case .stopped: "stop"
        }
        var movie: [String: Any] = ["title": title]
        if let year { movie["year"] = year }
        let (_, status) = try await post(
            path: "/scrobble/\(action)",
            body: ["movie": movie, "progress": progressPercent],
            accessToken: accessToken
        )
        if status == 401 { throw TraktError.unauthorized }
    }

    // MARK: - HTTP

    private func post(path: String, body: [String: Any], accessToken: String? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(TraktSecrets.clientID, forHTTPHeaderField: "trakt-api-key")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func get(path: String, query: [String: String]) async throws -> Data {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(TraktSecrets.clientID, forHTTPHeaderField: "trakt-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

/// Errors specific to the Trakt API.
enum TraktError: Error {
    case unauthorized
}

// MARK: - Last.fm

/// Last.fm scrobbler using the web-auth token flow. Credentials are embedded
/// in Secrets.swift (gitignored); only the session key lives in the Keychain.
struct LastFMClient {
    private static let baseURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    // MARK: - OAuth

    /// Fetches an unauthorized request token to use in the auth URL.
    static func requestToken() async throws -> String {
        struct Response: Decodable { let token: String }
        let data = try await LastFMClient().signedGet(params: ["method": "auth.getToken"])
        return try JSONDecoder().decode(Response.self, from: data).token
    }

    /// The Last.fm authorization URL the user visits to grant access.
    static func authorizeURL(token: String) -> URL {
        URL(string: "https://www.last.fm/api/auth/?api_key=\(LastFMSecrets.apiKey)&token=\(token)")!
    }

    /// Exchanges an authorized token for a permanent session key.
    static func getSession(token: String) async throws -> String {
        struct Response: Decodable {
            struct Session: Decodable { let key: String }
            let session: Session
        }
        let data = try await LastFMClient().signedGet(params: [
            "method": "auth.getSession",
            "token": token,
        ])
        return try JSONDecoder().decode(Response.self, from: data).session.key
    }

    // MARK: - Info (for Local Library metadata scraping)

    struct AlbumInfo {
        let imageURL: URL?
        let albumName: String
        let artistName: String
    }

    /// Fetches album artwork and canonical names. No authentication required.
    func albumInfo(artist: String, album: String) async -> AlbumInfo? {
        guard let data = try? await publicGet(params: [
            "method": "album.getInfo",
            "artist": artist,
            "album": album,
        ]) else { return nil }

        struct Response: Decodable {
            struct Album: Decodable {
                let name: String
                let artist: String
                let image: [Image]
                struct Image: Decodable {
                    let text: String
                    let size: String
                    enum CodingKeys: String, CodingKey { case text = "#text"; case size }
                }
            }
            let album: Album?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let album = response.album else { return nil }
        let imageURL = album.image
            .sorted { sizeRank($0.size) > sizeRank($1.size) }
            .compactMap { URL(string: $0.text) }
            .first
        return AlbumInfo(imageURL: imageURL, albumName: album.name, artistName: album.artist)
    }

    /// Fetches the largest available artist image. No authentication required.
    func artistImageURL(artist: String) async -> URL? {
        guard let data = try? await publicGet(params: [
            "method": "artist.getInfo",
            "artist": artist,
        ]) else { return nil }

        struct Response: Decodable {
            struct Artist: Decodable {
                let image: [Image]
                struct Image: Decodable {
                    let text: String
                    let size: String
                    enum CodingKeys: String, CodingKey { case text = "#text"; case size }
                }
            }
            let artist: Artist?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let artist = response.artist else { return nil }
        return artist.image
            .sorted { sizeRank($0.size) > sizeRank($1.size) }
            .compactMap { URL(string: $0.text) }
            .first
    }

    // MARK: - Scrobble

    func scrobble(artist: String, track: String, sessionKey: String) async throws {
        _ = try await post(params: [
            "method": "track.scrobble",
            "artist": artist,
            "track": track,
            "timestamp": String(Int(Date.now.timeIntervalSince1970)),
            "sk": sessionKey,
        ])
    }

    // MARK: - HTTP

    /// Signed GET for methods that require an api_sig (e.g. auth.getToken, auth.getSession).
    private func signedGet(params: [String: String]) async throws -> Data {
        var all = params
        all["api_key"] = LastFMSecrets.apiKey
        let signatureBase = all.keys.sorted().map { "\($0)\(all[$0]!)" }.joined() + LastFMSecrets.sharedSecret
        let digest = Insecure.MD5.hash(data: Data(signatureBase.utf8))
        all["api_sig"] = digest.map { String(format: "%02x", $0) }.joined()
        all["format"] = "json"
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// Unsigned GET for public read-only Last.fm methods.
    private func publicGet(params: [String: String]) async throws -> Data {
        var all = params
        all["api_key"] = LastFMSecrets.apiKey
        all["format"] = "json"
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// All authenticated POSTs carry api_sig: the MD5 of the sorted
    /// name+value concatenation plus the shared secret.
    private func post(params: [String: String]) async throws -> Data {
        var signed = params
        signed["api_key"] = LastFMSecrets.apiKey
        let signatureBase = signed.keys.sorted().map { "\($0)\(signed[$0]!)" }.joined() + LastFMSecrets.sharedSecret
        let digest = Insecure.MD5.hash(data: Data(signatureBase.utf8))
        signed["api_sig"] = digest.map { String(format: "%02x", $0) }.joined()
        signed["format"] = "json"

        var request = URLRequest(url: Self.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = signed.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func sizeRank(_ size: String) -> Int {
        switch size {
        case "mega": 5
        case "extralarge": 4
        case "large": 3
        case "medium": 2
        case "small": 1
        default: 0
        }
    }
}
