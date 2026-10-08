import Foundation
import ImageIO
import Synchronization
import SwiftUI

/// URL sessions for poster loading. The persistent one keeps artwork in a
/// dedicated disk cache so posters don't re-download every launch; the
/// ephemeral one (used when "Cache Artwork Locally" is off) keeps nothing
/// on disk.
nonisolated enum ArtworkCache {
    static let persistentSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Not sandboxed, so cachesDirectory is the shared ~/Library/Caches.
        let directory = URL.cachesDirectory.appending(path: "CineTray/Artwork")
        configuration.urlCache = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            directory: directory
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    static let ephemeralSession = URLSession(configuration: .ephemeral)

    /// The session matching the "Cache Artwork Locally" preference (default on).
    static var session: URLSession {
        UserDefaults.standard.object(forKey: SettingsKeys.cacheArtwork) as? Bool ?? true
            ? persistentSession : ephemeralSession
    }

    static var diskUsageBytes: Int {
        persistentSession.configuration.urlCache?.currentDiskUsage ?? 0
    }

    /// Plex tokens by server address ("scheme:host:port", so an http:// URL
    /// never gets the token of an https:// server). Poster URLs are stored
    /// without the token, so it is added as a header when loading them.
    private static let plexTokens = Mutex<[String: String]>([:])

    static func setPlexTokens(_ tokens: [String: String]) {
        plexTokens.withLock { $0 = tokens }
    }

    /// Navidrome server address and the credentials Subsonic expects in the
    /// query string. Cover art URLs are stored without them.
    private static let navidromeAuth = Mutex<(address: String, query: [URLQueryItem])?>(nil)

    static func setNavidromeAuth(_ auth: (address: String, query: [URLQueryItem])?) {
        navidromeAuth.withLock { $0 = auth }
    }

    static func addressKey(_ url: URL) -> String {
        "\(url.scheme ?? ""):\(url.host() ?? ""):\(url.port ?? 0)"
    }

    /// A request for artwork at `url`, authenticated when it's on a Plex or
    /// Navidrome server.
    static func request(for url: URL) -> URLRequest {
        var url = url
        if let auth = navidromeAuth.withLock({ $0 }), auth.address == addressKey(url), url.path().contains("/rest/") {
            url.append(queryItems: auth.query)
        }
        // A server that never answers would otherwise keep the placeholder
        // spinning for the default 60 seconds.
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        if let token = plexTokens.withLock({ $0[addressKey(url)] }) {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
        return request
    }

    static func clear() {
        persistentSession.configuration.urlCache?.removeAllCachedResponses()
        ephemeralSession.configuration.urlCache?.removeAllCachedResponses()
        decoded.removeAllObjects()
    }

    /// Decoded posters, so reopening the menu or scrolling back doesn't decode
    /// them again. The system empties it under memory pressure.
    private static let decoded = NSCache<NSURL, CGImage>()

    /// Fetches and decodes artwork off the main thread, downsampled so a
    /// full-size poster doesn't sit in memory at original resolution.
    @concurrent
    static func image(at url: URL) async -> CGImage? {
        if let image = decoded.object(forKey: url as NSURL) { return image }
        guard let data = await data(at: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // ponytail: fixed 600 px cap covers the largest view (280 pt music artwork @2x).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        decoded.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Navidrome's credentials are in the query, and the disk cache keys
    /// responses by URL, so its artwork is fetched without the cache and
    /// stored under the URL without them.
    private static func data(at url: URL) async -> Data? {
        let request = request(for: url)
        guard request.url != url else {
            return try? await session.data(for: request, delegate: PlexTokenRedirectGuard.shared).0
        }
        let key = URLRequest(url: url)
        let cache = session.configuration.urlCache
        if let cached = cache?.cachedResponse(for: key) { return cached.data }
        guard let (data, response) = try? await URLSession.uncached.data(for: request),
              let headers = (response as? HTTPURLResponse).flatMap({ $0.statusCode == 200 ? $0.allHeaderFields : nil }),
              let stored = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers as? [String: String])
        else { return nil }
        cache?.storeCachedResponse(CachedURLResponse(response: stored, data: data), for: key)
        return data
    }

    /// Removes cache entries older builds wrote with credentials in their
    /// URLs (Navidrome, API keys). Runs once.
    static func removeCredentialEntries() {
        guard !UserDefaults.standard.bool(forKey: SettingsKeys.removedCredentialCacheEntries) else { return }
        URLCache.shared.removeAllCachedResponses()
        persistentSession.configuration.urlCache?.removeAllCachedResponses()
        UserDefaults.standard.set(true, forKey: SettingsKeys.removedCredentialCacheEntries)
    }
}

/// Replacement for `AsyncImage(request:)` + `.asyncImageURLSession(_:)`,
/// which only exist on macOS 27. Loads through `ArtworkCache` on macOS 26+.
/// Shows `placeholder` while loading and `fallback` when there is no URL or
/// the image can't be loaded, e.g. a Jellyfin item without a poster (404).
struct ArtworkImage<Placeholder: View, Fallback: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var fallback: () -> Fallback

    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if url == nil || failed {
                fallback()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { return }
            image = await ArtworkCache.image(at: url)
            failed = image == nil
        }
    }
}
