<p align="center"><img src="Screenshots/Banner.png" alt="CineTray: movies, shows and music from your media servers and your own folders, in the macOS menu bar."></p>

<p align="center"><img src="https://visitor-badge.laobi.icu/badge?page_id=p3rception.CineTray&left_text=Visitors&left_color=%230B111D&right_color=%233B4489&radius=5&height=25" alt="Visitors"></p>

## Contents

*   [Supported servers](#supported-servers)
*   [About CineTray](#about-cinetray)
    *   [Building CineTray](#building-cinetray)
    *   [Scrobbling and artwork](#scrobbling-and-artwork)
*   [Screenshots](#screenshots)

## Supported servers

| Source | Movies | Shows | Music |
|:-:|:-:|:-:|:-:|
| <img src="Icons/plex.png" width="48" height="48" alt=""><br>Plex, one or more servers | ✓ | ✓ | ✓ |
| <img src="Icons/jellyfin.png" width="48" height="48" alt=""><br>Jellyfin | ✓ | ✓ | ✓ |
| <img src="Icons/navidrome.png" width="48" height="48" alt=""><br>Navidrome | | | ✓ |
| <img src="Icons/torrserver.png" width="48" height="48" alt=""><br>TorrServer | ✓ | ✓ | |
| <img src="Icons/folder.png" width="48" height="48" alt=""><br>Your own folders | ✓ | ✓ | ✓ |

Connect servers in Settings > Accounts and choose folders in Settings > Data.

## About CineTray

CineTray is a macOS menu bar app for movies, shows and music from your media servers and your own folders.

*   **Navidrome support.** Music from a Navidrome server, next to Plex, Jellyfin and your own folders.
*   **TorrServer support.** Movies and shows from a TorrServer. Releases of the same show are grouped into one poster, with seasons and episodes read from the file names.
*   **Your libraries, your names.** The menu shows one section per server library, named as on the server (for example Movies, Shows and YouTube). Choose which libraries appear in Settings > Libraries.
*   **Video and Music panes.** Click the menu title to switch between video and music. The Music pane has Artists, Albums and Playlists sections.
*   **Players.** Control music from the inline player in the menu, or open a separate music or video player window.
*   **Sorting.** Movies and shows are sorted by date added, newest first, by default. A small sort button on each open section changes the field and order without opening Settings. Drag the menu's sections into any order in Settings > Libraries.
*   **Continue Watching.** Merges the server's own list (Plex Continue Watching, Jellyfin Resume and Next Up) with what you started in CineTray. Movies and episodes resume where you stopped, on any device, and posters show watched checkmarks and progress bars.
*   **Search.** Ignores spacing, punctuation and accents ("madmen" finds "Mad Men") and shows only the sections with matches.
*   **Open in Plex or Jellyfin.** Hover a poster and click the arrow at its top right (or use the player's toolbar button) to open that item in the server's web app: browse in CineTray, watch in Plex or Jellyfin.
*   **Release calendar.** Connect Radarr and Sonarr in Settings > Accounts, and a calendar button in the menu shows their upcoming movies and episodes: a month view with a dot on each day with releases, and a list of the coming week.
*   **Your video player.** Play video in CineTray's own player, in IINA or VLC with one click, or in any other installed app, such as QuickTime Player (Settings > Playback). IINA and VLC get the original file, with all its subtitles and audio tracks. The built-in player lets you pick the audio track and subtitles for every format, MKV and AVI included, shift subtitles earlier or later, and set their size. Jellyfin videos list the same subtitles as Jellyfin's web app, subtitle files stored next to the video included.
*   **Downloads and Offline Mode.** Download movies, episodes and music to watch and listen without a connection. Offline Mode plays downloads alone.
*   **Scrobbling and artwork.** Trakt and Last.fm scrobbling, with API keys entered in Settings > Accounts; [Scrobbling and artwork](#scrobbling-and-artwork) says where to get them. Your own music gets covers and artist photos from Deezer, MusicBrainz, Last.fm, TheAudioDB or Discogs; turn each one on or off.
*   **Easy sign-in.** Jellyfin Quick Connect (approve a code from another signed-in device, no password). Server addresses work without `http://` or `https://`; the app uses HTTPS, and falls back to HTTP only for addresses on your local network. The TMDb API key field checks the key as you type.
*   **Security.** The Plex token is never sent over plain HTTP to remote servers or saved inside poster URLs, and all tokens and API keys are stored in the Keychain.
*   **Fast.** Sources load in parallel, Plex checks all server addresses at once, the menu refreshes in the background when opened, and Jellyfin plays compatible files directly, so videos start in under a second.
*   **Keyboard shortcuts in windows.** While a player or Settings is open, CineTray gets a Dock icon and a menu bar, so Full Screen, Hide and Close shortcuts work.
*   **Builds without Xcode.** Clone and run `make`: it builds, signs and installs the app using only the Command Line Tools.

See [CHANGELOG.md](CHANGELOG.md) for the full list.

Continue Watching, watched indicators and parts of the Settings reorganization are based on [#1](https://github.com/p3rception/CineTray/pull/1) by [@iosue-iulianus](https://github.com/iosue-iulianus).

### Building CineTray

Requirements: macOS 26 or later, plus either the Command Line Tools (`xcode-select --install`) or Xcode 26.4 or later. The SwiftVLC package requires Swift 6.3.

```sh
git clone https://github.com/p3rception/CineTray.git
cd CineTray
make
```

| Command | What it does |
| --- | --- |
| `make` | Builds CineTray, installs it in `/Applications` and opens it. Run it again after `git pull` to update. |
| `make clean` | Deletes the build files (about 4 GB). The installed app keeps working. |
| `make uninstall` | Removes the app. Settings, accounts and downloads stay. |
| `make wipe` | Removes the app and also deletes settings, watch progress, accounts and cached artwork. Downloaded media stays. |

Without an Apple Development certificate the app is signed ad-hoc, so macOS asks again for Keychain access after each rebuild.

For development, `./build.sh` builds `dist/CineTray.app` and opens it without installing. With Xcode, open `CineTray.xcodeproj`, select your own development team under Signing & Capabilities, and run.

### Scrobbling and artwork

Optional. Each service needs a free account of your own. The keys go in Settings > Accounts and are kept in the Keychain.

**Trakt** scrobbles the movies and episodes you play and finds posters for your own movies and shows.

1. Create an app at https://trakt.tv/oauth/applications/new. Name it `CineTray` and set Redirect uri to `cinetray://trakt-auth`.
2. Copy its Client ID and Client Secret into Settings > Accounts > Trakt.
3. Click Sign in with Trakt and approve.

**Last.fm** scrobbles the music you finish and finds album covers.

1. Create an API account at https://www.last.fm/api/account/create. Leave Callback URL empty; Last.fm only accepts web addresses there, and CineTray doesn't need one.
2. Copy its API Key and Shared Secret into Settings > Accounts > Last.fm.
3. Click Connect to Last.fm…, then Yes, allow access on the page that opens in your browser. CineTray notices within a few seconds.

**TMDb** finds posters for your own movies and shows. Copy the API Key (v3) from https://www.themoviedb.org/settings/api into Settings > Accounts > The Movie Database. The API Read Access Token doesn't work.

**Music artwork** for your own music comes from Deezer, MusicBrainz, Last.fm, TheAudioDB and Discogs, in that order. Deezer, MusicBrainz and TheAudioDB work without a key. Discogs needs a personal access token from https://www.discogs.com/settings/developers. Turn sources on or off in Settings > Accounts > Music Artwork.

## Screenshots

<table>
  <tr>
    <td align="center"><img src="Screenshots/Welcome-CineTray.png" width="205" alt="The CineTray menu with Continue Watching and Movies carousels"><br><sub>Continue Watching and your libraries</sub></td>
    <td align="center"><img src="Screenshots/Mini-Video-Player.png" width="500" alt="The video player window playing The Matrix"><br><sub>Video player</sub></td>
  </tr>
</table>

<table>
  <tr>
    <td align="center"><img src="Screenshots/Music-Player.png" width="254" alt="The music player window with album art, progress and Up Next"><br><sub>Music player</sub></td>
    <td align="center"><img src="Screenshots/Full-Library-Exploration.png" width="231" alt="Browsing from a show to its seasons and episodes"><br><sub>Shows, seasons and episodes</sub></td>
    <td align="center"><img src="Screenshots/Dynamic-Filtering.png" width="193" alt="Search results grouped by section"><br><sub>Search across every section</sub></td>
  </tr>
</table>

<table>
  <tr>
    <td align="center"><img src="Screenshots/Inline-Music-Player.png" width="247" alt="The Music pane with playback controls on the album poster"><br><sub>Music pane with inline player</sub></td>
    <td align="center"><img src="Screenshots/Compact-Mode.png" width="244" alt="The menu with Show Posters off, with titles instead of posters"><br><sub>Show Posters off</sub></td>
    <td align="center"><img src="Screenshots/Customisation.png" width="187" alt="The Visuals tab in Settings"><br><sub>Settings</sub></td>
  </tr>
</table>

<table>
  <tr>
    <td align="center"><img src="Screenshots/Release-Calendar.png" width="205" alt="The release calendar: a month view with dots on days with releases, and the week's movies and episodes from Radarr and Sonarr"><br><sub>Release calendar from Radarr and Sonarr</sub></td>
  </tr>
</table>
