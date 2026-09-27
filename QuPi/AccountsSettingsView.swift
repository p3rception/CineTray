import SwiftUI
import AuthenticationServices

/// Sign-in for the media servers (Plex PIN flow, Jellyfin username/password
/// or Quick Connect, Navidrome username/password)
/// and the scrobblers (Trakt OAuth, Last.fm web auth). Secrets are kept in the
/// Keychain; only non-secret settings use UserDefaults.
struct AccountsSettingsView: View {
    @Environment(AppState.self) private var appState

    // Non-secret settings.
    @AppStorage(SettingsKeys.jellyfinServerURL) private var jellyfinServerURL = ""
    @AppStorage(SettingsKeys.jellyfinUsername) private var jellyfinUsername = ""
    @AppStorage(SettingsKeys.jellyfinUserID) private var jellyfinUserID = ""
    @AppStorage(SettingsKeys.navidromeServerURL) private var navidromeServerURL = ""
    @AppStorage(SettingsKeys.navidromeUsername) private var navidromeUsername = ""
    @AppStorage(SettingsKeys.navidromeSalt) private var navidromeSalt = ""

    // Connected Plex servers; tokens live in the Keychain, one per server.
    @State private var plexServers = PlexServerStore.load()
    @State private var plexServerTokens: [String: String] = Dictionary(
        uniqueKeysWithValues: PlexServerStore.load().map { ($0.id, PlexServerStore.token(for: $0.id) ?? "") }
    )

    // Secrets, loaded from / persisted to the Keychain.
    @State private var plexAccountToken = KeychainStore.string(for: KeychainKeys.plexAccountToken) ?? ""
    @State private var traktAccessToken = KeychainStore.string(for: KeychainKeys.traktAccessToken) ?? ""
    @State private var lastfmSessionKey: String? = KeychainStore.string(for: KeychainKeys.lastfmSessionKey)
    @State private var tmdbAPIKey = KeychainStore.stringMigratingFromDefaults(for: KeychainKeys.tmdbAPIKey) ?? ""

    // Transient sign-in state.
    @State private var jellyfinPassword = ""
    @State private var navidromePassword = ""
    @State private var navidromeStatus = ""
    @State private var pinCode = ""
    @State private var plexStatus = ""
    @State private var plexAdvancedExpanded = false
    @State private var discoveredPlexServers: [PlexDiscoveredServer] = []
    @State private var plexServerStatuses: [String: String] = [:]
    @State private var manualPlexServerURL = ""
    @State private var jellyfinStatus = ""
    @State private var quickConnectCode: String?
    @State private var quickConnectTask: Task<Void, Never>?
    @State private var tmdbKeyStatus: KeyStatus?

    /// Result of checking the TMDb key against the API.
    private enum KeyStatus { case checking, valid, invalid, unreachable }
    @State private var traktStatus = ""
    @State private var lastfmStatus = ""
    @State private var plexSignInTask: Task<Void, Never>?
    @State private var traktSignInTask: Task<Void, Never>?
    @State private var lastfmSignInTask: Task<Void, Never>?
    @State private var plexAccount: PlexClient.Account?
    @State private var showingPlexSignOut = false

    var body: some View {
        Form {
            plexSection
            jellyfinSection
            navidromeSection
            // traktSection
            // lastfmSection
            tmdbSection
        }
        .formStyle(.grouped)
        .onDisappear {
            plexSignInTask?.cancel()
            traktSignInTask?.cancel()
            lastfmSignInTask?.cancel()
        }
    }

    // MARK: - Plex

    private var plexSection: some View {
        Section("Plex") {
            if plexAccountToken.isEmpty {
                Button(pinCode.isEmpty ? "Sign In with Plex…" : "Waiting for link…") {
                    signInWithPlex()
                }
                .disabled(plexSignInTask != nil)
                if !pinCode.isEmpty {
                    CopyableCodeRow(code: pinCode, destination: "plex.tv/link")
                }
            } else {
                plexAccountRow
            }
            statusText(plexStatus)
            ForEach(plexServers) { server in
                connectedPlexServerRow(server)
            }
            DisclosureGroup("Advanced", isExpanded: $plexAdvancedExpanded) {
                plexAdvancedContent
            }
        }
        .task(id: plexAccountToken) { await loadPlexAccount() }
        .confirmationDialog("Sign out of Plex?", isPresented: $showingPlexSignOut) {
            Button("Sign Out", role: .destructive) { signOutOfPlex() }
        } message: {
            Text("Your Plex servers will be removed from QuPi. You can sign in again at any time.")
        }
    }

    private var plexAccountRow: some View {
        LabeledContent {
            HStack {
                Label {
                    Text("Signed In")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
                Button("Sign Out…") { showingPlexSignOut = true }
            }
        } label: {
            Text(plexAccount?.username ?? "Plex Account")
            if let email = plexAccount?.email {
                Text(email)
            }
        }
    }

    private func loadPlexAccount() async {
        guard !plexAccountToken.isEmpty else {
            plexAccount = nil
            return
        }
        do {
            plexAccount = try await PlexClient.account(token: plexAccountToken)
        } catch PlexError.unauthorized {
            plexStatus = "Your Plex sign-in has expired. Sign out and sign in again."
        } catch {
            // Offline or plex.tv unreachable: the row keeps its generic label.
        }
    }

    /// Forgets the plex.tv account and every server connected through it.
    private func signOutOfPlex() {
        plexSignInTask?.cancel()
        for server in plexServers {
            PlexServerStore.setToken(nil, for: server.id)
        }
        plexServers = []
        plexServerTokens = [:]
        plexServerStatuses = [:]
        discoveredPlexServers = []
        PlexServerStore.save([])
        plexAccountToken = ""
        KeychainStore.set(nil, for: KeychainKeys.plexAccountToken)
        plexStatus = ""
        appState.plexServersChanged()
    }

    private func connectedPlexServerRow(_ server: PlexServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text(server.urlString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Remove") { removePlexServer(server) }
                .controlSize(.small)
        }
    }

    /// Manual paths for when Sign In doesn't locate every server: re-run
    /// discovery with Add buttons, per-server token editing with a
    /// connection test, and adding an unclaimed server by URL.
    @ViewBuilder
    private var plexAdvancedContent: some View {
        Button("Find Servers") { findPlexServers() }
            .disabled(plexAccountToken.isEmpty)
        if plexAccountToken.isEmpty {
            Text("Sign In with Plex first - finding servers needs a signed-in account.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(discoveredPlexServers.filter { discovered in
            !plexServers.contains { $0.id == discovered.id }
        }) { discovered in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(discovered.name)
                    Text(discovered.connections.first?.absoluteString ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Add") { addPlexServer(discovered) }
                    .controlSize(.small)
            }
        }
        ForEach(plexServers) { server in
            VStack(alignment: .leading, spacing: 4) {
                SecureField("\(server.name) Token", text: tokenBinding(for: server.id))
                HStack {
                    Button("Test Connection") { testPlexConnection(server) }
                        .controlSize(.small)
                        .disabled((plexServerTokens[server.id] ?? "").isEmpty)
                    statusText(plexServerStatuses[server.id] ?? "")
                }
            }
        }
        HStack {
            TextField("Server URL", text: $manualPlexServerURL)
                .autocorrectionDisabled()
            Button("Add Manually") { addManualPlexServer() }
                .controlSize(.small)
                .disabled(manualPlexServerURL.isEmpty)
        }
    }

    private func tokenBinding(for serverID: String) -> Binding<String> {
        Binding {
            plexServerTokens[serverID] ?? ""
        } set: { newValue in
            plexServerTokens[serverID] = newValue
            PlexServerStore.setToken(newValue, for: serverID)
            appState.plexServersChanged()
        }
    }

    private func signInWithPlex() {
        plexStatus = ""
        plexSignInTask = Task {
            defer {
                plexSignInTask = nil
                pinCode = ""
            }
            do {
                let pin = try await PlexClient.requestPIN()
                pinCode = pin.code
                NSWorkspace.shared.open(URL(string: "https://plex.tv/link")!)
                for _ in 0..<90 {
                    try await Task.sleep(for: .seconds(2))
                    let checked = try await PlexClient.checkPIN(id: pin.id)
                    if let token = checked.authToken, !token.isEmpty {
                        plexAccountToken = token
                        KeychainStore.set(token, for: KeychainKeys.plexAccountToken)
                        await connectDiscoveredPlexServers()
                        return
                    }
                }
                plexStatus = "Sign-in timed out - try again."
            } catch is CancellationError {
            } catch {
                plexStatus = "Sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    /// After sign-in, connects every server the account can reach, each with
    /// its own access token from plex.tv.
    private func connectDiscoveredPlexServers() async {
        plexStatus = "Looking for servers…"
        do {
            discoveredPlexServers = try await PlexClient.discoverServers(accountToken: plexAccountToken)
            for discovered in discoveredPlexServers
            where !plexServers.contains(where: { $0.id == discovered.id }) {
                addPlexServer(discovered)
            }
            plexStatus = switch plexServers.count {
            case 0: "Signed in, but no servers were found for this account. Try Advanced."
            case 1: "Connected 1 server."
            default: "Connected \(plexServers.count) servers."
            }
        } catch {
            plexStatus = "Signed in, but server discovery failed: \(error.localizedDescription)"
        }
    }

    private func findPlexServers() {
        plexStatus = "Looking for servers…"
        Task {
            do {
                discoveredPlexServers = try await PlexClient.discoverServers(accountToken: plexAccountToken)
                let new = discoveredPlexServers.filter { discovered in
                    !plexServers.contains { $0.id == discovered.id }
                }
                plexStatus = new.isEmpty
                    ? "No further servers found for this account."
                    : "Found \(new.count) more server\(new.count == 1 ? "" : "s")."
            } catch {
                plexStatus = "Server discovery failed: \(error.localizedDescription)"
            }
        }
    }

    private func addPlexServer(_ discovered: PlexDiscoveredServer) {
        let server = PlexServer(
            id: discovered.clientIdentifier,
            name: discovered.name,
            urlString: discovered.connections.first?.absoluteString ?? "",
            fallbackURLStrings: Array(discovered.connections.dropFirst()).map { $0.absoluteString }
        )
        plexServers.append(server)
        let token = discovered.accessToken ?? plexAccountToken
        plexServerTokens[server.id] = token
        PlexServerStore.save(plexServers)
        PlexServerStore.setToken(token, for: server.id)
        appState.plexServersChanged()
    }

    private func addManualPlexServer() {
        let candidates = serverURLCandidates(manualPlexServerURL)
        guard let url = candidates.first else {
            plexStatus = "Enter a valid server URL."
            return
        }
        // Without a scheme, HTTP is kept as a fallback; the first request
        // promotes whichever address answers.
        let server = PlexServer(
            id: UUID().uuidString,
            name: url.host() ?? "Plex Server",
            urlString: url.absoluteString,
            fallbackURLStrings: candidates.dropFirst().map(\.absoluteString)
        )
        plexServers.append(server)
        plexServerTokens[server.id] = ""
        PlexServerStore.save(plexServers)
        manualPlexServerURL = ""
        plexStatus = "Added \(server.name). Enter its token under Advanced, then Test Connection."
        appState.plexServersChanged()
    }

    private func removePlexServer(_ server: PlexServer) {
        plexServers.removeAll { $0.id == server.id }
        plexServerTokens[server.id] = nil
        plexServerStatuses[server.id] = nil
        PlexServerStore.save(plexServers)
        PlexServerStore.setToken(nil, for: server.id)
        appState.plexServersChanged()
    }

    private func testPlexConnection(_ server: PlexServer) {
        plexServerStatuses[server.id] = "Connecting…"
        Task {
            do {
                guard let url = URL(string: server.urlString) else {
                    plexServerStatuses[server.id] = "Invalid server URL."
                    return
                }
                let config = PlexConfiguration(
                    serverURL: url,
                    fallbackURLs: server.fallbackURLStrings?.compactMap(URL.init(string:)),
                    token: plexServerTokens[server.id] ?? "",
                    serverID: server.id,
                    serverName: server.name
                )
                let libraries = try await PlexClient(config: config).libraries()
                plexServerStatuses[server.id] = "Connected via \(config.serverURL.host() ?? server.urlString) - \(libraries.count) libraries found."
            } catch {
                plexServerStatuses[server.id] = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Jellyfin

    private var jellyfinSection: some View {
        Section("Jellyfin") {
            TextField("Server URL", text: $jellyfinServerURL)
            TextField("Username", text: $jellyfinUsername)
            SecureField("Password", text: $jellyfinPassword)
            HStack {
                Button("Sign In") { signInToJellyfin() }
                    .disabled(jellyfinServerURL.isEmpty || jellyfinUsername.isEmpty)
                Button(quickConnectTask == nil ? "Quick Connect" : "Cancel Quick Connect") {
                    if let quickConnectTask {
                        quickConnectTask.cancel()
                    } else {
                        startQuickConnect()
                    }
                }
                .disabled(jellyfinServerURL.isEmpty)
                .help("Sign in without a password by approving a code on a device that is already signed in to Jellyfin")
                if !jellyfinUserID.isEmpty {
                    Button("Sign Out") {
                        KeychainStore.set(nil, for: KeychainKeys.jellyfinToken)
                        jellyfinUserID = ""
                        jellyfinStatus = "Signed out."
                        appState.resetCatalog()
                    }
                }
            }
            if let quickConnectCode {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quickConnectCode)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .textSelection(.enabled)
                    Text("On a device signed in to Jellyfin, open Settings > Quick Connect and enter this code.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !jellyfinUserID.isEmpty {
                Text("Signed in as \(jellyfinUsername).")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            statusText(jellyfinStatus)
        }
    }

    private func signInToJellyfin() {
        jellyfinStatus = "Signing in…"
        Task {
            let candidates = serverURLCandidates(jellyfinServerURL)
            guard !candidates.isEmpty else {
                jellyfinStatus = "Invalid server URL."
                return
            }
            var lastError: Error?
            for url in candidates {
                do {
                    let result = try await JellyfinClient.authenticate(
                        serverURL: url,
                        username: jellyfinUsername,
                        password: jellyfinPassword
                    )
                    completeJellyfinSignIn(url: url, result: result)
                    return
                } catch let error as URLError where error.code == .userAuthenticationRequired {
                    // The server answered and rejected the credentials, so
                    // the other scheme won't help.
                    jellyfinStatus = "Sign-in failed: wrong username or password."
                    return
                } catch {
                    lastError = error
                }
            }
            jellyfinStatus = "Sign-in failed: \(lastError?.localizedDescription ?? "server not reachable.")"
        }
    }

    /// Quick Connect: shows a code, waits for the user to approve it in
    /// another signed-in Jellyfin app, then signs in with no password.
    private func startQuickConnect() {
        let candidates = serverURLCandidates(jellyfinServerURL)
        guard !candidates.isEmpty else {
            jellyfinStatus = "Invalid server URL."
            return
        }
        jellyfinStatus = "Starting Quick Connect…"
        quickConnectTask = Task {
            defer {
                quickConnectTask = nil
                quickConnectCode = nil
            }
            do {
                // Start on the first address that answers (HTTPS, then HTTP).
                var started: (url: URL, request: JellyfinClient.QuickConnectRequest)?
                var lastError: Error?
                for url in candidates {
                    do {
                        started = (url, try await JellyfinClient.initiateQuickConnect(serverURL: url))
                        break
                    } catch let error as JellyfinClient.QuickConnectError {
                        throw error
                    } catch {
                        lastError = error
                    }
                }
                guard let started else { throw lastError ?? URLError(.cannotConnectToHost) }
                quickConnectCode = started.request.Code
                jellyfinStatus = ""
                // ponytail: fixed 2 s poll for up to 5 min; the server expires codes on its own.
                for _ in 0..<150 {
                    try await Task.sleep(for: .seconds(2))
                    let state = try await JellyfinClient.quickConnectState(serverURL: started.url, secret: started.request.Secret)
                    guard state.Authenticated else { continue }
                    let result = try await JellyfinClient.authenticate(serverURL: started.url, quickConnectSecret: started.request.Secret)
                    completeJellyfinSignIn(url: started.url, result: result)
                    return
                }
                jellyfinStatus = "Quick Connect timed out. Try again."
            } catch is CancellationError {
                jellyfinStatus = ""
            } catch {
                jellyfinStatus = "Quick Connect failed: \(error.localizedDescription)"
            }
        }
    }

    /// Saves a successful Jellyfin sign-in: the address that worked (scheme
    /// included), the token in the Keychain, and the user.
    private func completeJellyfinSignIn(url: URL, result: JellyfinClient.SignInResult) {
        jellyfinServerURL = url.absoluteString
        jellyfinUsername = result.userName
        KeychainStore.set(result.token, for: KeychainKeys.jellyfinToken)
        jellyfinUserID = result.userID
        jellyfinPassword = ""
        jellyfinStatus = ""
        appState.resetCatalog()
    }

    // MARK: - Navidrome

    private var navidromeSection: some View {
        Section("Navidrome") {
            TextField("Server URL", text: $navidromeServerURL)
            TextField("Username", text: $navidromeUsername)
            SecureField("Password", text: $navidromePassword)
            HStack {
                Button("Sign In") { signInToNavidrome() }
                    .disabled(navidromeServerURL.isEmpty || navidromeUsername.isEmpty || navidromePassword.isEmpty)
                if !navidromeSalt.isEmpty {
                    Button("Sign Out") {
                        KeychainStore.set(nil, for: KeychainKeys.navidromeToken)
                        navidromeSalt = ""
                        navidromeStatus = "Signed out."
                        appState.resetCatalog()
                    }
                }
            }
            if !navidromeSalt.isEmpty {
                Text("Signed in as \(navidromeUsername).")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            statusText(navidromeStatus)
        }
    }

    /// Checks the credentials against each candidate address (HTTPS first),
    /// then keeps the address that worked and the token, never the password.
    private func signInToNavidrome() {
        navidromeStatus = "Signing in…"
        Task {
            let candidates = serverURLCandidates(navidromeServerURL)
            guard !candidates.isEmpty else {
                navidromeStatus = "Invalid server URL."
                return
            }
            let username = navidromeUsername.trimmingCharacters(in: .whitespaces)
            let credentials = NavidromeClient.credentials(password: navidromePassword)
            var lastError: Error?
            for url in candidates {
                let configuration = NavidromeConfiguration(serverURL: url, username: username, token: credentials.token, salt: credentials.salt)
                do {
                    try await NavidromeClient(config: configuration).ping()
                } catch let error as NavidromeClient.ServerError {
                    // The server answered, so the other scheme won't help.
                    navidromeStatus = "Sign-in failed: \(error.localizedDescription)"
                    return
                } catch {
                    lastError = error
                    continue
                }
                navidromeServerURL = url.absoluteString
                navidromeUsername = username
                KeychainStore.set(credentials.token, for: KeychainKeys.navidromeToken)
                navidromeSalt = credentials.salt
                navidromePassword = ""
                navidromeStatus = ""
                appState.resetCatalog()
                return
            }
            navidromeStatus = "Sign-in failed: \(lastError?.localizedDescription ?? "server not reachable.")"
        }
    }

    // MARK: - Trakt

    private var traktSection: some View {
        Section("Trakt") {
            HStack {
                Button(traktSignInTask != nil ? "Connecting…" : "Sign in with Trakt") {
                    connectTrakt()
                }
                .disabled(traktSignInTask != nil)
                if !traktAccessToken.isEmpty {
                    Button("Disconnect") {
                        traktAccessToken = ""
                        KeychainStore.set(nil, for: KeychainKeys.traktAccessToken)
                        KeychainStore.set(nil, for: KeychainKeys.traktRefreshToken)
                        traktStatus = ""
                    }
                }
            }
            if !traktAccessToken.isEmpty {
                Text("Connected - movie playback will be scrobbled.")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            statusText(traktStatus)
        }
    }

    private func connectTrakt() {
        traktStatus = ""
        traktSignInTask = Task {
            defer { traktSignInTask = nil }
            do {
                let callbackURL = try await webAuth(url: TraktClient.authorizeURL, callbackScheme: "qupi")
                guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                    traktStatus = "Sign-in failed: no authorization code in callback."
                    return
                }
                let (accessToken, refreshToken) = try await TraktClient.exchangeCode(code)
                traktAccessToken = accessToken
                KeychainStore.set(accessToken, for: KeychainKeys.traktAccessToken)
                KeychainStore.set(refreshToken, for: KeychainKeys.traktRefreshToken)
            } catch is CancellationError {
            } catch {
                traktStatus = "Sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Last.fm

    private var lastfmSection: some View {
        Section("Last.fm Scrobbler") {
            HStack {
                Button(lastfmSignInTask != nil ? "Connecting…" : "Connect to Last.fm") {
                    connectLastFM()
                }
                .disabled(lastfmSignInTask != nil)
                if lastfmSessionKey != nil {
                    Button("Disconnect") {
                        lastfmSessionKey = nil
                        KeychainStore.set(nil, for: KeychainKeys.lastfmSessionKey)
                        lastfmStatus = ""
                    }
                }
            }
            if lastfmSessionKey != nil {
                Text("Connected - finished music playback will be scrobbled.")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            statusText(lastfmStatus)
        }
    }

    private func connectLastFM() {
        lastfmStatus = ""
        lastfmSignInTask = Task {
            defer { lastfmSignInTask = nil }
            do {
                let token = try await LastFMClient.requestToken()
                let callbackURL = try await webAuth(
                    url: LastFMClient.authorizeURL(token: token),
                    callbackScheme: "qupi"
                )
                // Last.fm echoes the token in the callback; prefer the returned
                // value but fall back to the original if absent.
                let returnedToken = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "token" })?.value ?? token
                let sessionKey = try await LastFMClient.getSession(token: returnedToken)
                lastfmSessionKey = sessionKey
                KeychainStore.set(sessionKey, for: KeychainKeys.lastfmSessionKey)
            } catch is CancellationError {
            } catch {
                lastfmStatus = "Sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - TMDb

    private var tmdbSection: some View {
        Section("The Movie Database") {
            TextField("API Key (v3)", text: $tmdbAPIKey)
                .onChange(of: tmdbAPIKey) {
                    // Saved on every edit so closing Settings never loses it;
                    // an empty field removes the Keychain item.
                    KeychainStore.set(tmdbAPIKey, for: KeychainKeys.tmdbAPIKey)
                }
                .task(id: tmdbAPIKey) { await checkTMDbKey() }
            tmdbKeyStatusLabel
                .font(.callout)
            Text("Used to fetch posters and metadata when refreshing your Local Library. Get a free API key at themoviedb.org/settings/api.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tmdbKeyStatusLabel: some View {
        switch tmdbKeyStatus {
        case nil:
            EmptyView()
        case .checking:
            Label("Checking key…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .valid:
            Label("Key is valid.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid:
            // The v4 "API Read Access Token" is a JWT; this app uses the v3 key.
            Label(tmdbAPIKey.hasPrefix("eyJ")
                  ? "That's the API Read Access Token. Paste the API Key (v3) instead."
                  : "TMDb rejected this key. Check that it's copied in full.",
                  systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .unreachable:
            Label("Couldn't reach TMDb to check the key.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    /// Checks the TMDb key once typing pauses. Runs from `.task(id:)`, so a
    /// newer edit cancels an older check.
    private func checkTMDbKey() async {
        let key = tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key != tmdbAPIKey {
            // Pasted keys often carry a stray space or newline, which TMDb rejects.
            tmdbAPIKey = key
            return
        }
        guard !key.isEmpty else {
            tmdbKeyStatus = nil
            return
        }
        tmdbKeyStatus = .checking
        do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
        let status: KeyStatus
        do {
            status = try await TMDbClient.isValidKey(key) ? .valid : .invalid
        } catch {
            status = .unreachable
        }
        guard !Task.isCancelled else { return }
        tmdbKeyStatus = status
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusText(_ status: String) -> some View {
        if !status.isEmpty {
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func webAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme)
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            session.presentationContextProvider = sharedWebAuthContext
            session.start()
        }
    }
}

/// Stateless singleton providing the key window as ASWebAuthenticationSession anchor.
private final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}

private let sharedWebAuthContext = WebAuthPresentationContext()

/// A link code shown large and monospaced; clicking it copies it to the
/// clipboard. Used by the Plex PIN flow.
private struct CopyableCodeRow: View {
    let code: String
    let destination: String

    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Enter")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Text(code)
                    .font(.title3.weight(.bold).monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Click to copy")
            Text(copied ? "- copied!" : "at \(destination)")
                .foregroundStyle(copied ? .green : .primary)
        }
        .font(.callout)
    }
}
