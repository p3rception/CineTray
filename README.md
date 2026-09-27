## About this fork

This is a fork of [KuDoZ007/QP](https://github.com/KuDoZ007/QP). The main differences:

*   **Runs on macOS 26 (Tahoe).** Upstream needs macOS 27 because it used two SwiftUI APIs that only exist there (`AsyncImage(request:)` and `.asyncImageURLSession(_:)`). Posters now load through a small `ArtworkImage` view that works on both.
*   **Your libraries, your names.** The menu shows one section per server library, named as on the server (for example Movies, Shows and YouTube), instead of fixed Movies / TV Shows / Music sections. Choose which libraries appear in Settings > Libraries. "TV Shows" is called "Shows" throughout.
*   **Sorting.** Movies and shows are sorted by date added, newest first, by default. A small sort button on each open section changes the field and order without opening Settings.
*   **Open in Plex or Jellyfin.** Hover a poster and click the arrow at its top right (or use the player's toolbar button) to open that item in the server's web app: browse in QuPi, watch in Plex or Jellyfin.
*   **Easier sign-in.** Jellyfin Quick Connect (approve a code from another signed-in device, no password). Server addresses work without `http://` or `https://`; the app tries HTTPS first, then HTTP. The TMDb API key field checks the key as you type.
*   **Security.** Plex tokens are no longer saved in plain text inside poster URLs, the TMDb key is stored in the Keychain, and `Secrets.swift` is no longer committed (the upstream `.gitignore` pointed to the wrong path).
*   **Faster.** Server settings and download indexes stay in memory instead of being re-read from the Keychain and disk on every redraw, sources load in parallel, and a Plex address that works is remembered.
*   **Fixes.** Offline Mode works with downloads alone, and Plex errors are readable.
*   **Leaner.** The unfinished transcoding feature and other unused code are removed (about 1,450 lines), so FFmpeg is no longer needed.
*   **Builds without Xcode.** `./build.sh` builds, signs and launches the app using only the Command Line Tools.

See [CHANGELOG.md](CHANGELOG.md) for the full list.

### Building this fork

Requirements: macOS 26 or later, plus either the Command Line Tools (`xcode-select --install`) or Xcode 26.4 or later. The SwiftVLC package requires Swift 6.3.

1.  Create `QuPi/Secrets.swift` with your own credentials:

    ```swift
    enum TraktSecrets {
        static let clientID     = "YOUR_TRAKT_CLIENT_ID"
        static let clientSecret = "YOUR_TRAKT_CLIENT_SECRET"
        static let redirectURI  = "qupi://trakt-auth"
    }

    enum LastFMSecrets {
        static let apiKey       = "YOUR_LASTFM_API_KEY"
        static let sharedSecret = "YOUR_LASTFM_SHARED_SECRET"
        static let callbackURL  = "qupi://lastfm-auth"
    }
    ```

    Trakt: register at https://trakt.tv/oauth/applications/new with redirect URI `qupi://trakt-auth`.
    Last.fm: register at https://www.last.fm/api/account/create with callback URL `qupi://lastfm-auth`.
    The placeholders are enough to build; scrobbling needs real values.
2.  Build and launch:
    *   **Without Xcode:** run `./build.sh`. It builds with SwiftPM, creates `dist/QuPi.app`, signs it and opens it. Use `./build.sh build` to build without launching. Without an Apple Development certificate the app is signed ad-hoc, so macOS asks again for Keychain access after each rebuild.
    *   **With Xcode:** open `QuPi.xcodeproj`, select your own development team under Signing & Capabilities, and run.
3.  Optional: install it like any other app with `cp -R dist/QuPi.app /Applications/`. Repeat after each rebuild.

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
*   **Offline Downloads:** Queue up movies and episodes to download locally so you can enjoy your media on the go (`Download-Queue.jpg`).
*   **Highly Customizable UI:** Tailor QuPi to your exact preferences. 
    *   Choose which libraries appear, adjust the player UI size, and configure carousel items (`Customisation.jpg`).
    *   Switch to a streamlined view for a cleaner look (`Compact-Mode.jpg`).

## Screenshots

![Welcome.](/Screenshots/Welcome-QuPi.png)
![Simple Visuals Mode.](/Screenshots/Compact-Mode.png)
![Mini Video Player.](/Screenshots/Mini-Video-Player.png)
![Inline Music Player.](/Screenshots/Inline-Music-Player.png)
![Full Library Exploration.](/Screenshots/Full-Library-Exploration.png)
![Download Queue.](/Screenshots/Download-Queue.png)
![Dynamic Filtering.](/Screenshots/Dynamic-Filtering.png)
![Customisation.](/Screenshots/Customisation.png)

## Disclaimer

Have used Gemini and Claude to help me build this; though all the prototyping, testing and rewrites are on me.

## Prerequisites

*   macOS 26 (Tahoe) or later
*   A Plex Media Server, Jellyfin Server or local media files

## Getting Started
*   Build this fork from source as described in [Building this fork](#building-this-fork). The upstream DMG requires macOS 27.
