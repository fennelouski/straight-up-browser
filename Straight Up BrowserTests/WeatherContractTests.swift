import Foundation
import Testing
@testable import Browser

@MainActor struct WeatherContractTests {
    let now = Date(timeIntervalSince1970: 1791792000)
    var point: BrowserWeatherPlace { .init(town: "Leiden", region: "", country: "Netherlands", countryCode: "NL", latitude: 52.16, longitude: 4.49, timeZoneID: "Europe/Amsterdam") }
    private func payload() -> [String: Any] {
        let epoch = now.timeIntervalSince1970 * 1000
        let current: [String: Any] = ["observedAt": epoch, "expiresAt": epoch + 600000, "providerExpiresAt": epoch + 600000,
            "condition": ["code": "rain", "temperatureC": 12, "daylight": true]]
        let hours: [[String: Any]] = (0..<24).map { ["startAt": epoch + Double($0) * 3600000, "code": "rain", "temperatureC": 12, "daylight": true, "precipitationChance": 0.7] }
        let hourly: [String: Any] = ["observedAt": epoch, "expiresAt": epoch + 600000, "providerExpiresAt": epoch + 600000, "hours": hours]
        return ["version": 2, "location": ["latitude": point.latitude, "longitude": point.longitude], "datasets": ["current": current, "hourly": hourly],
            "attribution": ["serviceName": "Apple Weather", "markURL": "https://example.com/mark.png", "legalPageURL": "https://example.com/legal"],
            "provenance": ["provider": "apple-weather", "transformed": false], "expiresAt": epoch + 600000, "source": "cache", "stale": false]
    }
    private func decode(_ value: [String: Any]) throws -> BrowserWeatherForecast {
        try JSONDecoder().decode(SharedWeatherV2.self, from: JSONSerialization.data(withJSONObject: value)).forecast(place: point, now: now)
    }
    @Test func sharedContractPreservesExpiryAttributionAndMissingCapabilities() throws {
        let result = try decode(payload())
        #expect(result.scene.hours.count == 24 && result.scene.timeZone == point.timeZone)
        #expect(!result.source.dailyAvailable && !result.source.nowcastAvailable && !result.source.windAvailable)
        #expect(!result.source.apparentTemperatureAvailable && !result.source.historyAvailable)
        #expect(result.source.expiresAt == now.addingTimeInterval(600))
        #expect(result.source.markURL?.absoluteString == "https://example.com/mark.png")
    }
    @Test func sharedContractRejectsStaleFutureOrWrongLocationData() throws {
        var stale = payload(); stale["stale"] = true
        #expect(throws: BrowserWeatherError.self) { try decode(stale) }
        var expired = payload(); expired["expiresAt"] = now.timeIntervalSince1970 * 1000 - 1
        #expect(throws: BrowserWeatherError.self) { try decode(expired) }
        var wrong = payload(); wrong["location"] = ["latitude": 0, "longitude": 0]
        #expect(throws: BrowserWeatherError.self) { try decode(wrong) }
        var future = payload(), datasets = future["datasets"] as! [String: Any], current = datasets["current"] as! [String: Any]
        current["observedAt"] = now.timeIntervalSince1970 * 1000 + 60000; datasets["current"] = current; future["datasets"] = datasets
        #expect(throws: BrowserWeatherError.self) { try decode(future) }
    }
    @Test func sharedContractRejectsGapsProbabilityUnitsAndUnsafeAttribution() throws {
        var value = payload(), datasets = value["datasets"] as! [String: Any], hourly = datasets["hourly"] as! [String: Any]
        var hours = hourly["hours"] as! [[String: Any]]; hours[3]["startAt"] = hours[2]["startAt"]
        hourly["hours"] = hours; datasets["hourly"] = hourly; value["datasets"] = datasets
        #expect(throws: BrowserWeatherError.self) { try decode(value) }
        value = payload(); datasets = value["datasets"] as! [String: Any]; hourly = datasets["hourly"] as! [String: Any]
        hours = hourly["hours"] as! [[String: Any]]; hours[0]["precipitationChance"] = 70
        hourly["hours"] = hours; datasets["hourly"] = hourly; value["datasets"] = datasets
        #expect(throws: BrowserWeatherError.self) { try decode(value) }
        value = payload(); value["attribution"] = ["serviceName": "Apple Weather", "markURL": "http://example.com/mark", "legalPageURL": "https://example.com/legal"]
        #expect(throws: BrowserWeatherError.self) { try decode(value) }
    }
    @Test func tomorrowContractsNormalizePercentAndMetricUnits() throws {
        let current: [String: Any] = ["data": ["time": "2026-10-12T08:00:00Z", "values": ["temperature": 15, "temperatureApparent": 14,
            "windSpeed": 4, "windGust": 7, "weatherCode": 4001, "uvIndex": 1]]]
        let formatter = ISO8601DateFormatter()
        let hours: [[String: Any]] = (0..<24).map { ["time": formatter.string(from: now.addingTimeInterval(Double($0) * 3600)),
            "values": ["temperature": 15, "weatherCode": 4001, "windSpeed": 4, "windGust": 7, "precipitationProbability": 70, "rainIntensity": 2]] }
        let daily: [[String: Any]] = [["time": "2026-10-13T00:00:00Z", "values": ["temperatureMax": 18, "temperatureMin": 9,
            "precipitationProbabilityMax": 60, "rainAccumulationSum": 4, "weatherCodeMax": 4001, "sunriseTime": "2026-10-13T06:00:00Z"]]]
        let forecast: [String: Any] = ["timelines": ["hourly": hours, "daily": daily]]
        let result = try TomorrowWeatherAdapter.decode(realtime: JSONSerialization.data(withJSONObject: current),
            forecast: JSONSerialization.data(withJSONObject: forecast), place: point, now: now)
        #expect(result.scene.celsius == 15 && result.scene.wind == 4 && result.scene.gust == 7)
        #expect(result.scene.hours[0].precipitationChance == 0.7 && result.scene.hours[0].precipitationMM == 2)
        #expect(result.scene.days[0].precipitationChance == 0.6 && result.scene.days[0].precipitationMM == 4)
    }
    @Test func localAppleQuotaRefusesAnUncachedRequest() async {
        let prefs = UserDefaults(suiteName: "WeatherQuotaFixture." + UUID().uuidString)!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.dateInterval(of: .day, for: now)!.start.timeIntervalSince1970
        prefs.set(["apple|\(start)": 100], forKey: "browserWeatherRequestAttempts")
        var calls = 0
        let service = BrowserWeatherService(preferences: prefs, clock: { now }, provider: { _, _ in calls += 1; throw BrowserWeatherError.unavailable })
        await #expect(throws: BrowserWeatherError.self) { try await service.forecast(for: point) }
        #expect(calls == 0)
    }
}
