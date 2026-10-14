import Foundation
import Testing
import WeatherKit
import CoreLocation
import AppKit
import SwiftUI
@testable import Browser

@MainActor private final class WeatherFixtureConnection { var offline = true }
@MainActor private final class WeatherMarkCounter { var calls = 0 }
nonisolated private final class DeniedWeatherLocationFixture: CLLocationManager {
    override var authorizationStatus: CLAuthorizationStatus { .denied }
}

@MainActor struct WeatherServiceTests {
    @Test func emptyWeatherStatesRenderAsCompactControls() throws {
        let phases: [WeatherCardPhase] = [.location, .offline, .unavailable, .provider]
        let renderer = ImageRenderer(content: VStack(spacing: 12) {
            ForEach(phases, id: \.self) { phase in
                WeatherCompactStatus(phase: phase, onLocation: {}, onProvider: {}, onRetry: {}, onCandidate: { _ in })
                    .padding(18).frame(maxWidth: .infinity, minHeight: 76)
                    .foregroundStyle(.white).tint(.white)
                    .background(Color(red: 0.04, green: 0.09, blue: 0.16), in: RoundedRectangle(cornerRadius: 22))
            }
        }.frame(width: 560).environment(\.colorScheme, .dark).transaction { $0.disablesAnimations = true })
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == 560 && image.size.height < 400)
        if let path = ProcessInfo.processInfo.environment["WEATHER_STATUS_PREVIEW_PATH"],
           let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
    @Test func attributionReadinessSurvivesLocationChangesAndRepeatedLoads() async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let counter = WeatherMarkCounter()
        let url = URL(string: "https://example.com/mark/\(UUID().uuidString).png")!
        let loader = WeatherAttributionLoader { _ in
            await MainActor.run { counter.calls += 1 }
            return data
        }
        #expect(!loader.isReady(for: url))
        await loader.load(url)
        #expect(loader.isReady(for: url) && loader.image != nil)
        // Changing the place leaves the provider mark URL unchanged. Reloading
        // or remounting its view must not reset attribution or hide the forecast.
        await loader.load(url)
        #expect(loader.isReady(for: url) && !loader.loading && counter.calls == 1)
        let other = URL(string: "https://example.com/other/\(UUID().uuidString).png")!
        #expect(!loader.isReady(for: other))
        await loader.load(other)
        #expect(loader.isReady(for: other) && counter.calls == 2)
    }
    @Test func attributionFailuresRecoverAndLateMarksCannotReplaceTheCurrentProvider() async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let connection = WeatherFixtureConnection()
        let slow = URL(string: "https://example.com/slow/\(UUID().uuidString).png")!
        let fast = URL(string: "https://example.com/fast/\(UUID().uuidString).png")!
        let loader = WeatherAttributionLoader { url in
            if await MainActor.run(body: { connection.offline }) { throw URLError(.notConnectedToInternet) }
            if url == slow { try? await Task.sleep(for: .milliseconds(50)) }
            return data
        }
        await loader.load(fast)
        #expect(!loader.isReady(for: fast))
        if case .offline = loader.failure {} else { Issue.record("Missing mark must retain the real offline cause") }
        connection.offline = false
        let previous = Task { await loader.load(slow) }
        try await Task.sleep(for: .milliseconds(10))
        await loader.load(fast)
        await previous.value
        #expect(loader.isReady(for: fast) && loader.loadedURL == fast && loader.failure == nil)
    }
    @Test func weatherPresentationSeparatesMissingSetupOfflineAndProviderFailures() {
        func phase(forecast: Bool = false, mark: Bool = false, loading: Bool = false, offline: Bool = false,
                   location: Bool = false, failure: BrowserWeatherError? = nil, candidates: Bool = false, attributionFailed: Bool = false) -> WeatherCardPhase {
            .resolve(hasForecast: forecast, markReady: mark, loading: loading, offline: offline,
                     needsLocation: location, failure: failure, hasCandidates: candidates, attributionFailed: attributionFailed)
        }
        #expect(phase(location: true) == .location)
        #expect(phase(failure: .locationRequired) == .location)
        #expect(phase(loading: true) == .loading)
        #expect(phase(offline: true) == .offline)
        #expect(phase(failure: .offline) == .offline)
        #expect(phase(failure: .credentials) == .provider)
        #expect(phase(loading: true, location: true, failure: .credentials) == .provider)
        #expect(phase(failure: .unavailable) == .unavailable)
        #expect(phase(forecast: true, attributionFailed: true) == .unavailable)
        #expect(phase(forecast: true, mark: true, loading: true) == .ready)
        #expect(phase(forecast: true, mark: true, candidates: true) == .ambiguous)
        #expect(phase(forecast: true, mark: true, offline: true) == .ready)
        #expect(phase(forecast: true, mark: true, failure: .locationRequired) == .location)
        #expect(phase(offline: true, location: true) == .offline)
        #expect(WeatherCardPhase.location.preferredHeight() == 80)
        #expect(WeatherCardPhase.unavailable.preferredHeight() == 80)
        #expect(WeatherCardPhase.ready.preferredHeight() == 420)
    }
    @Test func fetchingAnimationStartsAfterThreeSecondsAndNestedOfflineErrorsAreRecognized() {
        let started = Date(timeIntervalSince1970: 1000)
        #expect(!WeatherCardPhase.showsLoadingAnimation(startedAt: nil, now: started))
        #expect(!WeatherCardPhase.showsLoadingAnimation(startedAt: started, now: started.addingTimeInterval(2.99)))
        #expect(WeatherCardPhase.showsLoadingAnimation(startedAt: started, now: started.addingTimeInterval(3)))
        let underlying = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        let mapFailure = NSError(domain: "MKErrorDomain", code: 5, userInfo: [NSUnderlyingErrorKey: underlying])
        if case .offline = BrowserWeatherError.classify(mapFailure) {} else { Issue.record("Nested offline error lost its connectivity state") }
        if case .unavailable = BrowserWeatherError.classify(URLError(.timedOut)) {} else { Issue.record("A slow provider is not evidence of being offline") }
    }
    private let now = Date(timeIntervalSince1970: 1791792000)
    private func preferences() -> UserDefaults { UserDefaults(suiteName: "WeatherFixture." + UUID().uuidString)! }
    private func place(_ town: String = "Erie", lat: Double = 40.045, lon: Double = -105.048) -> BrowserWeatherPlace {
        .init(town: town, region: "Colorado", country: "United States", countryCode: "US", latitude: lat, longitude: lon, timeZoneID: "America/Denver")
    }
    private func forecast(_ place: BrowserWeatherPlace, at date: Date, expires: TimeInterval = 60, provider: String = "apple") -> BrowserWeatherForecast {
        let preview = OmnibarWeatherSnapshot(city: place.label, condition: .rain, daylight: true, latitude: place.latitude, wind: 5, date: date)
        return .init(place: place, scene: preview, source: .init(provider: provider, name: "Fixture", legalURL: URL(string: "https://example.com/weather")!, markURL: nil, issuedAt: date, expiresAt: date.addingTimeInterval(expires), fixture: true))
    }
    @Test func parsesLocationCommandsAndPreservesUnrelatedNavigation() {
        for (text, location) in [("weather home", "home"), ("HOME WEATHER", "HOME"), ("work weather", "work"), ("weather WORK", "WORK"),
                                  ("weather 80516", "80516"), ("2725 DM Weather", "2725 DM"), ("weather Leiden", "Leiden"),
                                  ("SW1A 1AA weather", "SW1A 1AA"), ("weather São Paulo Brazil", "São Paulo Brazil")] {
            #expect(BrowserWeatherQuery.parse(text)?.location == location)
        }
        #expect(BrowserWeatherQuery.parse(" WEATHER ")?.location == nil)
        #expect(BrowserWeatherQuery.parse("rain home")?.mode == .rain)
        #expect(BrowserWeatherQuery.parse("weather work tomorrow") == .init(location: "work", mode: .tomorrow))
        #expect(BrowserWeatherQuery.parse("work weather tomorrow") == .init(location: "work", mode: .tomorrow))
        #expect(BrowserWeatherQuery.parse("when will rain stop?")?.mode == .rainStop)
        #expect(BrowserWeatherQuery.parse("next dry window")?.mode == .dryWindow)
        for text in ["weather.com", "https://weather.example", "the weather in Leiden", "rainforests", "", "weather weather.com"] {
            #expect(BrowserWeatherQuery.parse(text) == nil)
        }
        #expect(BrowserWeatherQuery.parse("weather home", historyMode: true) == nil)
    }
    @Test func deniedLocationOffersManualSetupWithoutRequestingPermission() {
        let prefs = preferences()
        prefs.set(true, forKey: NewspaperPreferences.Key.weatherCurrentLocation)
        let store = NewspaperWeatherStore(preferences: prefs, locationManager: DeniedWeatherLocationFixture())
        store.beginOmnibar(UUID())
        store.useCurrentLocation(requestPermission: false)
        #expect(store.forecast == nil && store.status.contains("Location access is unavailable"))
        #expect(!store.loading)
        if case .locationRequired = store.failure {} else { Issue.record("Denied location must offer location setup") }
    }
    @Test func savedPlacesStayPrivateAndMissingAliasesAreExplicit() throws {
        let first = WeatherPlacesStore(preferences: preferences()), second = WeatherPlacesStore(preferences: preferences())
        #expect(throws: BrowserWeatherError.self) { try first.query(for: "Home") }
        try first.save(name: "HOME", query: "80516")
        try first.save(name: "work", query: "2725 DM")
        #expect(try first.query(for: "home") == "80516")
        #expect(try first.query(for: "work") == "2725 DM")
        #expect(second.places.isEmpty)
        #expect(try first.query(for: "Leiden") == "Leiden")
        first.delete("Home"); #expect(first.places["home"] == nil)
        first.reset(); #expect(first.places.isEmpty)
    }
    @Test func mapImportsUseSelectedPlacesAndNeverCameraCenters() throws {
        #expect(WeatherMapLink.query("https://maps.apple.com/place?coordinate=52.16,4.49&name=Leiden") == "52.16,4.49")
        #expect(WeatherMapLink.query("https://www.google.com/maps/search/?api=1&query=2725%20DM") == "2725 DM")
        #expect(WeatherMapLink.query("https://www.google.com/maps/@52.16,4.49,12z") == nil)
        #expect(WeatherMapLink.query("https://evil.example/maps/search/?api=1&query=Home") == nil)
        #expect(WeatherMapLink.query("https://maps.app.goo.gl/example") == nil)
        #expect(WeatherMapLink.coordinates("91,0") == nil)
        let store = WeatherPlacesStore(preferences: preferences())
        let data = Data(#"{"features":[{"geometry":{"type":"Point","coordinates":[4.49,52.16]},"properties":{"name":"Home"}}]}"#.utf8)
        try store.importGooglePlaces(data)
        #expect(store.places["home"] == "52.16,4.49")
        #expect(throws: BrowserWeatherError.self) { try store.importGooglePlaces(Data(#"{"features":[]}"#.utf8)) }
    }
    @Test func geocodingFixturesResolveBothPostalFormatsAndDeduplicate() async throws {
        let fixtureURL = try #require(Bundle.main.url(forResource: "WeatherPreviewFixtures", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([String: [BrowserWeatherPlace]].self, from: Data(contentsOf: fixtureURL))
        var calls = 0
        let service = BrowserWeatherService(preferences: preferences(), clock: { now }, geocode: { query in
            calls += 1; try await Task.sleep(for: .milliseconds(10)); return fixtures[query.lowercased()] ?? []
        }, provider: { _, _ in throw BrowserWeatherError.unavailable })
        async let first = service.resolve("80516")
        async let second = service.resolve("80516")
        let (a, b) = try await (first, second)
        #expect(a[0].town == "Erie" && a[0].region == "Colorado" && a[0].countryCode == "US")
        #expect(a == b && calls == 1)
        let dutch = try await service.resolve("2725 DM")
        #expect(dutch[0].town == "Zoetermeer" && dutch[0].countryCode == "NL")
        #expect(dutch[0].timeZoneID == "Europe/Amsterdam")
        await #expect(throws: BrowserWeatherError.self) { try await service.resolve("invalid location fixture") }
    }
    @Test func ambiguityDoesNotSelectTheFirstPlace() async {
        let a = place("Springfield"), b = place("Springfield east", lat: 42)
        var providerCalls = 0
        let service = BrowserWeatherService(preferences: preferences(), clock: { now }, geocode: { _ in [a, b] }, provider: { place, _ in
            providerCalls += 1; return forecast(place, at: now)
        })
        let model = BrowserWeatherQueryModel(service: service, places: WeatherPlacesStore(preferences: preferences()))
        model.load("Springfield", debounce: false); await model.waitForRequest()
        #expect(model.result == nil && model.candidates.count == 2 && providerCalls == 0)
        model.load("Springfield", resolved: b, debounce: false); await model.waitForRequest()
        #expect(model.result?.place == b && providerCalls == 1)
    }
    @Test func identicalForecastsCoalesceAndExpiredCacheEntriesRefresh() async throws {
        var date = now, calls = 0
        let point = place()
        let service = BrowserWeatherService(preferences: preferences(), clock: { date }, geocode: { _ in [point] }, provider: { place, _ in
            calls += 1; try await Task.sleep(for: .milliseconds(10)); return forecast(place, at: date)
        })
        async let first = service.forecast(for: point)
        async let second = service.forecast(for: point)
        _ = try await (first, second)
        #expect(calls == 1 && service.cacheCount == 1)
        _ = try await service.forecast(for: point); #expect(calls == 1)
        date = now.addingTimeInterval(61)
        service.purgeExpired(); #expect(service.cacheCount == 0)
        _ = try await service.forecast(for: point); #expect(calls == 2 && service.cacheCount == 1)
        service.invalidate(); #expect(service.cacheCount == 0)
    }
    @Test func quotaFailuresBackOffAcrossPlacesAndDoNotFallBack() async {
        let prefs = preferences(); prefs.set(true, forKey: "browserWeatherAllowAppleFallback")
        var calls = 0
        let until = now.addingTimeInterval(60)
        let service = BrowserWeatherService(preferences: prefs, clock: { now }, provider: { _, _ in calls += 1; throw BrowserWeatherError.quota(until) })
        await #expect(throws: BrowserWeatherError.self) { try await service.forecast(for: place(), provider: .tomorrow) }
        await #expect(throws: BrowserWeatherError.self) { try await service.forecast(for: place("Other", lat: 41), provider: .tomorrow) }
        #expect(calls == 1)
    }
    @Test func providerFallbackIsExplicitAndBounded() async throws {
        let prefs = preferences(); prefs.set(true, forKey: "browserWeatherAllowAppleFallback")
        var providers: [BrowserWeatherProvider] = []
        let service = BrowserWeatherService(preferences: prefs, clock: { now }, provider: { point, provider in
            providers.append(provider)
            if provider == .tomorrow { throw BrowserWeatherError.unavailable }
            return forecast(point, at: now)
        })
        _ = try await service.forecast(for: place(), provider: .tomorrow)
        #expect(providers == [.tomorrow, .apple])
        let noFallback = BrowserWeatherService(preferences: preferences(), clock: { now }, provider: { _, _ in throw BrowserWeatherError.unavailable })
        await #expect(throws: BrowserWeatherError.self) { try await noFallback.forecast(for: place(), provider: .tomorrow) }
    }
    @Test func rapidEditsKeepTheOldCardAndRejectLateResponses() async {
        let first = place("First"), second = place("Second", lat: 41)
        let service = BrowserWeatherService(preferences: preferences(), clock: { now }, geocode: { query in query == "First" ? [first] : [second] }, provider: { point, _ in
            if point == first { try? await Task.sleep(for: .milliseconds(50)) }
            return forecast(point, at: now)
        })
        let model = BrowserWeatherQueryModel(service: service, places: WeatherPlacesStore(preferences: preferences()))
        model.preview(forecast(first, at: now))
        model.load("First", debounce: false)
        #expect(model.loading && model.result?.place == first)
        await Task.yield()
        model.load("Second", debounce: false); await model.waitForRequest()
        #expect(model.result?.place == second && !model.loading)
        model.cancel(); #expect(!model.loading)
        model.load("Second", debounce: false); await model.waitForRequest()
        #expect(model.result?.place == second)
    }
    @Test func offlineRecoveryRetainsPriorForecastAndRetrySucceeds() async {
        let point = place(); let connection = WeatherFixtureConnection()
        let service = BrowserWeatherService(preferences: preferences(), clock: { now }, geocode: { _ in [point] }, provider: { point, _ in
            if connection.offline { throw BrowserWeatherError.offline }; return forecast(point, at: now)
        })
        let model = BrowserWeatherQueryModel(service: service, places: WeatherPlacesStore(preferences: preferences()))
        model.preview(forecast(point, at: now))
        model.load("Erie", debounce: false); await model.waitForRequest()
        #expect(model.result?.place == point && model.status.contains("Offline"))
        connection.offline = false; model.load("Erie", debounce: false); await model.waitForRequest()
        #expect(model.status.isEmpty && model.result?.place == point)
    }
    @Test func cancellingOneConsumerDoesNotCancelAnother() async throws {
        let point = place(); var calls = 0
        let service = BrowserWeatherService(preferences: preferences(), clock: { now }, provider: { point, _ in
            calls += 1; try await Task.sleep(for: .milliseconds(50)); return forecast(point, at: now)
        })
        let first = Task { try await service.forecast(for: point) }
        let second = Task { try await service.forecast(for: point) }
        await Task.yield(); first.cancel()
        let result = try await second.value
        #expect(result.place == point && calls == 1)
    }
    @Test func secretsStayInHeadersAndCredentialRevisionsIsolateCaches() async throws {
        let key = "test-provider-key-never-live"
        let request = try TomorrowWeatherAdapter.request("forecast", place: place(), key: key)
        #expect(request.value(forHTTPHeaderField: "apikey") == key)
        #expect(!request.url!.absoluteString.contains(key) && !request.url!.absoluteString.contains("apikey"))
        #expect(!BrowserWeatherKeychain.valid("bad key"))
        let first = BrowserWeatherKeychain.identity(provider: "tomorrow", service: "profile-first")
        let second = BrowserWeatherKeychain.identity(provider: "tomorrow", service: "profile-second")
        #expect(String(describing: first) != String(describing: second))
        let prefs = preferences(); var calls = 0
        let service = BrowserWeatherService(preferences: prefs, clock: { now }, provider: { point, _ in calls += 1; return forecast(point, at: now) })
        _ = try await service.forecast(for: place())
        prefs.set("replacement-key-revision", forKey: "browserWeatherCredentialRevision")
        _ = try await service.forecast(for: place())
        #expect(calls == 2)
    }
    @Test func hourlyDryWindowsRequireAmountsAndNeverInventMinutePredictions() {
        let preview = OmnibarWeatherSnapshot(city: "Fixture", condition: .rain, daylight: true, latitude: 52, wind: 5, date: now)
        let window = BrowserRainWindow.hourly(preview, now: now)
        #expect(window != nil && window!.start >= now.addingTimeInterval(5 * 3600))
        let midHour = BrowserRainWindow.hourly(preview, now: now.addingTimeInterval(5 * 3600 + 123))
        #expect(midHour?.start == now.addingTimeInterval(6 * 3600))
        let unknown = [BrowserRainSample(date: now, millimetersPerHour: nil), BrowserRainSample(date: now.addingTimeInterval(300), millimetersPerHour: 0)]
        #expect(BrowserRainWindow.dry(samples: unknown, interval: 300, now: now, minimum: 1200) == nil)
        let gapped = [BrowserRainSample(date: now, millimetersPerHour: 0), BrowserRainSample(date: now.addingTimeInterval(900), millimetersPerHour: 0)]
        #expect(BrowserRainWindow.dry(samples: gapped, interval: 300, now: now, minimum: 1200) == nil)
    }
    @Test func regionalGridChecksProjectionTimesCoverageAndUnitConversion() throws {
        let point = place("Dutch fixture", lat: 52, lon: 4.5)
        let coordinate = try #require(KNMIRadarGrid.project(latitude: point.latitude, longitude: point.longitude))
        func grid(_ issue: Date) -> KNMIRadarGrid {
            .init(dataset: "radar_forecast", version: "2.0", projection: KNMIRadarGrid.projection, issuedAt: issue, expiresAt: issue.addingTimeInterval(300),
                width: 1, height: 1, originXKM: coordinate.x, originYKM: coordinate.y, stepXKM: 1, stepYKM: -1, fixture: true,
                frames: (0..<25).map { .init(date: issue.addingTimeInterval(Double($0) * 300), millimetersPerFiveMinutes: [$0 == 1 ? nil : 0.25]) })
        }
        let sampled = try grid(now).sample(point, now: now)
        let series = try #require(sampled)
        #expect(series.samples[0].millimetersPerHour == 3)
        #expect(series.samples[1].millimetersPerHour == nil)
        #expect(try grid(now).sample(place("Outside", lat: 40), now: now) == nil)
        #expect(throws: BrowserWeatherError.self) { try grid(now.addingTimeInterval(-601)).validate(now: now) }
        let pole = try #require(KNMIRadarGrid.project(latitude: 90, longitude: 0))
        #expect(abs(pole.x) < 0.00001 && abs(pole.y) < 0.00001)
        #expect(KNMIRadarGrid.project(latitude: -52, longitude: 4) == nil)
    }
}
