# Changelog

Changes in this fork compared to [KuDoZ007/QP](https://github.com/KuDoZ007/QP).
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 2026-09-28

### Added

- TorrServer support. Its movies and shows appear in the Movies and Shows sections, with posters, years and descriptions when the torrent carries TMDB data (as torrents added from Lampa do). Releases of the same show are grouped into one poster, with seasons and episodes read from the file names. MKV and AVI files play in QuPi's player. Connect in Settings > Accounts; a username and password are only needed for servers that ask for one.
- Install from source with one command: clone the repository and run `make`. It builds QuPi, installs it in Applications and opens it. `Secrets.swift` no longer has to be created by hand.
- An app icon, shown in the Dock while a player or Settings is open and in Finder: the menu bar symbol on navy, with glows of blue, purple and periwinkle.

### Changed

- The Rich Media info button sits at the top left of posters instead of the bottom left, clear of the watch progress bar.
- Simple Visuals in Settings > Visuals is now Show Posters, on by default. Turn it off for the text-only menu. Your current choice is kept.
- QuPi asks for Keychain access once instead of once per account. All sign-ins are now kept in a single Keychain item. The first launch after updating still asks once for each existing account while it moves them over.

### Fixed

- With Rich Media on, Jellyfin items in Continue Watching get the info button too. Its description in Settings no longer says tooltips show descriptions, which they never did.
- Clicking the Settings or a player window after switching to another app brings QuPi to the front again. Before, the window stayed inactive until you clicked QuPi's Dock icon.
- In Simple Visuals, the progress bar no longer covers the year or episode line of items you've started.
- VoiceOver can open posters of items you've started, such as everything in Continue Watching, and reads how much you've watched.

## 2026-09-27

### Added

- Video and Music panes. With both video and music libraries, the menu shows one kind at a time: click the title at the top (Video or Music) to switch. The line under it names the servers for that pane. The Music pane lists Artists, Albums and your music playlists as separate sections, and Continue Listening shows the music you stopped partway through. While you search, matches from both panes are shown. This replaces the Music Top Level setting, and the Playlists switch in Settings > Visuals is now Video Playlists.
- Navidrome support. Sign in under Settings > Accounts with your server address, username and password to browse artists, albums and playlists, search, play, download and open items in the Navidrome web app. Plays count on the server, and Navidrome shows what you're listening to. Ogg, Opus and other formats macOS can't play are converted to MP3 by the server. QuPi keeps a token in the Keychain, not your password.
- Continue Watching (renamed from "Continue…") includes the server's own list (Plex Continue Watching, Jellyfin Resume and Next Up), so things started on another device and the next episode of shows you're watching show up next to what you started in QuPi, most recently played first. Episodes show their show's poster and name, with the episode underneath. The section is on and open by default, first in the menu, and opens and closes independently of the library sections.
- Movies and episodes resume where you stopped, in QuPi or in Plex or Jellyfin on another device, whichever was more recent. Before, only music resumed. Right-click a poster and choose Play from Beginning to start over.
- Plex and Jellyfin posters show a checkmark for watched movies and episodes, and for shows and seasons once every episode is watched, plus a progress bar for anything in progress. They update a few seconds after playback stops.
- Menu Order in Settings > Libraries: drag sections into any order, or Control-click one to move it up or down. Sections turned off in Settings > Visuals are listed as Hidden and keep their place.
- While a player or the Settings window is open, QuPi has a Dock icon and a menu bar, so the usual shortcuts work (Control-Command-F for Full Screen, Command-H, Command-W).
- `AGENTS.md` with contribution rules for people and coding agents.

### Changed

- Search ignores spacing, punctuation and accents ("madmen" finds "Mad Men", "amelie" finds "Amélie"). While you type, the menu shows only the sections with matches, with a single "Searching…" or "No matches" line instead of one per section.
- The search field is ready for typing as soon as the menu opens.
- Opening the menu refreshes Continue Watching, and libraries loaded more than two minutes earlier refresh in the background, so changes made elsewhere show up without restarting QuPi.
- Plex connects faster after a network change. All of a server's addresses are checked at once, 3 seconds at most, on first use, after the network changes and when the current address stops answering. Switching to a hotspot or VPN connects in seconds instead of about three minutes.
- Settings are reorganized along the lines of macOS System Settings. Buttons moved out of section headers into rows, and each tab is split into smaller sections:
  - General: "Load on Startup" is now "Open at Login", and a Local Network row shows "Allowed" or, when access is missing, a button that opens Privacy settings.
  - Accounts: once you're signed in to Plex, the account (username and email) with "Signed In" and a Sign Out… button replaces the "Sign In with Plex…" button. Signing out asks first, then removes the account and its servers from QuPi. An expired sign-in shows a message. Test Connection says which address answered.
  - Libraries: Refresh (index new files in your library folders) and Reload (the server's library list) are rows instead of buttons in the section headers.
  - Playback: Movies, Shows, Music and Continue Watching sections with plain menus instead of long segmented controls: "When a Movie Ends" (Stop, Next in Series, Same Director, Same Lead Actor), "Play Next Episode", "When a Song Ends" (Finish Album, In Order, Shuffle by Artist), and "Group Music" and "Keep Items For" (formerly Continue Music and Continue Timeout).
  - Visuals: Menu, Player, Sections and Navigation sections, plus a sorting section per media type (Sort By, Order, Downloaded First) instead of a crowded row per type. "Local First" is now "Downloaded First".
  - Data: a section per media type with its folder, storage limit, usage and a Delete Downloads… button. "Show Download Button On" checkboxes replace the "Download Indicators" switch, which only revealed them. The artwork cache shows its size next to a Clear button.
  - The Settings window's height can be adjusted; the width stays fixed.
- Jellyfin videos in mp4 or mov files with H.264, HEVC (hvc1) or AV1 video and a compatible audio track play the original file directly, so playback starts in well under a second instead of waiting a few seconds for the server to prepare a stream. Other files still go through the server.

### Fixed

- Jellyfin video playlists were listed as music.
- Text fields in Settings (server URLs, username, password, tokens, API key, storage limit) are underlined. Empty ones looked like plain labels.
- Delete Downloads in Settings > Data deleted a media type's downloads immediately. It now asks first.
- The music "By Genre" option actually shuffled by artist. It is now called Shuffle by Artist.
- The Plex token could be sent unencrypted over the internet. For remote servers found through your plex.tv account, QuPi tried plain HTTP before HTTPS, and every request carries the token. Remote addresses now use HTTPS only, and local ones try HTTPS first. Servers connected before this change keep their saved addresses until you connect them again in Settings > Accounts.
- Jellyfin HEVC videos (for example mkv files, or mp4 files tagged hev1) played audio only, with a gray QuickTime placeholder instead of the picture. The server now sends them in fragmented MP4 segments, which macOS can display. VP9 videos are converted by the server instead of being sent in a format macOS can't play.

## 2026-09-26

### Added

- An "Open in Plex" / "Open in Jellyfin" button opens an item's page in the server's web app: in the player window toolbar, and at the top right of any poster in the menu when you hover over it, so you can browse your collection in QuPi and watch in Plex or Jellyfin. VoiceOver offers it as an action on the poster. Plex links use the web app hosted by the server itself, so they work without a plex.tv account.
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
