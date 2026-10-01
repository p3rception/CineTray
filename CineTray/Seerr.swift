import SwiftUI

/// Seerr's media status codes, for titles and for seasons.
enum SeerrStatus: Int {
    case unknown = 1, pending, processing, partiallyAvailable, available, blocklisted, deleted

    var label: String? {
        switch self {
        case .pending, .processing: "Requested"
        case .partiallyAvailable: "Partly available"
        case .available: "Available"
        case .unknown, .blocklisted, .deleted: nil
        }
    }
}

/// A movie or show found in Seerr. `id` is the TMDb ID.
struct SeerrTitle: Decodable {
    struct MediaInfo: Decodable { let status: Int }

    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let releaseDate: String?
    let firstAirDate: String?
    let posterPath: String?
    let mediaInfo: MediaInfo?

    /// TMDb IDs of movies and shows overlap.
    var key: String { "\(mediaType)-\(id)" }
    var isShow: Bool { mediaType == "tv" }
    var displayTitle: String { title ?? name ?? "" }
    var status: SeerrStatus? { mediaInfo.flatMap { SeerrStatus(rawValue: $0.status) } }

    var subtitle: String {
        let year = String((releaseDate ?? firstAirDate ?? "").prefix(4))
        return [year, isShow ? "Show" : "Movie"].filter { !$0.isEmpty }.joined(separator: " - ")
    }
}

struct SeerrSeason {
    let number: Int
    let episodeCount: Int?
    /// Nil when the season can still be requested.
    let status: SeerrStatus?
}

extension ArrClient {
    func search(_ query: String) async throws -> [SeerrTitle] {
        struct Page: Decodable { let results: [SeerrTitle] }
        return try await send("api/v1/search", query: [URLQueryItem(name: "query", value: query)], as: Page.self).results
    }

    /// A show's seasons without specials, which Seerr doesn't request by default.
    func seasons(ofShow id: Int) async throws -> [SeerrSeason] {
        struct Show: Decodable {
            struct Season: Decodable {
                let seasonNumber: Int
                let episodeCount: Int?
            }
            struct SeasonStatus: Decodable {
                let seasonNumber: Int
                let status: Int
            }
            struct Request: Decodable {
                let status: Int
                let seasons: [SeasonStatus]?
            }
            struct MediaInfo: Decodable {
                let seasons: [SeasonStatus]?
                let requests: [Request]?
            }
            let seasons: [Season]
            let mediaInfo: MediaInfo?
        }
        let show = try await send("api/v1/tv/\(id)", as: Show.self)
        var statuses: [Int: SeerrStatus] = [:]
        // A season waiting for approval only shows up in its request, which
        // counts unless it was declined (3) or failed (4).
        for request in show.mediaInfo?.requests ?? [] where ![3, 4].contains(request.status) {
            for season in request.seasons ?? [] {
                statuses[season.seasonNumber] = .pending
            }
        }
        for season in show.mediaInfo?.seasons ?? [] {
            if let status = SeerrStatus(rawValue: season.status), status.label != nil {
                statuses[season.seasonNumber] = status
            }
        }
        return show.seasons.filter { $0.seasonNumber > 0 }.map {
            SeerrSeason(number: $0.seasonNumber, episodeCount: $0.episodeCount, status: statuses[$0.seasonNumber])
        }
    }

    /// Requests a movie, or the given seasons of a show.
    func request(_ title: SeerrTitle, seasons: [Int]? = nil) async throws {
        struct Body: Encodable {
            let mediaType: String
            let mediaId: Int
            let seasons: [Int]?
        }
        let body = try JSONEncoder().encode(Body(mediaType: title.mediaType, mediaId: title.id, seasons: seasons))
        _ = try await send("api/v1/request", body: body, as: Ignored.self)
    }
}

private func seerrMessage(for error: Error) -> String {
    (error as? ArrClient.ServerError)?.message ?? "Seerr: \(error.localizedDescription)"
}

/// Search results from Seerr that aren't in a library yet, as a poster row
/// under the library results. Clicking a poster reveals its Request button.
struct SeerrSearchRow: View {
    let query: String

    @AppStorage(SettingsKeys.seerrURL) private var seerrURL = ""
    @AppStorage(SettingsKeys.carouselVisibleCount) private var visibleCount = 3
    @State private var titles: [SeerrTitle] = []
    @State private var error: String?
    @State private var isSearching = false
    @State private var revealedKey: String?
    /// Requested from here; marked until the next search brings Seerr's own status.
    @State private var requestedKeys: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isSearching || error != nil || !titles.isEmpty {
                Divider()
                header
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 12)
                } else if !titles.isEmpty {
                    carousel
                        .padding(.bottom, 10)
                }
            }
        }
        .task(id: query) { await search() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "plus.rectangle.on.rectangle")
                .frame(width: 20)
            Text("Seerr")
            Spacer()
            if isSearching {
                ProgressView()
                    .controlSize(.mini)
            } else if error == nil {
                Text("\(titles.count)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var carousel: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: MediaCarouselView.spacing) {
                ForEach(titles, id: \.key) { title in
                    SeerrPosterCell(
                        title: title,
                        pageURL: URL(string: seerrURL)?.appending(path: "\(title.isShow ? "tv" : "movie")/\(title.id)"),
                        isRequested: requestedKeys.contains(title.key),
                        isRevealed: Binding { revealedKey == title.key } set: { revealedKey = $0 ? title.key : nil }
                    ) {
                        requestedKeys.insert(title.key)
                        revealedKey = nil
                    }
                }
            }
            .padding(.vertical, MediaCarouselView.hoverInset)
            .scrollTargetLayout()
        }
        .frame(height: 165 + 30 + MediaCarouselView.hoverInset * 2)
        .scrollClipDisabled()
        .scrollTargetBehavior(.viewAligned)
        .frame(width: MediaCarouselView.carouselWidth(for: visibleCount))
        .frame(maxWidth: .infinity)
    }

    private func search() async {
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        guard let client = ArrClient.configured(.seerr) else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await client.search(query)
            guard !Task.isCancelled else { return }
            // Available titles are already in the library rows above, and
            // blocklisted ones can't be requested.
            titles = found.filter { title in
                (title.mediaType == "movie" || title.isShow) && title.status != .available && title.status != .blocklisted
            }
            requestedKeys = []
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            titles = []
            self.error = seerrMessage(for: error)
        }
    }
}

private struct SeerrPosterCell: View {
    let title: SeerrTitle
    let pageURL: URL?
    let isRequested: Bool
    @Binding var isRevealed: Bool
    let onRequested: () -> Void

    @State private var isHovering = false
    @State private var step = RequestStep.start
    @State private var error: String?
    @State private var showsSeasons = false

    private enum RequestStep { case start, confirm, sending, done }

    private let width = MediaCarouselView.baseCellWidth
    private let height: CGFloat = 165

    private var status: SeerrStatus? {
        isRequested ? .pending : title.status
    }

    /// A requested movie has nothing left to ask for; a show may still have seasons.
    private var canRequest: Bool {
        title.isShow || (status != .pending && status != .processing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isRevealed.toggle() }
            } label: {
                poster
            }
            .buttonStyle(.plain)
            .disabled(!canRequest)
            .accessibilityLabel(title.displayTitle)
            .accessibilityValue(status?.label ?? "")
            .accessibilityHint(canRequest ? "Shows the Request button" : "")
            .accessibilityActions {
                if let pageURL {
                    Button("Open in Seerr") { NSWorkspace.shared.open(pageURL) }
                }
            }
            .overlay {
                if isRevealed { requestControls }
            }
            .overlay(alignment: .topTrailing) { cornerControl }
            .popover(isPresented: $showsSeasons, arrowEdge: .trailing) {
                SeerrSeasonPicker(title: title, onRequested: showDone)
            }
            MarqueeText(text: title.displayTitle, font: .caption)
            MarqueeText(text: title.subtitle, font: .caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: width)
        // Scaling resamples the text on the poster, which then looks blurry.
        .scaleEffect(isHovering && !isRevealed ? 1.04 : 1)
        .animation(.snappy(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .help(title.displayTitle)
        .onChange(of: isRevealed) {
            error = nil
            step = .start
        }
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
            ArtworkImage(url: title.posterPath.flatMap(TMDbClient.posterURL(path:))) {
                ProgressView()
                    .controlSize(.small)
            } fallback: {
                Image(systemName: "questionmark.square.dashed")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        // Clipped before the blur, which otherwise fills in the rounded
        // corners with the artwork overflowing the frame.
        .clipped()
        .blur(radius: isRevealed ? 6 : 0, opaque: true)
        .overlay {
            if isRevealed { Color.black.opacity(0.3) }
        }
        .clipShape(.rect(cornerRadius: 8))
        .contentShape(.rect(cornerRadius: 8))
    }

    /// Clicks around the button reach the poster underneath, which hides it again.
    private var requestControls: some View {
        VStack(spacing: 6) {
            switch step {
            case .start:
                pill("Request", systemImage: "arrow.down.circle") {
                    if title.isShow { showsSeasons = true } else { step = .confirm }
                }
            case .confirm:
                pill("Confirm", systemImage: "checkmark", action: request)
            case .sending:
                ProgressView()
                    .controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                Text("Requested")
                    .font(.caption.weight(.semibold))
            }
            if let error {
                Text(error)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
        }
        .padding(8)
        // White on the darkened poster, like the other poster controls.
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    /// Open in Seerr while hovering, like Open in Plex on library posters,
    /// otherwise the request status.
    @ViewBuilder
    private var cornerControl: some View {
        if isHovering, let pageURL {
            Button("Open in Seerr", systemImage: "arrow.up.forward.circle.fill") {
                NSWorkspace.shared.open(pageURL)
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .foregroundStyle(.white, .black.opacity(0.55))
            .font(.system(size: 14))
            .padding(3)
            .help("Open in Seerr")
        } else if let label = status?.label {
            Image(systemName: status == .partiallyAvailable ? "circle.lefthalf.filled" : "clock")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(.black.opacity(0.55), in: .circle)
                .padding(2)
                .help(label)
                .accessibilityHidden(true)
        }
    }

    // Not glass: even clear glass frosts over the poster.
    private func pill(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(.black.opacity(0.2), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 1))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func request() {
        guard let client = ArrClient.configured(.seerr) else { return }
        step = .sending
        error = nil
        Task {
            do {
                try await client.request(title)
                showDone()
            } catch {
                self.error = seerrMessage(for: error)
                step = .start
            }
        }
    }

    /// Shows the checkmark briefly, then hands over to the Requested badge.
    private func showDone() {
        step = .done
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            onRequested()
        }
    }
}

/// A show's seasons to request. Seasons already requested or available are
/// listed with their status but can't be picked.
private struct SeerrSeasonPicker: View {
    let title: SeerrTitle
    let onRequested: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var seasons: [SeerrSeason]?
    @State private var selected: Set<Int> = []
    @State private var error: String?
    @State private var isSending = false

    private var open: [Int] {
        seasons?.filter { $0.status == nil }.map(\.number) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.displayTitle)
                .font(.headline)
            if let seasons {
                if open.isEmpty {
                    Text("Every season is requested or available.")
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("All seasons", isOn: Binding { selected.count == open.count } set: { selected = $0 ? Set(open) : [] })
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(seasons, id: \.number) { season in
                            seasonToggle(season)
                        }
                    }
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            } else if error == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(selected.isEmpty ? "Request" : "Request \(selected.count) \(selected.count == 1 ? "Season" : "Seasons")", action: request)
                    .disabled(selected.isEmpty || isSending)
            }
        }
        .padding(14)
        .frame(width: 260)
        .task { await load() }
    }

    private func seasonToggle(_ season: SeerrSeason) -> some View {
        Toggle(isOn: Binding {
            season.status != nil || selected.contains(season.number)
        } set: { isOn in
            if isOn { selected.insert(season.number) } else { selected.remove(season.number) }
        }) {
            HStack {
                Text("Season \(season.number)")
                Spacer()
                Text(season.status?.label ?? season.episodeCount.map { "\($0) episodes" } ?? "")
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(season.status != nil)
    }

    private func load() async {
        guard let client = ArrClient.configured(.seerr) else { return }
        do {
            seasons = try await client.seasons(ofShow: title.id)
        } catch {
            self.error = seerrMessage(for: error)
        }
    }

    private func request() {
        guard let client = ArrClient.configured(.seerr) else { return }
        isSending = true
        error = nil
        Task {
            defer { isSending = false }
            do {
                try await client.request(title, seasons: selected.sorted())
                onRequested()
                dismiss()
            } catch {
                self.error = seerrMessage(for: error)
            }
        }
    }
}
