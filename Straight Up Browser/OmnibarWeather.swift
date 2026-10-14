import SwiftUI
import WeatherKit

nonisolated enum OmnibarWeatherIntent {
    static func matches(_ query: String, historyMode: Bool = false) -> Bool {
        BrowserWeatherQuery.parse(query, historyMode: historyMode) != nil
    }
}

/// A single immutable projection keeps animation ticks away from WeatherKit and
/// the text field. Historical hours drive snow on surfaces, never future snow.
nonisolated struct OmnibarWeatherSnapshot: Sendable, Equatable {
    struct Hour: Identifiable, Sendable, Equatable {
        var id: Date { date }
        let date: Date
        let symbol: String
        let celsius: Double
        let precipitationChance: Double
        let wind: Double
        var gust: Double? = nil
        var precipitationMM: Double? = nil
    }
    struct Day: Identifiable, Sendable, Equatable {
        var id: Date { date }
        let date: Date
        let symbol: String
        let high: Double
        let low: Double
        let precipitationChance: Double
        let precipitationMM: Double
        var condition: WeatherCondition? = nil
    }
    let city: String
    let condition: WeatherCondition
    let symbol: String
    let celsius: Double
    let feelsLike: Double
    let daylight: Bool
    let cloudCover: Double
    let wind: Double
    let windDirection: Double
    let recentWind: Double
    let recentSnow: Double
    let latitude: Double
    let timeZone: TimeZone
    let date: Date
    let sunrise: Date?
    let sunset: Date?
    let hours: [Hour]
    var days: [Day] = []
    var gust: Double? = nil

    init(current: CurrentWeather, hourly: [HourWeather], daily: [DayWeather],
         city: String, latitude: Double, timeZone: TimeZone, now: Date) {
        self.city = city
        condition = current.condition
        symbol = current.symbolName
        celsius = current.temperature.converted(to: .celsius).value
        feelsLike = current.apparentTemperature.converted(to: .celsius).value
        daylight = current.isDaylight
        cloudCover = current.cloudCover
        wind = current.wind.speed.converted(to: .metersPerSecond).value
        windDirection = current.wind.direction.converted(to: .degrees).value
        let past = hourly.filter { $0.date.addingTimeInterval(3600) <= now && $0.date > now.addingTimeInterval(-86400) }
        recentWind = past.map { $0.wind.speed.converted(to: .metersPerSecond).value }.max() ?? wind
        recentSnow = past.reduce(0) { $0 + $1.snowfallAmount.converted(to: .millimeters).value }
        self.latitude = latitude
        self.timeZone = timeZone
        date = current.date
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = daily.first { calendar.isDate($0.date, inSameDayAs: now) }
        sunrise = today?.sun.sunrise
        sunset = today?.sun.sunset
        hours = hourly.filter { $0.date >= (calendar.dateInterval(of: .hour, for: now)?.start ?? now) }
            .sorted { $0.date < $1.date }.prefix(48).map {
                Hour(date: $0.date, symbol: $0.symbolName, celsius: $0.temperature.converted(to: .celsius).value,
                     precipitationChance: $0.precipitationChance, wind: $0.wind.speed.converted(to: .metersPerSecond).value,
                     gust: $0.wind.gust?.converted(to: .metersPerSecond).value,
                     precipitationMM: $0.precipitationAmount.converted(to: .millimeters).value)
            }
        gust = current.wind.gust?.converted(to: .metersPerSecond).value
        days = daily.map { Day(date: $0.date, symbol: $0.symbolName,
            high: $0.highTemperature.converted(to: .celsius).value,
            low: $0.lowTemperature.converted(to: .celsius).value,
            precipitationChance: $0.precipitationChance,
            precipitationMM: $0.precipitationAmountByType.rainfall.converted(to: .millimeters).value, condition: $0.condition) }
    }

    init(place: BrowserWeatherPlace, condition: WeatherCondition, symbol: String, celsius: Double,
         feelsLike: Double, daylight: Bool, cloudCover: Double, wind: Double, windDirection: Double,
         date: Date, hours: [Hour], days: [Day], gust: Double? = nil, sunrise: Date? = nil, sunset: Date? = nil) {
        city = place.label; self.condition = condition; self.symbol = symbol
        self.celsius = celsius; self.feelsLike = feelsLike; self.daylight = daylight
        self.cloudCover = cloudCover; self.wind = wind; self.windDirection = windDirection
        recentWind = wind; recentSnow = 0; latitude = place.latitude; timeZone = place.timeZone
        self.date = date; self.sunrise = sunrise; self.sunset = sunset; self.hours = hours; self.days = days; self.gust = gust
    }

    init(city: String, condition: WeatherCondition, daylight: Bool, latitude: Double, wind: Double,
         recentSnow: Double = 0, date: Date = .now) {
        self.city = city; self.condition = condition; self.daylight = daylight
        self.latitude = latitude; self.wind = wind; self.recentWind = wind; self.recentSnow = recentSnow
        self.date = date; timeZone = TimeZone(secondsFromGMT: 0)!
        cloudCover = condition == .clear ? 0.1 : 0.8; celsius = recentSnow > 0 ? -2 : 12
        feelsLike = celsius - 2; windDirection = 250; sunrise = nil; sunset = nil
        symbol = recentSnow > 0 ? "cloud.snow.fill" : condition == .clear ? "moon.stars.fill" : "cloud.rain.fill"
        let hourSymbol = symbol, baseTemperature = celsius
        let start = Calendar(identifier: .gregorian).dateInterval(of: .hour, for: date)?.start ?? date
        hours = (0..<24).map {
            Hour(date: start.addingTimeInterval(Double($0) * 3600), symbol: hourSymbol,
                 celsius: baseTemperature + sin(Double($0) / 3) * 3, precipitationChance: $0 >= 5 ? 0.1 : 0.7, wind: wind, gust: wind * 1.3, precipitationMM: $0 >= 5 ? 0 : 0.5)
        }
    }

    var isSnowing: Bool { [.snow, .heavySnow, .flurries, .blizzard, .blowingSnow, .sunFlurries, .wintryMix].contains(condition) }
    var isRaining: Bool { [.rain, .heavyRain, .drizzle, .freezingRain, .freezingDrizzle, .sunShowers,
        .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms, .tropicalStorm,
        .hurricane, .sleet, .hail, .wintryMix].contains(condition) }
    var isAutumn: Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let month = calendar.component(.month, from: date)
        return abs(latitude) > 15 && (latitude >= 0 ? [9, 10, 11] : [3, 4, 5]).contains(month)
    }
    var hasLeaves: Bool { isAutumn && max(wind, recentWind) >= 4 }
    var goldenHour: Bool { [sunrise, sunset].compactMap { $0 }.contains { abs($0.timeIntervalSince(date)) < 2700 } }
    var solarProgress: Double {
        guard let sunrise, let sunset, sunset > sunrise else { return 0.5 }
        return min(1, max(0, date.timeIntervalSince(sunrise) / sunset.timeIntervalSince(sunrise)))
    }
    var snowDepth: Double { min(14, sqrt(max(0, recentSnow)) * 2) }
    var windSign: Double { sin(windDirection * .pi / 180) > 0 ? -1 : 1 }

    static var testPreview: Self? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-uiTesting"), let index = args.firstIndex(of: "-weatherUITesting"),
              args.indices.contains(index + 1) else { return nil }
        let kind = args[index + 1]
        return Self(city: "Weather preview", condition: kind == "snow" ? .snow : kind == "clear" ? .clear : .rain,
                    daylight: kind != "clear", latitude: 52, wind: kind == "clear" ? 2 : 8,
                    recentSnow: kind == "snow" ? 24 : 0)
    }
}

struct OmnibarWeatherSurfaces: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}
struct OmnibarWeatherCreditVisible: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
extension View {
    func weatherLandingSurface() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: OmnibarWeatherSurfaces.self, value: [proxy.frame(in: .named("omnibarWeatherScene"))])
        })
    }
}

struct OmnibarWeatherResolvedScene: PreferenceKey {
    static var defaultValue: OmnibarWeatherSnapshot? { nil }
    static func reduce(value: inout OmnibarWeatherSnapshot?, nextValue: () -> OmnibarWeatherSnapshot?) {
        if let next = nextValue() { value = next }
    }
}

struct OmnibarWeatherPanelHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct OmnibarWeatherCard: View {
    var query = "weather"
    var mapURL: String? = nil
    var onSearch: () -> Void
    @ObservedObject private var store = NewspaperWeatherStore.shared
    @ObservedObject private var places = WeatherPlacesStore.shared
    @ObservedObject private var regional = WeatherRegionalFeedStore.shared
    @StateObject private var model = BrowserWeatherQueryModel()
    @StateObject private var credit = WeatherAttributionLoader()
    @ObservedObject private var network = WeatherNetworkStatus.shared
    @State private var client = UUID()
    @State private var configuring = false
    @State private var configuringProvider = false
    @State private var busySince: Date?
    @State private var saveStatus = ""
    @AppStorage(NewspaperPreferences.Key.weatherCity) private var city = ""
    @AppStorage(NewspaperPreferences.Key.weatherCurrentLocation) private var currentLocation = false
    @AppStorage(NewspaperPreferences.Key.weatherTemperatureUnit) private var unit = NewspaperTemperatureUnit.system.rawValue
    @AppStorage("browserWeatherProvider") private var provider = "apple"
    @AppStorage("browserWeatherCredentialRevision") private var revision = "native"
    @AppStorage("browserWeatherBYOEnabled") private var byo = false

    private var intent: BrowserWeatherQuery { BrowserWeatherQuery.parse(query) ?? .init() }
    private var usesCurrent: Bool { intent.location == nil && currentLocation && OmnibarWeatherSnapshot.testPreview == nil }
    private var forecast: BrowserWeatherForecast? { usesCurrent ? (store.forecast ?? model.result) : model.result }
    private var requestKey: String {
        let requested = intent.location ?? city
        let resolved = (try? places.query(for: requested)) ?? requested
        return "\(resolved)|\(usesCurrent)|\(provider)|\(revision)|\(byo)"
    }
    private var markReady: Bool { forecast.map { $0.source.fixture || credit.isReady(for: $0.source.markURL) } ?? false }
    private var failure: BrowserWeatherError? {
        if case .credentials = model.failure { return model.failure }
        return (usesCurrent ? store.failure : model.failure) ?? credit.failure
    }
    private var loading: Bool {
        (usesCurrent ? store.loading : model.loading) || credit.loading ||
            (forecast != nil && !markReady && credit.failure == nil)
    }
    private var needsLocation: Bool {
        guard !usesCurrent else { return false }
        let requested = (intent.location ?? city).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return requested.isEmpty || (["home", "work"].contains(requested) && places.places[requested] == nil)
    }
    private var phase: WeatherCardPhase {
        .resolve(hasForecast: forecast != nil, markReady: markReady, loading: loading,
                 offline: network.offline, needsLocation: needsLocation, failure: failure,
                 hasCandidates: !model.candidates.isEmpty, attributionFailed: credit.failure != nil)
    }
    private var ready: Bool { phase == .ready }
    private func temperature(_ celsius: Double) -> String {
        (NewspaperTemperatureUnit(rawValue: unit) ?? .system).formatted(Measurement(value: celsius, unit: .celsius))
    }
    private func hourTime(_ date: Date, timeZone: TimeZone) -> String {
        var format = Date.FormatStyle(date: .omitted, time: .shortened); format.timeZone = timeZone
        return date.formatted(format)
    }
    private func displayedHours(_ scene: OmnibarWeatherSnapshot) -> [OmnibarWeatherSnapshot.Hour] {
        guard intent.mode == .tomorrow else { return Array(scene.hours.prefix(24)) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = scene.timeZone
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return scene.hours.filter { calendar.isDate($0.date, inSameDayAs: tomorrow) }
    }
    private func tomorrowDay(_ scene: OmnibarWeatherSnapshot) -> OmnibarWeatherSnapshot.Day? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = scene.timeZone
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return scene.days.first { calendar.isDate($0.date, inSameDayAs: tomorrow) }
    }
    var body: some View {
        VStack(spacing: 0) {
            if ready, let forecast {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        updateNotice
                        forecastContent(forecast)
                            .id(forecast.place.id + String(forecast.source.issuedAt.timeIntervalSince1970))
                            .transition(.opacity)
                        if !saveStatus.isEmpty { Text(saveStatus).font(.caption).foregroundStyle(.white.opacity(0.7)) }
                    }.padding(18)
                }
                HStack(spacing: 12) {
                    locationButton(pulsing: false)
                    Spacer(minLength: 8)
                    savePlaceButton("home", symbol: "house", forecast: forecast)
                    savePlaceButton("work", symbol: "briefcase", forecast: forecast)
                    Button(action: onSearch) { Image(systemName: "magnifyingglass").frame(width: 36, height: 36) }
                        .accessibilityLabel("Search the web").help("Search the web")
                        .accessibilityIdentifier("omnibar-weather-search")
                }.padding(.horizontal, 14)
                attribution(forecast)
            } else {
                compactState
                    .padding(18)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            }
        }
        .foregroundStyle(.white).tint(.white)
        .background(Color(red: 0.04, green: 0.09, blue: 0.16).opacity(0.91), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.15)))
        .weatherLandingSurface()
        .preference(key: OmnibarWeatherCreditVisible.self, value: ready)
        .preference(key: OmnibarWeatherPanelHeight.self, value: phase.preferredHeight(candidateCount: model.candidates.count))
        .preference(key: OmnibarWeatherResolvedScene.self, value: ready ? forecast?.scene : nil)
        .accessibilityElement(children: .contain).accessibilityIdentifier("omnibar-weather")
        .popover(isPresented: $configuring) {
            NewspaperWeatherLocationPopup(enablesMasthead: false, validationPlace: forecast?.place,
                aliasToSave: ["home", "work"].contains(intent.location?.lowercased() ?? "") ? intent.location?.lowercased() : nil)
                .foregroundStyle(.primary).tint(.accentColor)
        }
        .popover(isPresented: $configuringProvider) {
            WeatherProviderSettings(validationPlace: forecast?.place).padding(18).frame(width: 360)
                .foregroundStyle(.primary).tint(.accentColor)
        }
        .onAppear { store.beginOmnibar(client) }
        .task(id: requestKey) { load() }
        .task(id: forecast?.source.markURL) { await credit.load(forecast?.source.markURL) }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                model.expireIfNeeded(now: Date()); store.expireIfNeeded(now: Date())
            }
        }
        .onChange(of: loading, initial: true) { _, fetching in busySince = fetching ? Date() : nil }
        .onChange(of: network.offline) { wasOffline, offline in
            if wasOffline && !offline { retry() }
        }
        .onChange(of: ready) { _, visible in store.setOmnibarAttributionVisible(visible, client: client) }
        .onDisappear { model.cancel(); store.endOmnibar(client) }
        .omnibarMotion(forecast?.place.id)
        .omnibarMotion(forecast?.source.issuedAt)
    }

    private var compactState: some View {
        WeatherCompactStatus(phase: phase, startedAt: busySince, retryAt: model.retryAt, candidates: model.candidates,
            onLocation: { configuring = true }, onProvider: { configuringProvider = true }, onRetry: retry,
            onCandidate: { load(resolved: $0) })
    }
    @ViewBuilder private var updateNotice: some View {
        if network.offline || isOfflineFailure {
            Label("Offline · saved forecast", systemImage: "wifi.slash").font(.caption)
                .accessibilityIdentifier("weather-offline")
        } else if failure != nil {
            HStack {
                Label("Couldn't update", systemImage: "exclamationmark.circle")
                Spacer()
                if case .credentials = failure {
                    Button { configuringProvider = true } label: { Image(systemName: "key") }
                        .accessibilityLabel("Weather providers")
                }
                retryButton
            }.font(.caption).padding(.horizontal, 18)
        } else if loading {
            WeatherFetchingIndicator(startedAt: busySince, refreshing: true)
        }
    }
    private var isOfflineFailure: Bool { if case .offline = failure { return true }; return false }
    private var retryButton: some View {
        WeatherRetryButton(retryAt: model.retryAt, action: retry)
    }
    private func locationButton(pulsing: Bool) -> some View {
        WeatherLocationButton(pulsing: pulsing) { configuring = true }
    }
    private func savePlaceButton(_ name: String, symbol: String, forecast: BrowserWeatherForecast) -> some View {
        Button { save(name, query: "\(forecast.place.latitude),\(forecast.place.longitude)") } label: {
            Image(systemName: symbol).frame(width: 36, height: 36)
        }
        .accessibilityLabel("Use this place as \(name.capitalized)").help("Save as \(name.capitalized)")
    }
    private func retry() {
        load(debounce: false)
        if !markReady { Task { await credit.load(forecast?.source.markURL, refresh: true) } }
    }
    @ViewBuilder private func forecastContent(_ forecast: BrowserWeatherForecast) -> some View {
        let scene = forecast.scene
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(scene.city).font(.headline).lineLimit(2)
                if intent.mode == .tomorrow, let day = tomorrowDay(scene) {
                    Text("Tomorrow").font(.subheadline)
                    Text("\(temperature(day.low))–\(temperature(day.high))").font(.system(size: 38, weight: .light, design: .rounded))
                    Text(day.condition?.description ?? "Daily forecast").font(.title3)
                    Text("\(day.precipitationChance.formatted(.percent)) precipitation chance · \(day.precipitationMM.formatted(.number.precision(.fractionLength(1)))) mm").font(.caption)
                } else {
                    if intent.mode == .tomorrow { Text("Current weather · daily forecast unavailable").font(.caption) }
                    Text(temperature(scene.celsius)).font(.system(size: 48, weight: .light, design: .rounded))
                    Text(forecast.source.conditionDescription ?? scene.condition.description).font(.title3)
                    if forecast.source.apparentTemperatureAvailable { Text("Feels like \(temperature(scene.feelsLike))").font(.caption) }
                    if forecast.source.windAvailable {
                        Text("Wind \(Measurement(value: scene.wind, unit: UnitSpeed.metersPerSecond).formatted(.measurement(width: .abbreviated)))")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                    if let gust = scene.gust {
                        Text("Gusts \(Measurement(value: gust, unit: UnitSpeed.metersPerSecond).formatted(.measurement(width: .abbreviated)))").font(.caption)
                    }
                }
            }
            Spacer(minLength: 8)
            Image(systemName: intent.mode == .tomorrow ? (tomorrowDay(scene)?.symbol ?? scene.symbol) : scene.symbol).symbolRenderingMode(.multicolor).font(.system(size: 48)).accessibilityHidden(true)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("omnibar-weather-current")
        if intent.mode != .overview { WeatherRainChart(forecast: forecast, mode: intent.mode, grid: regional.grid) }
        Text(intent.mode == .tomorrow ? "Tomorrow's hourly forecast" : "Hourly forecast").font(.subheadline.bold())
            .accessibilityIdentifier("weather-hourly-title").accessibilityAddTraits(.isHeader)
        ScrollView(.horizontal) {
            HStack(spacing: 18) {
                ForEach(displayedHours(scene)) { hour in
                    VStack(spacing: 9) {
                        Text(hourTime(hour.date, timeZone: scene.timeZone))
                        Image(systemName: hour.symbol).symbolRenderingMode(.multicolor).font(.title3)
                        Text(temperature(hour.celsius)).bold()
                        Text(hour.precipitationChance.formatted(.percent.precision(.fractionLength(0)))).font(.caption2).foregroundStyle(.cyan)
                        if let amount = hour.precipitationMM { Text("\(amount.formatted(.number.precision(.fractionLength(1)))) mm").font(.caption2) }
                    }.font(.caption).frame(minWidth: 54)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(hourTime(hour.date, timeZone: scene.timeZone)), \(temperature(hour.celsius)), precipitation \(hour.precipitationChance.formatted(.percent))")
                }
            }.padding(.vertical, 6)
        }.accessibilityIdentifier("omnibar-weather-hourly")
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            Text("\(forecast.isFresh(at: timeline.date) ? "Updated" : "Stale forecast") \(hourTime(scene.date, timeZone: scene.timeZone)) · \(scene.timeZone.identifier)")
                .font(.caption2).foregroundStyle(.white.opacity(0.7)).accessibilityIdentifier("weather-freshness")
        }
        if intent.mode == .overview { WeatherRainChart(forecast: forecast, mode: intent.mode, grid: regional.grid) }
    }
    @ViewBuilder private func attribution(_ forecast: BrowserWeatherForecast) -> some View {
        if forecast.source.fixture {
            Text("Preview weather · No live service requested").font(.caption2).padding(12)
        } else {
            HStack(spacing: 12) {
                if forecast.source.markURL != nil, let image = credit.image {
                    image.resizable().scaledToFit().frame(width: 90, height: 20)
                        .accessibilityLabel(forecast.source.name).accessibilityIdentifier("omnibar-weather-mark")
                } else { Text(forecast.source.name).font(.caption2) }
                Spacer(minLength: 0)
                Link("Weather data sources", destination: forecast.source.legalURL).font(.caption2).accessibilityIdentifier("omnibar-weather-attribution")
            }.padding(.horizontal, 18).padding(.vertical, 12)
                .help("Weather animations illustrate forecast data and are modified by Browser.")
        }
    }
    private func load(resolved: BrowserWeatherPlace? = nil, debounce: Bool = true) {
        let requested = intent.location ?? city
        if let preview = OmnibarWeatherSnapshot.testPreview {
            do {
                let place: BrowserWeatherPlace
                if let resolved { place = resolved }
                else if requested.isEmpty { place = .init(town: "Weather preview", region: "", country: "Fixture", countryCode: "", latitude: 52, longitude: 4.5, timeZoneID: "Europe/Amsterdam") }
                else {
                    let query = try places.query(for: requested).lowercased()
                    guard let url = Bundle.main.url(forResource: "WeatherPreviewFixtures", withExtension: "json") else { throw BrowserWeatherError.unavailable }
                    let entries = try JSONDecoder().decode([String: [BrowserWeatherPlace]].self, from: Data(contentsOf: url))
                    guard let matches = entries[query], matches.count == 1 else { throw BrowserWeatherError.message("Preview location not found or ambiguous. Choose a fixture location.") }
                    place = matches[0]
                }
                let scene = OmnibarWeatherSnapshot(place: place, condition: preview.condition, symbol: preview.symbol,
                    celsius: preview.celsius, feelsLike: preview.feelsLike, daylight: preview.daylight, cloudCover: preview.cloudCover,
                    wind: preview.wind, windDirection: preview.windDirection, date: preview.date,
                    hours: preview.hours + preview.hours.map { .init(date: $0.date.addingTimeInterval(86400), symbol: $0.symbol, celsius: $0.celsius, precipitationChance: $0.precipitationChance, wind: $0.wind, gust: $0.gust, precipitationMM: $0.precipitationMM) },
                    days: [.init(date: Date().addingTimeInterval(86400), symbol: preview.symbol, high: 16, low: 8, precipitationChance: 0.5, precipitationMM: 2, condition: preview.condition)])
                model.preview(.init(place: place, scene: scene,
                    source: .init(provider: "fixture", name: "Preview weather", legalURL: URL(string: "https://developer.apple.com/weatherkit/")!, markURL: nil,
                                  issuedAt: Date(), expiresAt: Date().addingTimeInterval(3600), fixture: true)))
            } catch { model.fail((error as? BrowserWeatherError)?.message ?? "Preview unavailable.") }
        } else if provider == "tomorrow" && (!byo || !BrowserWeatherKeychain.hasKey()) {
            model.fail(.credentials)
        } else if usesCurrent {
            model.cancel(); Task { await store.loadForOmnibar() }
        } else if requested.isEmpty { model.fail("Choose a location to see weather.") }
        else { model.load(requested, resolved: resolved, debounce: debounce) }
    }
    private func save(_ name: String, query: String) {
        do { try places.save(name: name, query: query); saveStatus = "\(name.capitalized) saved" }
        catch { saveStatus = "The place could not be saved." }
    }
}
