import Foundation

/// One partially-played item, powering the Continue Watching section and
/// resume-on-play.
struct PlaybackProgress: Codable {
    var item: MediaItem
    var positionSeconds: Double
    var durationSeconds: Double
    var updatedAt: Date
}

/// Local record of in-progress playback, persisted in UserDefaults. An item
/// appears once it's meaningfully started (>5%) and disappears once
/// essentially finished (>92%) - for any backend.
enum PlaybackProgressStore {
    private static let startedFraction = 0.05
    private static let finishedFraction = 0.92

    /// Items last played before this drop out of Continue Watching.
    static var cutoff: Date? {
        let timeout = UserDefaults.standard.string(forKey: SettingsKeys.continueTimeout)
            .flatMap(ContinueTimeout.init) ?? .forever
        return timeout.maxAge.map { Date.now.addingTimeInterval(-$0) }
    }

    static func all() -> [PlaybackProgress] {
        let cutoff = Self.cutoff
        return load().values
            .filter { entry in cutoff.map { entry.updatedAt >= $0 } ?? true }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func entry(for item: MediaItem) -> PlaybackProgress? {
        load()[item.id].flatMap { $0.item.isFromSameServer(as: item) ? $0 : nil }
    }

    /// Records progress, or clears the entry when playback is effectively
    /// finished. Containers are never tracked.
    static func update(item: MediaItem, positionSeconds: Double, durationSeconds: Double) {
        guard !item.kind.isExpandable, durationSeconds > 0 else { return }
        var (entries, unreadable) = read()
        let fraction = positionSeconds / durationSeconds
        if fraction >= finishedFraction || fraction < startedFraction {
            entries.removeValue(forKey: item.id)
        } else {
            entries[item.id] = PlaybackProgress(
                item: item,
                positionSeconds: positionSeconds,
                durationSeconds: durationSeconds,
                updatedAt: .now
            )
        }
        save(entries, keeping: unreadable)
    }

    static func remove(itemID: String) {
        var (entries, unreadable) = read()
        entries.removeValue(forKey: itemID)
        unreadable.removeValue(forKey: itemID)
        save(entries, keeping: unreadable)
    }

    private static func load() -> [String: PlaybackProgress] {
        read().entries
    }

    /// The saved entries, plus the JSON of any this build can't decode (one
    /// written by another build, say). Those are kept and saved back, so one
    /// bad entry doesn't take every saved position with it.
    private static func read() -> (entries: [String: PlaybackProgress], unreadable: [String: Any]) {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.playbackProgress) else { return ([:], [:]) }
        if let entries = try? JSONDecoder().decode([String: PlaybackProgress].self, from: data) {
            return (entries, [:])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([:], [:]) }
        var entries: [String: PlaybackProgress] = [:]
        var unreadable: [String: Any] = [:]
        for (id, value) in object {
            if let json = try? JSONSerialization.data(withJSONObject: value),
               let entry = try? JSONDecoder().decode(PlaybackProgress.self, from: json) {
                entries[id] = entry
            } else {
                unreadable[id] = value
            }
        }
        return (entries, unreadable)
    }

    /// Rewrites saved progress without Plex tokens; older builds stored
    /// them inside poster URLs.
    static func removeSavedPlexTokens() {
        let (entries, unreadable) = read()
        guard !entries.isEmpty else { return }
        save(entries, keeping: unreadable)
    }

    private static func save(_ entries: [String: PlaybackProgress], keeping unreadable: [String: Any]) {
        let entries = entries.mapValues { entry in
            var entry = entry
            entry.item = entry.item.removingPlexTokens
            return entry
        }
        guard var data = try? JSONEncoder().encode(entries) else { return }
        if !unreadable.isEmpty {
            guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            object.merge(unreadable) { readable, _ in readable }
            guard let merged = try? JSONSerialization.data(withJSONObject: object) else { return }
            data = merged
        }
        UserDefaults.standard.set(data, forKey: SettingsKeys.playbackProgress)
    }
}
