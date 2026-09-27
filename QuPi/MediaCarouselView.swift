import SwiftUI

/// Horizontal, swipeable poster carousel. Width and paging adapt to the
/// carouselVisibleCount preference (3–6 cells); height fits the tallest
/// poster kind present so mixed-content sections (Continue Watching) never clip.
struct MediaCarouselView: View {
    static let baseCellWidth: CGFloat = 110
    static let compactCellWidth: CGFloat = 76
    static let spacing: CGFloat = 10
    static let hoverInset: CGFloat = 6

    /// Width for a given number of visible cells - used by MenuBarContentView
    /// to size the overall dropdown width reactively.
    static func carouselWidth(for count: Int) -> CGFloat {
        baseCellWidth * CGFloat(count) + spacing * CGFloat(count - 1)
    }

    let items: [MediaItem]
    var selectedID: String?
    var navigationStep: Int?
    var nowPlayingItem: MediaItem?
    var isPlaying: Bool = false
    var isCompact: Bool = false
    /// Show episodes by their show's poster and name (Continue Watching).
    var presentsEpisodesByShow = false

    var onPlayPause: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    let onSelect: (MediaItem) -> Void

    @Environment(AppState.self) private var appState
    @AppStorage("carouselVisibleCount") private var visibleCount = 3
    @AppStorage(SettingsKeys.simpleVisuals) private var simpleVisuals = false
    @State private var scrolledUniqueID: String?

    var cellWidth: CGFloat {
        isCompact ? Self.compactCellWidth : Self.baseCellWidth
    }

    /// Tall enough for the tallest poster kind in this carousel plus the two
    /// text lines beneath it; short cells are vertically centered in this space.
    private var maxCellHeight: CGFloat {
        if simpleVisuals {
            return isCompact ? 54 : 62
        }
        
        let maxPoster = items.map { $0.posterHeight(byShow: presentsEpisodesByShow) }.max() ?? 110
        let scaledPoster = isCompact ? maxPoster * (Self.compactCellWidth / Self.baseCellWidth) : maxPoster
        return scaledPoster + (isCompact ? 26 : 30)
    }

    /// Index of the leading visible cell (0 when scrolledUniqueID is nil).
    private var scrolledIndex: Int {
        guard let uniqueID = scrolledUniqueID,
              let idx = items.firstIndex(where: { $0.uniqueID == uniqueID }) else { return 0 }
        return idx
    }

    private var effectiveNavigationStep: Int {
        navigationStep ?? visibleCount
    }

    private var canScrollLeft: Bool { scrolledIndex > 0 }
    private var canScrollRight: Bool { scrolledIndex + visibleCount < items.count }

    /// The item that shows the inline player overlay.
    /// Finds the exact item matching the currently playing track, or its parent (album/playlist).
    private var overlayItemID: String? {
        guard let nowPlaying = nowPlayingItem else { return nil }
        // Match the playing track directly, or - in the grouped Continue Watching
        // section - the album/playlist cell that contains it.
        let candidateIDs = [nowPlaying.id, nowPlaying.parentID].compactMap { $0 }
        return items.first(where: { candidateIDs.contains($0.id) })?.id
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .center, spacing: Self.spacing) {
                ForEach(items, id: \.uniqueID) { item in
                    let isNowPlaying = item.id == overlayItemID
                    ZStack(alignment: .top) {
                        PosterCell(item: item, isSelected: item.id == selectedID, isCompact: isCompact, presentsEpisodesByShow: presentsEpisodesByShow) {
                            onSelect(item)
                        }
                        if isNowPlaying, let onPlayPause {
                            InlinePlayerOverlay(
                                isPlaying: isPlaying,
                                progress: { [appState] in
                                    appState.totalDuration > 0 ? appState.currentTime / appState.totalDuration : 0
                                },
                                canGoPrevious: appState.hasInlineNeighbor(-1),
                                canGoNext: appState.hasInlineNeighbor(1),
                                onPlayPause: onPlayPause,
                                onPrevious: handlePrevious,
                                onNext: handleNext,
                                onScrub: { fraction in
                                    appState.seek(to: fraction * appState.totalDuration)
                                }
                            )
                            // Cover only the artwork, or the entire box if in simple visuals
                            .frame(
                                width: cellWidth,
                                height: simpleVisuals ? maxCellHeight : item.posterHeight(byShow: presentsEpisodesByShow) * (isCompact ? Self.compactCellWidth / Self.baseCellWidth : 1)
                            )
                        }
                    }
                }
            }
            .padding(.vertical, Self.hoverInset)
            .frame(minHeight: maxCellHeight)
            .scrollTargetLayout()
        }
        .frame(height: maxCellHeight + Self.hoverInset * 2)
        .scrollClipDisabled()
        .scrollPosition(id: $scrolledUniqueID)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .frame(width: MediaCarouselView.carouselWidth(for: visibleCount))
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            if canScrollLeft {
                pagingButton(systemImage: "chevron.compact.left", delta: -effectiveNavigationStep)
            }
        }
        .overlay(alignment: .trailing) {
            if canScrollRight {
                pagingButton(systemImage: "chevron.compact.right", delta: effectiveNavigationStep)
            }
        }
        .onChange(of: nowPlayingItem?.id) { _, newID in
            guard let newID, let index = items.firstIndex(where: { $0.id == newID }) else { return }
            let maxLeading = max(0, items.count - visibleCount)
            withAnimation(.snappy) {
                scrolledUniqueID = items[min(index, maxLeading)].uniqueID
            }
        }
    }

    private func pagingButton(systemImage: String, delta: Int) -> some View {
        Button {
            page(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: maxCellHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func page(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.uniqueID == scrolledUniqueID } ?? 0
        let target = min(max(current + delta, 0), items.count - 1)
        withAnimation(.snappy) {
            scrolledUniqueID = items[target].uniqueID
        }
    }

    private func handleNext() {
        guard let nowPlaying = nowPlayingItem,
              let index = items.firstIndex(where: { $0.id == nowPlaying.id }) else {
            onNext?()
            return
        }
        let maxLeading = max(0, items.count - visibleCount)
        withAnimation(.snappy) {
            scrolledUniqueID = items[min(index + 1, maxLeading)].uniqueID
        }
        onNext?()
    }

    private func handlePrevious() {
        guard let nowPlaying = nowPlayingItem,
              let index = items.firstIndex(where: { $0.id == nowPlaying.id }) else {
            onPrevious?()
            return
        }
        let maxLeading = max(0, items.count - visibleCount)
        withAnimation(.snappy) {
            scrolledUniqueID = items[min(max(index - 1, 0), maxLeading)].uniqueID
        }
        onPrevious?()
    }
}
