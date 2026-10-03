# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Contribution rules for all changes: @AGENTS.md

## Build & Verify

Two build paths. Both must keep working.

- **Install:** `make` runs `./build.sh build` and copies `dist/CineTray.app` to `/Applications`. This is the path the README gives users.
- **SwiftPM (no Xcode needed):** `./build.sh` builds, bundles `dist/CineTray.app`, ad-hoc signs and launches it. `./build.sh build` skips the launch. Compile only: `swift build -c release --disable-keychain`.
- **Release:** `./release.sh [x.y.z]` tags a version (rules in AGENTS.md section 9); pushing the tag runs `.github/workflows/release.yml`, which builds on a `macos-26` runner, publishes the GitHub release with its CHANGELOG section and updates the cask in `p3rception/homebrew-tap` (needs the `TAP_TOKEN` secret). `build.sh` reads the version from the last `v*` tag and the build number from the commit count; the Xcode project's `MARKETING_VERSION` is for local builds only.
- **Xcode:** `CineTray.xcodeproj`. When Xcode MCP tools are available, prefer `BuildProject`, `XcodeRefreshCodeIssuesInFile` and `GetBuildLog`. Project paths are `CineTray/<File>.swift`. `XcodeUpdate` does not always flush to disk; verify with a filesystem `Read` and fall back to `Edit`.

Build settings live in two places and must stay in sync: `Package.swift` (`swiftSettings`) and the target in `project.pbxproj`. Both use Swift 5 language mode, default actor isolation `MainActor`, and the upcoming features `InferIsolatedConformances`, `NonisolatedNonsendingByDefault`, `MemberImportVisibility` and bare-slash regex literals.

There is no test target and no linter.

## Platform constraints

- Deployment target is **macOS 26**. Do not use APIs introduced in macOS 27 (for example `AsyncImage(request:)` or `.asyncImageURLSession(_:)`). Load artwork with `ArtworkImage` (`ArtworkCache.swift`).
- The app is macOS-only (`SUPPORTED_PLATFORMS = macosx`). Do not add iOS code paths.
- `#Preview` blocks must be wrapped in `#if !SWIFT_PACKAGE`, because the Command Line Tools lack the previews macro plugin.

## Concurrency

Everything is `MainActor` by default. Work that must run off the main thread (image decoding, file scans, JSON decoding of large indexes) needs an explicit `@concurrent` function on a `nonisolated` type or member. Types used from such code (for example `SettingsKeys`) must be `nonisolated`.

## Architecture

CineTray is a macOS menu bar app. `ContentView.swift` declares:
- A `MenuBarExtra` (dropdown UI via `MenuBarContentView`)
- Two `WindowGroup` scenes keyed on `MediaItem`: `"video-player"` (780x460) and `"music-player"` (340x660)
- A `Settings` scene hosting `SettingsView`

### Central state: `AppState`

`AppState` is a `@MainActor @Observable final class` passed as an `@Environment` to all views. It owns:
- The catalog (`itemsBySection`, `drillPath`, `childrenByItemID`)
- Search state and the debounced deep-search task
- The playback engine (`AVPlayer` or `VLCPlayerBridge`) shared by inline and window playback
- Playback reporting (server timeline APIs, scrobblers, Now Playing)
- Auto-continue (next movie / next episode / next track)

Preferences are read from `UserDefaults` via `SettingsKeys` and secrets from the Keychain via `KeychainStore` + `KeychainKeys`. There is no SwiftData or Core Data.

### MediaProvider

`MediaProvider` (in `MediaModels.swift`) abstracts content sources. `AppState.providers` builds the list on every access:

1. One `PlexMediaProvider` per configured server (`PlexServerStore`, token per server in the Keychain)
2. `JellyfinMediaProvider`, if configured
3. `LocalMediaProvider`, when a library folder is set (`hasContent`)

In Offline Mode only `LocalMediaProvider` is used, with `includeDownloads: true`; online it serves library folders only, since downloads already appear (with a green download mark next to the title) in their server's sections. There is no sample provider; `MediaSource.sample` is kept only so old saved data decodes.

Items from multiple Plex servers are routed back to their server via the `plexServerID` attribute (`PlexMediaProvider.serverIDAttribute`). Local items are de-duplicated against server item IDs in `AppState.load`.

### Menu sections

`MenuSection` is built from data, not a fixed list. `AppState.loadLibrarySections()` asks every provider for `libraries()` and makes one section per library name and type, in provider order; libraries with the same name and type on different servers share a section. `LocalMediaProvider` reports one pseudo-library per media type named `MediaType.title` ("Movies", "Shows", "Music"), so local media joins a server library with that name. `sectionLibraries` maps each section to its provider libraries, and `load(_:)` calls `items(inLibrary:)` for each. Playlists and Continue… are the only fixed sections. Sort settings are per media type, not per section. `resetCatalog()` reloads the sections.

`MediaType.rawValue` ("TV Shows") is part of saved settings keys and local item IDs; show `MediaType.title` ("Shows") to users.

### Media hierarchy

```
MediaType (movies / tvShows / music)
  +- MediaKind (movie | show > season > episode | artist > album > track | playlist)
```

`MediaKind.isExpandable` decides whether selecting an item opens a child carousel or starts playback. The drill path per section lives in `AppState.drillPath`.

### Downloads and local library

`DownloadManager.shared` handles two kinds of folders per media type, each stored as a security-scoped bookmark:
- **Download folder** (`downloadFolderBookmark_*`): files downloaded from servers, indexed in `.cinetray-downloads.json` inside the folder.
- **Library folder** (`libraryFolderBookmark_*`): the user's own media, scanned by `LocalLibraryScanner` and enriched with artwork by `AppState.refreshLocalLibrary()`: music from the sources in `MusicArtworkSource` (each can be turned off in Settings), movies and shows from Trakt and TMDb.

`DownloadManager.localURL(for:)` is checked first by `AppState.streamURL`, so downloaded items play from disk.

### Caches to keep consistent

- `AppState` caches the Plex and Jellyfin configurations (Keychain reads are slow). Call `resetCatalog()` (or `plexServersChanged()`) after any account or server change.
- `DownloadManager` caches resolved folder bookmarks and parsed indexes. Change folders only through `setFolder`/`setLibraryFolder` and write indexes only through `writeIndex(_:to:)`.
- Views must not read `appState.currentTime` in large containers (carousels, the menu); it changes twice a second during playback. Read it in the smallest view that shows it.

### Playback

`isAVFoundationPlayable(_:)` picks the engine: `AVPlayer` for network URLs and mp4/mov/m4v/common audio files, `VLCPlayerBridge` (SwiftVLC, libVLC linked statically) for everything else, such as mkv and avi.

`PlaybackProgressStore` (UserDefaults) persists positions and drives the Continue... section. `ContinueMusicGrouping` collapses in-progress tracks into their album or playlist.

### Scrobbling

`ScrobbleClients.swift` implements Trakt (movies) and Last.fm (music). `AppState.scrobble` is called on state transitions only, not on the periodic `.playing` reports. Users register their own Trakt and Last.fm apps and enter the credentials in Settings > Accounts; they live in the Keychain, never in the source.

## Conventions

- All `@Observable` classes are `@MainActor`.
- New settings keys go in `SettingsKeys` or `KeychainKeys`, never as inline string literals.
- Never put tokens in URLs that get saved (poster URLs end up in UserDefaults and download indexes). Load Plex artwork through `ArtworkCache.request(for:)`, which adds the token as a header.
- The app name is **CineTray**. Avoid "QuickPlex" in user-facing strings and comments.
- Every user-visible change updates `CHANGELOG.md` and, when it changes what CineTray offers or how to build it, the "Works with", "A quick tour" or "Install and update" section of `README.md`, and the "All features" list, in the same commit.
