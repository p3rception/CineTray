import SwiftUI

/// The first-run tour. It starts in the menu and, at the Settings step,
/// continues in the Settings window. Each step dims the window except the
/// control it explains, which stays usable, and shows a card with the step
/// number, Back, Next and Skip Tour. Not TipKit: its tips can't dim the
/// window or count steps, and it decides on its own when to show them.
enum TourStep: Int, CaseIterable {
    case browse, search, posters, offline, settings, libraries, player, downloads

    var title: String {
        switch self {
        case .browse: "Browse a library"
        case .search: "Search everything"
        case .posters: "More on right-click"
        case .offline: "Offline Mode"
        case .settings: "Settings"
        case .libraries: "Add your own media"
        case .player: "Choose a video player"
        case .downloads: "Watch offline"
        }
    }

    var message: String {
        switch self {
        case .browse: "Click a row to show its posters. Click a show or album to open it."
        case .search: "Type while the menu is open to search all your libraries at once."
        case .posters: "Right-click a poster to play it from the beginning, download it, or open it in Plex or Jellyfin."
        case .offline: "Plays only what you downloaded, without a connection."
        case .settings: "The tour continues in Settings."
        case .libraries: "Choose a folder of movies, shows or music, and it joins your libraries."
        case .player: "Play videos in IINA, VLC or another app. Only CineTray itself resumes and saves your progress."
        case .downloads: "Turn on downloads and choose a folder. Then click Download on a poster."
        }
    }

    /// The Settings tab the step is on, or nil for a step in the menu.
    var settingsTab: String? {
        switch self {
        case .libraries: "libraries"
        case .player: "playback"
        case .downloads: "data"
        default: nil
        }
    }
}

private struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourStep: [Anchor<CGRect>]] = [:]
    static func reduce(value: inout [TourStep: [Anchor<CGRect>]], nextValue: () -> [TourStep: [Anchor<CGRect>]]) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}

extension View {
    /// Marks a view that `step` highlights; nil marks nothing. A step that
    /// marks several views highlights the area around all of them.
    func tourAnchor(_ step: TourStep?) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { anchor in
            step.map { [$0: [anchor]] } ?? [:]
        }
    }

    /// Draws the tour over this view, for steps whose anchor is inside it.
    /// `onNext` replaces advancing, for a step that continues elsewhere.
    func tourOverlay(onNext: [TourStep: () -> Void] = [:]) -> some View {
        overlayPreferenceValue(TourAnchorKey.self) { anchors in
            TourOverlay(anchors: anchors, onNext: onNext)
        }
    }
}

private struct TourOverlay: View {
    let anchors: [TourStep: [Anchor<CGRect>]]
    let onNext: [TourStep: () -> Void]

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardHeight: CGFloat = 160

    var body: some View {
        GeometryReader { proxy in
            if let step = appState.tourStep, let marked = anchors[step]?.map({ proxy[$0] }),
               let first = marked.first {
                let hole = marked.reduce(first) { $0.union($1) }.insetBy(dx: -4, dy: -4)
                ZStack(alignment: .topLeading) {
                    // Clicks inside the hole reach the highlighted control.
                    HoleShape(hole: hole)
                        .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                        .contentShape(HoleShape(hole: hole), eoFill: true)
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: hole.width, height: hole.height)
                        .offset(x: hole.minX, y: hole.minY)
                        .allowsHitTesting(false)
                    let x = min(max(hole.midX, Self.cardWidth / 2 + 12), proxy.size.width - Self.cardWidth / 2 - 12)
                    card(for: step)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                        .offset(x: x - Self.cardWidth / 2, y: cardTop(around: hole, in: proxy.size.height))
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: step)
            }
        }
    }

    private static let cardWidth: CGFloat = 290

    /// Below the hole if the card fits there, else above. When neither fits,
    /// as for a tall row of posters in a short menu, it sits at the bottom of
    /// the window over part of the hole, so it is never cut off.
    private func cardTop(around hole: CGRect, in height: CGFloat) -> CGFloat {
        let gap: CGFloat = 12
        if height - hole.maxY - gap >= cardHeight { return hole.maxY + gap }
        if hole.minY - gap >= cardHeight { return hole.minY - gap - cardHeight }
        return max(height - cardHeight - gap, 0)
    }

    private func card(for step: TourStep) -> some View {
        let number = step.rawValue + 1
        let count = TourStep.allCases.count
        let isLast = step == TourStep.allCases.last
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(number) of \(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(step.title)
                .font(.headline)
            Text(step.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !isLast {
                    Button("Skip Tour") { appState.endTour() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                // Back can't cross from Settings into the closed menu.
                if step != .browse, step != .libraries {
                    Button("Back") { appState.moveTour(by: -1) }
                }
                Button(isLast ? "Done" : step == .settings ? "Open Settings" : "Next") {
                    if let action = onNext[step] { action() } else { appState.moveTour(by: 1) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: Self.cardWidth)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tour, step \(number) of \(count): \(step.title)")
    }
}

/// The whole area with a rounded hole, filled even-odd.
private struct HoleShape: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: 8, height: 8))
        return path
    }
}
