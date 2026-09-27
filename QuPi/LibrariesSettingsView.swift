import SwiftUI
import AppKit

/// Multi-select of Plex and Jellyfin libraries to include in the dropdown.
struct LibrariesSettingsView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(SettingsKeys.plexSelectedLibraries) private var plexSelected = ""
    @AppStorage(SettingsKeys.jellyfinSelectedLibraries) private var jellyfinSelected = ""

    // Plex libraries and load status per connected server ID.
    @State private var plexLibraries: [String: [PlexLibrary]] = [:]
    @State private var plexStatuses: [String: String] = [:]
    @State private var jellyfinLibraries: [JellyfinLibrary] = []
    @State private var jellyfinStatus = ""
    @State private var localRefresh = 0
    @State private var isRefreshing = false

    var body: some View {
        let plexConfigurations = appState.plexConfigurations
        Form {
            localSection

            if plexConfigurations.isEmpty && appState.jellyfinConfiguration == nil && appState.navidromeConfiguration == nil {
                Section {
                    Text("Sign in to Plex, Jellyfin or Navidrome in the Accounts tab to choose libraries. Until then, the app shows a built-in sample catalog.")
                        .foregroundStyle(.secondary)
                }
            }
            let allPlexKeys = plexConfigurations.flatMap { config in
                (plexLibraries[config.serverID] ?? []).map { "\(config.serverID):\($0.key)" }
            }
            ForEach(plexConfigurations, id: \.serverID) { configuration in
                librarySection(
                    title: plexConfigurations.count == 1
                        ? "Plex Libraries"
                        : "Plex - \(configuration.serverName)",
                    // Selections are stored scoped as "serverID:key" so the
                    // same section number on two servers can't collide.
                    entries: (plexLibraries[configuration.serverID] ?? []).map {
                        ("\(configuration.serverID):\($0.key)", $0.title, $0.mediaType)
                    },
                    status: plexStatuses[configuration.serverID] ?? "",
                    selection: $plexSelected,
                    allKeys: allPlexKeys
                )
            }
            if appState.jellyfinConfiguration != nil {
                librarySection(
                    title: "Jellyfin Libraries",
                    entries: jellyfinLibraries.map { ($0.id, $0.name, $0.mediaType) },
                    status: jellyfinStatus,
                    selection: $jellyfinSelected,
                    allKeys: jellyfinLibraries.map { $0.id }
                )
            }
            menuOrderSection
        }
        .formStyle(.grouped)
        // Re-runs when servers are added/removed in the Accounts tab, so the
        // list refreshes without reopening Settings.
        .task(id: appState.serverConfigurationVersion) { refresh() }
        .onChange(of: plexSelected) { appState.resetCatalog() }
        .onChange(of: jellyfinSelected) { appState.resetCatalog() }
    }

    /// Drag a row onto another to take its place. Rows in a grouped Form
    /// don't support onMove on macOS, hence draggable/dropDestination; the
    /// context menu is the keyboard and VoiceOver alternative.
    private var menuOrderSection: some View {
        Section("Menu Order") {
            let sections = appState.orderableSections
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                HStack {
                    Label(section.title, systemImage: section.systemImage)
                    Spacer()
                    if !appState.enabledSections.contains(section) {
                        Text("Hidden")
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .draggable(section.id)
                .dropDestination(for: String.self) { ids, _ in
                    guard let from = sections.firstIndex(where: { $0.id == ids.first }), from != index else { return false }
                    appState.moveSection(from: from, to: index)
                    return true
                }
                .contextMenu {
                    Button("Move Up") { appState.moveSection(from: index, to: index - 1) }
                        .disabled(index == 0)
                    Button("Move Down") { appState.moveSection(from: index, to: index + 1) }
                        .disabled(index == sections.count - 1)
                }
            }
        }
    }

    private var localSection: some View {
        Section {
            ForEach(MediaType.allCases) { type in
                HStack {
                    Label(type.title, systemImage: type.systemImage)
                    let countText = libraryCountText(for: type)
                    if !countText.isEmpty {
                        Text(countText)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let folder = DownloadManager.resolvedLibraryFolder(for: type) {
                        Button("Open Location") {
                            NSWorkspace.shared.open(folder)
                        }
                        .controlSize(.small)
                        Button("Update Location") {
                            chooseLibraryFolder(for: type)
                        }
                        .controlSize(.small)
                    } else {
                        Button("Choose Folder") {
                            chooseLibraryFolder(for: type)
                        }
                        .controlSize(.small)
                    }
                }
                // Use a type-specific ID so SwiftUI can distinguish the three rows.
                .id("\(type.rawValue)-\(localRefresh)")
            }
            LabeledContent("Index New Files") {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Refresh") {
                        isRefreshing = true
                        Task {
                            await appState.refreshLocalLibrary()
                            localRefresh += 1
                            isRefreshing = false
                        }
                    }
                }
            }
        } header: {
            SectionInfoHeader(title: "Local Library", info: "Choose a folder for each media type to make local files available in the menu bar. Press Refresh to index new files and fetch metadata from Last.fm, Trakt, and TMDb.")
        }
    }

    private func libraryCountText(for type: MediaType) -> String {
        let counts = DownloadManager.mediaCounts(for: type)
        guard counts.leaves > 0 else { return "" }
        switch type {
        case .movies:
            return "\(counts.leaves) \(counts.leaves == 1 ? "Movie" : "Movies")"
        case .tvShows:
            let shows = counts.containers
            let eps = counts.leaves
            if shows > 0 {
                return "\(shows) \(shows == 1 ? "Show" : "Shows") / \(eps) \(eps == 1 ? "Episode" : "Episodes")"
            }
            return "\(eps) \(eps == 1 ? "Episode" : "Episodes")"
        case .music:
            let artists = counts.containers
            let tracks = counts.leaves
            if artists > 0 {
                return "\(artists) \(artists == 1 ? "Artist" : "Artists") / \(tracks) \(tracks == 1 ? "Track" : "Tracks")"
            }
            return "\(tracks) \(tracks == 1 ? "Track" : "Tracks")"
        }
    }

    private func chooseLibraryFolder(for type: MediaType) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as \(type.title) Library"
        panel.directoryURL = DownloadManager.resolvedLibraryFolder(for: type)
        if panel.runModal() == .OK, let url = panel.url {
            DownloadManager.setLibraryFolder(url, for: type)
            localRefresh += 1
            appState.resetCatalog()
        }
    }

    private func librarySection(
        title: String,
        entries: [(id: String, name: String, mediaType: MediaType?)],
        status: String,
        selection: Binding<String>,
        allKeys: [String]
    ) -> some View {
        Section {
            ForEach(entries, id: \.id) { entry in
                Toggle(isOn: binding(for: entry.id, in: selection, allKeys: allKeys)) {
                    Label {
                        Text(entry.name)
                    } icon: {
                        Image(systemName: entry.mediaType?.systemImage ?? "questionmark.square")
                    }
                }
            }
            if entries.isEmpty {
                Text(status.isEmpty ? "No libraries loaded yet." : status)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Library List") {
                Button("Reload") { refresh() }
            }
        } header: {
            SectionInfoHeader(title: title, info: "Selected libraries appear in the menu bar dropdown. With none selected, all libraries are included.")
        }
    }

    private func binding(for key: String, in selection: Binding<String>, allKeys: [String]) -> Binding<Bool> {
        Binding {
            if selection.wrappedValue.isEmpty { return true }
            return selection.wrappedValue.split(separator: ",").map(String.init).contains(key)
        } set: { isOn in
            var keys = Set(selection.wrappedValue.isEmpty ? allKeys : selection.wrappedValue.split(separator: ",").map(String.init))
            if isOn { keys.insert(key) } else { keys.remove(key) }
            if keys.count == allKeys.count {
                selection.wrappedValue = ""
            } else {
                selection.wrappedValue = keys.sorted().joined(separator: ",")
            }
        }
    }

    private func refresh() {
        for configuration in appState.plexConfigurations {
            let serverID = configuration.serverID
            plexStatuses[serverID] = "Loading…"
            Task {
                do {
                    let libraries = try await PlexClient(config: configuration).libraries()
                    plexLibraries[serverID] = libraries
                    plexStatuses[serverID] = libraries.isEmpty ? "The server reported no libraries." : ""
                } catch {
                    plexStatuses[serverID] = "Couldn't load libraries: \(error.localizedDescription)"
                }
            }
        }
        if let configuration = appState.jellyfinConfiguration {
            jellyfinStatus = "Loading…"
            Task {
                do {
                    jellyfinLibraries = try await JellyfinClient(config: configuration).libraries()
                    jellyfinStatus = jellyfinLibraries.isEmpty ? "The server reported no libraries." : ""
                } catch {
                    jellyfinStatus = "Couldn't load libraries: \(error.localizedDescription)"
                }
            }
        }
    }
}
