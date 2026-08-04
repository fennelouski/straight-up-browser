//
//  ToneScheduleTests.swift
//  Straight Up BrowserTests
//

import Testing
import Foundation
@testable import Browser

@MainActor
struct ToneScheduleTests {

    @Test func windowsWrapMidnight() {
        // 20:00 → 07:00 is night, not an empty window.
        let night: (Double) -> Bool = { ToneSchedule.inWindow($0, start: 1200, end: 420) }
        #expect(night(1380))
        #expect(night(120))
        #expect(!night(720))
        // Same-day window.
        let day: (Double) -> Bool = { ToneSchedule.inWindow($0, start: 540, end: 1020) }
        #expect(day(600))
        #expect(!day(1080))
        // Offsets can push a bound past a day boundary — 25:00 to −01:00 is
        // 01:00 to 23:00, not an inverted window.
        let offset: (Double) -> Bool = { ToneSchedule.inWindow($0, start: 1500, end: -60) }
        #expect(offset(720))
        #expect(!offset(1410))
    }

    @Test func sunTimesMatchAlmanac() throws {
        // New York, 21 June 2026: sunrise 09:25 UTC, sunset 00:31 UTC (22 June).
        let june21 = Date(timeIntervalSince1970: 1782000000) // 2026-06-21 04:00 UTC
        let sun = ToneSchedule.sunTimes(date: june21, latitude: 40.7128, longitude: -74.0060)
        let times = try! #require(sun)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let rise = utc.dateComponents([.hour, .minute], from: times.sunrise)
        let set = utc.dateComponents([.hour, .minute], from: times.sunset)
        let riseMinutes: Int = (rise.hour ?? 0) * 60 + (rise.minute ?? 0)
        let setMinutes: Int = (set.hour ?? 0) * 60 + (set.minute ?? 0)
        #expect(abs(riseMinutes - 565) <= 3)  // 09:25 UTC
        #expect(abs(setMinutes - 31) <= 3)    // 00:31 UTC, next day
    }

    @Test func polarNightHasNoSunTimes() {
        // Longyearbyen in midwinter: the sun never clears the horizon.
        let december = Date(timeIntervalSince1970: 1797120000) // 2026-12-15
        #expect(ToneSchedule.sunTimes(date: december, latitude: 78.22, longitude: 15.65) == nil)
    }
}
