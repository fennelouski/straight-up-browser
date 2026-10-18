import Foundation
import Combine
import WeatherKit
import MapKit
import Security

nonisolated enum BrowserWeatherError: Error, LocalizedError, Sendable {
    case message(String), offline, credentials, locationRequired, quota(Date), unavailable, ambiguous([BrowserWeatherPlace])
    var message: String {
        switch self {
        case .message(let text): text
        case .offline: "Offline. Your previous forecast stays visible; reconnect and retry."
        case .credentials: "The provider key is missing or invalid. Check Weather providers in Saved places."
        case .locationRequired: "Choose a location."
        case .quota: "Provider usage limit reached. Cached forecasts remain available; retry after the displayed time."
        case .unavailable: "Weather is unavailable. Retry or choose another location."
        case .ambiguous: "Several places match. Choose the town and country you meant."
        }
    }
    var errorDescription: String? { message }
    static func classify(_ error: Error) -> Self {
        if let weather = error as? Self { return weather }
        let underlying = error as NSError
        if underlying.domain == NSURLErrorDomain,
           [URLError.notConnectedToInternet.rawValue, URLError.networkConnectionLost.rawValue,
            URLError.dataNotAllowed.rawValue].contains(underlying.code) { return .offline }
        if let cause = underlying.userInfo[NSUnderlyingErrorKey] as? Error { return classify(cause) }
        return .unavailable
    }
}

nonisolated enum BrowserWeatherProvider: String, CaseIterable, Sendable {
    case apple, tomorrow
    var title: String { self == .apple ? "Apple Weather" : "Tomorrow.io" }
}

nonisolated struct BrowserWeatherSource: Sendable {
    let provider: String
    let name: String
    let legalURL: URL
    let markURL: URL?
    let issuedAt: Date
    let expiresAt: Date
    var fixture = false
    var currentIsObservation = true
    var dailyAvailable = true
    var nowcastAvailable = false
    var windAvailable = true
    var apparentTemperatureAvailable = true
    var historyAvailable = true
    var conditionDescription: String? = nil
}

nonisolated struct BrowserWeatherForecast: Sendable {
    let place: BrowserWeatherPlace
    let scene: OmnibarWeatherSnapshot
    let source: BrowserWeatherSource
    var nativeCurrent: CurrentWeather? = nil
    var nativeAttribution: WeatherAttribution? = nil
    var nowcast: BrowserRainNowcast? = nil
    func isFresh(at now: Date) -> Bool { now < source.expiresAt && source.issuedAt <= now.addingTimeInterval(60) }
}

nonisolated enum BrowserWeatherKeychain {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "Browser") + ".weather-provider" }
    static func identity(provider: String, service: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service ?? self.service,
         kSecAttrAccount as String: provider, kSecAttrSynchronizable as String: false]
    }
    static func valid(_ key: String) -> Bool {
        (8...256).contains(key.utf8.count) && key.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
    static func read() -> String? {
        guard !BrowserProfile.isIsolated, !ProcessInfo.processInfo.arguments.contains("-uiTesting") else { return nil }
        var query = identity(provider: "tomorrow")
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func hasKey() -> Bool {
        guard !BrowserProfile.isIsolated, !ProcessInfo.processInfo.arguments.contains("-uiTesting") else { return false }
        return SecItemCopyMatching(identity(provider: "tomorrow") as CFDictionary, nil) == errSecSuccess
    }
    static func write(_ key: String) throws {
        guard !BrowserProfile.isIsolated, !ProcessInfo.processInfo.arguments.contains("-uiTesting") else { throw BrowserWeatherError.credentials }
        let identity = identity(provider: "tomorrow")
        if key.isEmpty {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw BrowserWeatherError.credentials }
            return
        }
        guard valid(key) else { throw BrowserWeatherError.message("Use an 8–256 character provider key without spaces.") }
        let values = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity.merging(values) { $1 }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BrowserWeatherError.credentials }
    }
}

/// One native owner for masthead and omnibars. Memory caches never contain keys,
/// addresses/aliases from other profiles, or a permanent Apple weather archive.
@MainActor final class BrowserWeatherService {
    static let shared = BrowserWeatherService()
    typealias Geocode = @MainActor (String) async throws -> [BrowserWeatherPlace]
    typealias Provider = @MainActor (BrowserWeatherPlace, BrowserWeatherProvider) async throws -> BrowserWeatherForecast
    private let preferences: UserDefaults
    private let clock: () -> Date
    private let geocode: Geocode
    private let provider: Provider
    private var places: [String: (Date, [BrowserWeatherPlace])] = [:]
    private struct GeoFlight { let id: UUID; let task: Task<[BrowserWeatherPlace], Error>; var leases: Set<UUID> }
    private var geoFlights: [String: GeoFlight] = [:]
    private var cache: [String: BrowserWeatherForecast] = [:]
    private var cleanupTask: Task<Void, Never>?
    private struct Flight { let id: UUID; let task: Task<BrowserWeatherForecast, Error>; var leases: Set<UUID> }
    private var flights: [String: Flight] = [:]
    private var blockedUntil: [String: Date] = [:]
    private var usage: [String: Int]
    var cacheCount: Int { cache.count }
    var requestCount: Int { usage.values.reduce(0, +) }

    init(preferences: UserDefaults = BrowserProfile.defaults, clock: @escaping () -> Date = Date.init,
         geocode: @escaping Geocode = BrowserWeatherService.geocode,
         provider: @escaping Provider = BrowserWeatherAdapters.fetch) {
        self.preferences = preferences; self.clock = clock; self.geocode = geocode; self.provider = provider
        usage = preferences.dictionary(forKey: "browserWeatherRequestAttempts") as? [String: Int] ?? [:]
    }
    func resolve(_ query: String) async throws -> [BrowserWeatherPlace] {
        guard !BrowserProfile.isIsolated else { throw BrowserWeatherError.message("External weather is disabled in the isolated profile.") }
        let text = WeatherMapLink.query(query) ?? query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 200, !text.contains("://") else { throw BrowserWeatherError.message("Enter an address, postcode, or full supported Maps place link.") }
        let key = text.lowercased()
        places = places.filter { $0.value.0 > clock() }
        if let entry = places[key] { return entry.1 }
        if geoFlights[key] == nil {
            guard geoFlights.count < 8 else { throw BrowserWeatherError.message("Location search is busy. Try again shortly.") }
            let task = Task { [self] in
                let result = try await geocode(text).filter(\.isValid)
                try Task.checkCancellation()
                guard !result.isEmpty else { throw BrowserWeatherError.message("Location not found. Include a country or region, or search the web.") }
                if places.count >= 20 { places.removeValue(forKey: places.keys.sorted().first!) }
                places[key] = (clock().addingTimeInterval(900), result)
                scheduleCleanup()
                return result
            }
            geoFlights[key] = GeoFlight(id: UUID(), task: task, leases: [])
        }
        let lease = UUID(); geoFlights[key]?.leases.insert(lease)
        let flight = geoFlights[key]!
        defer { releaseGeocode(key, id: flight.id, lease: lease) }
        return try await withTaskCancellationHandler {
            let result = try await flight.task.value
            try Task.checkCancellation()
            return result
        } onCancel: { Task { @MainActor [weak self] in self?.releaseGeocode(key, id: flight.id, lease: lease) } }
    }
    private func releaseGeocode(_ key: String, id: UUID, lease: UUID) {
        guard geoFlights[key]?.id == id else { return }
        geoFlights[key]?.leases.remove(lease)
        if geoFlights[key]?.leases.isEmpty == true { geoFlights[key]?.task.cancel(); geoFlights.removeValue(forKey: key) }
    }

    func forecast(for place: BrowserWeatherPlace, provider selected: BrowserWeatherProvider? = nil, refresh: Bool = false) async throws -> BrowserWeatherForecast {
        guard !BrowserProfile.isIsolated else { throw BrowserWeatherError.message("External weather is disabled in the isolated profile.") }
        guard place.isValid else { throw BrowserWeatherError.message("The resolved location is invalid.") }
        let selection = selected ?? BrowserWeatherProvider(rawValue: preferences.string(forKey: "browserWeatherProvider") ?? "apple") ?? .apple
        let scope = preferences.string(forKey: "browserWeatherCredentialRevision") ?? "native"
        let key = "\(selection.rawValue)|\(scope)|\(place.id)|\(place.timeZoneID)"
        cache = cache.filter { $0.value.isFresh(at: clock()) }
        if refresh { cache.removeValue(forKey: key) }
        if let cached = cache[key] { return cached }
        let lease = UUID()
        if flights[key] == nil {
            guard flights.count < 8 else { throw BrowserWeatherError.message("Weather is busy. Try again shortly.") }
            let id = UUID()
            let task = Task { [self] in
                let result: BrowserWeatherForecast
                do { result = try await request(place, provider: selection) }
                catch BrowserWeatherError.unavailable where selection != .apple && preferences.bool(forKey: "browserWeatherAllowAppleFallback") {
                    result = try await request(place, provider: .apple)
                }
                try Task.checkCancellation()
                guard result.place.id == place.id, result.isFresh(at: clock()) else { throw BrowserWeatherError.unavailable }
                if cache.count >= 20 { cache.removeValue(forKey: cache.keys.sorted().first!) }
                cache[key] = result
                scheduleCleanup()
                return result
            }
            flights[key] = Flight(id: id, task: task, leases: [])
        }
        flights[key]?.leases.insert(lease)
        let flight = flights[key]!
        defer { release(key, id: flight.id, lease: lease) }
        return try await withTaskCancellationHandler {
            let result = try await flight.task.value
            try Task.checkCancellation()
            return result
        } onCancel: { Task { @MainActor [weak self] in self?.release(key, id: flight.id, lease: lease) } }
    }
    private func release(_ key: String, id: UUID, lease: UUID) {
        guard flights[key]?.id == id else { return }
        flights[key]?.leases.remove(lease)
        if flights[key]?.leases.isEmpty == true { flights[key]?.task.cancel(); flights.removeValue(forKey: key) }
    }
    func purgeExpired() {
        cache = cache.filter { $0.value.isFresh(at: clock()) }
        places = places.filter { $0.value.0 > clock() }
    }
    private func scheduleCleanup() {
        cleanupTask?.cancel()
        let expiry = (cache.values.map { $0.source.expiresAt } + places.values.map { $0.0 }).min()
        guard let expiry else { cleanupTask = nil; return }
        let delay = max(0.1, expiry.timeIntervalSince(clock()))
        cleanupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.purgeExpired(); self.scheduleCleanup()
        }
    }
    func invalidate() {
        flights.values.forEach { $0.task.cancel() }; flights = [:]; cache = [:]; scheduleCleanup()
    }
    private func request(_ place: BrowserWeatherPlace, provider: BrowserWeatherProvider) async throws -> BrowserWeatherForecast {
        let now = clock(), identity = provider.rawValue
        if let until = blockedUntil[identity], until > now { throw BrowserWeatherError.quota(until) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.dateInterval(of: .day, for: now)!
        let hour = calendar.dateInterval(of: .hour, for: now)!
        let month = calendar.dateInterval(of: .month, for: now)!
        let second = DateInterval(start: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)), duration: 1)
        let cost = provider == .apple ? 4 : 2
        let limits = provider == .apple ? [(day, 100), (month, 1000)] : [(day, 500), (hour, 25), (second, 3)]
        let activeKeys = limits.map { "\(identity)|\($0.0.start.timeIntervalSince1970)" }
        // These are local attempt bounds, not membership-wide remaining quota.
        for (index, limit) in limits.enumerated() {
            guard usage[activeKeys[index], default: 0] + cost <= limit.1 else { throw BrowserWeatherError.quota(limit.0.end) }
        }
        usage = usage.filter { key, _ in key.hasPrefix(identity + "|") ? activeKeys.contains(key) : true }
        for key in activeKeys { usage[key, default: 0] += cost }
        preferences.set(usage, forKey: "browserWeatherRequestAttempts")
        do { return try await self.provider(place, provider) }
        catch let error as BrowserWeatherError {
            if case .quota(let until) = error { blockedUntil[identity] = until }
            throw error
        } catch is CancellationError { throw CancellationError() }
        catch { throw BrowserWeatherError.classify(error) }
    }

    private static var mapSearches: [UUID: MKLocalSearch] = [:]
    static func geocode(_ query: String) async throws -> [BrowserWeatherPlace] {
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query; request.resultTypes = .address
        let search = MKLocalSearch(request: request), operation = UUID()
        mapSearches[operation] = search
        defer { mapSearches.removeValue(forKey: operation) }
        let response = try await withTaskCancellationHandler { try await search.start() }
            onCancel: { Task { @MainActor in mapSearches[operation]?.cancel() } }
        var results: [BrowserWeatherPlace] = []
        for item in response.mapItems {
            guard let timeZone = item.timeZone else { continue }
            // Existing availability fence keeps the macOS 15.6 / iOS 18 path.
            let place: BrowserWeatherPlace
            if #available(macOS 26, iOS 26, *) {
                let address = item.addressRepresentations
                let town = address?.cityName ?? item.name ?? ""
                let country = address?.regionName ?? ""
                let context = address?.cityWithContext ?? town
                let region = context.hasPrefix(town + ",") ? String(context.dropFirst(town.count + 1)).trimmingCharacters(in: .whitespaces) : ""
                place = BrowserWeatherPlace(town: town, region: region, country: country, countryCode: "",
                    latitude: item.location.coordinate.latitude, longitude: item.location.coordinate.longitude,
                    timeZoneID: timeZone.identifier)
            } else {
                let address = item.placemark
                place = BrowserWeatherPlace(town: address.locality ?? address.name ?? "", region: address.administrativeArea ?? "",
                    country: address.country ?? "", countryCode: address.isoCountryCode ?? "",
                    latitude: address.coordinate.latitude, longitude: address.coordinate.longitude,
                    timeZoneID: timeZone.identifier)
            }
            if place.isValid && !results.contains(where: { $0.label == place.label }) { results.append(place) }
        }
        return results
    }
}

@MainActor enum BrowserWeatherAdapters {
    static func fetch(_ place: BrowserWeatherPlace, provider: BrowserWeatherProvider) async throws -> BrowserWeatherForecast {
        if provider == .tomorrow { return try await TomorrowWeatherAdapter.fetch(place) }
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              SecTaskCopyValueForEntitlement(task, "com.apple.developer.weatherkit" as CFString, nil) as? Bool == true else {
            throw BrowserWeatherError.message("Apple Weather requires a signed app with the configured WeatherKit capability. Preview fixtures remain available.")
        }
        #endif
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude), service = WeatherService.shared
        let now = Date()
        async let data = service.weather(for: location, including: .current,
            .hourly(startDate: now.addingTimeInterval(-86400), endDate: now.addingTimeInterval(172800)), .daily)
        async let credits = service.attribution
        let ((current, hourly, daily), attribution) = try await (data, credits)
        try Task.checkCancellation()
        let expiry = min(current.metadata.expirationDate, hourly.metadata.expirationDate, daily.metadata.expirationDate, now.addingTimeInterval(3600))
        let scene = OmnibarWeatherSnapshot(current: current, hourly: Array(hourly), daily: Array(daily),
            city: place.label, latitude: place.latitude, timeZone: place.timeZone, now: now)
        return BrowserWeatherForecast(place: place, scene: scene,
            source: BrowserWeatherSource(provider: "apple", name: "Apple Weather", legalURL: attribution.legalPageURL,
                markURL: attribution.combinedMarkDarkURL, issuedAt: now, expiresAt: expiry),
            nativeCurrent: current, nativeAttribution: attribution)
    }
}

@MainActor final class BrowserWeatherQueryModel: ObservableObject {
    @Published private(set) var result: BrowserWeatherForecast?
    @Published private(set) var loading = false
    @Published private(set) var status = ""
    @Published private(set) var candidates: [BrowserWeatherPlace] = []
    @Published private(set) var retryAt: Date?
    @Published private(set) var failure: BrowserWeatherError?
    @Published private(set) var loadingStartedAt: Date?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let service: BrowserWeatherService
    private let places: WeatherPlacesStore
    init(service: BrowserWeatherService = .shared, places: WeatherPlacesStore = .shared) { self.service = service; self.places = places }
    func load(_ query: String, resolved: BrowserWeatherPlace? = nil, debounce: Bool = true) {
        cancel(); let id = generation
        loading = true; loadingStartedAt = Date(); failure = nil
        status = "Loading \(query)…"; candidates = []; retryAt = nil
        task = Task { [self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(350)) }
                let point: BrowserWeatherPlace
                if let resolved { point = resolved }
                else {
                    let results = try await service.resolve(places.query(for: query))
                    guard !Task.isCancelled, generation == id else { return }
                    guard results.count == 1 else { throw BrowserWeatherError.ambiguous(results) }
                    point = results[0]
                }
                let value = try await service.forecast(for: point)
                guard !Task.isCancelled, generation == id else { return }
                result = value; status = ""; loading = false; loadingStartedAt = nil
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                let failure = BrowserWeatherError.classify(error)
                self.failure = failure
                status = failure.message; loading = false; loadingStartedAt = nil
                if case .ambiguous(let values) = failure { candidates = values }
                if case .quota(let time) = failure { retryAt = time }
            }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; loading = false; loadingStartedAt = nil; failure = nil }
    func expireIfNeeded(now: Date) {
        guard let result, now.timeIntervalSince(result.source.issuedAt) >= 7200 else { return }
        self.result = nil; status = "Forecast expired. Retry for current weather."
    }
    func fail(_ error: BrowserWeatherError) { cancel(); failure = error; status = error.message; candidates = []; retryAt = nil }
    func fail(_ message: String) { fail(.message(message)) }
    func preview(_ value: BrowserWeatherForecast) { cancel(); result = value; failure = nil; status = ""; candidates = []; retryAt = nil }
    func waitForRequest() async { await task?.value }
}
