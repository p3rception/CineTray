import SwiftUI

/// PiP-style playback controls overlaid on the now-playing carousel cell's
/// album art: a Liquid Glass transport cluster (previous/play-pause/next) and
/// a draggable glass scrubber at the bottom. Sized to fit the 110×110 artwork.
struct InlinePlayerOverlay: View {
    var isPlaying: Bool
    /// Read inside this view's body, so the twice-a-second playback time
    /// updates redraw only the overlay, not the whole carousel.
    var progress: () -> Double = { 0 }
    /// Track length in seconds, for VoiceOver's scrubber value and steps.
    var duration: () -> Double = { 0 }
    var canGoPrevious = false
    var canGoNext = false
    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onScrub: (Double) -> Void

    @AppStorage(SettingsKeys.simpleVisuals) private var simpleVisuals = false

    /// Scrubber position while dragging - shown instead of live playback
    /// progress until the seek is committed.
    @State private var dragProgress: Double?

    private var displayProgress: Double {
        dragProgress ?? max(0, min(1, progress()))
    }

    var body: some View {
        ZStack {
            // Legibility scrim over bright artwork.
            Color.black.opacity(0.2)
                .allowsHitTesting(false)

            // Transport cluster - mirroring PiP, shrunk dynamically when posters are off
            GlassEffectContainer(spacing: simpleVisuals ? 4 : 8) {
                HStack(spacing: simpleVisuals ? 4 : 8) {
                    transportButton("backward.fill", label: "Previous",
                                    glyphSize: simpleVisuals ? 8 : 10,
                                    diameter: simpleVisuals ? 20 : 24,
                                    enabled: canGoPrevious, action: onPrevious)
                    
                    transportButton(isPlaying ? "pause.fill" : "play.fill",
                                    label: isPlaying ? "Pause" : "Play",
                                    glyphSize: simpleVisuals ? 10 : 14,
                                    diameter: simpleVisuals ? 24 : 30,
                                    enabled: true, action: onPlayPause)
                    
                    transportButton("forward.fill", label: "Next",
                                    glyphSize: simpleVisuals ? 8 : 10,
                                    diameter: simpleVisuals ? 20 : 24,
                                    enabled: canGoNext, action: onNext)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Interactive glass scrubber pinned to the bottom - completely hidden when posters are off
            if !simpleVisuals {
                VStack {
                    Spacer()
                    scrubber
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 8))
    }

    private func transportButton(
        _ systemName: String,
        label: String,
        glyphSize: CGFloat,
        diameter: CGFloat,
        enabled: Bool,
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
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .help(label)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white)
                    .frame(width: geo.size.width * displayProgress)
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragProgress = min(max(value.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        onScrub(fraction)
                        dragProgress = nil
                    }
            )
        }
        .frame(height: 14)
        .scrubberAccessibility(fraction: displayProgress, duration: duration(), seek: onScrub)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .glassEffect()
    }
}
