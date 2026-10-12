import SwiftUI
import Combine
import MapKit
import UniformTypeIdentifiers

nonisolated struct BrowserWeatherQuery: Equatable, Sendable {
    enum Mode: String, Sendable { case overview, rain, tomorrow, rainStop, dryWindow }
    var location: String?
    var mode: Mode = .overview

    static func parse(_ input: String, historyMode: Bool = false) -> Self? {
        guard !historyMode else { return nil }
        let words = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let lower = words.map { $0.lowercased() }
        guard !words.isEmpty, input.count <= 240, !input.contains("://") else { return nil }
        if lower.joined(separator: " ") == "when will rain stop?" || lower.joined(separator: " ") == "when will rain stop" {
            return Self(mode: .rainStop)
        }
        if lower == ["next", "dry", "window"] { return Self(mode: .dryWindow) }
        var remaining = words
        var mode: Mode = .overview
        if remaining.last?.lowercased() == "tomorrow" { remaining.removeLast(); mode = .tomorrow }
        let anchored = remaining.map { $0.lowercased() }
        if anchored.first == "weather" { remaining.removeFirst() }
        else if anchored.last == "weather" { remaining.removeLast() }
        else if anchored.first == "rain", remaining.count > 1 { remaining.removeFirst(); if mode != .tomorrow { mode = .rain } }
        else { return nil }
        if remaining.last?.lowercased() == "tomorrow" { remaining.removeLast(); mode = .tomorrow }
        let location = remaining.joined(separator: " ")
        guard !location.contains("?"), !location.contains("/"),
              !location.lowercased().hasSuffix(".com"), !location.lowercased().hasSuffix(".org") else { return nil }
        return Self(location: location.isEmpty ? nil : location, mode: mode)
    }
}

nonisolated struct BrowserWeatherPlace: Identifiable, Codable, Equatable, Sendable {
    let town: String
    let region: String
    let country: String
    let countryCode: String
    let latitude: Double
    let longitude: Double
    let timeZoneID: String
    var id: String { "\(latitude),\(longitude)" }
    var label: String { [town, region, country].filter { !$0.isEmpty }.joined(separator: ", ") }
    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)! }
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
            && !town.isEmpty && !country.isEmpty && TimeZone(identifier: timeZoneID) != nil
    }
}

@MainActor final class WeatherPlacesStore: ObservableObject {
    static let shared = WeatherPlacesStore()
    private let preferences: UserDefaults
    private let key = "browserWeatherSavedPlaces"
    @Published private(set) var places: [String: String]
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        places = preferences.dictionary(forKey: key) as? [String: String] ?? [:]
    }
    func query(for name: String) throws -> String {
        let alias = name.lowercased()
        if let query = places[alias] { return query }
        if ["home", "work"].contains(alias) { throw BrowserWeatherError.message("Set up \(alias.capitalized) in Saved places first.") }
        return name
    }
    func save(name: String, query: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !query.isEmpty, query.count <= 200,
              !name.contains(where: { $0.isNewline }), !query.contains(where: { $0.isNewline }),
              places[name] != nil || places.count < 20 else { throw BrowserWeatherError.message("Enter a place name and an address or postcode. Up to 20 places can be saved.") }
        places[name] = WeatherMapLink.query(query) ?? query
        preferences.set(places, forKey: key)
    }
    func delete(_ name: String) { places.removeValue(forKey: name.lowercased()); preferences.set(places, forKey: key) }
    func reset() { places = [:]; preferences.removeObject(forKey: key) }

    func importGooglePlaces(_ data: Data) throws {
        guard data.count <= 1_000_000 else { throw BrowserWeatherError.message("The selected Home/Work JSON file is too large.") }
        let archive = try JSONDecoder().decode(GooglePlacesArchive.self, from: data)
        var imported: [String: String] = [:]
        for feature in archive.features {
            let properties = feature.properties ?? feature.property ?? [:]
            guard let name = properties["name"]?.lowercased(), ["home", "work"].contains(name),
                  feature.geometry.type == "Point", feature.geometry.coordinates.count == 2 else { continue }
            let lon = feature.geometry.coordinates[0], lat = feature.geometry.coordinates[1]
            guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { throw BrowserWeatherError.message("The import contains invalid coordinates.") }
            imported[name] = "\(lat),\(lon)"
        }
        guard !imported.isEmpty else { throw BrowserWeatherError.message("No Home or Work points were found. Import the Home and Work JSON export, or enter addresses manually.") }
        places.merge(imported) { _, new in new }
        preferences.set(places, forKey: key)
    }
}

private nonisolated struct GooglePlacesArchive: Decodable {
    struct Feature: Decodable {
        struct Geometry: Decodable { let type: String; let coordinates: [Double] }
        let geometry: Geometry
        let property: [String: String]?
        let properties: [String: String]?
    }
    let features: [Feature]
}

nonisolated enum WeatherMapLink {
    static func query(_ input: String) -> String? {
        guard let components = URLComponents(string: input), components.scheme == "https",
              let host = components.host?.lowercased() else { return nil }
        let parameters = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        if host == "maps.apple.com" {
            if components.path == "/place", let coordinate = parameters["coordinate"], coordinates(coordinate) != nil { return coordinate }
            if let address = parameters["address"], !address.isEmpty { return address }
            if let q = parameters["q"], !q.isEmpty {
                if let point = parameters["ll"], coordinates(point) != nil { return point }
                return q
            }
            if let query = parameters["query"], !query.isEmpty { return query }
        }
        if ["google.com", "www.google.com", "maps.google.com"].contains(host),
           components.path.hasPrefix("/maps/search"), parameters["api"] == "1",
           let query = parameters["query"], !query.isEmpty { return query }
        // A map camera center or a shortened link does not identify a selected place.
        return nil
    }
    static func coordinates(_ input: String) -> (Double, Double)? {
        let parts = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (lat, lon)
    }
}

struct WeatherPlacesEditor: View {
    @ObservedObject private var places = WeatherPlacesStore.shared
    @State private var name = "home"
    @State private var address = ""
    @State private var status = ""
    @State private var importing = false
    @State private var resetting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved weather places").font(.headline)
            ForEach(places.places.keys.sorted(), id: \.self) { alias in
                HStack {
                    Button(alias.capitalized) { name = alias; address = places.places[alias] ?? "" }
                    Text(places.places[alias] ?? "").font(.caption).lineLimit(1)
                    Spacer()
                    Button("Delete", role: .destructive) { places.delete(alias) }
                        .accessibilityLabel("Delete \(alias.capitalized)")
                }
            }
            TextField("Name, such as Home or Work", text: $name).textFieldStyle(.roundedBorder)
            TextField("Address, postcode, or full Maps link", text: $address).textFieldStyle(.roundedBorder).onSubmit(save)
            Button("Save place", action: save).disabled(name.isEmpty || address.isEmpty)
            Button("Import Google Home/Work JSON…") { importing = true }
            Text("Saved places stay in this browser's local profile. Import only your own Home/Work export. Google Sign-in does not import these places. Short Maps links need a full place link or manual address.")
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.caption).accessibilityIdentifier("weather-places-status") }
            Button("Reset saved places", role: .destructive) { resetting = true }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try places.importGooglePlaces(Data(contentsOf: url))
                status = "Home/Work import saved locally."
            } catch { status = "Import failed. Choose a Home/Work JSON export or enter places manually." }
        }
        .confirmationDialog("Delete all saved weather places?", isPresented: $resetting) { Button("Reset", role: .destructive) { places.reset() } }
    }
    private func save() {
        do { try places.save(name: name, query: address); status = "\(name.capitalized) saved locally." }
        catch { status = (error as? BrowserWeatherError)?.message ?? "The place could not be saved." }
    }
}
