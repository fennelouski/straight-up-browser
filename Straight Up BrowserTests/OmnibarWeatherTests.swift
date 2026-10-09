import Foundation
import Testing
import WeatherKit
@testable import Browser

@MainActor struct OmnibarWeatherTests {
    @Test func weatherIntentIsExactAndDoesNotHijackURLsOrHistory() {
        for query in ["weather", " WEATHER ", "\nWeather\t"] { #expect(OmnibarWeatherIntent.matches(query)) }
        for query in ["weathe", "weather.com", "weather tomorrow", "https://weather.example", ""] {
            #expect(!OmnibarWeatherIntent.matches(query))
        }
        #expect(!OmnibarWeatherIntent.matches("weather", historyMode: true))
    }
    @Test func autumnLeavesFollowTheLocationsHemisphere() {
        let october = Date(timeIntervalSince1970: 1791540000)
        let north = OmnibarWeatherSnapshot(city: "North", condition: .rain, daylight: true, latitude: 52, wind: 8, date: october)
        let south = OmnibarWeatherSnapshot(city: "South", condition: .rain, daylight: true, latitude: -33, wind: 8, date: october)
        let tropics = OmnibarWeatherSnapshot(city: "Tropics", condition: .rain, daylight: true, latitude: 2, wind: 8, date: october)
        #expect(north.hasLeaves)
        #expect(!south.hasLeaves && !tropics.hasLeaves)
    }
    @Test func snowAndRainHaveDistinctEffectsAndSnowBanksAreBounded() {
        let snowy = OmnibarWeatherSnapshot(city: "Snow", condition: .snow, daylight: false, latitude: 52, wind: 3, recentSnow: 1000)
        let rain = OmnibarWeatherSnapshot(city: "Rain", condition: .heavyRain, daylight: true, latitude: 52, wind: 2)
        #expect(snowy.isSnowing && !snowy.isRaining && snowy.snowDepth == 14)
        #expect(rain.isRaining && !rain.isSnowing && rain.snowDepth == 0)
        #expect(snowy.hours.count == 24 && Set(snowy.hours.map(\.id)).count == 24)
    }
    @Test func independentOmnibarsRetainWeatherWithoutEnablingTheMasthead() {
        let defaults = UserDefaults(suiteName: "OmnibarWeatherTests." + UUID().uuidString)!
        let store = NewspaperWeatherStore(preferences: defaults)
        let first = UUID(), second = UUID()
        store.beginOmnibar(first); store.beginOmnibar(second)
        store.setOmnibarAttributionVisible(true, client: first)
        store.setOmnibarAttributionVisible(true, client: second)
        #expect(!defaults.bool(forKey: NewspaperPreferences.Key.showWeather))
        store.endOmnibar(first)
        #expect(store.hasOmnibarClients && store.hasSceneAttribution)
        store.endOmnibar(second)
        #expect(!store.hasOmnibarClients && !store.hasSceneAttribution && store.scene == nil)
    }
}
