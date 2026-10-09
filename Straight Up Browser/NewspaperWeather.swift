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
/// or inferred location. Current location is a reader-selected, one-shot request;
/// coordinates remain in memory and are sent only to Apple for weather.
@MainActor
final class NewspaperWeatherStore: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = NewspaperWeatherStore()
    @Published private(set) var weather: CurrentWeather?
    @Published private(set) var attribution: WeatherAttribution?
    @Published private(set) var city = ""
    @Published private(set) var status = ""
    private var fetchedAt: Date = .distantPast
    private var generation = UUID()
    private var locationManager: CLLocationManager?
    private var requestingLocation = false
    private var locationTimeout: Task<Void, Never>?
    private var currentLocationFetchedAt: Date = .distantPast

    func useCurrentLocation(requestPermission: Bool) {
        guard UserDefaults.standard.bool(forKey: NewspaperPreferences.Key.showWeather),
              UserDefaults.standard.bool(forKey: NewspaperPreferences.Key.weatherCurrentLocation) else { return }
        guard Date().timeIntervalSince(currentLocationFetchedAt) >= 3600 || weather == nil else { return }
        if locationManager == nil {
            let manager = CLLocationManager()
            manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            locationManager = manager
            manager.delegate = self
        }
        guard let manager = locationManager else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            requestingLocation = true
            status = String(localized: "Finding your location…")
            manager.requestLocation()
            startLocationTimeout()
        case .notDetermined:
            guard requestPermission else { status = String(localized: "Click the weather icon to choose your location."); return }
            requestingLocation = true
            status = String(localized: "Allow location access to see local weather.")
            manager.requestWhenInUseAuthorization()
            startLocationTimeout()
        case .denied, .restricted:
            requestingLocation = false
            status = String(localized: "Location access is unavailable. Enter a city instead, or allow Browser in System Settings.")
        @unknown default:
            requestingLocation = false
            status = String(localized: "Enter a city to see weather.")
        }
    }

    private func startLocationTimeout() {
        locationTimeout?.cancel()
        locationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.requestingLocation else { return }
            self.requestingLocation = false
            self.locationManager?.stopUpdatingLocation()
            self.status = String(localized: "Your location is unavailable. Enter a city instead.")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requestingLocation else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted:
            requestingLocation = false
            locationTimeout?.cancel()
            status = String(localized: "Location access is unavailable. Enter a city instead, or allow Browser in System Settings.")
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard requestingLocation, UserDefaults.standard.bool(forKey: NewspaperPreferences.Key.showWeather),
              UserDefaults.standard.bool(forKey: NewspaperPreferences.Key.weatherCurrentLocation), let location = locations.last,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 10000,
              abs(location.timestamp.timeIntervalSinceNow) < 120 else { return }
        requestingLocation = false
        locationTimeout?.cancel()
        let requestID = UUID()
        generation = requestID
        weather = nil
        attribution = nil
        status = String(localized: "Loading weather…")
        Task { await fetch(location: location, label: String(localized: "Current location"), requestID: requestID, currentLocation: true) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard requestingLocation else { return }
        requestingLocation = false
        locationTimeout?.cancel()
        status = String(localized: "Your location is unavailable. Enter a city instead.")
    }

    func clear() {
        generation = UUID()
        requestingLocation = false
        locationTimeout?.cancel()
        locationManager?.stopUpdatingLocation()
        currentLocationFetchedAt = .distantPast
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
            await fetch(location: location, label: requestedCity, requestID: requestID, currentLocation: false)
        } catch {
            guard !Task.isCancelled, generation == requestID else { return }
            status = String(localized: "Weather is unavailable. Try again later.")
            Logger.log("WeatherKit failed: \((error as NSError).domain) \((error as NSError).code)", type: "Newspaper", visibility: .public)
        }
    }

    private func fetch(location: CLLocation, label: String, requestID: UUID, currentLocation: Bool) async {
        do {
            let service = WeatherService.shared
            async let current = service.weather(for: location, including: .current)
            async let credits = service.attribution
            let (currentWeather, creditsValue) = try await (current, credits)
            guard !Task.isCancelled, generation == requestID,
                  UserDefaults.standard.bool(forKey: NewspaperPreferences.Key.showWeather),
                  UserDefaults.standard.bool(forKey: NewspaperPreferences.Key.weatherCurrentLocation) == currentLocation,
                  currentLocation || UserDefaults.standard.string(forKey: NewspaperPreferences.Key.weatherCity)?.trimmingCharacters(in: .whitespacesAndNewlines) == label else { return }
            weather = currentWeather
            attribution = creditsValue
            city = label
            fetchedAt = Date()
            if currentLocation { currentLocationFetchedAt = fetchedAt }
            status = ""
        } catch {
            guard !Task.isCancelled, generation == requestID else { return }
            status = String(localized: "Weather is unavailable. Click the weather icon to try another location.")
            Logger.log("WeatherKit failed: \((error as NSError).domain) \((error as NSError).code)", type: "Newspaper", visibility: .public)
        }
    }

}

struct NewspaperWeatherMasthead: View {
    @State private var configuring = false
    @State private var attributionLoaded = false
    @AppStorage(NewspaperPreferences.Key.showWeather) private var enabled = false
    @AppStorage(NewspaperPreferences.Key.weatherCity) private var city = ""
    @AppStorage(NewspaperPreferences.Key.weatherCurrentLocation) private var currentLocation = false
    @AppStorage(NewspaperPreferences.Key.weatherTemperatureUnit) private var unit = NewspaperTemperatureUnit.system.rawValue
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var store = NewspaperWeatherStore.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                configuring = true
            } label: {
                Group {
                    if enabled, attributionLoaded, let weather = store.weather {
                        Label("\(store.city) · \((NewspaperTemperatureUnit(rawValue: unit) ?? .system).formatted(weather.temperature)) · \(weather.condition.description)", systemImage: weather.symbolName)
                    } else {
                        Image(systemName: "cloud.sun").font(.title3)
                    }
                }.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .font(.caption).buttonStyle(BrowserPressStyle())
            .accessibilityLabel(enabled && store.weather != nil ? "Weather · \(store.city)" : "Choose weather location")
            .accessibilityIdentifier("newspaper-weather-location")
            .help("Choose weather location")
            if enabled, let weather = store.weather, let attribution = store.attribution {
                AsyncImage(url: scheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().frame(width: 90, height: 20).accessibilityLabel("Apple Weather")
                            .onAppear { attributionLoaded = true }
                            .onDisappear { attributionLoaded = false }
                        Text("Updated \(weather.date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("newspaper-weather-current")
                    } else if phase.error != nil {
                        Text("Weather attribution could not be loaded.").font(.caption)
                    } else { ProgressView().controlSize(.small) }
                }
                Link("Weather data sources", destination: attribution.legalPageURL).font(.caption2)
                    .accessibilityIdentifier("newspaper-weather-attribution")
            } else if enabled, !store.status.isEmpty {
                Text(store.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 240, alignment: .trailing)
            }
        }
        .popover(isPresented: $configuring) { NewspaperWeatherLocationPopup() }
        .task(id: "\(enabled)-\(currentLocation)-\(city)") {
            if !enabled { store.clear() }
            else if currentLocation { store.useCurrentLocation(requestPermission: false) }
            else { await store.load(city: city) }
        }
    }
}

struct NewspaperWeatherLocationPopup: View {
    @AppStorage(NewspaperPreferences.Key.showWeather) private var enabled = false
    @AppStorage(NewspaperPreferences.Key.weatherCity) private var city = ""
    @AppStorage(NewspaperPreferences.Key.weatherCurrentLocation) private var currentLocation = false
    @State private var draftCity = ""
    @ObservedObject private var store = NewspaperWeatherStore.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Weather location").font(.headline)
            Button("Use current location", systemImage: "location") {
                enabled = true
                currentLocation = true
                store.useCurrentLocation(requestPermission: true)
            }.accessibilityIdentifier("newspaper-weather-use-current")
            TextField("City and country", text: $draftCity).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("newspaper-weather-city")
                .onSubmit { saveCity() }
            Text("Choose a city or allow location access for local weather. Location and weather requests use Apple.")
                .font(.caption).foregroundStyle(.secondary)
            if !store.status.isEmpty { Text(store.status).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { dismiss() }
                if enabled { Button("Turn off weather") { enabled = false; store.clear(); dismiss() } }
                Spacer()
                Button("Use this city") { saveCity() }
                    .disabled(draftCity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 310)
            .onAppear { draftCity = city }
            .newspaperMotion(store.status)
    }
    private func saveCity() {
        let value = draftCity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { return }
        store.clear()
        city = value
        currentLocation = false
        enabled = true
        dismiss()
    }
}

struct NewspaperWeatherSettings: View {
    @AppStorage(NewspaperPreferences.Key.weatherTemperatureUnit) private var unit = NewspaperTemperatureUnit.system.rawValue
    @AppStorage(NewspaperPreferences.Key.showWeather) private var enabled = false
    @AppStorage(NewspaperPreferences.Key.weatherCity) private var city = ""
    @AppStorage(NewspaperPreferences.Key.weatherCurrentLocation) private var currentLocation = false
    @State private var configuring = false
    var body: some View {
        CollapsibleSection(searchID: "newspaper.weather") {
            Toggle("Show Apple Weather in the masthead", isOn: $enabled)
            if enabled {
                Button(currentLocation ? "Current location" : city.isEmpty ? "Choose location" : city, systemImage: "location") { configuring = true }
                    .popover(isPresented: $configuring) { NewspaperWeatherLocationPopup() }
                Picker("Temperature", selection: $unit) {
                    ForEach(NewspaperTemperatureUnit.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("City search and weather requests go directly to Apple. Your browsing and articles are not sent with them. Current location is requested only when you choose it; coordinates are not saved or synced.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Label("Weather", systemImage: "cloud.sun") }
        footer: { Text("Weather refreshes when you open Newspaper, at most once per hour. Apple Weather and its data-source attribution appear with the forecast. Weather needs an internet connection; the saved newspaper remains readable offline.") }
    }
}
