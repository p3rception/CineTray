import Foundation

/// Scans a local library folder and parses its contents into a MediaItem
/// hierarchy by interpreting the folder structure and file name conventions.
///
/// Expected layouts:
/// - Movies:  `<folder>/<Title> (Year).ext`  (flat)
/// - TV:      `<folder>/<Show>/<Season NN>/<SxxEyy Title.ext>`
/// - Music:   `<folder>/<Artist>/<Album>/<NN Title.ext>`
///
/// Items that don't match are still returned as bare leaves so they remain
/// accessible in the UI.
nonisolated struct LocalLibraryScanner {

    let type: MediaType
    let folder: URL

    // MARK: - Public API

    /// Returns index entries for all media files found in `folder`, plus
    /// container entries for the hierarchy above them. Off the main thread,
    /// since it walks the whole folder.
    @concurrent func scan() async -> [DownloadIndexEntry] {
        switch type {
        case .movies: return scanMovies()
        case .tvShows: return scanTV()
        case .music: return scanMusic()
        }
    }

    // MARK: - Movies

    private func scanMovies() -> [DownloadIndexEntry] {
        let files = mediaFiles(in: folder, recursive: false)
        return files.map { url in
            let relativePath = url.lastPathComponent
            let stem = url.deletingPathExtension().lastPathComponent
            let (title, year) = parseTitleYear(from: stem)
            let id = itemID(relativePath: relativePath)
            var item = MediaItem(id: id, source: .local, type: .movies, kind: .movie, title: title)
            item.subtitle = year.map { "\($0)" }
            item.posterURL = Self.artworkURL(in: url.deletingLastPathComponent(), stem: nil) ?? Self.artworkURL(in: url.deletingLastPathComponent(), stem: stem)
            return DownloadIndexEntry(item: item, filename: relativePath)
        }
    }

    // MARK: - TV

    private func scanTV() -> [DownloadIndexEntry] {
        var entries: [DownloadIndexEntry] = []
        let showDirs = subdirectories(of: folder)

        for showDir in showDirs {
            let showTitle = showDir.lastPathComponent
            let showID = itemID(relativePath: showTitle)
            var showItem = MediaItem(id: showID, source: .local, type: .tvShows, kind: .show, title: showTitle)
            // Show poster: sibling naming (ShowTitle.jpg in TV root) with fallback to poster.* inside show dir.
            showItem.posterURL = Self.artworkURL(in: folder, stem: showTitle)
                ?? Self.artworkURL(in: showDir, stem: nil)

            let seasonDirs = subdirectories(of: showDir)
            if seasonDirs.isEmpty {
                // Flat show layout: files directly under the show directory.
                let files = mediaFiles(in: showDir, recursive: false)
                for file in files {
                    let rel = "\(showTitle)/\(file.lastPathComponent)"
                    let stem = file.deletingPathExtension().lastPathComponent
                    let (epTitle, season, episode) = parseEpisode(from: stem)
                    let epID = itemID(relativePath: rel)
                    var ep = MediaItem(id: epID, source: .local, type: .tvShows, kind: .episode, title: epTitle)
                    ep.parentID = showID
                    ep.parentKind = .show
                    ep.subtitle = formatEpisodeCode(season: season, episode: episode)
                    ep.attributes["grandparentTitle"] = showTitle
                    ep.posterURL = Self.artworkURL(in: showDir, stem: stem)
                    entries.append(DownloadIndexEntry(item: ep, filename: rel))
                }
            } else {
                for seasonDir in seasonDirs {
                    let seasonTitle = seasonDir.lastPathComponent
                    let seasonNumber = parseSeasonNumber(from: seasonTitle)
                    let seasonID = itemID(relativePath: "\(showTitle)/\(seasonTitle)")
                    var seasonItem = MediaItem(id: seasonID, source: .local, type: .tvShows, kind: .season, title: seasonTitle)
                    seasonItem.parentID = showID
                    seasonItem.parentKind = .show
                    seasonItem.subtitle = seasonNumber.map { "Season \($0)" }
                    // Season poster: sibling naming (SeasonTitle.jpg in show dir) with fallbacks.
                    seasonItem.posterURL = Self.artworkURL(in: showDir, stem: seasonTitle)
                        ?? Self.artworkURL(in: seasonDir, stem: nil)
                        ?? showItem.posterURL

                    let files = mediaFiles(in: seasonDir, recursive: false)
                    for file in files {
                        let rel = "\(showTitle)/\(seasonTitle)/\(file.lastPathComponent)"
                        let stem = file.deletingPathExtension().lastPathComponent
                        let (epTitle, _, episode) = parseEpisode(from: stem)
                        let epID = itemID(relativePath: rel)
                        var ep = MediaItem(id: epID, source: .local, type: .tvShows, kind: .episode, title: epTitle)
                        ep.parentID = seasonID
                        ep.parentKind = .season
                        ep.subtitle = formatEpisodeCode(season: seasonNumber, episode: episode)
                        ep.attributes["grandparentTitle"] = showTitle
                        ep.posterURL = Self.artworkURL(in: seasonDir, stem: stem)
                        entries.append(DownloadIndexEntry(item: ep, filename: rel))
                    }

                    if !files.isEmpty {
                        entries.append(DownloadIndexEntry(item: seasonItem, filename: nil))
                    }
                }
            }

            // Add show container if any direct children reference it.
            if entries.contains(where: { $0.item.parentID == showID }) {
                entries.append(DownloadIndexEntry(item: showItem, filename: nil))
            }
        }

        // Also catch flat episode files dropped directly into the root.
        let rootFiles = mediaFiles(in: folder, recursive: false)
        for file in rootFiles {
            let rel = file.lastPathComponent
            let stem = file.deletingPathExtension().lastPathComponent
            let (epTitle, season, episode) = parseEpisode(from: stem)
            let id = itemID(relativePath: rel)
            var ep = MediaItem(id: id, source: .local, type: .tvShows, kind: .episode, title: epTitle)
            ep.subtitle = formatEpisodeCode(season: season, episode: episode)
            ep.posterURL = Self.artworkURL(in: folder, stem: stem)
            entries.append(DownloadIndexEntry(item: ep, filename: rel))
        }

        return entries
    }

    // MARK: - Music

    private func scanMusic() -> [DownloadIndexEntry] {
        var entries: [DownloadIndexEntry] = []
        let artistDirs = subdirectories(of: folder)

        for artistDir in artistDirs {
            let artistName = artistDir.lastPathComponent
            let artistID = itemID(relativePath: artistName)
            var artistItem = MediaItem(id: artistID, source: .local, type: .music, kind: .artist, title: artistName)
            artistItem.posterURL = Self.artworkURL(in: artistDir, stem: nil)

            let albumDirs = subdirectories(of: artistDir)
            for albumDir in albumDirs {
                let albumName = albumDir.lastPathComponent
                let albumID = itemID(relativePath: "\(artistName)/\(albumName)")
                var albumItem = MediaItem(id: albumID, source: .local, type: .music, kind: .album, title: albumName)
                albumItem.subtitle = artistName
                albumItem.parentID = artistID
                albumItem.parentKind = .artist
                albumItem.posterURL = Self.artworkURL(in: albumDir, stem: nil) ?? artistItem.posterURL

                let files = mediaFiles(in: albumDir, recursive: false)
                for file in files {
                    let rel = "\(artistName)/\(albumName)/\(file.lastPathComponent)"
                    let stem = file.deletingPathExtension().lastPathComponent
                    let trackTitle = parseTrackTitle(from: stem)
                    let trackID = itemID(relativePath: rel)
                    var track = MediaItem(id: trackID, source: .local, type: .music, kind: .track, title: trackTitle)
                    track.subtitle = artistName
                    track.parentID = albumID
                    track.parentKind = .album
                    track.parentTitle = albumName
                    track.posterURL = albumItem.posterURL
                    entries.append(DownloadIndexEntry(item: track, filename: rel))
                }

                if !files.isEmpty {
                    entries.append(DownloadIndexEntry(item: albumItem, filename: nil))
                }
            }

            if !albumDirs.isEmpty {
                entries.append(DownloadIndexEntry(item: artistItem, filename: nil))
            }

            // Flat tracks directly under the artist dir (no album).
            let flatTracks = mediaFiles(in: artistDir, recursive: false)
            for file in flatTracks {
                let rel = "\(artistName)/\(file.lastPathComponent)"
                let stem = file.deletingPathExtension().lastPathComponent
                let trackTitle = parseTrackTitle(from: stem)
                let trackID = itemID(relativePath: rel)
                var track = MediaItem(id: trackID, source: .local, type: .music, kind: .track, title: trackTitle)
                track.subtitle = artistName
                track.parentID = artistID
                track.parentKind = .artist
                track.posterURL = artistItem.posterURL
                entries.append(DownloadIndexEntry(item: track, filename: rel))
            }
        }

        // Flat tracks at the root.
        let rootFiles = mediaFiles(in: folder, recursive: false)
        for file in rootFiles {
            let rel = file.lastPathComponent
            let stem = file.deletingPathExtension().lastPathComponent
            let trackTitle = parseTrackTitle(from: stem)
            let id = itemID(relativePath: rel)
            var track = MediaItem(id: id, source: .local, type: .music, kind: .track, title: trackTitle)
            track.posterURL = Self.artworkURL(in: folder, stem: nil) ?? Self.artworkURL(in: folder, stem: stem)
            entries.append(DownloadIndexEntry(item: track, filename: rel))
        }

        return entries
    }

    // MARK: - Filesystem helpers

    /// The first existing `<stem>.jpg/.png/.jpeg` (or `poster.*` when no stem) in `folder`.
    static func artworkURL(in folder: URL, stem: String?) -> URL? {
        let candidates: [String]
        if let stem {
            candidates = ["\(stem).jpg", "\(stem).png", "\(stem).jpeg"]
        } else {
            candidates = ["poster.jpg", "poster.png", "poster.jpeg"]
        }
        for candidate in candidates {
            let url = folder.appending(path: candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func subdirectories(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func mediaFiles(in url: URL, recursive: Bool) -> [URL] {
        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return (enumerator.allObjects as? [URL] ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
                DownloadManager.mediaExtensions.contains($0.pathExtension.lowercased())
            }
        } else {
            return ((try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
                DownloadManager.mediaExtensions.contains($0.pathExtension.lowercased())
            }
        }
    }

    // MARK: - Parsing helpers

    private func itemID(relativePath: String) -> String {
        "lib-\(type.rawValue)-\(relativePath)"
    }

    /// Strips common quality/codec tags and extracts a year from the file stem.
    /// e.g. "The Matrix (1999)" → ("The Matrix", 1999)
    ///      "Inception.2010.1080p.BluRay" → ("Inception", 2010)
    private func parseTitleYear(from stem: String) -> (String, Int?) {
        // Match "Title (YYYY)" format.
        var s = stem
        var year: Int?
        if let range = s.range(of: #"\((\d{4})\)"#, options: .regularExpression) {
            let yearStr = String(s[range]).filter(\.isNumber)
            year = Int(yearStr)
            s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        // Match "Title.YYYY." or "Title 2010 1080p" format.
        // (?:^|\D) stands in for a (?<!\d) lookbehind, which Swift Regex lacks.
        if year == nil,
           let match = s.firstMatch(of: /(?:^|\D)(\d{4})(?!\d)/),
           let y = Int(match.1), (1900...2100).contains(y) {
            year = y
            s = String(s[..<match.1.startIndex]).trimmingCharacters(in: CharacterSet(charactersIn: ". _-").union(.whitespaces))
        }

        // Replace dots and underscores used as word separators, strip quality tags.
        s = s.replacing(".", with: " ").replacing("_", with: " ")
        let qualityTags = ["1080p", "720p", "4K", "2160p", "BluRay", "BDRip", "WEBRip", "HDTV", "x264", "x265", "HEVC", "AAC", "AC3"]
        for tag in qualityTags {
            s = s.replacing(tag, with: "").replacing(tag.lowercased(), with: "")
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return (s.isEmpty ? stem : s, year)
    }

    /// Parses episode info from a file stem.
    /// Recognises: "S01E05", "1x05", remaining stem becomes title with quality/metadata tags stripped.
    func parseEpisode(from stem: String) -> (title: String, season: Int?, episode: Int?) {
        // S01E05 / s01e05, then 1x05.
        for pattern in [/[Ss](\d{1,2})[Ee](\d{1,2})/, /(\d{1,2})x(\d{1,2})/] {
            guard let match = stem.firstMatch(of: pattern) else { continue }
            let rest = String(stem[match.range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
            let title = stripFileTags(from: rest)
            return (title.isEmpty ? stem : title, Int(match.1), Int(match.2))
        }
        return (stem, nil, nil)
    }

    private func stripFileTags(from s: String) -> String {
        s.replacing(/\{[^}]*\}/, with: "")
            .replacing(/\[[^\]]*\]/, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func parseSeasonNumber(from dirName: String) -> Int? {
        // "Season 1", "Season 01", "S1", "S01"
        dirName.firstMatch(of: /(?:[Ss]eason\s*|[Ss])(\d{1,2})/).flatMap { Int($0.1) }
    }

    private func formatEpisodeCode(season: Int?, episode: Int?) -> String? {
        switch (season, episode) {
        case (let s?, let e?): return String(format: "S%02dE%02d", s, e)
        case (nil, let e?): return String(format: "E%02d", e)
        default: return nil
        }
    }

    /// Strips a leading track number (e.g. "01 ", "01 - ", "01. ") from the stem.
    private func parseTrackTitle(from stem: String) -> String {
        guard let match = stem.prefixMatch(of: /\d{1,3}[\s.\-_]+/) else { return stem }
        let title = String(stem[match.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? stem : title
    }
}
