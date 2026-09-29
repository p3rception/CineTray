import AppKit
import Observation

/// One entry in the per-type download index.
struct DownloadIndexEntry: Codable {
    let item: MediaItem
    /// Filename (relative to the type's folder). `nil` for container entries
    /// written after all descendants of a batch download succeed.
    let filename: String?
}

/// Downloads media to the per-type folders chosen in Settings → Data,
/// enforcing the per-type storage allocation. Folder access persists across
/// launches via security-scoped bookmarks. A JSON index sidecar
/// (`.cinetray-downloads.json`) tracks what has been downloaded so the app can
/// serve it as a local library and prefer local files for playback.
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    /// IDs of items downloading; used by `PosterCell` to know if a download is active.
    var downloadingIDs: Set<String> = []
    
    /// Full items downloading; drives the Downloading section in the menu bar.
    var downloadingItems: [MediaItem] = []
    
    /// Tracks download progress (0.0 to 1.0) for active downloads by item ID.
    var downloadProgress: [String: Double] = [:]

    /// In-memory cache of downloaded item IDs per type, populated on launch and
    /// updated on each download completion. Used by sortedItems for O(1) Local First
    /// checks instead of reading the JSON index from disk on every sort call.
    var downloadedIDs: [MediaType: Set<String>] = [:]

    // MARK: - Init / folder lifetime access

    /// Folders currently held open for security-scoped access, keyed by
    /// their bookmark's UserDefaults key.
    private var openedFolders: [String: URL] = [:]

    private init() {
        for type in MediaType.allCases {
            refreshAccess(bookmarkKey: SettingsKeys.downloadFolderBookmark(type))
            refreshAccess(bookmarkKey: SettingsKeys.libraryFolderBookmark(type))
        }
        cleanUpOrphans()
        populateDownloadedIDCache()
    }

    private func populateDownloadedIDCache() {
        for type in MediaType.allCases {
            guard let folder = Self.resolvedFolder(for: type) else { continue }
            let index = Self.readIndexFromFolder(folder)
            let ids = Set(index.values.compactMap { entry -> String? in
                guard let filename = entry.filename else { return entry.item.id }
                return FileManager.default.fileExists(atPath: folder.appending(path: filename).path) ? entry.item.id : nil
            })
            downloadedIDs[type] = ids
        }
    }

    private func cleanUpOrphans() {
        for type in MediaType.allCases {
            guard let folder = Self.resolvedFolder(for: type) else { continue }
            var index = Self.readIndexFromFolder(folder)
            var dirty = false

            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil
            )) ?? []
            for file in files where file.pathExtension.lowercased() == "m3u8" {
                try? FileManager.default.removeItem(at: file)
            }

            for (id, entry) in index {
                guard let filename = entry.filename else { continue }
                let dest = folder.appending(path: filename)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    index.removeValue(forKey: id)
                    dirty = true
                }
            }
            // Older builds saved Plex tokens in poster URLs; writeIndex strips them.
            if index.values.contains(where: { $0.item != $0.item.removingPlexTokens }) {
                dirty = true
            }
            if dirty { Self.writeIndex(index, to: folder) }
        }
    }

    private func refreshAccess(bookmarkKey: String) {
        openedFolders.removeValue(forKey: bookmarkKey)?.stopAccessingSecurityScopedResource()
        if let folder = Self.resolveBookmark(bookmarkKey), folder.startAccessingSecurityScopedResource() {
            openedFolders[bookmarkKey] = folder
        }
    }

    // MARK: - Folder configuration

    /// Download folder: files downloaded from servers.
    static func setFolder(_ url: URL, for type: MediaType) {
        saveBookmark(for: url, bookmarkKey: SettingsKeys.downloadFolderBookmark(type), pathKey: SettingsKeys.downloadFolderPath(type))
    }

    static func folderPath(for type: MediaType) -> String? {
        UserDefaults.standard.string(forKey: SettingsKeys.downloadFolderPath(type))
    }

    static func resolvedFolder(for type: MediaType) -> URL? {
        resolveBookmark(SettingsKeys.downloadFolderBookmark(type))
    }

    /// Library folder: the user's own media, scanned by LocalLibraryScanner.
    static func setLibraryFolder(_ url: URL, for type: MediaType) {
        saveBookmark(for: url, bookmarkKey: SettingsKeys.libraryFolderBookmark(type), pathKey: SettingsKeys.libraryFolderPath(type))
    }

    static func libraryFolderPath(for type: MediaType) -> String? {
        UserDefaults.standard.string(forKey: SettingsKeys.libraryFolderPath(type))
    }

    static func resolvedLibraryFolder(for type: MediaType) -> URL? {
        resolveBookmark(SettingsKeys.libraryFolderBookmark(type))
    }

    private static func saveBookmark(for url: URL, bookmarkKey: String, pathKey: String) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            UserDefaults.standard.set(url.path, forKey: pathKey)
        }
        resolvedBookmarks[bookmarkKey] = nil
        shared.refreshAccess(bookmarkKey: bookmarkKey)
    }

    /// Resolved folder URLs by bookmark key. Resolving a bookmark is a system
    /// call, and folders are looked up for every poster on every redraw.
    private static var resolvedBookmarks: [String: URL] = [:]

    private static func resolveBookmark(_ key: String) -> URL? {
        if let cached = resolvedBookmarks[key] { return cached }
        guard let bookmark = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        resolvedBookmarks[key] = url
        return url
    }

    static let mediaExtensions: Set<String> = [
        "mp4", "mkv", "mov", "m4v", "avi",
        "mp3", "m4a", "flac", "aiff", "wav",
    ]

    static func mediaCounts(for type: MediaType) -> (containers: Int, leaves: Int) {
        guard let folder = resolvedLibraryFolder(for: type) else { return (0, 0) }
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        var leafCount = 0
        var containerDirs: Set<String> = []

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard values?.isRegularFile == true,
                  mediaExtensions.contains(url.pathExtension.lowercased()) else { continue }
            leafCount += 1
            let rel = url.path.replacing(folder.path + "/", with: "")
            let components = rel.split(separator: "/")
            if components.count >= 2 {
                containerDirs.insert(String(components[0]))
            }
        }
        return (containerDirs.count, leafCount)
    }

    static func libraryIndexedEntries(for type: MediaType) -> [DownloadIndexEntry] {
        entries(in: resolvedLibraryFolder(for: type))
    }

    static func mergeLibraryIndex(_ entries: [DownloadIndexEntry], for type: MediaType) {
        guard let folder = resolvedLibraryFolder(for: type) else { return }
        var index = readIndexFromFolder(folder)
        for entry in entries {
            index[entry.item.id] = entry
        }
        writeIndex(index, to: folder)
    }

    func localLibraryURL(for item: MediaItem) -> URL? {
        Self.indexedFileURL(for: item, in: Self.resolvedLibraryFolder(for: item.type))
    }

    static func limitBytes(for type: MediaType) -> Int64 {
        let gigabytes = UserDefaults.standard.double(forKey: SettingsKeys.downloadLimitGB(type))
        return Int64(gigabytes * 1_000_000_000)
    }

    static func usageBytes(for type: MediaType) -> Int64 {
        guard let folder = resolvedFolder(for: type),
              let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .totalFileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .totalFileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileSize ?? 0)
        }
        return total
    }

    static func folderUsageDetails(for type: MediaType) -> (localBytes: Int64, downloadedBytes: Int64) {
        guard let folder = resolvedFolder(for: type) else { return (0, 0) }
        let total = usageBytes(for: type)
        var downloaded: Int64 = 0
        let index = readIndexFromFolder(folder)
        for entry in index.values {
            guard let filename = entry.filename else { continue }
            let fileURL = folder.appending(path: filename)
            if let values = try? fileURL.resourceValues(forKeys: [.totalFileSizeKey]),
               let size = values.totalFileSize {
                downloaded += Int64(size)
            }
        }
        return (max(0, total - downloaded), downloaded)
    }
    
    static func deleteDownloads(for type: MediaType) {
        guard let folder = resolvedFolder(for: type) else { return }
        var index = readIndexFromFolder(folder)
        
        for (id, entry) in index {
            if entry.item.source != .local {
                if let fileURL = entry.filename.flatMap({ fileURL($0, in: folder) }) {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                index.removeValue(forKey: id)
            }
        }
        writeIndex(index, to: folder)

        shared.downloadedIDs[type] = []
        removeArtwork(in: folder)

        if let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let dirs = enumerator.compactMap { element -> URL? in
                guard let url = element as? URL else { return nil }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return isDir ? url : nil
            }
            for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                if contents.isEmpty {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
        }
    }
    
    static func clearDownloadedArtwork() {
        for type in MediaType.allCases {
            if let folder = resolvedFolder(for: type) { removeArtwork(in: folder) }
        }
    }

    /// Deletes the poster images saved next to downloads.
    private static func removeArtwork(in folder: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let fileURL as URL in enumerator
        where ["jpg", "jpeg", "png"].contains(fileURL.pathExtension.lowercased()) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    static func isLevelEnabled(for kind: MediaKind) -> Bool {
        guard let level = DownloadLevel(kind: kind) else { return false }
        return UserDefaults.standard.bool(forKey: SettingsKeys.downloadLevelEnabled(level))
    }

    private static func indexURL(in folder: URL) -> URL {
        folder.appending(path: ".cinetray-downloads.json")
    }

    /// Parsed indexes by folder path. The app is the only writer of these
    /// files, so the cache is kept current by writeIndex(_:to:).
    private static var indexCache: [String: [String: DownloadIndexEntry]] = [:]

    private static func readIndexFromFolder(_ folder: URL) -> [String: DownloadIndexEntry] {
        if let cached = indexCache[folder.path] { return cached }
        let index = (try? Data(contentsOf: indexURL(in: folder)))
            .flatMap { try? JSONDecoder().decode([String: DownloadIndexEntry].self, from: $0) } ?? [:]
        indexCache[folder.path] = index
        return index
    }

    private static func writeIndex(_ index: [String: DownloadIndexEntry], to folder: URL) {
        let index = index.mapValues { DownloadIndexEntry(item: $0.item.removingPlexTokens, filename: $0.filename) }
        indexCache[folder.path] = index
        guard let data = try? JSONEncoder().encode(index) else { return }
        // Atomic so a crash mid-write can't leave a truncated index behind.
        try? data.write(to: indexURL(in: folder), options: .atomic)
    }

    static func indexedEntries(for type: MediaType) -> [DownloadIndexEntry] {
        entries(in: resolvedFolder(for: type))
    }

    private static func entries(in folder: URL?) -> [DownloadIndexEntry] {
        folder.map { Array(readIndexFromFolder($0).values) } ?? []
    }

    func isDownloaded(_ item: MediaItem) -> Bool {
        guard let folder = Self.resolvedFolder(for: item.type) else { return false }
        let index = Self.readIndexFromFolder(folder)
        guard let entry = index[item.id] else { return false }
        guard let filename = entry.filename else { return true }
        return FileManager.default.fileExists(
            atPath: folder.appending(path: filename).path
        )
    }

    func localURL(for item: MediaItem) -> URL? {
        Self.indexedFileURL(for: item, in: Self.resolvedFolder(for: item.type))
    }

    /// The indexed file for `item` in `folder`, if it still exists on disk.
    private static func indexedFileURL(for item: MediaItem, in folder: URL?) -> URL? {
        guard let folder,
              let filename = readIndexFromFolder(folder)[item.id]?.filename,
              let fileURL = fileURL(filename, in: folder) else { return nil }
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// `filename` from an index inside `folder`, or nil when a ".." would
    /// leave it. Anyone who can write to the folder can edit its index.
    private static func fileURL(_ filename: String, in folder: URL) -> URL? {
        filename.split(separator: "/").contains("..") ? nil : folder.appending(path: filename)
    }

    func download(_ item: MediaItem, appState: AppState) {
        guard !downloadingIDs.contains(item.id) else { return }
        Task {
            if item.kind.isExpandable {
                await downloadContainer(item, appState: appState)
            } else {
                await downloadLeaf(item, appState: appState, showAlerts: true)
            }
        }
    }

    private func downloadContainer(_ item: MediaItem, appState: AppState) async {
        guard Self.resolvedFolder(for: item.type) != nil else {
            Self.alert(
                title: "No Download Folder",
                message: "Choose a folder for \(item.type.title) in Settings → Data → Downloads first."
            )
            return
        }
        downloadingIDs.insert(item.id)
        defer { downloadingIDs.remove(item.id) }

        let leavesWithAncestors = await appState.downloadLeaves(of: item)
        guard !leavesWithAncestors.isEmpty else { return }

        var failCount = 0
        for (leaf, ancestors) in leavesWithAncestors where !isDownloaded(leaf) {
            let ok = await downloadLeaf(leaf, ancestors: ancestors, appState: appState, showAlerts: false)
            if !ok { failCount += 1 }
        }

        let leaves = leavesWithAncestors.map(\.item)
        if leaves.allSatisfy({ isDownloaded($0) }),
           let folder = Self.resolvedFolder(for: item.type) {
            var index = Self.readIndexFromFolder(folder)
            index[item.id] = DownloadIndexEntry(item: item, filename: nil)
            Self.writeIndex(index, to: folder)
            
            if let firstLeaf = leavesWithAncestors.first,
               let leafEntry = index[firstLeaf.item.id],
               let filename = leafEntry.filename {
                let leafURL = folder.appending(path: filename)
                let leafFolder = leafURL.deletingLastPathComponent()

                switch item.kind {
                case .show:
                    let hasSeasonAncestor = firstLeaf.ancestors.contains(where: { $0.kind == .season })
                        || firstLeaf.item.parentKind == .season
                    let showFolder = hasSeasonAncestor ? leafFolder.deletingLastPathComponent() : leafFolder
                    let rootFolder = showFolder.deletingLastPathComponent()
                    if let freshURL = firstLeaf.ancestors.first(where: { $0.kind == .season })?.parentPosterURL {
                        await downloadArtwork(from: freshURL, stem: showFolder.lastPathComponent,
                                              destinationFolder: rootFolder)
                    } else {
                        await downloadArtwork(for: item, fileURL: nil, destinationFolder: rootFolder,
                                              name: showFolder.lastPathComponent)
                    }
                case .season:
                    let showFolder = leafFolder.deletingLastPathComponent()
                    await downloadArtwork(for: item, fileURL: nil, destinationFolder: showFolder,
                                          name: leafFolder.lastPathComponent)
                    if let showPosterURL = item.parentPosterURL {
                        let rootFolder = showFolder.deletingLastPathComponent()
                        await downloadArtwork(from: showPosterURL, stem: showFolder.lastPathComponent,
                                              destinationFolder: rootFolder)
                    }
                default:
                    await downloadArtwork(for: item, fileURL: nil, destinationFolder: leafFolder)
                }
            }
        }

        if failCount > 0 {
            Self.alert(
                title: "Some Downloads Failed",
                message: "\(failCount) of \(leavesWithAncestors.count) item(s) couldn't be downloaded."
            )
        }
    }

    @discardableResult
    private func downloadLeaf(
        _ item: MediaItem,
        ancestors: [MediaItem] = [],
        appState: AppState,
        showAlerts: Bool
    ) async -> Bool {
        guard !downloadingIDs.contains(item.id) else { return true }
        guard let folder = Self.resolvedFolder(for: item.type) else {
            if showAlerts {
                Self.alert(
                    title: "No Download Folder",
                    message: "Choose a folder for \(item.type.title) in Settings → Data → Downloads first."
                )
            }
            return false
        }
        
        downloadingIDs.insert(item.id)
        downloadingItems.append(item)
        downloadProgress[item.id] = 0.0
        
        defer {
            downloadingIDs.remove(item.id)
            downloadingItems.removeAll { $0.id == item.id }
            downloadProgress.removeValue(forKey: item.id)
        }
        
        do {
            let url = try await appState.downloadURL(for: item)

            let expected = await Self.expectedSize(of: url)
            let limit = Self.limitBytes(for: item.type)
            if limit > 0 {
                let usage = Self.usageBytes(for: item.type)
                if usage + max(expected, 0) > limit {
                    if showAlerts {
                        let formatter = ByteCountFormatter()
                        Self.alert(
                            title: "Not Enough Download Storage",
                            message: "\(item.title) needs \(formatter.string(fromByteCount: max(expected, 0))), but \(item.type.title) downloads are limited to \(formatter.string(fromByteCount: limit)) and \(formatter.string(fromByteCount: usage)) is already used. Increase the allocation in Settings → Data or remove other downloads."
                        )
                    }
                    return false
                }
            }

            let (temporary, response) = try await downloadFileWithProgress(url: url, itemID: item.id)
            
            let fileExtension = response.suggestedFilename.flatMap { name -> String? in
                let ext = (name as NSString).pathExtension
                return ext.isEmpty ? nil : ext
            } ?? (url.pathExtension.isEmpty ? "media" : url.pathExtension)

            let relativePath = Self.relativePath(for: item, ancestors: ancestors, fileExtension: fileExtension)
            let destination = folder.appending(path: relativePath)

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)

            var index = Self.readIndexFromFolder(folder)
            index[item.id] = DownloadIndexEntry(item: item, filename: relativePath)

            for ancestor in ancestors {
                if index[ancestor.id] == nil {
                    index[ancestor.id] = DownloadIndexEntry(item: ancestor, filename: nil)
                }
                if ancestor.kind == .season, ancestor.parentKind == .show,
                   let showID = ancestor.parentID, !showID.isEmpty,
                   let showTitle = ancestor.parentTitle, !showTitle.isEmpty {
                    if index[showID] == nil {
                        let showItem = MediaItem(id: showID, source: ancestor.source, type: ancestor.type,
                                                 kind: .show, title: showTitle, posterURL: ancestor.parentPosterURL)
                        index[showID] = DownloadIndexEntry(item: showItem, filename: nil)
                    }
                }
            }

            if ancestors.isEmpty, item.parentKind == .season,
               let seasonID = item.parentID, !seasonID.isEmpty {
                if index[seasonID] == nil {
                    var seasonItem = MediaItem(id: seasonID, source: item.source, type: item.type,
                                               kind: .season, title: item.parentTitle ?? "Season",
                                               posterURL: item.parentPosterURL)
                    if let showID = item.attributes["grandparentRatingKey"], !showID.isEmpty,
                       let showTitle = item.attributes["grandparentTitle"], !showTitle.isEmpty {
                        seasonItem.parentID = showID
                        seasonItem.parentKind = .show
                        if index[showID] == nil {
                            let showPosterURL = item.attributes["grandparentPosterURL"].flatMap { URL(string: $0) }
                            let showItem = MediaItem(id: showID, source: item.source, type: item.type,
                                                     kind: .show, title: showTitle, posterURL: showPosterURL)
                            index[showID] = DownloadIndexEntry(item: showItem, filename: nil)
                        }
                    }
                    index[seasonID] = DownloadIndexEntry(item: seasonItem, filename: nil)
                }
            }

            Self.writeIndex(index, to: folder)

            downloadedIDs[item.type, default: []].insert(item.id)

            let currentFileURL = destination
            await downloadArtwork(for: item, fileURL: currentFileURL, destinationFolder: currentFileURL.deletingLastPathComponent())

            if item.kind == .episode {
                let episodeFolder = currentFileURL.deletingLastPathComponent()
                let hasSeason = ancestors.contains(where: { $0.kind == .season }) || item.parentKind == .season

                if hasSeason {
                    let showFolder = episodeFolder.deletingLastPathComponent()
                    let seasonFolderName = episodeFolder.lastPathComponent

                    if let seasonAncestor = ancestors.first(where: { $0.kind == .season }),
                       let url = seasonAncestor.posterURL {
                        await downloadArtwork(from: url, stem: seasonFolderName, destinationFolder: showFolder)
                    } else if item.parentKind == .season, let url = item.parentPosterURL {
                        await downloadArtwork(from: url, stem: seasonFolderName, destinationFolder: showFolder)
                    }

                    let rootFolder = showFolder.deletingLastPathComponent()
                    let showFolderName = showFolder.lastPathComponent

                    if let showAncestor = ancestors.first(where: { $0.kind == .show }),
                       let url = showAncestor.posterURL {
                        await downloadArtwork(from: url, stem: showFolderName, destinationFolder: rootFolder)
                    } else if let seasonAncestor = ancestors.first(where: { $0.kind == .season }),
                              let url = seasonAncestor.parentPosterURL {
                        await downloadArtwork(from: url, stem: showFolderName, destinationFolder: rootFolder)
                    } else if let urlString = item.attributes["grandparentPosterURL"], let url = URL(string: urlString) {
                        await downloadArtwork(from: url, stem: showFolderName, destinationFolder: rootFolder)
                    } else {
                        let showFolder = episodeFolder
                        let rootFolder = showFolder.deletingLastPathComponent()
                        let showFolderName = showFolder.lastPathComponent
                        
                        if let showAncestor = ancestors.first(where: { $0.kind == .show }),
                           let url = showAncestor.posterURL {
                            await downloadArtwork(from: url, stem: showFolderName, destinationFolder: rootFolder)
                        } else if item.parentKind == .show, let url = item.parentPosterURL {
                            await downloadArtwork(from: url, stem: showFolderName, destinationFolder: rootFolder)
                        }
                    }
                }
            }

            return true
        } catch {
            if showAlerts {
                Self.alert(title: "Download Failed", message: error.localizedDescription)
            }
            return false
        }
    }
    
    private func downloadFileWithProgress(url: URL, itemID: String) async throws -> (URL, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL = tempURL, let response = response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                let stableTemp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try? FileManager.default.removeItem(at: stableTemp)
                    try FileManager.default.moveItem(at: tempURL, to: stableTemp)
                    continuation.resume(returning: (stableTemp, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            
            let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                DispatchQueue.main.async {
                    self?.downloadProgress[itemID] = fraction
                }
            }
            
            objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)
            
            task.resume()
        }
    }

    private func downloadArtwork(for item: MediaItem, fileURL: URL?, destinationFolder: URL, name: String? = nil) async {
        guard let posterURL = item.posterURL else { return }
        await downloadArtwork(from: posterURL, stem: name ?? {
            if (item.kind == .episode || item.kind == .movie), let fileURL {
                return fileURL.deletingPathExtension().lastPathComponent
            }
            return "poster"
        }(), destinationFolder: destinationFolder)
    }

    private func downloadArtwork(from posterURL: URL, stem: String, destinationFolder: URL) async {
        let preferredExt = posterURL.pathExtension.lowercased() == "png" ? "png" : "jpg"
        do {
            let (tempURL, response) = try await URLSession.shared.download(for: ArtworkCache.request(for: posterURL), delegate: PlexTokenRedirectGuard.shared)
            var finalExt = preferredExt
            if let mime = response.mimeType {
                if mime.contains("png") { finalExt = "png" }
                else if mime.contains("jpeg") || mime.contains("jpg") { finalExt = "jpg" }
            }
            let finalDest = destinationFolder.appending(path: "\(stem).\(finalExt)")
            if FileManager.default.fileExists(atPath: finalDest.path) { return }
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: finalDest)
            try FileManager.default.moveItem(at: tempURL, to: finalDest)
        } catch {
            // Artwork is optional; the error's URL can carry Navidrome credentials, so it isn't logged.
        }
    }

    /// Makes a title safe to use as a file or folder name.
    nonisolated static func sanitizePathComponent(_ s: String) -> String {
        var result = s.replacing("/", with: "-").replacing(":", with: "-")
        while result.hasPrefix(".") { result = String(result.dropFirst()) }
        return result.isEmpty ? "Unknown" : result
    }

    /// Every component comes from the server (paths, IDs, titles, the file
    /// extension), so each is sanitized: a ".." would place the file, and the
    /// removeItem before it, outside the download folder.
    private static func relativePath(for item: MediaItem, ancestors: [MediaItem], fileExtension ext: String) -> String {
        let fallbackFilename = "\(sanitizePathComponent(item.id))-\(sanitizePathComponent(item.title)).\(sanitizePathComponent(ext))"
        if item.kind == .episode {
            let originalComponents = (item.attributes["originalPath"] ?? "")
                .components(separatedBy: CharacterSet(charactersIn: "\\/")).filter { !$0.isEmpty }
            let filename = originalComponents.last.map(sanitizePathComponent) ?? fallbackFilename

            let showName: String?
            if let s = ancestors.first(where: { $0.kind == .show }) {
                showName = s.title
            } else if item.parentKind == .show, let pt = item.parentTitle, !pt.isEmpty {
                showName = pt
            } else if let gt = item.attributes["grandparentTitle"], !gt.isEmpty {
                showName = gt
            } else {
                showName = nil
            }

            let seasonName: String?
            if let s = ancestors.first(where: { $0.kind == .season }) {
                seasonName = s.title
            } else if item.parentKind == .season, let pt = item.parentTitle, !pt.isEmpty {
                seasonName = pt
            } else if let idxStr = item.attributes["parentIndex"], let idx = Int(idxStr) {
                seasonName = "Season \(String(format: "%02d", idx))"
            } else if let match = filename.firstMatch(of: /[Ss](\d{1,2})[Ee]\d{1,2}/), let num = Int(match.1) {
                seasonName = "Season \(String(format: "%02d", num))"
            } else {
                seasonName = nil
            }

            if let show = showName.map(sanitizePathComponent), let season = seasonName.map(sanitizePathComponent) {
                return "\(show)/\(season)/\(filename)"
            } else if let show = showName.map(sanitizePathComponent) {
                return "\(show)/\(filename)"
            } else if let season = seasonName.map(sanitizePathComponent) {
                return "\(season)/\(filename)"
            }
            return filename
        }

        if let original = item.attributes["originalPath"], !original.isEmpty {
            let components = original.components(separatedBy: CharacterSet(charactersIn: "\\/")).filter { !$0.isEmpty }
                .map(sanitizePathComponent)
            if !components.isEmpty {
                switch item.type {
                case .tvShows: return components.suffix(3).joined(separator: "/")
                case .music:   return components.suffix(3).joined(separator: "/")
                case .movies:  return components.suffix(2).joined(separator: "/")
                }
            }
        }

        let filename = fallbackFilename
        switch item.kind {
        case .track:
            let artistName = item.subtitle ?? ancestors.first(where: { $0.kind == .artist })?.title
            let albumName = item.parentTitle ?? ancestors.first(where: { $0.kind == .album })?.title
            if let artist = artistName.map(sanitizePathComponent),
               let album = albumName.map(sanitizePathComponent) {
                return "\(artist)/\(album)/\(filename)"
            } else if let album = albumName.map(sanitizePathComponent) {
                return "\(album)/\(filename)"
            }
            return filename
        default:
            return filename
        }
    }

    private static func expectedSize(of url: URL) async -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return 0 }
        let length = response.expectedContentLength
        return length > 0 ? length : 0
    }

    private static func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApplication.shared.activate()
        alert.runModal()
    }
}
