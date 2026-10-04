import SwiftUI
import AVKit
import Combine
import MediaAccessibility

/// Playback window for a media item (AVKit for video, mini-player for music).
/// Handles async stream resolution, scrobbling, position resuming, and queue management.
struct PlayerView: View {
    @Binding var item: MediaItem

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismissWindow
    @State private var isPinned = false
    @State private var queue: [MediaItem] = []
    @State private var videoAspectRatio: CGFloat?
    @State private var selectedCrop: VideoCrop = .original
    @State private var showsSubtitleTiming = false
    @State private var usePiPControls = false
    @State private var controlsVisible = true

    @AppStorage(SettingsKeys.playerUISize) private var playerUISizeRaw = PlayerUISize.medium.rawValue

    private var playerUISize: PlayerUISize {
        PlayerUISize(rawValue: playerUISizeRaw) ?? .medium
    }

    /// Toolbar icon size from Settings > Visuals > Player UI Size. Text
    /// styles, so Dynamic follows the system text size.
    private var toolbarIconFont: Font {
        switch playerUISize {
        case .small: .body
        case .medium, .dynamic: .title3
        case .large: .title2
        }
    }

    /// The aspect ratio to lock the window to. Uses the crop target when one is
    /// chosen, otherwise falls back to the video's native presentation ratio.
    private var effectiveVideoAspectRatio: CGFloat? {
        guard item.type != .music else { return nil }
        return selectedCrop.ratio ?? videoAspectRatio
    }

    private var windowTitle: String {
        item.subtitle.map { "\(item.title) - \($0)" } ?? item.title
    }

    var body: some View {
        Group {
            if appState.hasActivePlayer {
                if item.type == .music {
                    MusicPlayerLayout(
                        item: item,
                        queue: queue,
                        isPlaying: appState.isPlaying,
                        currentTime: Binding(
                            get: { appState.currentTime },
                            set: { appState.currentTime = $0 }
                        ),
                        totalDuration: appState.totalDuration,
                        isScrubbing: Binding(
                            get: { appState.isScrubbing },
                            set: { appState.isScrubbing = $0 }
                        ),
                        onSeek: seek,
                        onPlayPause: appState.togglePlayPause,
                        onNext: playNext,
                        onPick: { picked in item = picked }
                    )
                    .frame(minWidth: 300, minHeight: 480)
                    .toolbar {
                        openInServerToolbarItem
                        pinToolbarItem
                    }
                } else if let player = appState.player {
                    videoPlayerView(player: player)
                } else if let bridge = appState.vlcBridge {
                    vlcPlayerView(bridge: bridge)
                }
            } else if let errorMessage = appState.playbackError {
                ContentUnavailableView(
                    "Playback Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading \(item.title)…")
                    .frame(minWidth: 300, minHeight: 270)
            }
        }
        .navigationTitle(windowTitle)
        .background(WindowLevelAccessor(
            isPinned: isPinned,
            videoAspectRatio: effectiveVideoAspectRatio,
            useCompactToolbar: playerUISize != .large,
            chromeOverlaysContent: item.type != .music,
            isPlaying: appState.isPlaying,
            chromeSuppressed: usePiPControls,
            onChromeVisibilityChange: { controlsVisible = $0 }
        ))
        .task(id: item) {
            selectedCrop = .original
            await appState.startPlayback(item: item)
            queue = item.type == .music ? await appState.upcomingQueue(after: item) : []
            await watchForPlaybackEnd()
        }
        .onChange(of: appState.currentItem?.id) {
            // Another playback session (window or inline) took over: only one
            // thing plays at a time, so this window closes itself.
            if let currentID = appState.currentItem?.id, currentID != item.id {
                dismissWindow()
            }
        }
        .onAppear { AppWindowActivation.windowOpened() }
        .onDisappear {
            appState.stopPlayback(if: item)
            AppWindowActivation.windowClosed()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CineTray.MediaKeyNext"))) { _ in
            if appState.currentItem?.id == item.id { playNext() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CineTray.MediaKeyPrevious"))) { _ in
            if appState.currentItem?.id == item.id {
                appState.seek(to: 0) // Basic previous logic for windowed mode
            }
        }
    }

    // MARK: - Video player

    /// Window size below which AVKit's controls are swapped for the
    /// PiP-style ones. The switch happens once the window shrinks past
    /// whichever threshold is crossed later while resizing down (width for
    /// landscape videos, height for portrait), hence both conditions must
    /// hold; below the minimum width AVKit's floating bar no longer fits.
    private static let pipControlsMaxWidth: CGFloat = 600
    private static let pipControlsMaxHeight: CGFloat = 480
    /// AVKit's floating control bar is 457 pt wide on macOS 26.
    private static let floatingBarMinWidth: CGFloat = 480

    private func videoPlayerView(player: AVPlayer) -> some View {
        videoChrome(
            // Floating, not inline: the inline style pins fullscreen, PiP
            // and volume to the view's top corners (ignoring the safe area),
            // which puts them under the titlebar that floats over the video.
            VideoPlayerRepresentable(
                player: player,
                controlsStyle: usePiPControls ? .none : .floating,
                videoGravity: selectedCrop == .original ? .resizeAspect : .resizeAspectFill,
                onSingleClick: appState.togglePlayPause
            )
            .overlay {
                if let cues = appState.subtitleCues {
                    SubtitleOverlay(cues: cues, player: player, offset: appState.subtitleOffset)
                }
            }
            .overlay {
                // AVKit draws its own floating control bar at normal sizes.
                if usePiPControls { pipControls }
            }
            .task(id: ObjectIdentifier(player)) {
                await observeVideoAspectRatio(of: player)
            }
        )
    }

    /// SwiftVLC video view with the same feature set as the AVKit path:
    /// aspect-ratio-locked window, auto-hiding chrome, size-driven control switch
    /// (full transport bar at normal size, PiP-style overlay when tiny), and crop.
    private func vlcPlayerView(bridge: VLCPlayerBridge) -> some View {
        videoChrome(
            VLCVideoPlayerView(bridge: bridge)
                .overlay {
                    VideoClickCapture(onSingleClick: appState.togglePlayPause)
                }
                .overlay {
                    if usePiPControls {
                        pipControls
                    } else {
                        VideoTransportBar(
                            isPlaying: appState.isPlaying,
                            visible: controlsVisible || !appState.isPlaying,
                            currentTime: appState.currentTime,
                            totalDuration: appState.totalDuration,
                            onPlayPause: appState.togglePlayPause,
                            onSeek: seek,
                            bridge: bridge
                        )
                    }
                }
                .background {
                    // AVKit handles these keys itself for AVPlayer.
                    Group {
                        Button("Play or Pause", action: appState.togglePlayPause)
                            .keyboardShortcut(.space, modifiers: [])
                        Button("Skip Back 10 Seconds") { seek(max(appState.currentTime - 10, 0)) }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Button("Skip Forward 10 Seconds") { seek(min(appState.currentTime + 10, appState.totalDuration)) }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .opacity(0)
                    .accessibilityHidden(true)
                }
                .task(id: ObjectIdentifier(bridge.player)) {
                    await observeVLCVideoAspectRatio(of: bridge)
                }
                .onChange(of: selectedCrop) { _, newCrop in
                    bridge.setCrop(newCrop)
                }
        )
    }

    /// Window behaviour shared by both video engines: size-driven switch to
    /// the PiP-style controls, full-window layout under the titlebar, and
    /// the toolbar.
    private func videoChrome(_ video: some View) -> some View {
        video
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                usePiPControls = size.width < Self.floatingBarMinWidth
                    || (size.width < Self.pipControlsMaxWidth && size.height < Self.pipControlsMaxHeight)
            }
            // A token floor only: the real minimum comes from the
            // ratio-conforming contentMinSize in applyAspectRatio. A larger
            // SwiftUI minimum wins the window-limit fight and forces the
            // aspect-locked window out of ratio, letterboxing the video.
            .frame(minWidth: 200, minHeight: 120)
            // Fill the whole window, with the titlebar floating over the
            // video (QuickTime-style). This lets the window frame match the
            // video aspect ratio exactly; otherwise the toolbar strip makes
            // the visible video area shorter than the frame and letterbox
            // bars appear.
            .ignoresSafeArea(.container, edges: .top)
            .toolbar {
                // Tiny (PiP-style) mode has no toolbar at all; the overlay
                // provides its own close/pin buttons like the system popout.
                if !usePiPControls {
                    // The window's own title is hidden (see
                    // WindowLevelAccessor) and shown as a toolbar item
                    // instead so it sits in a Liquid Glass pill like the
                    // rest of the player controls.
                    ToolbarItem(placement: .principal) {
                        Text(windowTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .glassEffect()
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Crop", selection: $selectedCrop) {
                                ForEach(VideoCrop.allCases) { crop in
                                    Text(crop.title).tag(crop)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label("Crop", systemImage: "aspectratio")
                                .font(toolbarIconFont)
                        }
                        .help("Crop the video to a fixed aspect ratio")
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) {
                        Button { showsSubtitleTiming.toggle() } label: {
                            Label("Subtitle Timing", systemImage: appState.subtitleOffset == 0 ? "captions.bubble" : "captions.bubble.fill")
                                .font(toolbarIconFont)
                        }
                        .help("Subtitle timing")
                        // A popover, not a menu, so repeated clicks on - and + don't close it.
                        .popover(isPresented: $showsSubtitleTiming, arrowEdge: .bottom) {
                            subtitleTimingControl
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                    openInServerToolbarItem
                    pinToolbarItem
                }
            }
    }

    /// Subtitle offset with - and + in view, so repeated clicks step it
    /// without reopening anything. Clicking the value resets it.
    private var subtitleTimingControl: some View {
        let offset = appState.subtitleOffset
        let value = "\(offset.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))) s"
        return HStack(spacing: 4) {
            Button { appState.subtitleOffset -= 0.5 } label: { Image(systemName: "minus").frame(width: 32, height: 32).contentShape(.rect) }
                .help("Show subtitles 0.5 seconds earlier")
                .accessibilityLabel("Show Subtitles Earlier")
            Button(value) { appState.subtitleOffset = 0 }
                .font(.callout.monospacedDigit())
                .frame(minWidth: 44)
                .disabled(offset == 0)
                .help("Subtitle timing. Click to reset.")
                .accessibilityLabel("Subtitle Timing \(value), reset")
            Button { appState.subtitleOffset += 0.5 } label: { Image(systemName: "plus").frame(width: 32, height: 32).contentShape(.rect) }
                .help("Show subtitles 0.5 seconds later")
                .accessibilityLabel("Show Subtitles Later")
        }
        .buttonStyle(.borderless)
        .font(toolbarIconFont)
        .padding(4)
    }

    /// Opens the playing item's page in Plex Web or Jellyfin.
    @ToolbarContentBuilder
    private var openInServerToolbarItem: some ToolbarContent {
        if let serverName = item.source.webAppName {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.openInWebApp(item)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(toolbarIconFont)
                }
                .help("Open in \(serverName)")
                .accessibilityLabel("Open in \(serverName)")
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private var pinToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isPinned.toggle()
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(toolbarIconFont)
            }
            .help(isPinned ? "Let other windows cover this player" : "Keep this player above other windows")
        }
        // Drop the shared glass pill; the button keeps its own compact
        // circular background.
        .sharedBackgroundVisibility(.hidden)
    }

    private var pipControls: some View {
        PiPControlsOverlay(
            isPlaying: appState.isPlaying,
            visible: controlsVisible || !appState.isPlaying,
            isPinned: $isPinned,
            currentTime: appState.currentTime,
            totalDuration: appState.totalDuration,
            onPlayPause: appState.togglePlayPause,
            onSeek: seek,
            onClose: { dismissWindow() }
        )
    }

    /// Seeks with scrubbing flagged so the periodic time observer doesn't
    /// overwrite the new position mid-seek.
    private func seek(_ seconds: Double) {
        appState.isScrubbing = true
        appState.seek(to: seconds)
        appState.isScrubbing = false
    }

    /// Observes (KVO) the current item's presentation size, which (unlike
    /// the asset's video-track natural size) is also populated for HLS
    /// streams once playback starts, and follows the item when
    /// auto-continue swaps it. Ends when the view's task is cancelled.
    private func observeVideoAspectRatio(of player: AVPlayer) async {
        for await size in player.publisher(for: \.currentItem?.presentationSize).values {
            guard let size, size.width > 0, size.height > 0 else { continue }
            let ratio = size.width / size.height
            if videoAspectRatio != ratio {
                videoAspectRatio = ratio
            }
        }
    }

    /// Polls the VLC engine's decoded video size to lock the window to the
    /// native aspect ratio - the VLC equivalent of `observeVideoAspectRatio(of:)`.
    private func observeVLCVideoAspectRatio(of bridge: VLCPlayerBridge) async {
        while !Task.isCancelled {
            if let size = bridge.videoSize, size.width > 0, size.height > 0 {
                let ratio = size.width / size.height
                if videoAspectRatio != ratio {
                    videoAspectRatio = ratio
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - Playback lifecycle

    private func watchForPlaybackEnd() async {
        if appState.player != nil {
            // AVPlayer path: wait for the standard end-of-item notification.
            var lastPlayerItem: AVPlayerItem?
            while !Task.isCancelled {
                guard let player = appState.player,
                      let currentItem = player.currentItem,
                      currentItem !== lastPlayerItem else {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                lastPlayerItem = currentItem
                for await _ in NotificationCenter.default.notifications(
                    named: AVPlayerItem.didPlayToEndTimeNotification,
                    object: currentItem
                ) {
                    break
                }
                break
            }
        } else if appState.vlcBridge != nil {
            // SwiftVLC path: wait for the notification posted by the event watcher.
            for await _ in NotificationCenter.default.notifications(
                named: AppState.vlcPlaybackEndedNotification
            ) {
                break
            }
        } else {
            return
        }

        guard !Task.isCancelled else { return }
        appState.stopPlayback(atEnd: true)
        if let next = await appState.autoContinueItem(after: item) {
            item = next
        }
    }

    private func playNext() {
        Task {
            if let next = queue.first {
                item = next
            } else if let next = await appState.autoContinueItem(after: item) {
                item = next
            }
        }
    }
}

// MARK: - AVKit player view

/// AVKit video view with a controllable controls style, so the scrubber can
/// be dropped at small window sizes - SwiftUI's `VideoPlayer` offers no
/// control over its overlay controls.
/// AVPlayer's subtitles, taken over from AVKit so `SubtitleOverlay` can
/// shift them: AVPlayer has no subtitle delay.
final class SubtitleCues: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    let output = AVPlayerItemLegibleOutput()
    /// Choosing Off in AVKit's menu stops the cues without clearing the
    /// last ones, so the selection in this group is checked when drawing.
    var group: AVMediaSelectionGroup?
    private var cues: [(time: Double, text: String)] = []

    override init() {
        super.init()
        output.suppressesPlayerRendering = true
        // Cues arrive this far ahead of their time, which bounds how much
        // earlier than AVPlayer's timing they can be shown.
        output.advanceIntervalForDelegateInvocation = 30
        output.setDelegate(self, queue: .main)
    }

    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        // After a seek, cues arrive again from the new position; later ones are stale.
        cues.removeAll { $0.time >= itemTime.seconds }
        cues.append((itemTime.seconds, strings.map(\.string).joined(separator: "\n")))
    }

    func text(at seconds: Double, in item: AVPlayerItem?) -> String {
        guard let group, item?.currentMediaSelection.selectedMediaOption(in: group) != nil else { return "" }
        return cues.last { $0.time <= seconds }?.text ?? ""
    }
}

/// Draws `SubtitleCues`, shifted by the user's offset, in the caption style
/// chosen in AVKit's subtitle menu or in System Settings > Accessibility >
/// Captions. The style is read on every redraw,
/// so a change shows while the video plays.
private struct SubtitleOverlay: View {
    let cues: SubtitleCues
    let player: AVPlayer
    let offset: Double
    @AppStorage(SettingsKeys.subtitleSize) private var sizeScale = 1.0

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let text = cues.text(at: player.currentTime().seconds - offset, in: player.currentItem)
                if !text.isEmpty {
                    let size = max(11, geo.size.height / 28 * sizeScale * MACaptionAppearanceGetRelativeCharacterSize(.user, nil))
                    let font = MACaptionAppearanceCopyFontDescriptorForStyle(.user, nil, .default).takeRetainedValue()
                    // ponytail: text edges are approximated with shadows.
                    let (blur, shift): (CGFloat, CGFloat) = switch MACaptionAppearanceGetTextEdgeStyle(.user, nil) {
                    case .uniform: (size / 20, 0)
                    case .dropShadow: (size / 20, size / 15)
                    case .raised: (0, size / 30)
                    case .depressed: (0, -size / 30)
                    default: (0, 0)
                    }
                    let edgeColor: Color = blur == 0 && shift == 0 ? .clear : .black
                    Text(text)
                        .font(Font(CTFontCreateWithFontDescriptor(font, size, nil)))
                        .foregroundStyle(Color(cgColor: MACaptionAppearanceCopyForegroundColor(.user, nil).takeRetainedValue())
                            .opacity(MACaptionAppearanceGetForegroundOpacity(.user, nil)))
                        // Twice, since one shadow is too faint for an outline.
                        .shadow(color: edgeColor, radius: blur, x: shift, y: shift)
                        .shadow(color: edgeColor, radius: blur, x: shift, y: shift)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(cgColor: MACaptionAppearanceCopyBackgroundColor(.user, nil).takeRetainedValue())
                            .opacity(MACaptionAppearanceGetBackgroundOpacity(.user, nil)), in: .rect(cornerRadius: 4))
                        .padding(4)
                        .background(Color(cgColor: MACaptionAppearanceCopyWindowColor(.user, nil).takeRetainedValue())
                            .opacity(MACaptionAppearanceGetWindowOpacity(.user, nil)),
                            in: .rect(cornerRadius: MACaptionAppearanceGetWindowRoundedCornerRadius(.user, nil)))
                        // ponytail: fixed height clears AVKit's control bar; follow the bar if it gets in the way.
                        .padding(.bottom, 72)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct VideoPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    let controlsStyle: AVPlayerViewControlsStyle
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    let onSingleClick: () -> Void

    func makeCoordinator() -> VideoClickHandler {
        VideoClickHandler(onSingleClick: onSingleClick)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controlsStyle
        view.videoGravity = videoGravity
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        // AVKit layers contentOverlayView between the video and its
        // controls, so this gets clicks on the video while the floating bar
        // (which the user can drag anywhere) keeps its own.
        if let overlay = view.contentOverlayView {
            let clickView = ClickCaptureView(frame: overlay.bounds)
            clickView.autoresizingMask = [.width, .height]
            overlay.addSubview(clickView)
            context.coordinator.install(on: clickView)
        }
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        context.coordinator.onSingleClick = onSingleClick
        if nsView.player !== player {
            nsView.player = player
        }
        if nsView.controlsStyle != controlsStyle {
            nsView.controlsStyle = controlsStyle
        }
        if nsView.videoGravity != videoGravity {
            nsView.videoGravity = videoGravity
        }
    }
}

// MARK: - PiP-style small-size controls

/// Controls that replicate the system picture-in-picture window (minus its
/// PiP button): dimmed video, glass close (top-left) and pin (top-right)
/// buttons, a central 10-second-skip transport cluster, and a glass time
/// bar with a seekable scrubber along the bottom. Shown instead of AVKit's
/// inline bar (and the window chrome) when the window is too small for it.
private struct PiPControlsOverlay: View {
    let isPlaying: Bool
    let visible: Bool
    @Binding var isPinned: Bool
    let currentTime: Double
    let totalDuration: Double
    let onPlayPause: () -> Void
    let onSeek: (Double) -> Void
    let onClose: () -> Void

    /// Scrubber position while dragging, shown in place of the live
    /// playback progress until the seek is committed.
    @State private var dragProgress: Double?

    private var progress: Double {
        dragProgress
            ?? (totalDuration > 0 ? min(max(currentTime / totalDuration, 0), 1) : 0)
    }

    var body: some View {
        ZStack {
            // The popout dims the video while its controls are up.
            Color.black.opacity(0.2)
                .allowsHitTesting(false)

            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 16) {
                    transportButton("gobackward.10", glyphSize: 14, diameter: 36) {
                        onSeek(max(currentTime - 10, 0))
                    }
                    transportButton(isPlaying ? "pause.fill" : "play.fill", glyphSize: 20, diameter: 48, action: onPlayPause)
                    transportButton("goforward.10", glyphSize: 14, diameter: 36) {
                        onSeek(min(currentTime + 10, totalDuration))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                HStack {
                    cornerButton("xmark", help: "Close the player", action: onClose)
                    Spacer()
                    cornerButton(isPinned ? "pin.fill" : "pin",
                                 help: isPinned ? "Let other windows cover this player" : "Keep this player above other windows") {
                        isPinned.toggle()
                    }
                }
                .padding(10)
                Spacer()
                timeBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: visible)
        .allowsHitTesting(visible)
    }

    private func transportButton(_ systemName: String, glyphSize: CGFloat, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }

    private func cornerButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }

    /// Glass bar along the bottom like the popout's: elapsed time, seekable
    /// scrubber, remaining time. While dragging, the labels preview the
    /// drag position.
    private var timeBar: some View {
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
    }

    /// Thin seekable progress track with an enlarged strip around it for
    /// the drag gesture.
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
        .scrubberAccessibility(fraction: progress, duration: totalDuration) { onSeek($0 * totalDuration) }
    }
}

// MARK: - Music mini-player

/// Vertical layout in the style of Apple Music / YouTube Music mini players:
/// album art on top, track info, scrubber, transport controls, and the
/// Up Next queue.
private struct MusicPlayerLayout: View {
    let item: MediaItem
    let queue: [MediaItem]
    let isPlaying: Bool
    @Binding var currentTime: Double
    let totalDuration: Double
    @Binding var isScrubbing: Bool
    let onSeek: (Double) -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onPick: (MediaItem) -> Void

    var body: some View {
        VStack(spacing: 14) {
            artwork
            VStack(spacing: 2) {
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            scrubber
            controls
            Divider()
            upNext
        }
        .padding(16)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
            ArtworkImage(url: item.posterURL) {
                ProgressView()
            } fallback: {
                Image(systemName: "music.note")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 280)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 6)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(value: $currentTime, in: 0...max(totalDuration, 1)) { editing in
                isScrubbing = editing
                if !editing { onSeek(currentTime) }
            }
            HStack {
                Text(timeString(currentTime))
                Spacer()
                Text(timeString(totalDuration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            Button {
                onSeek(max(currentTime - 15, 0))
            } label: {
                Image(systemName: "gobackward.15").font(.title3)
            }
            .help("Back 15 seconds")
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 42))
            }
            .help(isPlaying ? "Pause" : "Play")
            .keyboardShortcut(.space, modifiers: [])
            Button(action: onNext) {
                Image(systemName: "forward.end.fill").font(.title3)
            }
            .help("Next track")
            .disabled(queue.isEmpty)
        }
        .buttonStyle(.plain)
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Up Next").font(.headline)
            if queue.isEmpty {
                Text("End of the queue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(queue) { track in
                            Button {
                                onPick(track)
                            } label: {
                                HStack(spacing: 8) {
                                    queueThumb(for: track)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(track.title).font(.callout).lineLimit(1)
                                        Text(track.subtitle ?? " ")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func queueThumb(for track: MediaItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            ArtworkImage(url: track.posterURL) {
                EmptyView()
            } fallback: {
                Image(systemName: "music.note").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

#if !SWIFT_PACKAGE // Previews need Xcode; SwiftPM builds skip them.
#Preview("Music mini-player") {
    @Previewable @State var time = 83.0
    @Previewable @State var scrubbing = false
    MusicPlayerLayout(
        item: MediaItem(id: "t1", source: .local, type: .music, kind: .track, title: "Sample Track", subtitle: "Sample Artist"),
        queue: (2...8).map {
            MediaItem(id: "t\($0)", source: .local, type: .music, kind: .track, title: "Queued Track \($0)", subtitle: "Sample Artist")
        },
        isPlaying: true,
        currentTime: $time,
        totalDuration: 214,
        isScrubbing: $scrubbing,
        onSeek: { _ in },
        onPlayPause: {},
        onNext: {},
        onPick: { _ in }
    )
    .frame(width: 340, height: 660)
}
#endif

// MARK: - Window pinning

/// Manages window-level settings: pin behavior, toolbar visibility (while maintaining size),
/// and video aspect ratio locking.
private struct WindowLevelAccessor: NSViewRepresentable {
    let isPinned: Bool
    var videoAspectRatio: CGFloat?
    var useCompactToolbar = true
    var chromeOverlaysContent = false
    var isPlaying = false
    var chromeSuppressed = false
    var onChromeVisibilityChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> ToolbarVisibilityView {
        let view = ToolbarVisibilityView()
        view.fadesChrome = chromeOverlaysContent
        return view
    }

    func updateNSView(_ nsView: ToolbarVisibilityView, context: Context) {
        nsView.onChromeVisibilityChange = onChromeVisibilityChange
        nsView.isPlaying = isPlaying
        nsView.chromeSuppressed = chromeSuppressed
        let isPinned = isPinned
        let videoAspectRatio = videoAspectRatio
        let useCompactToolbar = useCompactToolbar
        let chromeOverlaysContent = chromeOverlaysContent
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if !window.collectionBehavior.contains(.fullScreenPrimary) {
                window.collectionBehavior.insert(.fullScreenPrimary)
            }
            // A window subtitle makes the toolbar title wrap onto a second
            // line, so keep it cleared.
            if !window.subtitle.isEmpty {
                window.subtitle = ""
            }
            guard !window.styleMask.contains(.fullScreen) else { return }
            // Only write when the value changes: this runs on every SwiftUI
            // update, and redundant window mutations mid-drag abort mouse
            // tracking in toolbar controls like the volume slider.
            let level: NSWindow.Level = isPinned ? .floating : .normal
            if window.level != level {
                window.level = level
            }
            let toolbarStyle: NSWindow.ToolbarStyle = useCompactToolbar ? .unifiedCompact : .unified
            if window.toolbarStyle != toolbarStyle {
                window.toolbarStyle = toolbarStyle
            }
            // Keep the titlebar permanently overlaying the content
            // (QuickTime-style) so chrome fades never change the window's
            // content geometry. Toggling this per-fade resized the window on
            // every mouse enter/exit, flickering the chrome and accumulating
            // letterbox space at small sizes.
            if chromeOverlaysContent {
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
                if !window.titlebarAppearsTransparent {
                    window.titlebarAppearsTransparent = true
                }
                // The plain window title is replaced by a principal toolbar
                // item that carries its own Liquid Glass pill.
                if window.titleVisibility != .hidden {
                    window.titleVisibility = .hidden
                }
            }
            if let videoAspectRatio {
                nsView.applyAspectRatio(videoAspectRatio)
            }
        }
    }
}

/// Fades the window chrome (toolbar, title, traffic lights) in on mouse
/// activity and back out after a short idle delay, and keeps the content
/// area sized to the video's aspect ratio. The chrome overlays the content
/// rather than occupying its own strip, so showing and hiding it never
/// moves or resizes the window.
private class ToolbarVisibilityView: NSView {
    private var aspectRatio: CGFloat?
    private var trackingArea: NSTrackingArea?
    private weak var trackedContentView: NSView?
    private var chromeHidden = false
    private var autoHideTask: Task<Void, Never>?

    /// Off when the titlebar sits above the content (music): moving onto it
    /// counts as leaving the content view, which would hide it under the mouse.
    var fadesChrome = true

    /// Reports chrome visibility so SwiftUI overlays (the PiP-style
    /// controls) can fade in sync with the toolbar.
    var onChromeVisibilityChange: ((Bool) -> Void)?

    /// While paused the chrome stays visible; auto-hide only runs during
    /// playback.
    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            if isPlaying {
                if !chromeHidden {
                    scheduleAutoHide()
                }
            } else {
                autoHideTask?.cancel()
                setChromeHidden(false, animated: true)
            }
        }
    }

    /// Tiny (PiP-style) mode: the titlebar - traffic lights included -
    /// stays hidden outright while the SwiftUI overlay supplies its own
    /// close/pin controls. The hover state machine keeps running so the
    /// overlay still fades via onChromeVisibilityChange.
    var chromeSuppressed = false {
        didSet {
            guard chromeSuppressed != oldValue else { return }
            applyTitlebarState(animated: true)
        }
    }

    /// How long the chrome stays up after the last mouse movement.
    private static let chromeAutoHideDelay: Duration = .seconds(3)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeTracking()
        guard let window = self.window, let contentView = window.contentView else { return }

        // Like AVKit's floating controls, the chrome shows on mouse movement
        // (regardless of key status) and fades out again after a short idle
        // delay.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        contentView.addTrackingArea(area)
        trackingArea = area
        trackedContentView = contentView

        let mouseInWindow = contentView.bounds.contains(
            contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        )
        if mouseInWindow {
            showChrome()
        } else {
            setChromeHidden(true, animated: false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        showChrome()
    }

    override func mouseMoved(with event: NSEvent) {
        showChrome()
    }

    override func mouseExited(with event: NSEvent) {
        autoHideTask?.cancel()
        // Keep the chrome up while paused so the controls stay reachable.
        guard isPlaying else { return }
        setChromeHidden(true, animated: true)
    }

    private func showChrome() {
        setChromeHidden(false, animated: true)
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard isPlaying else { return }
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.chromeAutoHideDelay)
            guard !Task.isCancelled else { return }
            self?.setChromeHidden(true, animated: true)
        }
    }

    /// Constrains the window's content area to the video ratio and snaps
    /// the current size to match. The min/max limits are re-asserted on
    /// every call (not just ratio changes): SwiftUI also derives window
    /// limits from the root view's frame bounds, and if its non-conforming
    /// minimum won, the window could shrink out of ratio and letterbox the
    /// video.
    func applyAspectRatio(_ ratio: CGFloat) {
        guard let window = self.window else { return }
        aspectRatio = ratio
        let contentRatio = NSSize(width: ratio, height: 1.0)
        if window.contentAspectRatio != contentRatio {
            window.contentAspectRatio = contentRatio
        }
        let minSide: CGFloat = 320
        let minSize = ratio >= 1
            ? NSSize(width: minSide, height: (minSide / ratio).rounded())
            : NSSize(width: (minSide * ratio).rounded(), height: minSide)
        if window.contentMinSize != minSize {
            window.contentMinSize = minSize
        }
        let maxSide: CGFloat = 1920
        let maxSize = ratio >= 1
            ? NSSize(width: maxSide, height: (maxSide / ratio).rounded())
            : NSSize(width: (maxSide * ratio).rounded(), height: maxSide)
        if window.contentMaxSize != maxSize {
            window.contentMaxSize = maxSize
        }
        snapToAspectRatio()
    }

    /// Fades the titlebar container (toolbar, title, and traffic lights in
    /// one view) rather than toggling toolbar visibility or the style mask:
    /// those change the content geometry, which re-triggers the mouse
    /// tracking and resizes the window - the source of the chrome flicker
    /// and the letterbox space that drifted in at small sizes.
    private func setChromeHidden(_ hidden: Bool, animated: Bool) {
        guard let window = self.window, !window.styleMask.contains(.fullScreen) else { return }
        guard hidden != chromeHidden, fadesChrome || !hidden else { return }
        chromeHidden = hidden
        if let onChromeVisibilityChange {
            let visible = !hidden
            // Deferred because this can run inside a SwiftUI update pass
            // (via viewDidMoveToWindow), where writing @State is not allowed.
            DispatchQueue.main.async { onChromeVisibilityChange(visible) }
        }
        applyTitlebarState(animated: animated)
    }

    /// The titlebar tracks the chrome state, except while suppressed
    /// (tiny mode) where it stays hidden regardless.
    private func applyTitlebarState(animated: Bool) {
        guard let window = self.window, !window.styleMask.contains(.fullScreen) else { return }
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview else { return }
        let hidden = chromeHidden || chromeSuppressed
        let targetAlpha: CGFloat = hidden ? 0 : 1
        guard titlebar.alphaValue != targetAlpha || titlebar.isHidden != hidden else { return }
        // isHidden tracks the fade so invisible chrome can't swallow clicks.
        if animated {
            if !hidden {
                titlebar.isHidden = false
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                titlebar.animator().alphaValue = targetAlpha
            }, completionHandler: { [weak self] in
                if let self, self.chromeHidden || self.chromeSuppressed {
                    titlebar.isHidden = true
                }
            })
        } else {
            titlebar.alphaValue = targetAlpha
            titlebar.isHidden = hidden
        }
    }

    /// Resizes the content area to match the video ratio, keeping the current
    /// width. No-ops when already conforming, so it is safe to call on every
    /// update.
    private func snapToAspectRatio() {
        guard let aspectRatio,
              let window = self.window,
              !window.styleMask.contains(.fullScreen) else { return }
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        let targetHeight = (contentSize.width / aspectRatio).rounded()
        guard abs(contentSize.height - targetHeight) > 1 else { return }
        window.setContentSize(NSSize(width: contentSize.width, height: targetHeight))
    }

    private func removeTracking() {
        autoHideTask?.cancel()
        autoHideTask = nil
        if let trackingArea, let trackedContentView {
            trackedContentView.removeTrackingArea(trackingArea)
        }
        trackingArea = nil
        trackedContentView = nil
    }

    deinit {
        removeTracking()
    }
}

/// Transparent overlay over the VLC video that maps single clicks to
/// play/pause and double clicks to fullscreen toggle.
private struct VideoClickCapture: NSViewRepresentable {
    let onSingleClick: () -> Void

    func makeCoordinator() -> VideoClickHandler {
        VideoClickHandler(onSingleClick: onSingleClick)
    }

    func makeNSView(context: Context) -> ClickCaptureView {
        let view = ClickCaptureView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: ClickCaptureView, context: Context) {
        context.coordinator.onSingleClick = onSingleClick
    }
}

/// Single click toggles play/pause, double click toggles fullscreen.
private final class VideoClickHandler: NSObject, NSGestureRecognizerDelegate {
    var onSingleClick: () -> Void
    private weak var singleTap: NSClickGestureRecognizer?
    private weak var doubleTap: NSClickGestureRecognizer?

    init(onSingleClick: @escaping () -> Void) {
        self.onSingleClick = onSingleClick
    }

    func install(on view: NSView) {
        let doubleTap = NSClickGestureRecognizer(target: self, action: #selector(handleDouble(_:)))
        doubleTap.numberOfClicksRequired = 2
        doubleTap.delegate = self
        view.addGestureRecognizer(doubleTap)

        let singleTap = NSClickGestureRecognizer(target: self, action: #selector(handleSingle(_:)))
        singleTap.numberOfClicksRequired = 1
        singleTap.delegate = self
        view.addGestureRecognizer(singleTap)

        self.singleTap = singleTap
        self.doubleTap = doubleTap
    }

    @objc private func handleSingle(_ r: NSClickGestureRecognizer) { onSingleClick() }

    @objc private func handleDouble(_ r: NSClickGestureRecognizer) {
        r.view?.window?.toggleFullScreen(nil)
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRequireFailureOf other: NSGestureRecognizer
    ) -> Bool {
        gestureRecognizer === singleTap && other === doubleTap
    }
}

private class ClickCaptureView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
