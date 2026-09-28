import SwiftUI
import SwiftVLC

// MARK: - Bridge

/// Wraps SwiftVLC.Player to expose observable transport state, keeping
/// PlayerView and AppState free of a direct SwiftVLC import.
///
/// SwiftVLC's raw event stream (`.newest(64)`) is lossy and libVLC often
/// never emits `MediaPlayerLengthChanged`; the Player instead polls natively
/// and updates its `@Observable` properties without emitting raw events.
/// This bridge surfaces those properties as simple computed values that
/// AppState can poll on a timer.
@Observable
@MainActor
final class VLCPlayerBridge {
    let player: Player
    /// URL stored by AppState so that play() can be deferred until VideoView
    /// is in the window hierarchy (libVLC crashes otherwise on macOS).
    private(set) var pendingURL: URL?

    init() {
        player = Player()
    }

    // MARK: - Observable transport state

    /// Current playback position in seconds.
    var currentTimeSeconds: Double { player.currentTime.seconds }
    /// Total media duration in seconds; 0 until libVLC reports it.
    var durationSeconds: Double { player.duration?.seconds ?? 0 }
    var isPlaying: Bool { player.isPlaying }
    var isSeekable: Bool { player.isSeekable }
    /// Becomes true when the media plays to its end; stays true until new media loads.
    var didReachEnd: Bool { player.didReachEnd }
    var isError: Bool { player.state == .error }

    // MARK: - Video geometry

    /// Decoded dimensions of the current video track; nil until the first frame
    /// is decoded. Mirrors `Player.videoSize` without requiring a SwiftVLC import.
    var videoSize: CGSize? { player.videoSize }

    /// Maps a `VideoCrop` selection onto the VLC engine.
    func setCrop(_ crop: VideoCrop) {
        player.aspectRatio = crop == .original ? .default : .fill
    }

    // MARK: - Playback control

    /// Stores `url` for deferred playback. Call `playPending()` once VideoView
    /// is in the window hierarchy to avoid libVLC's "no NSApplication" crash.
    func setPendingURL(_ url: URL) {
        pendingURL = url
    }

    /// Plays the pending URL. Must be called from the view's onAppear so that
    /// VideoView's NSView is already attached to a window before libVLC initialises
    /// its video output module.
    func playPending() throws {
        guard let url = pendingURL else { return }
        pendingURL = nil
        try player.play(url: url)
    }

    func play(url: URL) throws {
        try player.play(url: url)
    }

    func pause() { player.pause() }
    func resume() { try? player.play() }
    func togglePlayPause() { player.togglePlayPause() }
    func stop() { player.stop() }

    func seek(toSeconds seconds: Double) throws {
        guard player.isSeekable else { return }
        try player.seek(to: .milliseconds(Int64(seconds * 1000)))
    }

    func setVolume(_ volume: Float) throws {
        try player.setAudioVolume(Volume(volume))
    }
}

// MARK: - SwiftUI view

/// SwiftUI wrapper for SwiftVLC's VideoView, keeping PlayerView free of a
/// direct SwiftVLC import while still letting the bridge own the Player.
struct VLCVideoPlayerView: View {
    let bridge: VLCPlayerBridge

    var body: some View {
        VideoView(bridge.player)
            .onAppear {
                // Play is deferred until the VideoView's NSView is in a window;
                // calling play() before this causes libVLC's video output to crash.
                try? bridge.playPending()
            }
    }
}

// MARK: - Duration convenience

private extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }
}
