import SwiftUI

/// Offline downloads (per-type folders and storage allocations) and the
/// artwork cache.
struct DataSettingsView: View {
    @AppStorage(SettingsKeys.downloadsEnabled) private var downloadsEnabled = false
    @AppStorage(SettingsKeys.cacheArtwork) private var cacheArtwork = true

    // Refresh trigger for folder paths and usage after choosing folders.
    @State private var folderRefresh = 0
    @State private var cacheSizeDescription = ""
    @State private var confirmingDelete: MediaType?

    var body: some View {
        Form {
            Section {
                Toggle("Enable Downloads", isOn: $downloadsEnabled)
            } header: {
                SectionInfoHeader(title: "Downloads", info: "With downloads enabled, playable items in the dropdown get a small download button. Each media type saves into its own folder, capped at its storage limit.")
            }

            ForEach(MediaType.allCases) { type in
                downloadSection(for: type)
            }

            Section {
                LabeledContent("Movies") {
                    Toggle("Movie", isOn: levelBinding(.movie))
                }
                LabeledContent("Shows") {
                    HStack {
                        Toggle("Series", isOn: levelBinding(.series))
                        Toggle("Season", isOn: levelBinding(.season))
                        Toggle("Episode", isOn: levelBinding(.episode))
                    }
                }
                LabeledContent("Music") {
                    HStack {
                        Toggle("Playlist", isOn: levelBinding(.playlist))
                        Toggle("Artist", isOn: levelBinding(.artist))
                        Toggle("Album", isOn: levelBinding(.album))
                        Toggle("Song", isOn: levelBinding(.song))
                    }
                }
            } header: {
                SectionInfoHeader(title: "Show Download Button On", info: "Downloading a series, season, artist, album or playlist downloads everything in it.")
            }
            .toggleStyle(.checkbox)
            .disabled(!downloadsEnabled)

            Section {
                Toggle("Cache Artwork Locally", isOn: $cacheArtwork)
                LabeledContent("Artwork Cache") {
                    HStack {
                        Text(cacheSizeDescription)
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            ArtworkCache.clear()
                            DownloadManager.clearDownloadedArtwork()
                            updateCacheSize()
                        }
                    }
                }
            } header: {
                SectionInfoHeader(title: "Caching", info: "Cached artwork is kept on disk so posters don't re-download every launch.")
            }
        }
        .formStyle(.grouped)
        .task { updateCacheSize() }
        .confirmationDialog(
            "Delete all downloaded \(confirmingDelete?.title.lowercased() ?? "")?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            presenting: confirmingDelete
        ) { type in
            Button("Delete Downloads", role: .destructive) {
                DownloadManager.deleteDownloads(for: type)
                folderRefresh += 1
            }
        } message: { _ in
            Text("The downloaded files are removed from the folder. You can download them again at any time.")
        }
    }

    private func downloadSection(for type: MediaType) -> some View {
        Section {
            LabeledContent("Folder") {
                HStack {
                    Text(DownloadManager.folderPath(for: type).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not set")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFolder(for: type) }
                }
            }
            LabeledContent("Storage Limit") {
                HStack(spacing: 4) {
                    TextField("Storage Limit", value: limitBinding(for: type), format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .underlinedField()
                    Text("GB")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Used", value: usageDescription(for: type))
            Button("Delete Downloads…", role: .destructive) {
                confirmingDelete = type
            }
        } header: {
            Label(type.title, systemImage: type.systemImage)
        }
        // Changes after choosing a folder or deleting, so path and usage re-read.
        .id("\(type.rawValue)-\(folderRefresh)")
        .task(id: folderRefresh) {
            if DownloadManager.resolvedFolder(for: type) == nil {
                adoptLibraryFolder(for: type)
            }
        }
        .disabled(!downloadsEnabled)
    }

    private func usageDescription(for type: MediaType) -> String {
        guard DownloadManager.folderPath(for: type) != nil else { return "-" }
        let details = DownloadManager.folderUsageDetails(for: type)
        let downloaded = ByteCountFormatter.string(fromByteCount: details.downloadedBytes, countStyle: .file)
        guard details.localBytes > 0 else { return downloaded }
        let local = ByteCountFormatter.string(fromByteCount: details.localBytes, countStyle: .file)
        return "\(downloaded) downloaded, \(local) of your own files"
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
