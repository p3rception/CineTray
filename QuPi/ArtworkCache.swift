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
        let directory = URL.cachesDirectory.appending(path: "Artwork")
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

    /// Plex tokens by server address ("host:port"). Poster URLs are stored
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
        "\(url.host() ?? ""):\(url.port ?? 0)"
    }

    /// A request for artwork at `url`, authenticated when it's on a Plex or
    /// Navidrome server.
    static func request(for url: URL) -> URLRequest {
        var url = url
        if let auth = navidromeAuth.withLock({ $0 }), auth.address == addressKey(url), url.path().contains("/rest/") {
            url.append(queryItems: auth.query)
        }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        if let token = plexTokens.withLock({ $0[addressKey(url)] }) {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
        return request
    }

    static func clear() {
        persistentSession.configuration.urlCache?.removeAllCachedResponses()
        ephemeralSession.configuration.urlCache?.removeAllCachedResponses()
    }

    /// Fetches and decodes artwork off the main thread, downsampled so a
    /// full-size poster doesn't sit in memory at original resolution.
    @concurrent
    static func image(at url: URL) async -> CGImage? {
        guard let (data, _) = try? await session.data(for: request(for: url)),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // ponytail: fixed 600 px cap covers the largest view (280 pt music artwork @2x).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Replacement for `AsyncImage(request:)` + `.asyncImageURLSession(_:)`,
/// which only exist on macOS 27. Loads through `ArtworkCache` on macOS 26+.
struct ArtworkImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            image = await ArtworkCache.image(at: url)
        }
    }
}
