import Foundation

/// Serves locally downloaded media from the per-type folders configured in
/// Settings → Data → Downloads. Items carry `source: .local` for routing
/// but keep their original `id` values so they de-duplicate against server
/// items in the catalog (same id → server poster gets the green tick;
/// local item only appears when no server counterpart is present).
struct LocalMediaProvider: MediaProvider {
    var tvTopLevel: TVTopLevel = .series
    var musicTopLevel: MusicTopLevel = .album
    /// Whether downloads are served here too. Only in Offline Mode: online,
    /// downloaded items already show in their server's sections (with a
    /// green download mark), and here they couldn't be placed in the right library.
    var includeDownloads = false

    var source: MediaSource { .local }
    var id: String { "local" }

    // MARK: - MediaProvider

    /// One pseudo-library per media type with local content, named like
    /// the menu's defaults ("Movies", "Shows", "Music"), so it merges with a
    /// server library of the same name.
    func libraries() async throws -> [MediaLibrary] {
        types.map { MediaLibrary(id: $0.rawValue, name: $0.title, type: $0) }
    }

    func items(inLibrary library: MediaLibrary) async throws -> [MediaItem] {
        let type = library.type
        let entries = DownloadManager.libraryIndexedEntries(for: type)
            + (includeDownloads ? DownloadManager.indexedEntries(for: type) : [])
        var indexedIDs = Set<String>()
        var filenames: [String: String] = [:]
        let indexed = entries.compactMap { entry -> MediaItem? in
            guard entry.filename != nil || entry.item.kind.isExpandable else { return nil }
            if !indexedIDs.insert(entry.item.id).inserted { return nil }
            filenames[entry.item.id] = entry.filename
            return entry.item
        }
        let dropped = unindexedItems(for: type, excluding: indexedIDs)
        // Pick the top level first so artwork is only looked up (several
        // file checks each) for the items shown, not every episode/track.
        let top = topLevel(of: indexed + dropped, type: type)
            .map { localised($0, filename: filenames[$0.id]) }

        // Enrich items with extracted offline metadata before returning
        return enrich(items: top, allEntries: entries)
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        let entries = DownloadManager.libraryIndexedEntries(for: item.type) + DownloadManager.indexedEntries(for: item.type)
        var indexedIDs = Set<String>()
        let kids = entries.compactMap { entry -> MediaItem? in
            guard (entry.filename != nil || entry.item.kind.isExpandable), entry.item.parentID == item.id else { return nil }
            if !indexedIDs.insert(entry.item.id).inserted { return nil }
            return localised(entry.item, filename: entry.filename)
        }
        
        // Enrich children with extracted offline metadata before returning
        return enrich(items: kids, allEntries: entries)
    }

    func playlists() async throws -> [MediaItem] {
        let entries = DownloadManager.libraryIndexedEntries(for: .music) + DownloadManager.indexedEntries(for: .music)
        var indexedIDs = Set<String>()
        return entries.compactMap { entry -> MediaItem? in
            guard entry.item.kind == .playlist else { return nil }
            if !indexedIDs.insert(entry.item.id).inserted { return nil }
            return localised(entry.item, filename: entry.filename)
        }
    }

    func streamURL(for item: MediaItem) async throws -> URL {
        guard let url = DownloadManager.shared.localLibraryURL(for: item) else {
            throw URLError(.fileDoesNotExist)
        }
        return url
    }

    // MARK: - Content check

    /// True when there is a folder to serve, used by AppState to decide
    /// whether to register this provider.
    var hasContent: Bool { !types.isEmpty }

    /// Media types with a library folder set (or a download folder, when
    /// serving downloads). Deliberately a settings lookup, not a scan:
    /// AppState.providers runs on every catalog access.
    private var types: [MediaType] {
        MediaType.allCases.filter { type in
            DownloadManager.libraryFolderPath(for: type) != nil
                || (includeDownloads && DownloadManager.folderPath(for: type) != nil)
        }
    }

    // MARK: - Enrichment (Offline Metadata Recovery)
    
    /// Dynamically recalculates episode counts for Seasons and extracts missing year metadata
    /// for synthesized TV Shows while in offline mode.
    private func enrich(items: [MediaItem], allEntries: [DownloadIndexEntry]) -> [MediaItem] {
        return items.map { item in
            var enriched = item
            
            // 1. Season: Dynamically calculate the offline episode count
            if enriched.kind == .season {
                let count = allEntries.filter { $0.item.parentID == enriched.id && $0.item.kind == .episode && $0.filename != nil }.count
                if count > 0 {
                    enriched.subtitle = "\(count) episode\(count == 1 ? "" : "s")"
                }
            }
            
            // 2. Show: Recover missing year metadata from child episodes
            if enriched.kind == .show && (enriched.subtitle == nil || enriched.subtitle?.isEmpty == true) {
                let episode = allEntries.first { entry in
                    guard entry.item.kind == .episode else { return false }
                    if entry.item.attributes["grandparentRatingKey"] == enriched.id { return true }
                    if entry.item.parentKind == .season, let seasonID = entry.item.parentID {
                        if let seasonEntry = allEntries.first(where: { $0.item.id == seasonID }) {
                            return seasonEntry.item.parentID == enriched.id
                        }
                    }
                    return false
                }?.item
                
                if let ep = episode, let year = ep.attributes["grandparentYear"] ?? ep.attributes["year"] {
                    enriched.subtitle = year
                }
            }
            
            return enriched
        }
    }

    // MARK: - Helpers

    private func localArtworkURL(filename: String?, type: MediaType,
                                 kind: MediaKind? = nil, title: String? = nil,
                                 parentTitle: String? = nil) -> URL? {
        let folders = [DownloadManager.resolvedFolder(for: type), DownloadManager.resolvedLibraryFolder(for: type)].compactMap { $0 }
        for folder in folders {
            if let filename {
                let fileURL = folder.appending(path: filename)
                let baseDir = fileURL.deletingLastPathComponent()
                let stem = fileURL.deletingPathExtension().lastPathComponent
                if let url = LocalLibraryScanner.artworkURL(in: baseDir, stem: stem) { return url }
                if let url = LocalLibraryScanner.artworkURL(in: baseDir, stem: nil) { return url }
            } else if kind == .show, let title {
                // Sibling naming: ShowTitle.jpg sits next to show folder, inside type root.
                if let url = LocalLibraryScanner.artworkURL(in: folder, stem: DownloadManager.sanitizePathComponent(title)) { return url }
                // Fallback: poster.* inside the show folder.
                if let url = LocalLibraryScanner.artworkURL(in: folder.appending(path: DownloadManager.sanitizePathComponent(title)), stem: nil) { return url }
            } else if kind == .season, let title {
                // Sibling naming: SeasonTitle.jpg sits next to season folder, inside show folder.
                if let parent = parentTitle {
                    let showDir = folder.appending(path: DownloadManager.sanitizePathComponent(parent))
                    if let url = LocalLibraryScanner.artworkURL(in: showDir, stem: DownloadManager.sanitizePathComponent(title)) { return url }
                    // Fallback: poster.* inside the season folder.
                    if let url = LocalLibraryScanner.artworkURL(in: showDir.appending(path: DownloadManager.sanitizePathComponent(title)), stem: nil) { return url }
                } else {
                    if let url = LocalLibraryScanner.artworkURL(in: folder, stem: DownloadManager.sanitizePathComponent(title)) { return url }
                    if let url = LocalLibraryScanner.artworkURL(in: folder.appending(path: DownloadManager.sanitizePathComponent(title)), stem: nil) { return url }
                }
            }
        }
        return nil
    }

    private func localised(_ item: MediaItem, filename: String?) -> MediaItem {
        var m = item
        m.source = .local
        if let poster = localArtworkURL(filename: filename, type: item.type,
                                        kind: item.kind, title: item.title,
                                        parentTitle: item.parentTitle) {
            m.posterURL = poster
        }
        return m
    }

    /// Files present in the library folder that have no index entry (content dropped
    /// in manually). Synthesises minimal MediaItems so they appear in the UI.
    private func unindexedItems(for type: MediaType, excluding known: Set<String>) -> [MediaItem] {
        guard let folder = DownloadManager.resolvedLibraryFolder(for: type) else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []
        let scanner = LocalLibraryScanner(type: type, folder: folder)
        return contents.compactMap { url -> MediaItem? in
            guard !url.lastPathComponent.hasPrefix("."),
                  DownloadManager.mediaExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            let id = "local-\(name)"
            guard !known.contains(id) else { return nil }
            let kind: MediaKind = switch type {
            case .movies: .movie
            case .tvShows: .episode
            case .music: .track
            }
            let title: String = switch type {
            case .tvShows: scanner.parseEpisode(from: name).title
            default: name
            }
            return MediaItem(id: id, source: .local, type: type, kind: kind, title: title)
        }
    }

    /// Returns the appropriate top-level items given the configured navigation
    /// top-level preference, mirroring server provider behaviour.
    private func topLevel(of items: [MediaItem], type: MediaType) -> [MediaItem] {
        switch type {
        case .movies:
            return items.filter { $0.kind == .movie }
        case .tvShows:
            if tvTopLevel == .series, items.contains(where: { $0.kind == .show }) {
                return items.filter { $0.kind == .show }
            }
            if items.contains(where: { $0.kind == .season }) {
                return items.filter { $0.kind == .season }
            }
            return items.filter { $0.kind == .episode }
        case .music:
            if musicTopLevel == .artist, items.contains(where: { $0.kind == .artist }) {
                return items.filter { $0.kind == .artist }
            }
            if items.contains(where: { $0.kind == .album }) {
                return items.filter { $0.kind == .album }
            }
            if items.contains(where: { $0.kind == .playlist }) {
                return items.filter { $0.kind == .playlist }
            }
            return items.filter { $0.kind == .track }
        }
    }
}
