import SwiftUI

/// Servers reached with an address and an API key, which hold nothing to
/// play: Radarr and Sonarr feed the release calendar, Seerr takes requests
/// from search.
enum ArrApp: String, CaseIterable, Identifiable {
    case radarr = "Radarr"
    case sonarr = "Sonarr"
    case seerr = "Seerr"

    var id: Self { self }
    var urlKey: String {
        switch self {
        case .radarr: SettingsKeys.radarrURL
        case .sonarr: SettingsKeys.sonarrURL
        case .seerr: SettingsKeys.seerrURL
        }
    }
    var apiKeyKey: String {
        switch self {
        case .radarr: KeychainKeys.radarrAPIKey
        case .sonarr: KeychainKeys.sonarrAPIKey
        case .seerr: KeychainKeys.seerrAPIKey
        }
    }
    var color: Color { self == .radarr ? .orange : .blue }
}

struct ArrRelease: Identifiable {
    let id: String
    let app: ArrApp
    let date: Date
    /// Movie release dates have no time of day; episode air times do.
    let hasTime: Bool
    let title: String
    let detail: String
    let isDownloaded: Bool
}

struct ArrClient {
    let app: ArrApp
    let serverURL: URL
    let apiKey: String

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func configured(_ app: ArrApp) -> ArrClient? {
        guard let url = UserDefaults.standard.string(forKey: app.urlKey).flatMap(URL.init(string:)),
              let apiKey = KeychainStore.string(for: app.apiKeyKey), !apiKey.isEmpty else { return nil }
        return ArrClient(app: app, serverURL: url, apiKey: apiKey)
    }

    private static let unreservedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Sends a GET, or a POST with `body` as JSON.
    func send<Response: Decodable>(_ path: String, query: [URLQueryItem] = [], body: Data? = nil, as _: Response.Type) async throws -> Response {
        var components = URLComponents(url: serverURL.appending(path: path), resolvingAgainstBaseURL: false)
        // Seerr rejects a search containing characters such as ' or ! unless
        // they are percent-encoded, which URLQueryItem leaves as they are.
        if !query.isEmpty {
            components?.percentEncodedQueryItems = query.map {
                URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: Self.unreservedCharacters))
            }
        }
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request, delegate: PlexTokenRedirectGuard.shared)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200, 201: return try JSONDecoder().decode(Response.self, from: data)
        // Seerr answers 403 to a wrong key.
        case 401, 403: throw ServerError(message: "\(app.rawValue) rejected the API key.")
        default:
            // Seerr explains refused requests, such as one that already exists.
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                throw ServerError(message: "\(app.rawValue): \(failure.message)")
            }
            throw URLError(.badServerResponse)
        }
    }

    private struct Failure: Decodable { let message: String }

    /// Decodes any JSON object, for responses whose content isn't needed.
    struct Ignored: Decodable {}

    func checkStatus() async throws {
        // Seerr's status endpoint doesn't need the key, so ask who it belongs to.
        _ = try await send(app == .seerr ? "api/v1/auth/me" : "api/v3/system/status", as: Ignored.self)
    }

    private struct Movie: Decodable {
        let id: Int
        let title: String
        let inCinemas: String?
        let digitalRelease: String?
        let physicalRelease: String?
        let hasFile: Bool?
    }

    private struct Episode: Decodable {
        struct Series: Decodable { let title: String }
        let id: Int
        let title: String?
        let seasonNumber: Int
        let episodeNumber: Int
        let airDateUtc: String?
        let hasFile: Bool?
        let series: Series?
    }

    /// Radarr sends release days as midnight UTC, which is the day before
    /// west of UTC, so only the date part is read, as a local day.
    private static let dayFormat = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()

    func releases(in range: Range<Date>) async throws -> [ArrRelease] {
        var query = [URLQueryItem(name: "start", value: range.lowerBound.ISO8601Format()),
                     URLQueryItem(name: "end", value: range.upperBound.ISO8601Format())]
        switch app {
        case .radarr:
            // A movie is listed when any of its dates is in range, so each date is checked.
            return try await send("api/v3/calendar", query: query, as: [Movie].self).flatMap { movie in
                [("In Cinemas", movie.inCinemas), ("Digital Release", movie.digitalRelease), ("Physical Release", movie.physicalRelease)]
                    .compactMap { label, value -> ArrRelease? in
                        guard let value, let date = try? Date(String(value.prefix(10)), strategy: Self.dayFormat),
                              range.contains(date) else { return nil }
                        return ArrRelease(id: "radarr-\(movie.id)-\(label)", app: .radarr, date: date, hasTime: false,
                                          title: movie.title, detail: label, isDownloaded: movie.hasFile ?? false)
                    }
            }
        case .sonarr:
            query.append(URLQueryItem(name: "includeSeries", value: "true"))
            return try await send("api/v3/calendar", query: query, as: [Episode].self).compactMap { episode in
                guard let date = episode.airDateUtc.flatMap({ try? Date($0, strategy: .iso8601) }) else { return nil }
                let number = "S\(episode.seasonNumber)E\(episode.episodeNumber)"
                return ArrRelease(id: "sonarr-\(episode.id)", app: .sonarr, date: date, hasTime: true,
                                  title: episode.series?.title ?? episode.title ?? number,
                                  detail: [number, episode.title].compactMap { $0 }.joined(separator: " "),
                                  isDownloaded: episode.hasFile ?? false)
            }
        case .seerr:
            return []
        }
    }
}

/// The menu's calendar pane: a month grid with a dot per app on days with
/// releases, and the releases of the selected day and the six after it.
struct ReleaseCalendarView: View {
    @Environment(\.appearsActive) private var appearsActive

    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var releases: [ArrRelease] = []
    @State private var errors: [String] = []
    @State private var isLoading = false

    private let calendar = Calendar.current
    private let agendaDays = 7

    private var gridDays: [Date] {
        let start = calendar.dateInterval(of: .weekOfMonth, for: month)?.start ?? month
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        let byDay = Dictionary(grouping: releases) { calendar.startOfDay(for: $0.date) }
        VStack(alignment: .leading, spacing: 8) {
            monthBar
            grid(byDay: byDay)
            ForEach(errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            agenda(byDay: byDay)
        }
        .padding(12)
        // Reloads each time the menu opens and when the month changes.
        .task(id: appearsActive ? month : nil) {
            if appearsActive { await load() }
        }
    }

    private var monthBar: some View {
        HStack(spacing: 12) {
            Text(month, format: .dateTime.month(.wide).year())
                .font(.headline)
            if isLoading {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Button("Previous Month", systemImage: "chevron.left") { showMonth(offset: -1) }
            Button("Today", systemImage: "circle.fill") {
                month = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
                selectedDay = calendar.startOfDay(for: .now)
            }
            .imageScale(.small)
            Button("Next Month", systemImage: "chevron.right") { showMonth(offset: 1) }
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .foregroundStyle(.secondary)
    }

    private func showMonth(offset: Int) {
        guard let next = calendar.date(byAdding: .month, value: offset, to: month) else { return }
        month = next
        selectedDay = next
    }

    private func grid(byDay: [Date: [ArrRelease]]) -> some View {
        let days = gridDays
        return Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<(days.count / 7), id: \.self) { week in
                GridRow {
                    ForEach(days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
                        dayCell(day, releases: byDay[day] ?? [])
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date, releases: [ArrRelease]) -> some View {
        let isToday = calendar.isDateInToday(day)
        let apps = ArrApp.allCases.filter { app in releases.contains { $0.app == app } }
        return Button { selectedDay = day } label: {
            VStack(spacing: 2) {
                Text(day, format: .dateTime.day())
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .foregroundStyle(calendar.isDate(day, equalTo: month, toGranularity: .month) ? .primary : .tertiary)
                HStack(spacing: 2) {
                    ForEach(apps) { app in
                        Circle().fill(app.color).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(day == selectedDay ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if isToday { RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(day, format: .dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityValue(releases.isEmpty ? "" : "\(releases.count) releases")
    }

    private func agenda(byDay: [Date: [ArrRelease]]) -> some View {
        let days = (0..<agendaDays).compactMap { calendar.date(byAdding: .day, value: $0, to: selectedDay) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(days, id: \.self) { day in
                    let dayReleases = (byDay[day] ?? []).sorted { ($0.date, $0.title) < ($1.date, $1.title) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(dayTitle(day))
                            Spacer()
                            Text(day, format: .dateTime.month(.abbreviated).day())
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(dayReleases.isEmpty ? .tertiary : .primary)
                        ForEach(dayReleases) { release in
                            releaseRow(release)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }

    private func dayTitle(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide))
    }

    private func releaseRow(_ release: ArrRelease) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(release.app.color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(release.title)
                    .lineLimit(1)
                Text(release.hasTime
                     ? "\(release.detail), \(release.date.formatted(date: .omitted, time: .shortened))"
                     : release.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if release.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Downloaded")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        let days = gridDays
        guard let start = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: agendaDays, to: last) else { return }
        isLoading = true
        defer { isLoading = false }
        var loaded: [ArrRelease] = []
        var failures: [String] = []
        await withTaskGroup(of: (ArrApp, Result<[ArrRelease], Error>).self) { group in
            for client in ArrApp.allCases.compactMap(ArrClient.configured) {
                group.addTask {
                    do { return (client.app, .success(try await client.releases(in: start..<end))) }
                    catch { return (client.app, .failure(error)) }
                }
            }
            for await (app, result) in group {
                switch result {
                case .success(let releases): loaded += releases
                case .failure(let error as ArrClient.ServerError): failures.append(error.localizedDescription)
                case .failure(let error): failures.append("\(app.rawValue): \(error.localizedDescription)")
                }
            }
        }
        guard !Task.isCancelled else { return }
        releases = loaded
        errors = failures.sorted()
    }
}
