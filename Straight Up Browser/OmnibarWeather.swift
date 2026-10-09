import SwiftUI
import WeatherKit

nonisolated enum OmnibarWeatherIntent {
    static func matches(_ query: String, historyMode: Bool = false) -> Bool {
        !historyMode && query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "weather"
    }
}

/// A single immutable projection keeps animation ticks away from WeatherKit and
/// the text field. Historical hours drive snow on surfaces, never future snow.
nonisolated struct OmnibarWeatherSnapshot: Sendable {
    struct Hour: Identifiable, Sendable {
        var id: Date { date }
        let date: Date
        let symbol: String
        let celsius: Double
        let precipitationChance: Double
        let wind: Double
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
            .sorted { $0.date < $1.date }.prefix(24).map {
                Hour(date: $0.date, symbol: $0.symbolName, celsius: $0.temperature.converted(to: .celsius).value,
                     precipitationChance: $0.precipitationChance, wind: $0.wind.speed.converted(to: .metersPerSecond).value)
            }
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
        hours = (0..<24).map {
            Hour(date: date.addingTimeInterval(Double($0) * 3600), symbol: hourSymbol,
                 celsius: baseTemperature + sin(Double($0) / 3) * 3, precipitationChance: 0.7, wind: wind)
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
    var snowDepth: Double { min(14, max(isSnowing ? 3 : 0, sqrt(max(0, recentSnow)) * 2)) }
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

struct OmnibarWeatherCard: View {
    var onSearch: () -> Void
    @ObservedObject private var store = NewspaperWeatherStore.shared
    @State private var client = UUID()
    @State private var configuring = false
    @State private var credited = false
    @AppStorage(NewspaperPreferences.Key.weatherCity) private var city = ""
    @AppStorage(NewspaperPreferences.Key.weatherCurrentLocation) private var currentLocation = false
    @AppStorage(NewspaperPreferences.Key.weatherTemperatureUnit) private var unit = NewspaperTemperatureUnit.system.rawValue

    private var preview: Bool { OmnibarWeatherSnapshot.testPreview != nil }
    private func temperature(_ celsius: Double) -> String {
        (NewspaperTemperatureUnit(rawValue: unit) ?? .system).formatted(Measurement(value: celsius, unit: .celsius))
    }
    private func hourTime(_ date: Date, timeZone: TimeZone) -> String {
        var format = Date.FormatStyle(date: .omitted, time: .shortened)
        format.timeZone = timeZone
        return date.formatted(format)
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let scene = store.scene, credited || preview {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(scene.city).font(.headline).lineLimit(2)
                                Text(temperature(scene.celsius)).font(.system(size: 48, weight: .light, design: .rounded))
                                Text(scene.condition.description).font(.title3)
                                Text("Feels like \(temperature(scene.feelsLike)) · Wind \(Measurement(value: scene.wind, unit: UnitSpeed.metersPerSecond).formatted(.measurement(width: .abbreviated)))")
                                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                            }
                            Spacer(minLength: 8)
                            Image(systemName: scene.symbol).symbolRenderingMode(.multicolor).font(.system(size: 48))
                                .accessibilityHidden(true)
                        }.accessibilityElement(children: .combine).accessibilityIdentifier("omnibar-weather-current")
                        Text("Hourly forecast").font(.subheadline.bold())
                        ScrollView(.horizontal) {
                            HStack(spacing: 18) {
                                ForEach(scene.hours) { hour in
                                    VStack(spacing: 9) {
                                        Text(hourTime(hour.date, timeZone: scene.timeZone))
                                        Image(systemName: hour.symbol).symbolRenderingMode(.multicolor).font(.title3)
                                        Text(temperature(hour.celsius)).bold()
                                        Text(hour.precipitationChance.formatted(.percent.precision(.fractionLength(0))))
                                            .font(.caption2).foregroundStyle(.cyan)
                                    }
                                    .font(.caption).frame(minWidth: 54)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("\(hourTime(hour.date, timeZone: scene.timeZone)), \(temperature(hour.celsius)), precipitation \(hour.precipitationChance.formatted(.percent))")
                                }
                            }.padding(.vertical, 6)
                        }.accessibilityIdentifier("omnibar-weather-hourly")
                        Text("Updated \(scene.date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.white.opacity(0.65))
                    } else {
                        Label("Weather", systemImage: "cloud.sun").font(.title2)
                        Text(store.status.isEmpty ? "Choose a location to see your weather and hourly forecast." : store.status)
                            .font(.callout).foregroundStyle(.white.opacity(0.85))
                            .accessibilityIdentifier("omnibar-weather-status")
                        if store.status.contains("Loading") || store.status.contains("Finding") {
                            ProgressView().tint(.white)
                        }
                    }
                }.padding(18)
            }
            HStack {
                Button(city.isEmpty && !currentLocation ? "Choose location" : "Change location", systemImage: "location") { configuring = true }
                    .frame(minHeight: 44).accessibilityIdentifier("omnibar-weather-location")
                Spacer(minLength: 8)
                Button("Search the web", action: onSearch)
                    .frame(minHeight: 44).accessibilityIdentifier("omnibar-weather-search")
            }.font(.caption).padding(.horizontal, 18)
            if let attribution = store.attribution {
                HStack(spacing: 12) {
                    AsyncImage(url: attribution.combinedMarkDarkURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit().frame(width: 90, height: 20)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Apple Weather").accessibilityAddTraits(.isImage)
                                .accessibilityIdentifier("omnibar-weather-mark")
                                .onAppear { credited = true }
                                .onDisappear { credited = false }
                        } else {
                            Text(phase.error == nil ? "Loading Apple Weather attribution…" : "Apple Weather attribution is unavailable.")
                                .font(.caption2).onAppear { credited = false }
                        }
                    }
                    Spacer(minLength: 0)
                    Link("Weather data sources", destination: attribution.legalPageURL)
                        .font(.caption2).accessibilityIdentifier("omnibar-weather-attribution")
                }.padding(.horizontal, 18).padding(.vertical, 12)
            } else if preview {
                Text("Preview weather · No live service requested").font(.caption2).padding(12)
            }
        }
        .foregroundStyle(.white).tint(.white)
        .background(Color(red: 0.04, green: 0.09, blue: 0.16).opacity(0.91),
                    in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.15)))
        .weatherLandingSurface()
        .preference(key: OmnibarWeatherCreditVisible.self, value: credited)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("omnibar-weather")
        .popover(isPresented: $configuring) { NewspaperWeatherLocationPopup(enablesMasthead: false).foregroundStyle(.primary).tint(.accentColor) }
        .onAppear { store.beginOmnibar(client) }
        .onChange(of: credited) { _, visible in store.setOmnibarAttributionVisible(visible, client: client) }
        .task(id: "\(city)-\(currentLocation)") { store.beginOmnibar(client); await store.loadForOmnibar() }
        .onDisappear { store.endOmnibar(client) }
    }
}
