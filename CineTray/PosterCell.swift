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
                    MarqueeText(text: displayTitle, font: isCompact ? .system(size: 11) : .caption)
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
        }
        .scaleEffect(isHovering ? 1.04 : 1)
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

    /// Opens the item in Plex or Jellyfin, so the collection can be browsed
    /// here and watched there. Shown on hover to keep posters clean;
    /// VoiceOver gets it as an action on the poster instead.
    @ViewBuilder
    private var openInWebAppButton: some View {
        if isHovering, let name = item.source.webAppName {
            Button("Open in \(name)", systemImage: "arrow.up.forward.circle.fill") {
                appState.openInWebApp(item)
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .foregroundStyle(.white, .black.opacity(0.55))
            .font(.system(size: isCompact ? 10 : 14))
            .padding(isCompact ? 2 : 3)
            .help("Open in \(name)")
        }
    }

    /// White on a dark disc, like the other poster controls, so it isn't
    /// confused with the green Downloaded mark. Hidden while hovering, when
    /// the Open in Plex/Jellyfin button takes its corner.
    @ViewBuilder
    private var watchedBadge: some View {
        if item.isWatched == true, !isHovering {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, .black.opacity(0.55))
                .font(.system(size: isCompact ? 10 : 14))
                .padding(isCompact ? 2 : 3)
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

    @ViewBuilder
    private var infoButton: some View {
        let showsInfo = richMedia
            && item.summary != nil
            && item.kind != .track
            && item.kind != .playlist
        if showsInfo {
            Button("Info", systemImage: "info.circle.fill") {
                showingInfo = true
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .foregroundStyle(.white, .black.opacity(0.55))
            .font(.system(size: isCompact ? 10 : 14))
            .padding(isCompact ? 2 : 3)
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
            Text(displayTitle)
                .font(isCompact ? .system(size: 11) : .caption)
                .lineLimit(2, reservesSpace: true)
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
            if let url = showsByShow ? item.showPosterURL : item.posterURL {
                ArtworkImage(url: url) {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
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
/// content is wider than its container.
struct MarqueeText: View {
    let text: String
    let font: Font
    
    @State private var offset: CGFloat = 0
    
    var body: some View {
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

    @Environment(AppState.self) private var appState
    @AppStorage(SettingsKeys.downloadsEnabled) private var downloadsEnabled = false
    @AppStorage private var levelEnabled: Bool

    init(item: MediaItem, isCompact: Bool) {
        self.item = item
        self.isCompact = isCompact
        _levelEnabled = AppStorage(wrappedValue: false, SettingsKeys.downloadLevelEnabled(DownloadLevel(kind: item.kind)))
    }

    var body: some View {
        if downloadsEnabled, levelEnabled {
            Group {
                if DownloadManager.shared.downloadingIDs.contains(item.id) {
                    ProgressView()
                        .controlSize(.mini)
                } else if DownloadManager.shared.isDownloaded(item) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Downloaded")
                } else {
                    Button("Download for offline use", systemImage: "arrow.down.circle.fill") {
                        DownloadManager.shared.download(item, appState: appState)
                    }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .help("Download for offline use")
                }
            }
            .font(.system(size: isCompact ? 10 : 14))
            .padding(isCompact ? 2 : 3)
        }
    }
}
