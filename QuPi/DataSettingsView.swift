import SwiftUI

/// Offline downloads (per-type folders and storage allocations) and the
/// artwork cache.
struct DataSettingsView: View {
    @AppStorage(SettingsKeys.downloadsEnabled) private var downloadsEnabled = false
    @AppStorage(SettingsKeys.downloadIndicatorsEnabled) private var downloadIndicators = false
    @AppStorage(SettingsKeys.cacheArtwork) private var cacheArtwork = true

    // Refresh trigger for folder paths and usage after choosing folders.
    @State private var folderRefresh = 0
    @State private var cacheSizeDescription = ""

    var body: some View {
        Form {
            Section {
                Toggle("Enable Downloads", isOn: $downloadsEnabled)
                ForEach(MediaType.allCases) { type in
                    downloadRow(for: type)
                }
                Toggle("Download Indicators", isOn: $downloadIndicators)
                    .disabled(!downloadsEnabled)
                if downloadIndicators {
                    moviesLevelRow
                    tvLevelRow
                    musicLevelRow
                }
            } header: {
                SectionInfoHeader(title: "Downloads", info: "With downloads enabled, playable items in the dropdown get a small download button. Use the checkboxes to also show the download button at higher levels - tapping a series or album downloads everything inside it. Each media type saves into its own folder, capped at its storage amount.")
            }
            Section {
                Toggle("Cache Artwork Locally", isOn: $cacheArtwork)
                HStack {
                    Button("Clear Artwork Cache") {
                        ArtworkCache.clear()
                        DownloadManager.clearDownloadedArtwork()
                        updateCacheSize()
                    }
                    if !cacheSizeDescription.isEmpty {
                        Text(cacheSizeDescription)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionInfoHeader(title: "Caching", info: "Cached artwork is kept on disk so posters don't re-download every launch.")
            }
        }
        .formStyle(.grouped)
        .task { updateCacheSize() }
    }

    private func downloadRow(for type: MediaType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(type.title, systemImage: type.systemImage)
                    .frame(width: 110, alignment: .leading)
                Spacer()
                TextField("Max", value: limitBinding(for: type), format: .number)
                    .labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("GB")
                    .foregroundStyle(.secondary)
                Button("Update Location") { chooseFolder(for: type) }
                Button("Delete Downloads") {
                    DownloadManager.deleteDownloads(for: type)
                    folderRefresh += 1
                }
            }
            let description = folderDescription(for: type)
            if !description.isEmpty {
                Text(description)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .id(folderRefresh)
            }
        }
        .task(id: folderRefresh) {
            if DownloadManager.resolvedFolder(for: type) == nil {
                adoptLibraryFolder(for: type)
            }
        }
        .disabled(!downloadsEnabled)
    }

    private func folderDescription(for type: MediaType) -> String {
        guard let path = DownloadManager.folderPath(for: type) else { return "" }
        let details = DownloadManager.folderUsageDetails(for: type)
        let localStr = ByteCountFormatter.string(fromByteCount: details.localBytes, countStyle: .file)
        let downStr = ByteCountFormatter.string(fromByteCount: details.downloadedBytes, countStyle: .file)
        let totalStr = ByteCountFormatter.string(fromByteCount: details.localBytes + details.downloadedBytes, countStyle: .file)
        return "\((path as NSString).abbreviatingWithTildeInPath) (\(localStr) local / \(downStr) downloaded / Total = \(totalStr) stored)"
    }

    private func chooseFolder(for type: MediaType) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for \(type.title) Downloads"
        panel.directoryURL = DownloadManager.resolvedFolder(for: type)
        if panel.runModal() == .OK, let url = panel.url {
            DownloadManager.setFolder(url, for: type)
            folderRefresh += 1
        }
    }

    private func adoptLibraryFolder(for type: MediaType) {
        guard let folder = DownloadManager.resolvedLibraryFolder(for: type) else { return }
        DownloadManager.setFolder(folder, for: type)
        folderRefresh += 1
    }

    private func limitBinding(for type: MediaType) -> Binding<Double> {
        Binding {
            UserDefaults.standard.double(forKey: SettingsKeys.downloadLimitGB(type))
        } set: { newValue in
            UserDefaults.standard.set(max(newValue, 0), forKey: SettingsKeys.downloadLimitGB(type))
        }
    }

    private var moviesLevelRow: some View {
        VStack(alignment: .leading) {
            Text("Movies")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Movie", isOn: levelBinding(.movie))
            }
        }
        .disabled(!downloadsEnabled)
    }

    private var tvLevelRow: some View {
        VStack(alignment: .leading) {
            Text("Shows")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Series", isOn: levelBinding(.series))
                Toggle("Season", isOn: levelBinding(.season))
                Toggle("Episode", isOn: levelBinding(.episode))
            }
        }
        .disabled(!downloadsEnabled)
    }

    private var musicLevelRow: some View {
        VStack(alignment: .leading) {
            Text("Music")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Playlist", isOn: levelBinding(.playlist))
                Toggle("Artist", isOn: levelBinding(.artist))
                Toggle("Album", isOn: levelBinding(.album))
                Toggle("Song", isOn: levelBinding(.song))
            }
        }
        .disabled(!downloadsEnabled)
    }

    private func levelBinding(_ level: DownloadLevel) -> Binding<Bool> {
        Binding {
            UserDefaults.standard.bool(forKey: SettingsKeys.downloadLevelEnabled(level))
        } set: { newValue in
            UserDefaults.standard.set(newValue, forKey: SettingsKeys.downloadLevelEnabled(level))
        }
    }

    private func updateCacheSize() {
        let bytes = ArtworkCache.diskUsageBytes
        cacheSizeDescription = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            : "Empty"
    }
}
