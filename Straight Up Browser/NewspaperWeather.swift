import SwiftUI
import Combine
import WeatherKit
import MapKit
import CoreLocation

enum NewspaperTemperatureUnit: String, CaseIterable, Identifiable {
    case system, celsius, fahrenheit
    var id: String { rawValue }
    var title: String {
        switch self { case .system: String(localized: "Follow Region"); case .celsius: "Celsius"; case .fahrenheit: "Fahrenheit" }
    }
    func formatted(_ value: Measurement<UnitTemperature>) -> String {
        switch self {
        case .system: value.formatted(.measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
        case .celsius: value.converted(to: .celsius).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
        case .fahrenheit: value.converted(to: .fahrenheit).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
    }
}

/// Native WeatherKit only. No Browser backend, account, IP-derived location,
/// or location permission is involved; the reader supplies a city.
@MainActor
final class NewspaperWeatherStore: ObservableObject {
    static let shared = NewspaperWeatherStore()
    @Published private(set) var weather: CurrentWeather?
    @Published private(set) var attribution: WeatherAttribution?
    @Published private(set) var city = ""
    @Published private(set) var status = ""
    private var fetchedAt: Date = .distantPast
    private var generation = UUID()

    func clear() {
        generation = UUID()
        weather = nil
        attribution = nil
        city = ""
        status = ""
        fetchedAt = .distantPast
    }

    func load(city requestedCity: String) async {
        let requestedCity = requestedCity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedCity.count <= 200 else { clear(); status = String(localized: "Enter a city and country."); return }
        guard !requestedCity.isEmpty else { clear(); status = String(localized: "Choose a city in Newspaper settings."); return }
        guard city != requestedCity || Date().timeIntervalSince(fetchedAt) >= 3600 else { return }
        let requestID = UUID()
        generation = requestID
        weather = nil
        attribution = nil
        status = String(localized: "Loading weather…")
        do {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = requestedCity
            request.resultTypes = .address
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled, generation == requestID else { return }
            guard let place = response.mapItems.first else { status = String(localized: "City not found. Include a country or region."); return }
            let location: CLLocation
            if #available(macOS 26, iOS 26, *) { location = place.location }
            else { location = CLLocation(latitude: place.placemark.coordinate.latitude, longitude: place.placemark.coordinate.longitude) }
            let service = WeatherService.shared
            async let current = service.weather(for: location, including: .current)
            async let credits = service.attribution
            let (currentWeather, attribution) = try await (current, credits)
            guard !Task.isCancelled, generation == requestID,
                  UserDefaults.standard.bool(forKey: NewspaperPreferences.Key.showWeather),
                  UserDefaults.standard.string(forKey: NewspaperPreferences.Key.weatherCity)?.trimmingCharacters(in: .whitespacesAndNewlines) == requestedCity else { return }
            self.weather = currentWeather
            self.attribution = attribution
            city = requestedCity
            fetchedAt = Date()
            status = ""
        } catch {
            guard !Task.isCancelled, generation == requestID else { return }
            status = String(localized: "Weather is unavailable. Try again later.")
            Logger.log("WeatherKit failed: \((error as NSError).domain) \((error as NSError).code)", type: "Newspaper", visibility: .public)
        }
    }
}

struct NewspaperWeatherMasthead: View {
    @AppStorage(NewspaperPreferences.Key.showWeather) private var enabled = false
    @AppStorage(NewspaperPreferences.Key.weatherCity) private var city = ""
    @AppStorage(NewspaperPreferences.Key.weatherTemperatureUnit) private var unit = NewspaperTemperatureUnit.system.rawValue
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var store = NewspaperWeatherStore.shared

    var body: some View {
        Group {
            if enabled {
                if let weather = store.weather, let attribution = store.attribution {
                    VStack(alignment: .leading, spacing: 4) {
                        AsyncImage(url: scheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit().frame(width: 90, height: 20)
                                    .accessibilityLabel("Apple Weather")
                                Label("\(store.city) · \((NewspaperTemperatureUnit(rawValue: unit) ?? .system).formatted(weather.temperature)) · \(weather.condition.description)", systemImage: weather.symbolName)
                                    .font(.caption)
                                    .accessibilityIdentifier("newspaper-weather-current")
                                Text("Updated \(weather.date.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else if phase.error != nil {
                                Text("Weather attribution could not be loaded.").font(.caption)
                            } else { ProgressView().controlSize(.small) }
                        }
                        Link("Weather data sources", destination: attribution.legalPageURL).font(.caption2)
                            .accessibilityIdentifier("newspaper-weather-attribution")
                    }
                } else {
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(enabled)-\(city)") {
            if enabled { await store.load(city: city) } else { store.clear() }
        }
    }
}

struct NewspaperWeatherSettings: View {
    @AppStorage(NewspaperPreferences.Key.weatherTemperatureUnit) private var unit = NewspaperTemperatureUnit.system.rawValue
    @AppStorage(NewspaperPreferences.Key.showWeather) private var enabled = false
    @AppStorage(NewspaperPreferences.Key.weatherCity) private var city = ""
    var body: some View {
        CollapsibleSection(searchID: "newspaper.weather") {
            Toggle("Show Apple Weather in the masthead", isOn: $enabled)
            if enabled {
                TextField("City and country", text: $city)
                Picker("Temperature", selection: $unit) {
                    ForEach(NewspaperTemperatureUnit.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("City search and weather requests go directly to Apple. Your browsing and articles are not sent with them. No current-location access is requested.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Label("Weather", systemImage: "cloud.sun") }
        footer: { Text("Weather refreshes when you open Newspaper, at most once per hour. Apple Weather and its data-source attribution appear with the forecast. Weather needs an internet connection; the saved newspaper remains readable offline.") }
    }
}
