<h1 align="center">QuPi</h1>

<p align="center">Your Plex, Jellyfin and Navidrome libraries, and your own media, in the macOS menu bar.</p>

<table>
  <tr>
    <td align="center"><img src="Screenshots/Welcome-QuPi.png" width="205" alt="The QuPi menu with Continue Watching and Movies carousels"><br><sub>Continue Watching and your libraries</sub></td>
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

## About this fork

This is a fork of [KuDoZ007/QP](https://github.com/KuDoZ007/QP). The main differences:

*   **Runs on macOS 26 (Tahoe).** Upstream needs macOS 27 because it used two SwiftUI APIs that only exist there (`AsyncImage(request:)` and `.asyncImageURLSession(_:)`). Posters now load through a small `ArtworkImage` view that works on both.
*   **Navidrome support.** Music from a Navidrome server, next to Plex, Jellyfin and your own folders.
*   **Your libraries, your names.** The menu shows one section per server library, named as on the server (for example Movies, Shows and YouTube), instead of fixed Movies / TV Shows / Music sections. Choose which libraries appear in Settings > Libraries. "TV Shows" is called "Shows" throughout.
*   **Video and Music panes.** Click the menu title to switch between video and music. The Music pane has Artists, Albums and Playlists sections.
*   **Sorting.** Movies and shows are sorted by date added, newest first, by default. A small sort button on each open section changes the field and order without opening Settings. Drag the menu's sections into any order in Settings > Libraries.
*   **Continue Watching.** Merges the server's own list (Plex Continue Watching, Jellyfin Resume and Next Up) with what you started in QuPi. Movies and episodes resume where you stopped, on any device, and posters show watched checkmarks and progress bars.
*   **Better search.** Ignores spacing, punctuation and accents ("madmen" finds "Mad Men") and shows only the sections with matches.
*   **Open in Plex or Jellyfin.** Hover a poster and click the arrow at its top right (or use the player's toolbar button) to open that item in the server's web app: browse in QuPi, watch in Plex or Jellyfin.
*   **Easier sign-in.** Jellyfin Quick Connect (approve a code from another signed-in device, no password). Server addresses work without `http://` or `https://`; the app tries HTTPS first, then HTTP. The TMDb API key field checks the key as you type.
*   **Security.** The Plex token is never sent over plain HTTP to remote servers, Plex tokens are no longer saved in plain text inside poster URLs, the TMDb key is stored in the Keychain, and `Secrets.swift` is no longer committed (the upstream `.gitignore` pointed to the wrong path).
*   **Faster.** Server settings and download indexes stay in memory instead of being re-read from the Keychain and disk on every redraw, sources load in parallel, Plex checks all server addresses at once (seconds instead of minutes after switching networks), the menu refreshes in the background when opened, and Jellyfin plays compatible files directly, so videos start in under a second.
*   **Clearer Settings.** Smaller sections with buttons in rows, the signed-in Plex account in Accounts, plain-language playback menus, a section per media type in Data, and Delete Downloads asks first.
*   **Keyboard shortcuts in windows.** While a player or Settings is open, QuPi gets a Dock icon and a menu bar, so Full Screen, Hide and Close shortcuts work.
*   **Fixes.** Offline Mode works with downloads alone, Plex errors are readable, and Jellyfin HEVC videos show the picture instead of playing audio only.
*   **Leaner.** The unfinished transcoding feature and other unused code are removed (about 1,450 lines), so FFmpeg is no longer needed.
*   **Builds without Xcode.** Clone and run `make`: it builds, signs and installs the app using only the Command Line Tools.

See [CHANGELOG.md](CHANGELOG.md) for the full list.

Continue Watching, watched indicators and parts of the Settings reorganization are based on [#1](https://github.com/p3rception/QP/pull/1) by [@iosue-iulianus](https://github.com/iosue-iulianus).

### Building this fork

Requirements: macOS 26 or later, plus either the Command Line Tools (`xcode-select --install`) or Xcode 26.4 or later. The SwiftVLC package requires Swift 6.3.

```sh
git clone https://github.com/p3rception/QP.git
cd QP
make
```

`make` builds QuPi, installs it in `/Applications` and opens it. Run `make` again after `git pull` to update. Without an Apple Development certificate the app is signed ad-hoc, so macOS asks again for Keychain access after each rebuild.

Scrobbling (optional): the first build creates `QuPi/Secrets.swift` with placeholders. Replace them with your own credentials and run `make` again.

*   Trakt: register at https://trakt.tv/oauth/applications/new with redirect URI `qupi://trakt-auth`.
*   Last.fm: register at https://www.last.fm/api/account/create with callback URL `qupi://lastfm-auth`.

For development, `./build.sh` builds `dist/QuPi.app` and opens it without installing. With Xcode, run `make` once (or `./build.sh build`) to create `Secrets.swift`, then open `QuPi.xcodeproj`, select your own development team under Signing & Capabilities, and run.

---

# QuPi 

**Your entire media library, right from your macOS menu bar.**

QuPi is a sleek, lightweight, and highly customizable menu bar application designed to give you instant access to your Plex or Jellyfin server as well as downloaded media. Whether you want to quickly resume a movie, put on a playlist, or download media for offline use, QuPi keeps your entertainment just a click away without cluttering your desktop.

## Key Features

*   **Quick Access:** Access every library on your servers (movies, shows, music and more) and your playlists directly from the menu bar (`Welcome-QuPi.jpg`).
*   **Dynamic Search & Filtering:** Find exactly what you're looking for instantly. The search bar dynamically filters your library as you type, narrowing down results across all media types (`Dynamic-Filtering.jpg`).
*   **Full Library Exploration:** Easily drill down into your content. Browse from your top-level shows down to specific seasons and episodes with a clean, intuitive interface (`Full-Library-Exploration.jpg`).
*   **Integrated Playback:**
    *   **Inline Music Player:** Control your tunes without opening a separate window. The inline player lives right inside the menu bar dropdown (`Inline-Music-Player.jpg`).
    *   **Mini Video Player:** Watch your favorite shows while you work using the floating picture-in-picture video player (`Mini-Video-Player.jpg`).
*   **Offline Downloads:** Queue up movies and episodes to download locally so you can enjoy your media on the go.
*   **Highly Customizable UI:** Tailor QuPi to your exact preferences. 
    *   Choose which libraries appear, adjust the player UI size, and configure carousel items (`Customisation.jpg`).
    *   Switch to a streamlined view for a cleaner look (`Compact-Mode.jpg`).

## Disclaimer

Have used Gemini and Claude to help me build this; though all the prototyping, testing and rewrites are on me.

## Prerequisites

*   macOS 26 (Tahoe) or later
*   A Plex Media Server, Jellyfin Server or local media files

## Getting Started
*   Build this fork from source as described in [Building this fork](#building-this-fork). The upstream DMG requires macOS 27.
