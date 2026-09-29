import SwiftUI

/// Full-width bottom transport bar for the VLC video player at normal (non-PiP)
/// window sizes. Provides skip ±10 s, play/pause, and a seekable scrubber with
/// elapsed/remaining labels - the functional equivalent of AVKit's inline bar,
/// styled with Liquid Glass to match the rest of the player chrome.
struct VideoTransportBar: View {
    let isPlaying: Bool
    let visible: Bool
    let currentTime: Double
    let totalDuration: Double
    let onPlayPause: () -> Void
    let onSeek: (Double) -> Void
    let bridge: VLCPlayerBridge

    @State private var dragProgress: Double?

    private var progress: Double {
        dragProgress ?? (totalDuration > 0 ? min(max(currentTime / totalDuration, 0), 1) : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 10) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        transportButton("gobackward.10", label: "Skip back 10 seconds",
                                        glyphSize: 13, diameter: 32) {
                            onSeek(max(currentTime - 10, 0))
                        }
                        transportButton(isPlaying ? "pause.fill" : "play.fill",
                                        label: isPlaying ? "Pause" : "Play",
                                        glyphSize: 15, diameter: 38, action: onPlayPause)
                        transportButton("goforward.10", label: "Skip forward 10 seconds",
                                        glyphSize: 13, diameter: 32) {
                            onSeek(min(currentTime + 10, totalDuration))
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text(timeString(progress * totalDuration))
                    scrubber
                    Text("-" + timeString(max(totalDuration - progress * totalDuration, 0)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect()
                .frame(maxWidth: .infinity)
                VLCTrackMenu(bridge: bridge)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: visible)
        .allowsHitTesting(visible)
    }

    private func transportButton(
        _ systemName: String,
        label: String,
        glyphSize: CGFloat,
        diameter: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
        .help(label)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white)
                    .frame(width: geo.size.width * progress)
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragProgress = min(max(value.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { value in
                        let target = min(max(value.location.x / geo.size.width, 0), 1)
                        onSeek(target * totalDuration)
                        dragProgress = nil
                    }
            )
        }
        .frame(height: 16)
    }
}

/// "m:ss" for a playback position in seconds, or "0:00" when unknown.
func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, roundFractionalSeconds: .towardZero)))
}
