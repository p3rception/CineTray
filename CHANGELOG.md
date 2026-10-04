# Changelog

All notable changes to CineTray are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Settings > General shows the installed version and build number, next to Check for Updates.
- VoiceOver can read and change the playback position in the video player and in music played in the menu, 10 seconds at a time.
- Remove Download in a poster's right-click menu deletes that download, or for a show, season, artist or album everything downloaded from it. Before, downloads could only be deleted all at once in Settings > Data. Playlists don't have it yet.
- VoiceOver says whether a section in the menu is expanded or collapsed.
- Keyboard shortcuts: Space plays and pauses in the music player window, and in the menu while the search field is empty. In the menu, Command-Comma opens Settings and Command-Q quits CineTray.
- A poster's right-click menu also has Open in Plex or Jellyfin, Info, and Download or Stop Download, so they work without pointing at the poster, including with Full Keyboard Access and Voice Control.
- When the menu bar icon is missing, open CineTray again from Spotlight or the Applications folder to get to Settings. Settings > General > Menu Bar has Show Again, which puts the icon back, and a link to the Menu Bar settings in System Settings, where CineTray has to be allowed.

### Changed

- The buttons at the top of the menu and on posters are easier to click. Offline Mode and the Release Calendar button also get a background while on, and VoiceOver reads them as selected.
- Downloaded items show a green download arrow next to their title instead of a green tick on the poster, where it was hard to see on some artwork and looked like the Watched checkmark. It now also shows when downloads are turned off in Settings.
- Choose… in Settings > Playback lists the installed apps that play video, with a search field, instead of opening a Finder window. Other… still lets you pick any app.
- With Reduce Motion on, long titles under posters no longer scroll back and forth, and posters no longer grow when you point at them.

## [1.1.0] - 2026-10-02

### Added

- Update notices. Once a day CineTray checks GitHub for a new version. When one is out, the menu bar icon turns blue and the menu shows a line: with Homebrew it copies `brew upgrade cinetray` for you to paste in Terminal, otherwise it opens the release page. Close the line to hide it until the next version, or turn off Check for Updates in Settings > General.
- Export Logs in Settings > General. It saves the errors CineTray ran into since it was opened, such as a server it couldn't reach, playback that failed or a download that didn't finish, as a text file to attach to a bug report. To skip the save dialog, choose a folder under Save Logs To; each export then gets its own file there. After saving, Settings names the file and offers Show in Finder. They also appear in Console.app under the subsystem `CineTray`.

### Fixed

- When a server can't list its libraries, the menu says so above the libraries that did load, with a Retry button. Before, the message appeared only when every server failed, so a single failing server disappeared without a word, and the Video and Music switch could disappear with it.
- When Jellyfin no longer accepts your sign-in, for example after a server update, the menu, playback and Settings > Accounts say so and ask you to sign in again. Before, playback failed with "The data couldn't be read because it isn't in the correct format", and Settings still showed "Signed in as" in green. Navidrome errors also replace "Signed in as" in Settings.
- Items without a poster, such as home videos on Jellyfin, show a placeholder instead of loading forever. Artwork that doesn't arrive within 15 seconds gets the placeholder too.

## [1.0.0] - 2026-10-01

### Added

- Version numbers, starting with 1.0.0. Each release lists its changes on the [Releases](https://github.com/p3rception/CineTray/releases) page.
- Install with Homebrew: `brew install p3rception/tap/cinetray`, and update with `brew upgrade cinetray`. It needs an Apple Silicon Mac. Building from source with `make` still works.
- Requests with Seerr. Connect Seerr in Settings > Accounts with its API key, and a search also shows a Seerr row with the movies and shows that aren't in your libraries yet. Click a poster, then Request, then Confirm. For a show, pick the seasons you want; seasons already requested or available are listed but can't be picked. A checkmark confirms the request, and a clock then marks titles already requested. Hover a poster and click the arrow at its top right to open it in Seerr. Requests are made as the Seerr admin.
- Stop a download. While an item downloads, its download button becomes a stop button. Stopping a show, season or album, or the episode or track downloading now, stops the rest too. Files that finished downloading stay.

### Changed

- Poster rows no longer have arrows at their sides. Scroll them with the trackpad or the system scroll bar, which follows the Show scroll bars setting in System Settings > Appearance.

### Fixed

- The Settings window can be made taller or shorter again by dragging its top or bottom edge. CineTray remembers the height.
- Downloading a show, season, album or playlist whose contents can't be loaded from the server shows an error. Before, a season that failed to load was skipped without a message, and the show was still marked downloaded.
- A download whose folder can't be written to, such as a full or read-only disk, shows an error and doesn't leave the file behind. Before, it appeared downloaded, but after a restart CineTray no longer knew about the file, which still took up space. An unreadable download list is no longer replaced, which would have made CineTray forget every earlier download. If the list is damaged, starting a download offers to move it to the Trash and start a new one.

## 2026-09-30

### Added

- Release calendar for Radarr and Sonarr. Connect them in Settings > Accounts with their API key, then click the calendar button at the top of the menu. A month view marks the days with releases, orange for movies and blue for episodes, and below it the selected day and the six after it list each movie release (in cinemas, digital or physical) and each episode with its air time. A green tick marks what is already downloaded. Click the button again, or start typing a search, to return to your libraries.
- IINA and VLC buttons next to Play Video In in Settings > Playback, to switch to either player in one click. CineTray switches back to the built-in player. A player that isn't installed has its button dimmed and is named below Play Video In.
- Keyboard control for MKV, AVI and other videos in CineTray's player that play in the VLC engine: Space plays or pauses, Left and Right Arrow skip back and forward 10 seconds, as in other videos.

### Changed

- Shows with a single season list their episodes directly, without the season card in between.
- Subtitle timing in the video player's toolbar is one button. Click it to show - and + and the current value, which stay open while you click; click the value to reset it. The button is filled while the timing is changed.

### Fixed

- Subtitles in IINA and VLC. These players now get the original video file from Plex and Jellyfin, with all its subtitles and audio tracks, instead of the stream converted for CineTray's player. Plex left the subtitles out of that stream.
- Jellyfin videos in CineTray's player list the same subtitles as Jellyfin's web app, including subtitle files stored next to the video, under the same names. The one your Jellyfin settings pick is turned on. Videos that Jellyfin used to convert for playback, such as MKV files, now play the original file, with all its subtitles, image subtitles (PGS) included, and all its audio tracks.
- A TorrServer release whose name doesn't give the season, such as one added from Lampa, gets its own card in its show, with the date it was added and its size. It is woken only when you open it; its episodes then join their season. Before, its season could be missing, and the seasons changed between opens.
- TorrServer release names with the season number first, as in "5 сезон: 1-5 серии", are placed in season 5.
- An open season closes when a refresh removes it, instead of staying open without its card.
- `make` and `./build.sh` work with Xcode 27 (Swift 6.4), which puts the built app in a different folder.
- Playing a TorrServer release that nobody shares anymore shows an error after 20 seconds, instead of loading forever.
- A video or song that CineTray's player can't open, or that fails while playing, shows the error in the player window instead of loading forever.
- With Music Player set to Inline, a song that can't be played shows the error under its carousel in the menu. Before, it disappeared without a message.
- A streamed video or song whose server stops sending data stops with an error after 30 seconds of waiting, instead of loading forever.
- The music player's title bar, with the window buttons and the pin, stays visible when you move the mouse onto it. Before, it disappeared while music played.

## 2026-09-29

### Added

- Choose the audio track and subtitles for MKV, AVI and other videos that play in CineTray's own player: click the speech bubble at the right of the control bar. The button appears when a video has subtitles or more than one audio track. MP4 and MOV videos already had this in their control bar.
- Subtitles for Jellyfin videos that the server converts for playback, such as MKV files. Every text subtitle is listed in the player's subtitle menu, and the one your Jellyfin settings pick is turned on. Image subtitles (PGS, VobSub) are shown only when your Jellyfin settings pick them, burned into the picture. Jellyfin 12.1 and earlier time these subtitles 10 seconds late; CineTray corrects this.
- Subtitle timing in the video player's toolbar, for subtitles that don't match the speech: click - to show them half a second earlier and + to show them later, as many times as needed. Click the value between them to reset it. The setting applies to the current video only.
- Subtitle Size in Settings > Playback: Small, Medium or Large, for every video. It changes the subtitles of a playing video right away. Subtitles also follow the style chosen in the player's subtitle menu or in System Settings > Accessibility > Captions, such as Classic or Outline Text.
- Trakt scrobbles TV episodes, not only movies. Episodes are matched by show name, season and episode number. Episodes in your own Shows folder need a Refresh in Settings > Libraries first, so CineTray knows their show.

### Changed

- Server addresses typed without `http://` or `https://` fall back to plain HTTP only on your local network, for example `192.168.1.5:8096`, `nas.local` or `nas`. For a server on the internet without HTTPS, type the address with `http://`. Before, a failed HTTPS attempt sent your password over plain HTTP, where others on the network path could read it.

### Fixed

- TorrServer shows list all their seasons at once, read from the release names, without waking every release. A season's files load when you open it. If TorrServer is still looking for peers for a release, the season says so, instead of leaving that release's episodes out.
- A TorrServer release without TMDB data joins its show when one of the titles in its name, as in "Ричер (Сезон 2) / Reacher / S2E1-8", matches the show's title or original title.
- Sample and trailer files in a TorrServer release no longer take the place of an episode. Episodes named only by a number, such as "The Devil Judge 05.mp4", get that number.
- When a show's seasons or a season's episodes fail to load, a Retry button tries again.
- Servers on your local network no longer show an offline error right after launch, while macOS is still settling the Local Network permission.
- The checkboxes that choose which items get a download button now tick when clicked, and posters show the button right away. They moved into the Downloads section of Settings > Data, next to Enable Downloads.
- An account saved by an older build is no longer lost when it can't be moved to the Keychain, for example because you denied access. CineTray tries again on the next launch.
- Posters from TorrServer and the music artwork sources are only loaded from web addresses, never from files on your Mac.
- The playlist handed to another video player holds the stream address with your token, so it is deleted when CineTray quits. `make wipe` removes it too.
- Navidrome sign-in details and TMDb, Last.fm and TheAudioDB keys are no longer written to CineTray's cache on disk. The first launch after updating empties the cache once, so posters download again.
- Your Plex token is no longer passed on when a server redirects to another address.
- A Plex server on your home network is reached over HTTP only when none of its HTTPS addresses answers. Before, the fastest address won, which was usually plain HTTP, and every request carries your Plex token.
- Downloads can no longer end up outside the download folder. A server could name a file so that downloading it wrote to, or deleted, a folder above your download folder.
- Delete Downloads only removes files inside the download folder, even when the folder's `.cinetray-downloads.json` has been edited.
- Albums in your own music show their cover instead of a photo of the artist, and artists get a photo. Albums indexed before this fix keep their old picture; delete `.cinetray-downloads.json` in your Music library folder and press Refresh to fetch them again.

## 2026-09-28

### Added

- TorrServer support. Its movies and shows appear in the Movies and Shows sections, with posters, years and descriptions when the torrent carries TMDB data (as torrents added from Lampa do). Releases of the same show are grouped into one poster, with seasons and episodes read from the file names. MKV and AVI files play in CineTray's player. Connect in Settings > Accounts; a username and password are only needed for servers that ask for one.
- Install from source with one command: clone the repository and run `make`. It builds CineTray, installs it in Applications and opens it. `make clean` deletes the build files, `make uninstall` removes the app, and `make wipe` also removes its settings, accounts and caches.
- Play video in another app. In Settings > Playback, click Choose… next to Play Video In and pick an app such as VLC, IINA or QuickTime Player. Use CineTray switches back to the built-in player, which stays the default. Another app starts from the beginning, and CineTray can't resume, save progress, scrobble or play the next item for it. Music always plays in CineTray.
- Trakt and Last.fm sign-in in Settings > Accounts. Enter the keys of your own Trakt app and Last.fm API account there, then sign in to scrobble movies and music. The README lists the steps. Last.fm sign-in happens in your browser, and CineTray notices when you allow access. The keys are kept in the Keychain; `Secrets.swift` is no longer used. If you filled it in before, copy its values into Settings and delete the file.
- Music Artwork in Settings > Accounts. Your own music gets covers and artist photos from Deezer, MusicBrainz, Last.fm, TheAudioDB or Discogs, from the first one that has a picture. Turn each source on or off. TheAudioDB works without a key; Discogs needs a personal access token.
- An app icon, shown in the Dock while a player or Settings is open and in Finder: the menu bar symbol on navy, with glows of blue, purple and periwinkle.

### Changed

- The app is now called CineTray. Settings and accounts from earlier builds aren't carried over, so sign in again after running `make`.
- The Rich Media info button sits at the top left of posters instead of the bottom left, clear of the watch progress bar.
- Simple Visuals in Settings > Visuals is now Show Posters, on by default. Turn it off for the text-only menu. Your current choice is kept.
- Cached artwork is stored in `~/Library/Caches/CineTray/Artwork` instead of `~/Library/Caches/Artwork`, so it's clear which app it belongs to. Posters download once more after updating. You can delete the old `Artwork` folder if no other app uses it.
- CineTray asks for Keychain access once instead of once per account. All sign-ins are now kept in a single Keychain item. The first launch after updating still asks once for each existing account while it moves them over.

### Fixed

- Artists in your own music no longer get Last.fm's grey star placeholder as their photo.
- With Rich Media on, Jellyfin items in Continue Watching get the info button too. Its description in Settings no longer says tooltips show descriptions, which they never did.
- Clicking the Settings or a player window after switching to another app brings CineTray to the front again. Before, the window stayed inactive until you clicked CineTray's Dock icon.
- In Simple Visuals, the progress bar no longer covers the year or episode line of items you've started.
- VoiceOver can open posters of items you've started, such as everything in Continue Watching, and reads how much you've watched.

## 2026-09-27

### Added

- Video and Music panes. With both video and music libraries, the menu shows one kind at a time: click the title at the top (Video or Music) to switch. The line under it names the servers for that pane. The Music pane lists Artists, Albums and your music playlists as separate sections, and Continue Listening shows the music you stopped partway through. While you search, matches from both panes are shown. This replaces the Music Top Level setting, and the Playlists switch in Settings > Visuals is now Video Playlists.
- Navidrome support. Sign in under Settings > Accounts with your server address, username and password to browse artists, albums and playlists, search, play, download and open items in the Navidrome web app. Plays count on the server, and Navidrome shows what you're listening to. Ogg, Opus and other formats macOS can't play are converted to MP3 by the server. CineTray keeps a token in the Keychain, not your password.
- Continue Watching (renamed from "Continue…") includes the server's own list (Plex Continue Watching, Jellyfin Resume and Next Up), so things started on another device and the next episode of shows you're watching show up next to what you started in CineTray, most recently played first. Episodes show their show's poster and name, with the episode underneath. The section is on and open by default, first in the menu, and opens and closes independently of the library sections.
- Movies and episodes resume where you stopped, in CineTray or in Plex or Jellyfin on another device, whichever was more recent. Before, only music resumed. Right-click a poster and choose Play from Beginning to start over.
- Plex and Jellyfin posters show a checkmark for watched movies and episodes, and for shows and seasons once every episode is watched, plus a progress bar for anything in progress. They update a few seconds after playback stops.
- Menu Order in Settings > Libraries: drag sections into any order, or Control-click one to move it up or down. Sections turned off in Settings > Visuals are listed as Hidden and keep their place.
- While a player or the Settings window is open, CineTray has a Dock icon and a menu bar, so the usual shortcuts work (Control-Command-F for Full Screen, Command-H, Command-W).
- `AGENTS.md` with contribution rules for people and coding agents.

### Changed

- Search ignores spacing, punctuation and accents ("madmen" finds "Mad Men", "amelie" finds "Amélie"). While you type, the menu shows only the sections with matches, with a single "Searching…" or "No matches" line instead of one per section.
- The search field is ready for typing as soon as the menu opens.
- Opening the menu refreshes Continue Watching, and libraries loaded more than two minutes earlier refresh in the background, so changes made elsewhere show up without restarting CineTray.
- Plex connects faster after a network change. All of a server's addresses are checked at once, 3 seconds at most, on first use, after the network changes and when the current address stops answering. Switching to a hotspot or VPN connects in seconds instead of about three minutes.
- Settings are reorganized along the lines of macOS System Settings. Buttons moved out of section headers into rows, and each tab is split into smaller sections:
  - General: "Load on Startup" is now "Open at Login", and a Local Network row shows "Allowed" or, when access is missing, a button that opens Privacy settings.
  - Accounts: once you're signed in to Plex, the account (username and email) with "Signed In" and a Sign Out… button replaces the "Sign In with Plex…" button. Signing out asks first, then removes the account and its servers from CineTray. An expired sign-in shows a message. Test Connection says which address answered.
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
- The Plex token could be sent unencrypted over the internet. For remote servers found through your plex.tv account, CineTray tried plain HTTP before HTTPS, and every request carries the token. Remote addresses now use HTTPS only, and local ones try HTTPS first. Servers connected before this change keep their saved addresses until you connect them again in Settings > Accounts.
- Jellyfin HEVC videos (for example mkv files, or mp4 files tagged hev1) played audio only, with a gray QuickTime placeholder instead of the picture. The server now sends them in fragmented MP4 segments, which macOS can display. VP9 videos are converted by the server instead of being sent in a format macOS can't play.

## 2026-09-26

### Added

- An "Open in Plex" / "Open in Jellyfin" button opens an item's page in the server's web app: in the player window toolbar, and at the top right of any poster in the menu when you hover over it, so you can browse your collection in CineTray and watch in Plex or Jellyfin. VoiceOver offers it as an action on the poster. Plex links use the web app hosted by the server itself, so they work without a plex.tv account.
- One menu section per server library, named as on the server (see Changed).
- Jellyfin Quick Connect: in Settings > Accounts, click Quick Connect, then enter the code shown on any device already signed in to Jellyfin. No password needed. Requires Jellyfin 10.9 or later with Quick Connect enabled.
- A small sort button on every open movie, show and music section in the menu, for choosing the sort field and order without opening Settings. Order labels match the field (for example "Newest First" for dates instead of "Z -> A"), here and in Settings > Visuals.
- The TMDb API key field in Settings > Accounts checks the key with TMDb as you type and shows whether it is valid. It points out when the v4 Read Access Token was pasted instead of the v3 API Key, and trims stray spaces from pasted keys.
- Build without Xcode: `Package.swift` builds the app with SwiftPM using only the Command Line Tools, and `build.sh` wraps the result in `dist/CineTray.app`, signs it and launches it.

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
- `CineTray/Secrets.swift` from the repository. Create it locally before building; the README has a template.

### Fixed

- In the video player, AVKit's fullscreen, picture-in-picture and volume controls overlapped the window's close/minimize/zoom buttons and the crop and pin buttons. The player now uses AVKit's floating control bar, which stays clear of the title bar and can be dragged anywhere; clicking the video still pauses and double-clicking still toggles fullscreen.
- Server addresses typed without `http://` or `https://` (for example `jellyfin.example.com`) now work. The app tries HTTPS first, then HTTP. Jellyfin saves the address that worked; a manually added Plex server keeps HTTP as a fallback. Before, Jellyfin signed in over HTTP only, which fails on servers that redirect to HTTPS, and saved the address without a scheme, which broke every later request.
- The Plex token was saved in plain text inside poster URLs, in the Continue list (UserDefaults) and in each download folder's `.cinetray-downloads.json`. Poster URLs no longer contain it; it is sent as a request header instead, and tokens saved by earlier runs are removed on launch.
- Plex errors are now readable. A rejected token or a server error used to appear as a confusing "data couldn't be read" message because the HTTP status was never checked.
- Offline Mode showed nothing when you had downloads but no library folder set, because only library folders counted as local content.
- `.gitignore` pointed to `CineTray/CineTray/Secrets.swift` instead of `CineTray/Secrets.swift`, so the secrets file was committed upstream.
- `CLAUDE.md` (developer notes) was copied into `CineTray.app` by the Xcode build.
