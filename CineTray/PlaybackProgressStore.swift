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
/// essentially finished (>92%) - for any backend, including the sample
/// catalog.
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

    static func entry(forItemID id: String) -> PlaybackProgress? {
        load()[id]
    }

    /// Records progress, or clears the entry when playback is effectively
    /// finished. Containers are never tracked.
    static func update(item: MediaItem, positionSeconds: Double, durationSeconds: Double) {
        guard !item.kind.isExpandable, durationSeconds > 0 else { return }
        var entries = load()
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
        save(entries)
    }

    static func remove(itemID: String) {
        var entries = load()
        entries.removeValue(forKey: itemID)
        save(entries)
    }

    private static func load() -> [String: PlaybackProgress] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.playbackProgress) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: PlaybackProgress].self, from: data)) ?? [:]
    }

    /// Rewrites saved progress without Plex tokens; older builds stored
    /// them inside poster URLs.
    static func removeSavedPlexTokens() {
        let entries = load()
        guard !entries.isEmpty else { return }
        save(entries)
    }

    private static func save(_ entries: [String: PlaybackProgress]) {
        let entries = entries.mapValues { entry in
            var entry = entry
            entry.item = entry.item.removingPlexTokens
            return entry
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: SettingsKeys.playbackProgress)
        }
    }
}
