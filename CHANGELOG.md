# Changelog

Changes in this fork compared to [KuDoZ007/QP](https://github.com/KuDoZ007/QP).
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 2026-09-26

### Added

- An "Open in Plex" / "Open in Jellyfin" button in the player window toolbar opens the playing item's page in the server's web app. Plex links use the web app hosted by the server itself, so they work without a plex.tv account.
- One menu section per server library, named as on the server (see Changed).
- Jellyfin Quick Connect: in Settings > Accounts, click Quick Connect, then enter the code shown on any device already signed in to Jellyfin. No password needed. Requires Jellyfin 10.9 or later with Quick Connect enabled.
- A small sort button on every open movie, show and music section in the menu, for choosing the sort field and order without opening Settings. Order labels match the field (for example "Newest First" for dates instead of "Z -> A"), here and in Settings > Visuals.
- The TMDb API key field in Settings > Accounts checks the key with TMDb as you type and shows whether it is valid. It points out when the v4 Read Access Token was pasted instead of the v3 API Key, and trims stray spaces from pasted keys.
- Build without Xcode: `Package.swift` builds the app with SwiftPM using only the Command Line Tools, and `build.sh` wraps the result in `dist/QuPi.app`, signs it and launches it.

### Changed

- The player window's toolbar buttons (crop, pin, open in Plex/Jellyfin) are larger (15 pt instead of 9 pt) and follow Settings > Visuals > Player UI Size: Small 13 pt, Medium 15 pt, Large 17 pt, and Dynamic scales with the system text size.
- The menu shows one section per server library, named as on the server, instead of fixed Movies, TV Shows and Music sections. A Jellyfin "YouTube" library now gets its own section instead of being mixed into TV Shows. Libraries with the same name and type on different servers share a section, and local library folders join the section named "Movies", "Shows" or "Music". Choose which libraries appear in Settings > Libraries; the Movies/TV Shows/Music toggles in Settings > Visuals are gone.
- "TV Shows" is called "Shows" throughout the app.
- Movies and shows are sorted by date added, newest first, by default. Items without a year or date added now sort last in either direction instead of jumping to the top.
- Online, downloads appear only in their server's sections (with the green tick); on their own they show in Offline Mode.
- Search results are placed in the library they belong to, and no longer include matches from libraries you excluded in Settings > Libraries.
- Minimum macOS version lowered from 27 to 26 (Tahoe).
- Posters now load through a new `ArtworkImage` view instead of `AsyncImage(request:)` and `.asyncImageURLSession(_:)`, which only exist on macOS 27. Images are decoded and downsampled off the main thread, and the "Cache Artwork Locally" setting still applies.
- Faster menu and browsing: server settings and download indexes are kept in memory instead of being re-read from the Keychain and disk on every redraw, sources load in parallel, and inline music playback no longer redraws every poster twice a second.
- A Plex server address that works after the saved one fails is remembered, so later requests and launches no longer wait for the dead address to time out.
- The TMDb API key is stored in the Keychain instead of in plain text in the app's preferences. A key saved earlier is moved over automatically the first time it is read.
- Jellyfin sign-in says "wrong username or password" when the server rejects the credentials, instead of a generic network error.
- Download indexes are written atomically, so a crash mid-write can't corrupt them.
- The menu header says "No sources" instead of "Sample catalog" when no server is connected, since there is no sample catalog.
- Xcode previews (`#Preview`) are skipped in SwiftPM builds, since previews only work in Xcode. They still work in the Xcode project.
- `.gitignore` now excludes the SwiftPM build output (`.build/` and `dist/`).

### Removed

- Post-download transcoding (`VideoTranscoder.swift`, `TranscodeSettings.swift`, the Converting section and the convert prompt). Its settings were already commented out upstream, so it never ran on a fresh install. FFmpeg is no longer needed.
- `ActivitySection.swift`, which was not used anywhere.
- Other unused code: the player's `pinOverlay`, `uiScale` and `toggleFullScreen`, `TMDbClient.episodeStillPath`, and the always-empty `MediaItem.streamURL` field.
- `QuPi/Secrets.swift` from the repository. Create it locally before building; the README has a template.

### Fixed

- In the video player, AVKit's fullscreen, picture-in-picture and volume controls overlapped the window's close/minimize/zoom buttons and the crop and pin buttons. The player now uses AVKit's floating control bar, which stays clear of the title bar and can be dragged anywhere; clicking the video still pauses and double-clicking still toggles fullscreen.
- Server addresses typed without `http://` or `https://` (for example `jellyfin.example.com`) now work. The app tries HTTPS first, then HTTP. Jellyfin saves the address that worked; a manually added Plex server keeps HTTP as a fallback. Before, Jellyfin signed in over HTTP only, which fails on servers that redirect to HTTPS, and saved the address without a scheme, which broke every later request.
- The Plex token was saved in plain text inside poster URLs, in the Continue list (UserDefaults) and in each download folder's `.qp-downloads.json`. Poster URLs no longer contain it; it is sent as a request header instead, and tokens saved by earlier runs are removed on launch.
- Plex errors are now readable. A rejected token or a server error used to appear as a confusing "data couldn't be read" message because the HTTP status was never checked.
- Offline Mode showed nothing when you had downloads but no library folder set, because only library folders counted as local content.
- `.gitignore` pointed to `QuPi/QuPi/Secrets.swift` instead of `QuPi/Secrets.swift`, so the secrets file was committed upstream.
- `CLAUDE.md` (developer notes) was copied into `QuPi.app` by the Xcode build.
