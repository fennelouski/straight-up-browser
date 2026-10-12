import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct BrowserRainSample: Codable, Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let millimetersPerHour: Double?
}

nonisolated struct BrowserRainNowcast: Sendable {
    let issuedAt: Date
    let expiresAt: Date
    let samples: [BrowserRainSample]
    let fixture: Bool
    let sourceName: String
    let sourceURL: URL
    func isFresh(at now: Date) -> Bool {
        issuedAt <= now.addingTimeInterval(60) && now.timeIntervalSince(issuedAt) <= 600 && expiresAt > now
    }
}

nonisolated enum BrowserRainWindow {
    static func dry(samples: [BrowserRainSample], interval: TimeInterval, now: Date, minimum: TimeInterval) -> DateInterval? {
        var start: Date?, previous: Date?
        for sample in samples where sample.date.addingTimeInterval(interval) > now {
            let contiguous = previous.map { abs(sample.date.timeIntervalSince($0) - interval) < 1 } ?? true
            if !contiguous { start = nil }
            if let rain = sample.millimetersPerHour, rain >= 0, rain < 0.1 {
                if start == nil { start = max(now, sample.date) }
                let end = sample.date.addingTimeInterval(interval)
                if let start, end.timeIntervalSince(start) >= minimum { return DateInterval(start: start, end: end) }
            } else { start = nil }
            previous = sample.date
        }
        return nil
    }
    static func hourly(_ scene: OmnibarWeatherSnapshot, now: Date) -> DateInterval? {
        let samples = scene.hours.filter { $0.date >= now }.map { hour in
            BrowserRainSample(date: hour.date, millimetersPerHour: hour.precipitationChance <= 0.25 ? hour.precipitationMM : nil)
        }
        return dry(samples: samples, interval: 3600, now: now, minimum: 3600)
    }
}

/// Normalized regional tiles, not a decoder for unverified raw HDF5 metadata.
/// Geometry names the centre of cell (0,0); missing precipitation stays unknown.
nonisolated struct KNMIRadarGrid: Codable, Sendable {
    struct Frame: Codable, Sendable { let date: Date; let millimetersPerFiveMinutes: [Double?] }
    static let projection = "+proj=stere +lat_0=90 +lon_0=0 +lat_ts=60 +a=6378137 +b=6356752 +x_0=0 +y_0=0 +units=km"
    let dataset: String
    let version: String
    let projection: String
    let issuedAt: Date
    let expiresAt: Date
    let width: Int
    let height: Int
    let originXKM: Double
    let originYKM: Double
    let stepXKM: Double
    let stepYKM: Double
    let fixture: Bool
    let frames: [Frame]
    func validate(now: Date) throws {
        guard dataset == "radar_forecast", version == "2.0", projection == Self.projection,
              width > 0, height > 0, width <= 128, height <= 128,
              originXKM.isFinite, originYKM.isFinite, abs(originXKM) <= 20000, abs(originYKM) <= 20000,
              abs(stepXKM) == 1, abs(stepYKM) == 1,
              issuedAt <= now.addingTimeInterval(60), now.timeIntervalSince(issuedAt) <= 600,
              expiresAt > now, expiresAt <= issuedAt.addingTimeInterval(600), frames.count == 25,
              abs(frames[0].date.timeIntervalSince(issuedAt)) < 1 else { throw BrowserWeatherError.message("The regional tile is stale or has unsupported geometry, timestamps, or coverage.") }
        for (index, frame) in frames.enumerated() {
            guard abs(frame.date.timeIntervalSince(issuedAt) - Double(index) * 300) < 1,
                  frame.millimetersPerFiveMinutes.count == width * height,
                  frame.millimetersPerFiveMinutes.allSatisfy({ $0 == nil || ($0!.isFinite && (0...200).contains($0!)) }) else { throw BrowserWeatherError.message("The regional tile contains missing steps or invalid precipitation units.") }
        }
    }
    static func project(latitude: Double, longitude: Double) -> (x: Double, y: Double)? {
        guard latitude.isFinite, longitude.isFinite, latitude > 0, latitude <= 90, abs(longitude) <= 180 else { return nil }
        let a = 6378137.0, b = 6356752.0, eccentricity = sqrt(1 - b * b / (a * a))
        let phi = latitude * .pi / 180, lambda = longitude * .pi / 180, reference = Double.pi / 3
        func t(_ latitude: Double) -> Double {
            tan(.pi / 4 - latitude / 2) / pow((1 - eccentricity * sin(latitude)) / (1 + eccentricity * sin(latitude)), eccentricity / 2)
        }
        let m = cos(reference) / sqrt(1 - eccentricity * eccentricity * pow(sin(reference), 2))
        let rho = a * m * t(phi) / t(reference) / 1000
        return (rho * sin(lambda), -rho * cos(lambda))
    }
    func sample(_ place: BrowserWeatherPlace, now: Date) throws -> BrowserRainNowcast? {
        try validate(now: now)
        guard (48.9...55.97).contains(place.latitude), (0...10.86).contains(place.longitude),
              let point = Self.project(latitude: place.latitude, longitude: place.longitude) else { return nil }
        let columnValue = ((point.x - originXKM) / stepXKM).rounded(), rowValue = ((point.y - originYKM) / stepYKM).rounded()
        guard columnValue >= 0, columnValue < Double(width), rowValue >= 0, rowValue < Double(height) else { return nil }
        let column = Int(columnValue), row = Int(rowValue)
        guard (0..<width).contains(column), (0..<height).contains(row) else { return nil }
        let index = row * width + column
        return BrowserRainNowcast(issuedAt: issuedAt, expiresAt: expiresAt,
            samples: frames.map { BrowserRainSample(date: $0.date, millimetersPerHour: $0.millimetersPerFiveMinutes[index].map { $0 * 12 }) },
            fixture: fixture, sourceName: fixture ? "KNMI format fixture" : "Imported KNMI regional tile",
            sourceURL: URL(string: "https://dataplatform.knmi.nl/dataset/radar-forecast-2-0")!)
    }
}

@MainActor final class WeatherRegionalFeedStore: ObservableObject {
    static let shared = WeatherRegionalFeedStore()
    @Published private(set) var grid: KNMIRadarGrid?
    func load(_ data: Data, now: Date = Date()) throws {
        guard data.count <= 16_000_000 else { throw BrowserWeatherError.message("Choose a regional tile smaller than 16 MB.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let grid = try decoder.decode(KNMIRadarGrid.self, from: data)
        try grid.validate(now: now); self.grid = grid
    }
    func clear() { grid = nil }
}

struct WeatherRegionalFeedSettings: View {
    @ObservedObject private var regional = WeatherRegionalFeedStore.shared
    @State private var importing = false
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Regional rain").font(.headline)
            Text("No authenticated regional feed is configured. A validated imported regional tile can be sampled locally. Otherwise Browser shows a labelled hourly forecast.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Import normalized KNMI regional tile…") { importing = true }
            if regional.grid != nil { Button("Remove imported tile", role: .destructive) { regional.clear() } }
            if !status.isEmpty { Text(status).font(.caption) }
        }.fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try regional.load(Data(contentsOf: url)); status = "Tile loaded into temporary memory. Forecast uncertainty applies."
            } catch { status = (error as? BrowserWeatherError)?.message ?? "The regional tile could not be read." }
        }
    }
}
