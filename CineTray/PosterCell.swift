import SwiftUI

/// One cell in the carousel: artwork with title and subtitle, or a compact
/// text box when Show Posters is off. Selected cells (open drill-down
/// containers) get an accent border.
struct PosterCell: View {
    let item: MediaItem
    var isSelected = false
    var isCompact = false
    /// Show an episode by its show's poster and name, with "S1E2 - Title"
    /// underneath (Continue Watching).
    var presentsEpisodesByShow = false
    let action: () -> Void

    @Environment(AppState.self) private var appState
    @AppStorage(SettingsKeys.simpleVisuals) private var simpleVisuals = false
    @AppStorage(SettingsKeys.richMedia) private var richMedia = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering = false
    @State private var showingInfo = false

    private var cellWidth: CGFloat {
        isCompact ? MediaCarouselView.compactCellWidth : MediaCarouselView.baseCellWidth
    }

    private var cellHeight: CGFloat {
        item.posterHeight(byShow: presentsEpisodesByShow) * (isCompact ? MediaCarouselView.compactCellWidth / MediaCarouselView.baseCellWidth : 1)
    }

    private var showsByShow: Bool {
        presentsEpisodesByShow && item.showPosterURL != nil
    }

    private var displayTitle: String {
        if appState.tvTopLevel == .season, item.kind == .season {
            return item.parentTitle ?? item.subtitle ?? item.title
        }
        if showsByShow, let show = item.attributes["grandparentTitle"], !show.isEmpty {
            return show
        }
        return item.title
    }

    private var displaySubtitle: String? {
        if appState.tvTopLevel == .season, item.kind == .season {
            return item.title
        }
        if showsByShow {
            return [item.subtitle, item.title].compactMap { $0 }.joined(separator: " - ")
        }
        return item.subtitle
    }

    var body: some View {
        Button(action: action) {
            if simpleVisuals {
                compactBox
                    .overlay(alignment: .bottomTrailing) { DownloadButton(item: item, isCompact: isCompact) }
                    .overlay(alignment: .topLeading) { infoButton }
                    .overlay(alignment: .topTrailing) { openInWebAppButton }
                    .overlay(alignment: .topTrailing) { watchedBadge }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    poster
                        .overlay(alignment: .bottomTrailing) { DownloadButton(item: item, isCompact: isCompact) }
                        .overlay(alignment: .topLeading) { infoButton }
                        .overlay(alignment: .topTrailing) { openInWebAppButton }
                        .overlay(alignment: .topTrailing) { watchedBadge }
                    HStack(spacing: 3) {
                        MarqueeText(text: displayTitle, font: titleFont)
                        downloadedMark
                    }
                    MarqueeText(text: displaySubtitle ?? " ", font: isCompact ? .system(size: 9) : .caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: cellWidth)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !item.kind.isExpandable {
                Button("Play from Beginning", systemImage: "arrow.counterclockwise") {
                    appState.startOverItemID = item.id
                    action()
                }
            }
            if let name = item.source.webAppName {
                Button("Open in \(name)", systemImage: "arrow.up.forward.square") { appState.openInWebApp(item) }
            }
            if showsInfo {
                Button("Info", systemImage: "info.circle") { showingInfo = true }
            }
            // Only Continue presents episodes by show. Plex and Jellyfin keep
            // their own list, which would bring the item back.
            if presentsEpisodesByShow, !item.source.keepsWatchState {
                Button("Remove from Continue", systemImage: "xmark.circle") { appState.removeFromContinue(item) }
            }
            Section {
                DownloadButton(item: item, isCompact: isCompact, inMenu: true)
                removeDownloadButton
            }
        }
        .scaleEffect(isHovering && !reduceMotion ? 1.04 : 1)
        .animation(.snappy(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .help(item.title)
        .accessibilityValue(item.watchedFraction.map { "\(Int($0 * 100))% watched" } ?? "")
        .accessibilityActions {
            if let name = item.source.webAppName {
                Button("Open in \(name)") { appState.openInWebApp(item) }
            }
        }
    }

    @ViewBuilder
    private var removeDownloadButton: some View {
        if item.kind != .playlist, DownloadManager.shared.isDownloaded(item),
           !DownloadManager.shared.downloadingIDs.contains(item.id) {
            Button("Remove Download", systemImage: "trash", role: .destructive) {
                // Offline sections list downloads, so the removed item has to go.
                if DownloadManager.shared.removeDownload(item), appState.isOfflineMode {
                    for section in appState.itemsBySection.keys {
                        Task { await appState.load(section, force: true) }
                    }
                }
            }
        }
    }

    /// Opens the item in Plex or Jellyfin, so the collection can be browsed
    /// here and watched there. Shown on hover to keep posters clean; the
    /// context menu and VoiceOver actions have it too.
    @ViewBuilder
    private var openInWebAppButton: some View {
        if isHovering, let name = item.source.webAppName {
            Button("Open in \(name)", systemImage: "arrow.up.forward.circle.fill") {
                appState.openInWebApp(item)
            }
            .buttonStyle(PosterControlStyle())
            .font(.system(size: isCompact ? 10 : 14))
            .help("Open in \(name)")
        }
    }

    /// Next to the title rather than on the artwork, where no color stays
    /// visible on every poster. It also can't be confused with the Download
    /// button, which disappears once the item is downloaded.
    @ViewBuilder
    private var downloadedMark: some View {
        if DownloadManager.shared.isDownloaded(item) {
            Image(systemName: "arrow.down.circle.fill")
                .font(titleFont)
                .foregroundStyle(.green)
                .help("Downloaded")
                .accessibilityLabel("Downloaded")
        }
    }

    private var titleFont: Font {
        isCompact ? .system(size: 11) : .caption
    }

    /// White on a dark disc, like the other poster controls. Hidden while
    /// hovering, when the Open in Plex/Jellyfin button takes its corner.
    @ViewBuilder
    private var watchedBadge: some View {
        if item.isWatched == true, !isHovering {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, .black.opacity(0.55))
                .font(.system(size: isCompact ? 10 : 14))
                .frame(width: 20, height: 20)
                .help("Watched")
                .accessibilityLabel("Watched")
        }
    }

    /// Thin bar along the bottom edge showing how far a partly watched item got.
    @ViewBuilder
    private var watchProgressBar: some View {
        if let fraction = item.watchedFraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
                .allowsHitTesting(false)
                // An accessible ProgressView inside the Button's label replaces the
                // button for VoiceOver, so the fraction is the button's value instead.
                .accessibilityHidden(true)
        }
    }

    private var showsInfo: Bool {
        richMedia && item.summary != nil && item.kind != .track && item.kind != .playlist
    }

    @ViewBuilder
    private var infoButton: some View {
        if showsInfo {
            Button("Info", systemImage: "info.circle.fill") {
                showingInfo = true
            }
            .buttonStyle(PosterControlStyle())
            .font(.system(size: isCompact ? 10 : 14))
            .popover(isPresented: $showingInfo, arrowEdge: .trailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title)
                            .bold()
                        if let summary = item.summary {
                            Text(summary)
                        }
                    }
                    .padding()
                }
                .frame(width: 280, height: 200)
            }
        }
    }

    private var compactBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(displayTitle)
                    .font(titleFont)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                downloadedMark
            }
            Text(displaySubtitle ?? " ")
                .font(isCompact ? .system(size: 9) : .caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding([.top, .horizontal], 6)
        .padding(.bottom, 10) // room for the watch progress bar
        .frame(width: cellWidth, alignment: .topLeading)
        .background(isHovering ? .tertiary : .quaternary,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) { watchProgressBar }
        .overlay {
            if let progress = DownloadManager.shared.downloadProgress[item.id] {
                Color.black.opacity(0.4)
                    .mask(alignment: .top) {
                        GeometryReader { geo in
                            Rectangle()
                                .frame(height: geo.size.height * (1.0 - CGFloat(progress)))
                        }
                    }
                    .animation(.linear, value: progress)
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
            ArtworkImage(url: showsByShow ? item.showPosterURL : item.posterURL) {
                ProgressView()
                    .controlSize(.small)
            } fallback: {
                Image(systemName: item.kind == .playlist ? "music.note.list" : "questionmark.square.dashed")
                    .font(isCompact ? .title : .largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: cellWidth, height: cellHeight)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .bottom) { watchProgressBar }
        .overlay {
            if let progress = DownloadManager.shared.downloadProgress[item.id] {
                Color.black.opacity(0.65)
                    .mask(alignment: .top) {
                        GeometryReader { geo in
                            Rectangle()
                                .frame(height: geo.size.height * (1.0 - CGFloat(progress)))
                        }
                    }
                    .animation(.linear, value: progress)
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if isHovering {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.35))
                Image(systemName: item.kind.isExpandable ? "square.stack.fill" : "play.circle.fill")
                    .font(.system(size: isCompact ? 22 : 32))
                    .foregroundStyle(.white)
            }
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 2.5)
            }
        }
    }
}


/// A text view that automatically scrolls horizontally back and forth if its
/// content is wider than its container. With Reduce Motion on, it truncates
/// instead.
struct MarqueeText: View {
    let text: String
    let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0

    var body: some View {
        if reduceMotion {
            Text(text)
                .font(font)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            marquee
        }
    }

    private var marquee: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden() // Establish height and intrinsic max width
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { container in
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .fixedSize()
                        .background(GeometryReader { content in
                            Color.clear
                                .onAppear { startAnimation(containerWidth: container.size.width, contentWidth: content.size.width) }
                                .onChange(of: text) { _, _ in
                                    offset = 0
                                    startAnimation(containerWidth: container.size.width, contentWidth: content.size.width)
                                }
                        })
                        .offset(x: offset)
                }
                .clipped()
            }
    }
    
    private func startAnimation(containerWidth: CGFloat, contentWidth: CGFloat) {
        let diff = contentWidth - containerWidth
        guard diff > 0 else {
            offset = 0
            return
        }
        let duration = Double(diff) * 0.04
        withAnimation(.linear(duration: duration).delay(1.5).repeatForever(autoreverses: true)) {
            offset = -diff
        }
    }
}

/// The download control on a poster. Its own view so @AppStorage can watch the
/// setting for this item's kind, which is only known at runtime; the poster
/// then updates as soon as the checkbox changes in Settings.
private struct DownloadButton: View {
    let item: MediaItem
    let isCompact: Bool
    /// Plain menu items for the poster's context menu.
    var inMenu = false

    @Environment(AppState.self) private var appState
    @AppStorage(SettingsKeys.downloadsEnabled) private var downloadsEnabled = false
    @AppStorage private var levelEnabled: Bool

    init(item: MediaItem, isCompact: Bool, inMenu: Bool = false) {
        self.item = item
        self.isCompact = isCompact
        self.inMenu = inMenu
        _levelEnabled = AppStorage(wrappedValue: false, SettingsKeys.downloadLevelEnabled(DownloadLevel(kind: item.kind)))
    }

    var body: some View {
        if downloadsEnabled, levelEnabled, inMenu {
            if DownloadManager.shared.downloadingIDs.contains(item.id) {
                Button("Stop Download", systemImage: "stop.circle") { DownloadManager.shared.cancelDownload(item) }
            } else if !DownloadManager.shared.isDownloaded(item) {
                Button("Download", systemImage: "arrow.down.circle") { DownloadManager.shared.download(item, appState: appState) }
            }
        } else if downloadsEnabled, levelEnabled {
            Group {
                if DownloadManager.shared.downloadingIDs.contains(item.id) {
                    Button("Stop download", systemImage: "stop.circle.fill") {
                        DownloadManager.shared.cancelDownload(item)
                    }
                    .buttonStyle(PosterControlStyle())
                    .help("Stop download")
                } else if !DownloadManager.shared.isDownloaded(item) {
                    Button("Download for offline use", systemImage: "arrow.down.circle.fill") {
                        DownloadManager.shared.download(item, appState: appState)
                    }
                    .buttonStyle(PosterControlStyle())
                    .help("Download for offline use")
                }
            }
            .font(.system(size: isCompact ? 10 : 14))
        }
    }
}

/// The icon buttons on a poster's corners: white on a dark disc, with a
/// 20 pt click target, the HIG minimum, which still fits a compact poster.
/// The disc darkens and grows under the pointer.
struct PosterControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Control(configuration: configuration)
    }

    // A ButtonStyle can't hold @State, so hover is tracked in a view.
    private struct Control: View {
        let configuration: Configuration

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .foregroundStyle(.white, .black.opacity(isHovering ? 0.85 : 0.55))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
                .scaleEffect(isHovering && !reduceMotion ? 1.1 : 1)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .animation(.snappy(duration: 0.15), value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}
