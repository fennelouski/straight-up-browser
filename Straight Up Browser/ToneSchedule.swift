//
//  ToneSchedule.swift
//  Straight Up Browser
//
//  Decides whether the white/black point adjustments are in effect right now.
//

#if os(macOS)
import SwiftUI
import AppKit
import Combine
import Intents

@MainActor
final class ToneSchedule: ObservableObject {
    static let shared = ToneSchedule()

    enum Mode: String, CaseIterable {
        case always, fixed, sun, sleepFocus, darkMode
    }

    /// True when the tone adjustments should be applied to pages.
    @Published private(set) var isActive = true
    /// One line describing what the current mode resolved to, shown in Settings.
    @Published private(set) var status = ""

    private var timer: Timer?
    private var locationTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    private init() {
        refresh()
        // ponytail: one 60s poll drives fixed times, sun times and the Focus
        // file alike. Watching three sources properly (file events, a timer
        // armed for the next boundary) buys nothing a minute of lag doesn't.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        NotificationCenter.default.addObserver(
            forName: .toneScheduleChanged, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    var mode: Mode { Mode(rawValue: defaults.string(forKey: "toneScheduleMode") ?? "") ?? .always }

    /// The on-window as minutes-of-day, for the two time-based modes. Takes a
    /// mode so the settings demo can preview one you haven't saved yet.
    func window(for previewMode: Mode? = nil) -> (start: Double, end: Double)? {
        switch previewMode ?? mode {
        case .fixed:
            return (minutes("toneFixedStart", default: 20 * 60), minutes("toneFixedEnd", default: 7 * 60))
        case .sun:
            let sunset = defaults.double(forKey: "toneSunsetOffset")
            let sunrise = defaults.double(forKey: "toneSunriseOffset")
            guard let sun = sunTimes(for: Date()) else {
                // No location yet, or a polar day/night where the sun never
                // crosses the horizon. Fall back to the fixed-time defaults.
                return (20 * 60 + sunset, 7 * 60 + sunrise)
            }
            return (Self.minutesOfDay(sun.sunset) + sunset, Self.minutesOfDay(sun.sunrise) + sunrise)
        default:
            return nil
        }
    }

    func refresh() {
        switch mode {
        case .always:
            set(true, "Always on.")
        case .fixed, .sun:
            if mode == .sun { refreshLocationIfStale() }
            guard let w = window() else { return }
            let times = "\(Self.clock(w.start)) to \(Self.clock(w.end))"
            let label: String
            if mode == .fixed {
                label = times + "."
            } else if sunTimes(for: Date()) == nil {
                label = "Sun times unavailable — using \(times)."
            } else {
                label = "\(placeName.map { "\($0), " } ?? "")\(times)."
            }
            set(Self.inWindow(Self.minutesOfDay(Date()), start: w.start, end: w.end), label)
        case .sleepFocus:
            requestFocusAuthorizationIfNeeded()
            switch Self.focusAuthorization {
            case .authorized:
                let focused = Self.focusIsOn()
                set(focused, focused ? "A Focus is on." : "No Focus is on.")
            case .notDetermined:
                set(false, "Waiting for permission to read Focus.")
            default:
                set(false, "Focus access denied — allow it in System Settings › Privacy & Security › Focus.")
            }
        case .darkMode:
            let dark = Self.systemIsDark()
            set(dark, dark ? "Dark mode is on." : "Dark mode is off.")
        }
    }

    private func set(_ active: Bool, _ status: String) {
        if isActive != active { isActive = active }
        if self.status != status { self.status = status }
    }

    private func minutes(_ key: String, default fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    // MARK: - Time helpers

    static func minutesOfDay(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// Windows wrap midnight: 20:00–07:00 is nine hours of night, not a typo.
    static func inWindow(_ now: Double, start: Double, end: Double) -> Bool {
        let s = wrap(start), e = wrap(end)
        return s <= e ? (now >= s && now < e) : (now >= s || now < e)
    }

    static func wrap(_ minutes: Double) -> Double {
        let m = minutes.truncatingRemainder(dividingBy: 1440)
        return m < 0 ? m + 1440 : m
    }

    static func date(minutes: Double) -> Date {
        let m = Int(wrap(minutes))
        return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }

    static func clock(_ minutes: Double) -> String {
        let m = Int(wrap(minutes).rounded())
        var comps = DateComponents()
        comps.hour = m / 60
        comps.minute = m % 60
        let date = Calendar.current.date(from: comps) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Sunrise / sunset

    private(set) var placeName: String? {
        get { defaults.string(forKey: "toneSunPlace") }
        set { defaults.set(newValue, forKey: "toneSunPlace") }
    }

    /// Sunrise and sunset for the day `date` falls in, at the cached location.
    /// Standard NOAA approximation — good to a minute or two, which is all a
    /// dimming schedule needs.
    func sunTimes(for date: Date) -> (sunrise: Date, sunset: Date)? {
        guard defaults.object(forKey: "toneSunLatitude") != nil else { return nil }
        let lat = defaults.double(forKey: "toneSunLatitude")
        let lon = defaults.double(forKey: "toneSunLongitude")
        return Self.sunTimes(date: date, latitude: lat, longitude: lon)
    }

    static func sunTimes(date: Date, latitude: Double, longitude: Double) -> (sunrise: Date, sunset: Date)? {
        let rad = Double.pi / 180
        let julian = date.timeIntervalSince1970 / 86400 + 2440587.5
        let n = (julian - 2451545.0 + 0.0008).rounded()
        let meanSolarTime = n - longitude / 360
        let m = (357.5291 + 0.98560028 * meanSolarTime).truncatingRemainder(dividingBy: 360)
        let center = 1.9148 * sin(m * rad) + 0.02 * sin(2 * m * rad) + 0.0003 * sin(3 * m * rad)
        let lambda = (m + center + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let transit = 2451545.0 + meanSolarTime + 0.0053 * sin(m * rad) - 0.0069 * sin(2 * lambda * rad)
        let declination = asin(sin(lambda * rad) * sin(23.44 * rad))
        // -0.833° puts the whole disc below the horizon, refraction included.
        let cosHourAngle = (sin(-0.833 * rad) - sin(latitude * rad) * sin(declination))
            / (cos(latitude * rad) * cos(declination))
        guard abs(cosHourAngle) <= 1 else { return nil }  // polar day or night
        let hourAngle = acos(cosHourAngle) / rad
        let toDate = { (j: Double) in Date(timeIntervalSince1970: (j - 2440587.5) * 86400) }
        return (toDate(transit - hourAngle / 360), toDate(transit + hourAngle / 360))
    }

    // MARK: - Approximate location

    /// Coarse location from the IP address, refreshed weekly and only ever
    /// fetched while the sun schedule is the selected mode — picking that mode
    /// is the opt-in. ponytail: one public endpoint, no key, no CoreLocation
    /// permission prompt; swap in CLLocationManager if city-level is too coarse.
    private func refreshLocationIfStale() {
        let fetched = defaults.double(forKey: "toneSunLocationFetched")
        guard Date().timeIntervalSince1970 - fetched > 7 * 86400, locationTask == nil else { return }
        locationTask = Task { [weak self] in
            defer { Task { @MainActor in self?.locationTask = nil } }
            var request = URLRequest(url: URL(string: "https://ipapi.co/json/")!)
            request.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lat = json["latitude"] as? Double, let lon = json["longitude"] as? Double
            else { return }
            await MainActor.run {
                guard let self else { return }
                self.defaults.set(lat, forKey: "toneSunLatitude")
                self.defaults.set(lon, forKey: "toneSunLongitude")
                self.defaults.set(Date().timeIntervalSince1970, forKey: "toneSunLocationFetched")
                self.placeName = json["city"] as? String
                self.refresh()
            }
        }
    }

    // MARK: - Focus

    /// Which Focus is on isn't something a sandboxed app can learn: the Focus
    /// daemon's own store (which does name Sleep) sits outside the container,
    /// and the public API answers one bit — focused or not. So this mode is
    /// "any Focus", and Sleep is the one people schedule for bed anyway.
    /// Permission is asked for only when the mode is selected, and a refusal
    /// leaves it permanently off rather than nagging.
    static func focusIsOn() -> Bool {
        guard INFocusStatusCenter.default.authorizationStatus == .authorized else { return false }
        return INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }

    static var focusAuthorization: INFocusStatusAuthorizationStatus {
        INFocusStatusCenter.default.authorizationStatus
    }

    func requestFocusAuthorizationIfNeeded() {
        guard INFocusStatusCenter.default.authorizationStatus == .notDetermined else { return }
        INFocusStatusCenter.default.requestAuthorization { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Dark mode

    static func systemIsDark() -> Bool {
        switch SettingsManager.shared.theme {
        case "Dark": return true
        case "Light": return false
        default:
            return NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
}
#endif
