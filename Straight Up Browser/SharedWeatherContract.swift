import Foundation
import WeatherKit

/// Tested Fonsters v2 contract only. No invented HTTP route or embedded server
/// token; activation requires production account auth and missing coverage work.
nonisolated struct SharedWeatherV2: Decodable {
    struct Location: Decodable { let latitude: Double; let longitude: Double }
    struct Condition: Decodable { let code: String; let temperatureC: Double; let daylight: Bool }
    struct Current: Decodable { let observedAt: Double; let expiresAt: Double; let providerExpiresAt: Double; let condition: Condition }
    struct Hour: Decodable { let startAt: Double; let code: String; let temperatureC: Double; let daylight: Bool; let precipitationChance: Double }
    struct Hourly: Decodable { let observedAt: Double; let expiresAt: Double; let providerExpiresAt: Double; let hours: [Hour] }
    struct Datasets: Decodable { let current: Current; let hourly: Hourly }
    struct Attribution: Decodable { let serviceName: String; let markURL: URL; let legalPageURL: URL }
    struct Provenance: Decodable { let provider: String; let transformed: Bool }
    let version: Int
    let location: Location
    let datasets: Datasets
    let attribution: Attribution
    let provenance: Provenance
    let expiresAt: Double
    let source: String
    let stale: Bool
    func forecast(place: BrowserWeatherPlace, now: Date) throws -> BrowserWeatherForecast {
        let current = datasets.current, hourly = datasets.hourly, epoch = now.timeIntervalSince1970 * 1000
        guard version == 2, !stale, ["apple", "cache"].contains(source), provenance.provider == "apple-weather", !provenance.transformed,
              location.latitude.isFinite, location.longitude.isFinite,
              abs(location.latitude - place.latitude) < 0.00001, abs(location.longitude - place.longitude) < 0.00001,
              attribution.serviceName == "Apple Weather", attribution.markURL.scheme == "https", attribution.legalPageURL.scheme == "https",
              expiresAt.isFinite, expiresAt == min(current.expiresAt, hourly.expiresAt), expiresAt > epoch,
              !current.condition.code.isEmpty, current.condition.code.count <= 128, current.condition.temperatureC.isFinite, (-100...100).contains(current.condition.temperatureC), hourly.hours.count == 24 else { throw BrowserWeatherError.unavailable }
        for (issued, expiry, providerExpiry) in [(current.observedAt, current.expiresAt, current.providerExpiresAt), (hourly.observedAt, hourly.expiresAt, hourly.providerExpiresAt)] {
            guard issued.isFinite, expiry.isFinite, providerExpiry.isFinite, issued <= epoch, epoch - issued < 7_200_000,
                  expiry > epoch, expiry <= providerExpiry, expiry <= issued + 7_200_000 else { throw BrowserWeatherError.unavailable }
        }
        let start = floor(epoch / 3_600_000) * 3_600_000
        for (index, hour) in hourly.hours.enumerated() {
            guard hour.startAt == start + Double(index) * 3_600_000, hour.temperatureC.isFinite,
                  (-100...100).contains(hour.temperatureC), hour.precipitationChance.isFinite,
                  (0...1).contains(hour.precipitationChance), !hour.code.isEmpty, hour.code.count <= 128 else { throw BrowserWeatherError.unavailable }
        }
        let condition = WeatherCondition(rawValue: current.condition.code) ?? .cloudy
        let hours = hourly.hours.map { OmnibarWeatherSnapshot.Hour(date: Date(timeIntervalSince1970: $0.startAt / 1000),
            symbol: "cloud.fill", celsius: $0.temperatureC, precipitationChance: $0.precipitationChance, wind: 0) }
        let scene = OmnibarWeatherSnapshot(place: place, condition: condition, symbol: "cloud.fill", celsius: current.condition.temperatureC,
            feelsLike: current.condition.temperatureC, daylight: current.condition.daylight, cloudCover: 0, wind: 0, windDirection: 0,
            date: Date(timeIntervalSince1970: current.observedAt / 1000), hours: hours, days: [])
        return BrowserWeatherForecast(place: place, scene: scene,
            source: BrowserWeatherSource(provider: "shared-v2", name: attribution.serviceName, legalURL: attribution.legalPageURL,
                markURL: attribution.markURL, issuedAt: Date(timeIntervalSince1970: max(current.observedAt, hourly.observedAt) / 1000),
                expiresAt: Date(timeIntervalSince1970: expiresAt / 1000), dailyAvailable: false, windAvailable: false, apparentTemperatureAvailable: false, historyAvailable: false, conditionDescription: WeatherCondition(rawValue: current.condition.code)?.description ?? "Condition code: \(current.condition.code)"))
    }
}
