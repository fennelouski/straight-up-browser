import SwiftUI
import Combine
import Network
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Reachability describes the connection, never provider availability. A failed
/// forecast alone must not be presented as a disconnected internet connection.
@MainActor final class WeatherNetworkStatus: ObservableObject {
    static let shared = WeatherNetworkStatus()
    @Published private(set) var offline = false
    private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status == .unsatisfied
            Task { @MainActor [weak self] in self?.offline = offline }
        }
        monitor.start(queue: DispatchQueue(label: "Browser.weather-connectivity"))
    }
    deinit { monitor.cancel() }
}

/// Provider marks are keyed by their URL, not a location or view appearance.
/// Reusing the same mark for another postcode cannot revoke its loaded state.
@MainActor final class WeatherAttributionLoader: ObservableObject {
    typealias Fetch = @Sendable (URL) async throws -> Data
    @Published private(set) var image: Image?
    @Published private(set) var loadedURL: URL?
    @Published private(set) var loading = false
    @Published private(set) var failure: BrowserWeatherError?
    private var generation = UUID()
    private let fetch: Fetch
    private static var cache: [URL: Data] = [:]
    init(fetch: @escaping Fetch = WeatherAttributionLoader.fetchMark) { self.fetch = fetch }
    func isReady(for url: URL?) -> Bool { url == nil || (url == loadedURL && image != nil) }
    func load(_ url: URL?, refresh: Bool = false) async {
        let request = UUID(); generation = request
        guard let url else { image = nil; loadedURL = nil; failure = nil; loading = false; return }
        if !refresh, isReady(for: url) { loading = false; failure = nil; return }
        loading = true; failure = nil
        do {
            let data: Data
            if !refresh, let cached = Self.cache[url] { data = cached }
            else { data = try await fetch(url) }
            try Task.checkCancellation()
            guard generation == request else { return }
            guard data.count <= 1_000_000, let mark = Self.decode(data) else { throw BrowserWeatherError.unavailable }
            if Self.cache.count >= 8 { Self.cache = [:] }
            Self.cache[url] = data
            image = mark; loadedURL = url; loading = false
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            loading = false; failure = BrowserWeatherError.classify(error)
        }
    }
    private static func decode(_ data: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }
    @concurrent private static func fetchMark(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw BrowserWeatherError.unavailable }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw BrowserWeatherError.unavailable
        }
        return data
    }
}

nonisolated enum WeatherCardPhase: Hashable {
    case ready, loading, location, offline, provider, ambiguous, unavailable
    static func resolve(hasForecast: Bool, markReady: Bool, loading: Bool, offline: Bool,
                        needsLocation: Bool, failure: BrowserWeatherError?, hasCandidates: Bool,
                        attributionFailed: Bool) -> Self {
        if !hasForecast || !markReady {
            if offline { return .offline }
            if case .offline = failure { return .offline }
            if case .credentials = failure { return .provider }
        }
        if needsLocation { return .location }
        if case .locationRequired = failure { return .location }
        if hasCandidates { return .ambiguous }
        if hasForecast && markReady { return .ready }
        if offline { return .offline }
        if case .offline = failure { return .offline }
        if loading { return .loading }
        if case .credentials = failure { return .provider }
        if attributionFailed || failure != nil { return .unavailable }
        return hasForecast ? .loading : .location
    }
    static func showsLoadingAnimation(startedAt: Date?, now: Date) -> Bool {
        startedAt.map { now.timeIntervalSince($0) >= 3 } ?? false
    }
    func preferredHeight(candidateCount: Int = 0) -> CGFloat {
        switch self {
        case .ready: 420
        case .ambiguous: min(300, 80 + CGFloat(candidateCount) * 40)
        default: 80
        }
    }
}

struct WeatherLocationButton: View {
    let pulsing: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.title3).foregroundStyle(.cyan)
                .symbolEffect(.pulse, options: .repeating, isActive: pulsing && !reduceMotion)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain).help("Choose weather location")
        .accessibilityLabel("Choose weather location")
        .accessibilityIdentifier("omnibar-weather-location")
    }
}

struct WeatherFetchingIndicator: View {
    let startedAt: Date?
    var refreshing = false
    var body: some View {
        TimelineView(.periodic(from: startedAt ?? Date(), by: 1)) { timeline in
            let delayed = WeatherCardPhase.showsLoadingAnimation(startedAt: startedAt, now: timeline.date)
            HStack(spacing: 10) {
                if delayed { ProgressView().controlSize(.small) }
                else if !refreshing { Image(systemName: "cloud.sun") }
                if delayed || !refreshing { Text(refreshing ? "Updating…" : delayed ? "Fetching weather…" : "Weather").font(.callout) }
            }
            .accessibilityIdentifier(delayed ? "weather-loading" : "weather-pending")
        }
    }
}

struct WeatherRetryButton: View {
    var retryAt: Date?
    let action: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Button(action: action) { Image(systemName: "arrow.clockwise").frame(width: 36, height: 36) }
                .accessibilityLabel("Retry weather").help("Retry weather")
                .disabled(retryAt.map { $0 > timeline.date } ?? false)
                .accessibilityIdentifier("weather-retry")
        }
    }
}

/// Empty-state UI has no service dependencies and no forecast-sized scroll area.
struct WeatherCompactStatus: View {
    let phase: WeatherCardPhase
    var startedAt: Date? = nil
    var retryAt: Date? = nil
    var candidates: [BrowserWeatherPlace] = []
    let onLocation: () -> Void
    let onProvider: () -> Void
    let onRetry: () -> Void
    let onCandidate: (BrowserWeatherPlace) -> Void
    var body: some View {
        Group {
            switch phase {
            case .location:
                HStack { Spacer(); WeatherLocationButton(pulsing: true, action: onLocation); Spacer() }
            case .loading:
                WeatherFetchingIndicator(startedAt: startedAt)
            case .offline:
                HStack {
                    Label("Offline", systemImage: "wifi.slash").foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    WeatherRetryButton(retryAt: retryAt, action: onRetry)
                }.accessibilityIdentifier("weather-offline")
            case .provider:
                Button(action: onProvider) { Label("Connect weather", systemImage: "key.fill") }
                    .buttonStyle(.bordered).accessibilityIdentifier("weather-provider-setup")
            case .ambiguous:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Which place?").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(candidates) { candidate in
                                Button { onCandidate(candidate) } label: {
                                    Label(candidate.label, systemImage: "mappin").lineLimit(2)
                                }.frame(minHeight: 36)
                            }
                        }
                    }.frame(height: min(220, CGFloat(candidates.count) * 40))
                }
            case .unavailable:
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Weather unavailable", systemImage: "exclamationmark.icloud")
                            .accessibilityIdentifier("omnibar-weather-status")
                        if let retryAt {
                            Text("Try after \(retryAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    Spacer(minLength: 8)
                    Button(action: onProvider) { Image(systemName: "key").frame(width: 36, height: 36) }
                        .accessibilityLabel("Weather providers").help("Weather providers")
                    WeatherRetryButton(retryAt: retryAt, action: onRetry)
                }
            case .ready: EmptyView()
            }
        }
    }
}
