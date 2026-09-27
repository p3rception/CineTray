import SwiftUI
import AppKit
import ServiceManagement

/// General app preferences. Currently exposes launch-at-login, backed by the
/// modern `SMAppService` login-item API, media keys and local network access.
struct GeneralSettingsView: View {
    @State private var launchAtLogin = false
    @State private var requiresApproval = false
    @State private var networkMonitor = LocalNetworkAccessMonitor()
    @AppStorage(SettingsKeys.useMediaKeys) private var useMediaKeys = false

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
                        ? "QuPi is registered but needs approval in System Settings › General › Login Items before it can launch at startup."
                        : "Launch QuPi automatically when you log in."
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
                        ? "QuPi has local network access and can discover servers on your network. Media keys let you play/pause and skip tracks globally."
                        : "Grant QuPi access to find and connect to Plex and Jellyfin servers on your local network."
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
        .frame(width: 520, height: 560)
}
#endif
