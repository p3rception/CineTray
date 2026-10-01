import SwiftUI
import AppKit
import OSLog
import ServiceManagement
import UniformTypeIdentifiers

/// General app preferences. Currently exposes launch-at-login, backed by the
/// modern `SMAppService` login-item API, media keys and local network access.
struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLogin = false
    @State private var requiresApproval = false
    @State private var networkMonitor = LocalNetworkAccessMonitor()
    @AppStorage(SettingsKeys.useMediaKeys) private var useMediaKeys = false
    @AppStorage(SettingsKeys.logFolder) private var logFolder = ""
    @AppStorage(SettingsKeys.checkForUpdates) private var checkForUpdates = true
    @State private var logExportError: String?
    @State private var exportedLog: URL?

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, isOn in
                        updateLoginItem(enabled: isOn)
                    }
            } header: {
                SectionInfoHeader(
                    title: "General",
                    info: requiresApproval
                        ? "CineTray is registered but needs approval in System Settings › General › Login Items before it can launch at startup."
                        : "Launch CineTray automatically when you log in."
                )
            }

            Section {
                Toggle("Use Mac Media Keys", isOn: $useMediaKeys)
                LabeledContent("Local Network") {
                    if networkMonitor.status == .granted {
                        Label {
                            Text("Allowed")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Button("Open Privacy Settings…") { openLocalNetworkSettings() }
                    }
                }
            } header: {
                SectionInfoHeader(
                    title: "Access",
                    info: networkMonitor.status == .granted
                        ? "CineTray has local network access and can discover servers on your network. Media keys let you play/pause and skip tracks globally."
                        : "Grant CineTray access to find and connect to Plex and Jellyfin servers on your local network."
                )
            }

            Section {
                Toggle("Check for Updates", isOn: $checkForUpdates)
                    .onChange(of: checkForUpdates) { Task { await appState.checkForUpdate() } }
            } header: {
                SectionInfoHeader(
                    title: "Updates",
                    info: "Once a day, CineTray asks GitHub for the latest version. When a newer one is out, the menu bar icon turns blue and the menu shows how to update."
                )
            }

            Section {
                LabeledContent("Save Logs To") {
                    HStack {
                        Text(logFolder.isEmpty ? "Ask Each Time" : (logFolder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseLogFolder() }
                        if !logFolder.isEmpty {
                            Button("Ask Each Time") { logFolder = "" }
                        }
                    }
                }
                LabeledContent("Logs") {
                    Button(logFolder.isEmpty ? "Export…" : "Export") { exportLogs() }
                }
                if let logExportError {
                    Text(logExportError)
                        .font(.callout)
                        .foregroundStyle(.red)
                } else if let exportedLog {
                    HStack {
                        Text("Saved \(exportedLog.lastPathComponent).")
                            .font(.callout)
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exportedLog]) }
                    }
                }
            } header: {
                SectionInfoHeader(
                    title: "Troubleshooting",
                    info: "Saves the errors CineTray ran into since it was opened, such as a server it couldn't reach or playback that failed, as a text file to attach to a bug report. Quitting CineTray clears them."
                )
            }
        }
        .formStyle(.grouped)
        .task {
            let status = SMAppService.mainApp.status
            launchAtLogin = status == .enabled || status == .requiresApproval
            requiresApproval = status == .requiresApproval
            networkMonitor.start()
        }
        .onDisappear {
            networkMonitor.stop()
        }
    }

    /// Opens the Privacy & Security › Local Network panel in System Settings.
    private func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    private func exportLogs() {
        Task {
            logExportError = nil
            exportedLog = nil
            do {
                let text = try await Self.logText()
                if logFolder.isEmpty {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "CineTray Log.txt"
                    panel.allowedContentTypes = [.plainText]
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    exportedLog = url
                } else {
                    // Timestamped so an export never replaces an earlier one.
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                    let url = URL(filePath: logFolder, directoryHint: .isDirectory)
                        .appending(path: "CineTray Log \(formatter.string(from: .now)).txt")
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    exportedLog = url
                }
            } catch {
                logExportError = error.localizedDescription
            }
        }
    }

    private func chooseLogFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Logs Here"
        if panel.runModal() == .OK, let url = panel.url {
            logFolder = url.path
        }
    }

    /// An app can read only its own process's log, so entries from before
    /// the last launch aren't included.
    @concurrent nonisolated private static func logText() async throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(matching: NSPredicate(format: "subsystem == %@", "CineTray"))
            .compactMap { $0 as? OSLogEntryLog }
            .map { "\($0.date.formatted(.iso8601)) \($0.composedMessage)" }
        let info = Bundle.main.infoDictionary
        let header = "CineTray \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        return ([header] + (entries.isEmpty ? ["No errors since CineTray was opened."] : entries)).joined(separator: "\n") + "\n"
    }

    /// Registers or unregisters the app as a login item. Registration can
    /// come back pending user approval, which we surface in the footer rather
    /// than flipping the toggle back off.
    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Ignored: the most common failure is the user needing to approve
            // the login item in System Settings, reflected by the status below.
        }
        requiresApproval = SMAppService.mainApp.status == .requiresApproval
    }
}

#if !SWIFT_PACKAGE // Previews need Xcode; SwiftPM builds skip them.
#Preview("General") {
    GeneralSettingsView()
        .environment(AppState())
        .frame(width: 520, height: 560)
}
#endif
