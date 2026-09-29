<p align="center"><img src="Screenshots/Banner.png" alt="CineTray: movies, shows and music from your media servers and your own folders, in the macOS menu bar."></p>

<p align="center"><img src="https://visitor-badge.laobi.icu/badge?page_id=p3rception.CineTray&left_text=Visitors&left_color=%230B111D&right_color=%233B4489&radius=5&height=25" alt="Visitors"></p>

## Contents

*   [Supported servers](#supported-servers)
*   [About this fork](#about-this-fork)
    *   [Building this fork](#building-this-fork)
    *   [Scrobbling and artwork](#scrobbling-and-artwork)
*   [Screenshots](#screenshots)
*   [CineTray](#cinetray)
    *   [Key Features](#key-features)
    *   [Disclaimer](#disclaimer)
    *   [Prerequisites](#prerequisites)
    *   [Getting Started](#getting-started)

## Supported servers

| Source | Movies | Shows | Music |
|:-:|:-:|:-:|:-:|
| <img src="Icons/plex.png" width="48" height="48" alt=""><br>Plex, one or more servers | ✓ | ✓ | ✓ |
| <img src="Icons/jellyfin.png" width="48" height="48" alt=""><br>Jellyfin | ✓ | ✓ | ✓ |
| <img src="Icons/navidrome.png" width="48" height="48" alt=""><br>Navidrome | | | ✓ |
| <img src="Icons/torrserver.png" width="48" height="48" alt=""><br>TorrServer | ✓ | ✓ | |
| <img src="Icons/folder.png" width="48" height="48" alt=""><br>Your own folders | ✓ | ✓ | ✓ |

Connect servers in Settings > Accounts and choose folders in Settings > Data.

## About this fork

This is a fork of [KuDoZ007/QP](https://github.com/KuDoZ007/QP). The main differences:

*   **Runs on macOS 26 (Tahoe).** Upstream needs macOS 27 because it used two SwiftUI APIs that only exist there (`AsyncImage(request:)` and `.asyncImageURLSession(_:)`). Posters now load through a small `ArtworkImage` view that works on both.
*   **Navidrome support.** Music from a Navidrome server, next to Plex, Jellyfin and your own folders.
*   **TorrServer support.** Movies and shows from a TorrServer. Releases of the same show are grouped into one poster, with seasons and episodes read from the file names.
*   **Your libraries, your names.** The menu shows one section per server library, named as on the server (for example Movies, Shows and YouTube), instead of fixed Movies / TV Shows / Music sections. Choose which libraries appear in Settings > Libraries. "TV Shows" is called "Shows" throughout.
*   **Video and Music panes.** Click the menu title to switch between video and music. The Music pane has Artists, Albums and Playlists sections.
*   **Sorting.** Movies and shows are sorted by date added, newest first, by default. A small sort button on each open section changes the field and order without opening Settings. Drag the menu's sections into any order in Settings > Libraries.
*   **Continue Watching.** Merges the server's own list (Plex Continue Watching, Jellyfin Resume and Next Up) with what you started in CineTray. Movies and episodes resume where you stopped, on any device, and posters show watched checkmarks and progress bars.
*   **Better search.** Ignores spacing, punctuation and accents ("madmen" finds "Mad Men") and shows only the sections with matches.
*   **Open in Plex or Jellyfin.** Hover a poster and click the arrow at its top right (or use the player's toolbar button) to open that item in the server's web app: browse in CineTray, watch in Plex or Jellyfin.
*   **Your video player.** Play video in CineTray's own player or in another installed app, such as VLC, IINA or QuickTime Player (Settings > Playback). The built-in player lets you pick the audio track and subtitles for every format, MKV and AVI included, shift subtitles earlier or later, and set their size. Jellyfin subtitles show in sync, working around a Jellyfin bug that shows them 10 seconds late.
*   **Scrobbling and artwork set up in the app.** Trakt and Last.fm sign-in are back. Their API keys go in Settings > Accounts instead of a source file you edit before building, and [Scrobbling and artwork](#scrobbling-and-artwork) says where to get them. Your own music gets covers and artist photos from Deezer, MusicBrainz, Last.fm, TheAudioDB or Discogs; turn each one on or off.
*   **Easier sign-in.** Jellyfin Quick Connect (approve a code from another signed-in device, no password). Server addresses work without `http://` or `https://`; the app uses HTTPS, and falls back to HTTP only for addresses on your local network. The TMDb API key field checks the key as you type.
*   **Security.** The Plex token is never sent over plain HTTP to remote servers, Plex tokens are no longer saved in plain text inside poster URLs, and the TMDb, Trakt and Last.fm keys are stored in the Keychain instead of in the source code (upstream committed its `Secrets.swift` by accident, because its `.gitignore` pointed to the wrong path).
*   **Faster.** Server settings and download indexes stay in memory instead of being re-read from the Keychain and disk on every redraw, sources load in parallel, Plex checks all server addresses at once (seconds instead of minutes after switching networks), the menu refreshes in the background when opened, and Jellyfin plays compatible files directly, so videos start in under a second.
*   **Clearer Settings.** Smaller sections with buttons in rows, the signed-in Plex account in Accounts, plain-language playback menus, a section per media type in Data, and Delete Downloads asks first.
*   **Keyboard shortcuts in windows.** While a player or Settings is open, CineTray gets a Dock icon and a menu bar, so Full Screen, Hide and Close shortcuts work.
*   **Fixes.** Offline Mode works with downloads alone, Plex errors are readable, and Jellyfin HEVC videos show the picture instead of playing audio only.
*   **Leaner.** The unfinished transcoding feature and other unused code are removed (about 1,450 lines), so FFmpeg is no longer needed.
*   **Builds without Xcode.** Clone and run `make`: it builds, signs and installs the app using only the Command Line Tools.

See [CHANGELOG.md](CHANGELOG.md) for the full list.

Continue Watching, watched indicators and parts of the Settings reorganization are based on [#1](https://github.com/p3rception/CineTray/pull/1) by [@iosue-iulianus](https://github.com/iosue-iulianus).

### Building this fork

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

**Trakt** scrobbles the movies you play and finds posters for your own movies and shows.

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

---

# CineTray 

**Your entire media library, right from your macOS menu bar.**

CineTray is a sleek, lightweight, and highly customizable menu bar application designed to give you instant access to your Plex or Jellyfin server as well as downloaded media. Whether you want to quickly resume a movie, put on a playlist, or download media for offline use, CineTray keeps your entertainment just a click away without cluttering your desktop.

## Key Features

*   **Quick Access:** Access every library on your servers (movies, shows, music and more) and your playlists directly from the menu bar ([Welcome-CineTray.png](https://github.com/p3rception/CineTray/blob/main/Screenshots/Welcome-CineTray.png)).
*   **Dynamic Search & Filtering:** Find exactly what you're looking for instantly. The search bar dynamically filters your library as you type, narrowing down results across all media types ([Dynamic-Filtering.png](https://github.com/p3rception/CineTray/blob/main/Screenshots/Dynamic-Filtering.png)).
*   **Full Library Exploration:** Easily drill down into your content. Browse from your top-level shows down to specific seasons and episodes with a clean, intuitive interface ([Full-Library-Exploration.png](https://github.com/p3rception/CineTray/blob/main/Screenshots/Full-Library-Exploration.png)).
*   **Integrated Playback:**
    *   **Inline Music Player:** Control your tunes without opening a separate window. The inline player lives right inside the menu bar dropdown ([Inline-Music-Player.png](https://github.com/p3rception/CineTray/blob/main/Screenshots/Inline-Music-Player.png)).
    *   **Mini Video Player:** Watch your favorite shows while you work using the floating picture-in-picture video player ([Mini-Video-Player.png](https://github.com/p3rception/CineTray/blob/main/Screenshots/Mini-Video-Player.png)).
*   **Offline Downloads:** Queue up movies and episodes to download locally so you can enjoy your media on the go.
*   **Highly Customizable UI:** Tailor CineTray to your exact preferences. 
    *   Choose which libraries appear, adjust the player UI size, and configure carousel items ([Customisation.png](https://github.com/p3rception/CineTray/blob/main/Screenshots/Customisation.png)).
    *   Switch to a streamlined view for a cleaner look ([Compact-Mode.png](https://github.com/p3rception/CineTray/blob/main/Screenshots/Compact-Mode.png)).

## Disclaimer

Have used Gemini and Claude to help me build this; though all the prototyping, testing and rewrites are on me.

## Prerequisites

*   macOS 26 (Tahoe) or later
*   A Plex, Jellyfin, Navidrome or TorrServer server, or local media files

## Getting Started
*   Build this fork from source as described in [Building this fork](#building-this-fork). The upstream DMG requires macOS 27.
