import SwiftUI
import TipKit

/// Offline downloads (per-type folders and storage allocations) and the
/// artwork cache.
struct DataSettingsView: View {
    @AppStorage(SettingsKeys.showsTour) private var showsTour = false
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
                    .popoverTip(showsTour && !downloadsEnabled ? DownloadsTip() : nil)
                    .onChange(of: downloadsEnabled) {
                        if downloadsEnabled { DownloadsTip().invalidate(reason: .actionPerformed) }
                    }
                Group {
                    LabeledContent("Movies") {
                        DownloadLevelToggle("Movie", level: .movie)
                    }
                    LabeledContent("Shows") {
                        HStack {
                            DownloadLevelToggle("Series", level: .series)
                            DownloadLevelToggle("Season", level: .season)
                            DownloadLevelToggle("Episode", level: .episode)
                        }
                    }
                    LabeledContent("Music") {
                        HStack {
                            DownloadLevelToggle("Playlist", level: .playlist)
                            DownloadLevelToggle("Artist", level: .artist)
                            DownloadLevelToggle("Album", level: .album)
                            DownloadLevelToggle("Song", level: .song)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!downloadsEnabled)
            } header: {
                SectionInfoHeader(title: "Downloads", info: "With downloads enabled, the items ticked here get a small download button in the dropdown. Downloading a series, season, artist, album or playlist downloads everything in it. Each media type saves into its own folder, capped at its storage limit.")
            }

            ForEach(MediaType.allCases) { type in
                downloadSection(for: type)
            }

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

    private func updateCacheSize() {
        let bytes = ArtworkCache.diskUsageBytes
        cacheSizeDescription = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            : "Empty"
    }
}

/// A "Show Download Button On" checkbox. @AppStorage rather than a Binding
/// over UserDefaults, which SwiftUI doesn't watch, so the box redraws when
/// clicked.
private struct DownloadLevelToggle: View {
    let title: String
    @AppStorage private var isOn: Bool

    init(_ title: String, level: DownloadLevel) {
        self.title = title
        _isOn = AppStorage(wrappedValue: false, SettingsKeys.downloadLevelEnabled(level))
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
    }
}
