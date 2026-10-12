import Foundation
import CoreGraphics
import Testing
import WeatherKit
@testable import Browser

@MainActor struct OmnibarWeatherTests {
    @Test func weatherIntentIsExactAndDoesNotHijackURLsOrHistory() {
        for query in ["weather", " WEATHER ", "\nWeather\t"] { #expect(OmnibarWeatherIntent.matches(query)) }
        for query in ["weathe", "weather.com", "https://weather.example", ""] {
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
        let freshSnow = OmnibarWeatherSnapshot(city: "Fresh snow", condition: .snow, daylight: true, latitude: 52, wind: 2)
        #expect(freshSnow.snowDepth == 0)
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

    @Test func precipitationEntersAboveTheViewportAndAcceleratesToTerminalSpeed() {
        let drop = OmnibarWeatherParticle(originX: 80, terminalSpeed: 500, responseTime: 0.14, wind: 30)
        #expect(drop.position(at: 0) == CGPoint(x: 80, y: -24))
        let first = drop.position(at: 0.05).y - drop.position(at: 0).y
        let next = drop.position(at: 0.1).y - drop.position(at: 0.05).y
        #expect(next > first)
        #expect(abs(drop.position(at: 3.1).y - drop.position(at: 3).y - 50) < 0.001)
        for y in [0.0, 10, 200, 900] {
            #expect(abs(drop.position(at: drop.fallTime(to: y)).y - y) < 0.001)
        }
        let flake = OmnibarWeatherParticle(originX: 80, terminalSpeed: 60, responseTime: 0.65, wind: 30)
        #expect(flake.fallTime(to: 200) > drop.fallTime(to: 200))
    }

    @Test func collisionsUseTheWindBlownPositionAndFirstExposedTopEdge() {
        let size = CGSize(width: 500, height: 500)
        let lower = CGRect(x: 0, y: 200, width: 400, height: 60)
        let upper = CGRect(x: 0, y: 100, width: 150, height: 50)
        let drop = OmnibarWeatherParticle(originX: 50, terminalSpeed: 100, responseTime: 0.2, wind: 80)
        let landing = drop.landing(in: size, surfaces: [lower, upper])
        // Wind carries this drop past the upper control before it reaches its top.
        #expect(landing.surface == 0)
        #expect(abs(landing.point.y - lower.minY) < 0.001)
        #expect(landing.point.x > upper.maxX)
        let calm = OmnibarWeatherParticle(originX: 50, terminalSpeed: 100, responseTime: 0.2, wind: 0)
        #expect(calm.landing(in: size, surfaces: [lower, upper]).surface == 1)
        #expect(calm.landing(in: size, surfaces: [upper, lower]).surface == 0)
        let corner = OmnibarWeatherParticle(originX: 5, terminalSpeed: 100, responseTime: 0.2, wind: 0)
        #expect(corner.landing(in: size, surfaces: [upper]).surface == nil)
        #expect(calm.landing(in: size, surfaces: [.zero, CGRect(x: 0, y: -20, width: 100, height: 10)]).surface == nil)
    }

    @Test func accumulationStartsAtImpactAndDoesNotDependOnFrameRate() {
        #expect(OmnibarWeatherParticle.impactCount(time: 0, delay: 0.5, flight: 2, period: 5) == 0)
        #expect(OmnibarWeatherParticle.impactCount(time: 2.49, delay: 0.5, flight: 2, period: 5) == 0)
        #expect(OmnibarWeatherParticle.impactCount(time: 2.5, delay: 0.5, flight: 2, period: 5) == 1)
        #expect(OmnibarWeatherParticle.impactCount(time: 7.5, delay: 0.5, flight: 2, period: 5) == 2)
        #expect(OmnibarWeatherParticle.impactCount(time: 52.5, delay: 0.5, flight: 2, period: 5) == 11)
    }
}
