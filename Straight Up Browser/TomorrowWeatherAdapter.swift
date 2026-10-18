import Foundation
import SwiftUI
import WeatherKit

/// Header-only authentication, no cookies, disk cache, redirects or key logging.
private final class WeatherNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor enum TomorrowWeatherAdapter {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: BrowserProfileNetwork.configuration(configuration), delegate: WeatherNoRedirectDelegate(), delegateQueue: nil)
    }()
    static func request(_ endpoint: String, place: BrowserWeatherPlace, key: String) throws -> URLRequest {
        guard ["forecast", "realtime"].contains(endpoint), place.isValid, BrowserWeatherKeychain.valid(key) else { throw BrowserWeatherError.credentials }
        var components = URLComponents(string: "https://api.tomorrow.io/v4/weather/\(endpoint)")!
        components.queryItems = [.init(name: "location", value: "\(place.latitude),\(place.longitude)"), .init(name: "units", value: "metric")]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(key, forHTTPHeaderField: "apikey"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    static func fetch(_ place: BrowserWeatherPlace) async throws -> BrowserWeatherForecast {
        guard BrowserProfile.defaults.bool(forKey: "browserWeatherBYOEnabled"), let key = BrowserWeatherKeychain.read() else { throw BrowserWeatherError.credentials }
        let realtime = try await get(request("realtime", place: place, key: key))
        try Task.checkCancellation()
        let forecast = try await get(request("forecast", place: place, key: key))
        return try decode(realtime: realtime, forecast: forecast, place: place, now: Date())
    }
    private static func get(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.host == "api.tomorrow.io", data.count <= 2_000_000 else { throw BrowserWeatherError.unavailable }
        switch response.statusCode {
        case 200: return data
        case 401, 403: throw BrowserWeatherError.credentials
        case 429:
            let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 3600
            throw BrowserWeatherError.quota(Date().addingTimeInterval(min(86400, max(1, seconds))))
        default: throw BrowserWeatherError.unavailable
        }
    }
    struct Payload: Decodable {
        struct Step: Decodable { let time: String; let values: [String: Double] }
        struct Timelines: Decodable { let hourly: [Step] }
        let timelines: Timelines
    }
    struct Realtime: Decodable { let data: Payload.Step }
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
    static func decode(realtime: Data, forecast: Data, place: BrowserWeatherPlace, now: Date) throws -> BrowserWeatherForecast {
        let current = try JSONDecoder().decode(Realtime.self, from: realtime).data
        let payload = try JSONDecoder().decode(Payload.self, from: forecast)
        guard let issued = date(current.time), issued <= now.addingTimeInterval(60), now.timeIntervalSince(issued) <= 3600 else { throw BrowserWeatherError.unavailable }
        func value(_ values: [String: Double], _ name: String, range: ClosedRange<Double>) throws -> Double {
            guard let value = values[name], value.isFinite, range.contains(value) else { throw BrowserWeatherError.unavailable }
            return value
        }
        let temperature = try value(current.values, "temperature", range: -100...100)
        let feelsLike = try value(current.values, "temperatureApparent", range: -100...100)
        let wind = try value(current.values, "windSpeed", range: 0...200)
        let code = try value(current.values, "weatherCode", range: 0...10000)
        let (currentCondition, symbol) = condition(Int(code))
        var hours: [OmnibarWeatherSnapshot.Hour] = []
        for step in payload.timelines.hourly.prefix(120) {
            guard let time = date(step.time) else { throw BrowserWeatherError.unavailable }
            let temperature = try value(step.values, "temperature", range: -100...100)
            let probability = try value(step.values, "precipitationProbability", range: 0...100) / 100
            let speed = try value(step.values, "windSpeed", range: 0...200)
            let code = try value(step.values, "weatherCode", range: 0...10000)
            var rain: Double?
            if let intensity = step.values["rainIntensity"] {
                guard intensity.isFinite && (0...2000).contains(intensity) else { throw BrowserWeatherError.unavailable }
                rain = intensity // mm/hour over a one-hour forecast interval.
            }
            let gust = step.values["windGust"]
            guard gust == nil || (gust!.isFinite && (0...200).contains(gust!)) else { throw BrowserWeatherError.unavailable }
            hours.append(.init(date: time, symbol: condition(Int(code)).1, celsius: temperature,
                precipitationChance: probability, wind: speed, gust: gust, precipitationMM: rain))
        }
        guard hours.count >= 24, Set(hours.map(\.id)).count == hours.count else { throw BrowserWeatherError.unavailable }
        hours.sort { $0.date < $1.date }
        guard zip(hours, hours.dropFirst()).allSatisfy({ abs($1.date.timeIntervalSince($0.date) - 3600) < 1 }),
              hours[0].date <= now, hours[0].date > now.addingTimeInterval(-3600) else { throw BrowserWeatherError.unavailable }
        var days: [OmnibarWeatherSnapshot.Day] = []
        var sunrise: Date?, sunset: Date?
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = place.timeZone
        // Daily values include timestamp strings, so decode that branch separately.
        if let root = try JSONSerialization.jsonObject(with: forecast) as? [String: Any],
           let timelines = root["timelines"] as? [String: Any], let daily = timelines["daily"] as? [[String: Any]] {
            for day in daily.prefix(7) {
                guard let time = day["time"] as? String, let date = date(time), let values = day["values"] as? [String: Any],
                      let high = values["temperatureMax"] as? Double, let low = values["temperatureMin"] as? Double,
                      let probability = values["precipitationProbabilityMax"] as? Double,
                      let precipitation = values["rainAccumulationSum"] as? Double,
                      high.isFinite, low.isFinite, (-100...100).contains(low), (-100...100).contains(high), low <= high,
                      (0...100).contains(probability), precipitation.isFinite, precipitation >= 0 else { continue }
                if calendar.isDate(date, inSameDayAs: now) {
                    sunrise = (values["sunriseTime"] as? String).flatMap(Self.date)
                    sunset = (values["sunsetTime"] as? String).flatMap(Self.date)
                }
                days.append(.init(date: date, symbol: condition((values["weatherCodeMax"] as? Int) ?? 1001).1,
                    high: high, low: low, precipitationChance: probability / 100, precipitationMM: precipitation,
                    condition: (values["weatherCodeMax"] as? Int).map { condition($0).0 }))
            }
        }
        let gust = current.values["windGust"]
        guard gust == nil || (gust!.isFinite && (0...200).contains(gust!)) else { throw BrowserWeatherError.unavailable }
        let daylight: Bool
        if let sunrise, let sunset, sunset > sunrise { daylight = now >= sunrise && now < sunset }
        else { daylight = (current.values["uvIndex"] ?? 0) > 0 }
        let scene = OmnibarWeatherSnapshot(place: place, condition: currentCondition, symbol: symbol, celsius: temperature,
            feelsLike: feelsLike, daylight: daylight, cloudCover: min(1, max(0, (current.values["cloudCover"] ?? 100) / 100)),
            wind: wind, windDirection: current.values["windDirection"] ?? 0, date: issued,
            hours: Array(hours.prefix(48)), days: days, gust: gust, sunrise: sunrise, sunset: sunset)
        return BrowserWeatherForecast(place: place, scene: scene,
            source: BrowserWeatherSource(provider: "tomorrow", name: "Tomorrow.io", legalURL: URL(string: "https://www.tomorrow.io/weather-api/")!,
                markURL: nil, issuedAt: now, expiresAt: now.addingTimeInterval(300), dailyAvailable: !days.isEmpty, historyAvailable: false))
    }
    static func condition(_ code: Int) -> (WeatherCondition, String) {
        switch code {
        case 1000, 1100: (.clear, "sun.max.fill")
        case 1101, 1102: (.partlyCloudy, "cloud.sun.fill")
        case 2000, 2100: (.foggy, "cloud.fog.fill")
        case 4000: (.drizzle, "cloud.drizzle.fill")
        case 4001, 4200: (.rain, "cloud.rain.fill")
        case 4201: (.heavyRain, "cloud.heavyrain.fill")
        case 5000, 5001, 5100, 5101: (.snow, "cloud.snow.fill")
        case 6000, 6001, 6200, 6201: (.freezingRain, "cloud.sleet.fill")
        case 7000, 7101, 7102: (.sleet, "cloud.sleet.fill")
        case 8000: (.thunderstorms, "cloud.bolt.rain.fill")
        default: (.cloudy, "cloud.fill")
        }
    }
}

struct WeatherProviderSettings: View {
    var validationPlace: BrowserWeatherPlace? = nil
    @State private var validating = false
    @AppStorage("browserWeatherProvider", store: BrowserProfile.defaults) private var provider = "apple"
    @AppStorage("browserWeatherAllowAppleFallback", store: BrowserProfile.defaults) private var fallback = false
    @AppStorage("browserWeatherBYOEnabled", store: BrowserProfile.defaults) private var enabled = false
    @AppStorage("browserWeatherCredentialRevision", store: BrowserProfile.defaults) private var revision = "native"
    @State private var key = ""
    @State private var hasKey = false
    @State private var status = ""
    @State private var showingHelp = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Forecast", systemImage: "cloud.sun").font(.headline)
                Spacer()
                Button { showingHelp = true } label: { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel("Weather provider help")
                    .popover(isPresented: $showingHelp) {
                        Text("Keys stay in this device's Keychain. Coordinates go to your selected provider. Tomorrow.io uses your existing plan; check its limits before enabling requests. Browser does not purchase or upgrade plans. Apple limits are local safeguards, not your membership's remaining shared quota.")
                            .font(.callout).padding(16).frame(width: 280)
                    }
            }
            Picker("Provider", selection: $provider) {
                Text("Apple Weather").tag("apple")
                Text("Tomorrow.io").tag("tomorrow")
            }
            .onChange(of: provider) { _, _ in BrowserWeatherService.shared.invalidate() }
            if provider == "tomorrow" {
            SecureField(hasKey ? "Replace API key" : "API key", text: $key).textFieldStyle(.roundedBorder)
            HStack {
                Button(hasKey ? "Replace key" : "Save key") { update(key) }.disabled(key.isEmpty)
                if hasKey { Button("Remove key", role: .destructive) { update("") } }
            }
            Toggle("Use my Tomorrow.io plan", isOn: $enabled)
                .disabled(!hasKey).onChange(of: enabled) { _, _ in BrowserWeatherService.shared.invalidate() }
            Text("Uses your plan's requests.").font(.caption).foregroundStyle(.secondary)
            if let validationPlace {
                Button(validating ? "Checking…" : "Check connection") {
                    validating = true
                    Task {
                        do {
                            _ = try await BrowserWeatherService.shared.forecast(for: validationPlace, provider: .tomorrow, refresh: true)
                            status = "Connected"
                        } catch { status = (error as? BrowserWeatherError)?.message ?? "Validation failed." }
                        validating = false
                    }
                }.disabled(!hasKey || !enabled || validating)
            }
            Toggle("Apple fallback", isOn: $fallback)
            }
            if !status.isEmpty { Text(status).font(.caption).lineLimit(3) }
        }.onAppear { hasKey = BrowserWeatherKeychain.hasKey() }
    }
    private func update(_ value: String) {
        do {
            try BrowserWeatherKeychain.write(value)
            key = ""; hasKey = !value.isEmpty; enabled = false
            revision = UUID().uuidString; BrowserWeatherService.shared.invalidate()
            status = hasKey ? "Key saved. Enable your plan above." : "Key removed"
        } catch { status = (error as? BrowserWeatherError)?.message ?? "Keychain could not save the key." }
    }
}
