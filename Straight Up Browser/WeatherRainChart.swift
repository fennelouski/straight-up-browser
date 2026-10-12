import SwiftUI
import Charts
import Accessibility

struct WeatherRainChart: View {
    let forecast: BrowserWeatherForecast
    let mode: BrowserWeatherQuery.Mode
    var grid: KNMIRadarGrid?
    private func time(_ date: Date) -> String {
        var format = Date.FormatStyle(date: .omitted, time: .shortened)
        format.timeZone = forecast.place.timeZone
        return date.formatted(format)
    }
    private func hours(at date: Date) -> [OmnibarWeatherSnapshot.Hour] {
        guard mode == .tomorrow else { return Array(forecast.scene.hours.prefix(24)) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = forecast.place.timeZone
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return forecast.scene.hours.filter { calendar.isDate($0.date, inSameDayAs: tomorrow) }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let imported = try? grid?.sample(forecast.place, now: timeline.date)
            let nowcast = (mode == .tomorrow ? nil : (imported ?? forecast.nowcast)).flatMap { $0.isFresh(at: timeline.date) ? $0 : nil }
            let samples = nowcast?.samples ?? hours(at: timeline.date).map { BrowserRainSample(date: $0.date, millimetersPerHour: $0.precipitationMM) }
            VStack(alignment: .leading, spacing: 8) {
                Text(nowcast == nil ? "Hourly precipitation · mm/hour" : "Five-minute precipitation estimate · mm/hour").font(.subheadline.bold())
                if samples.contains(where: { $0.millimetersPerHour != nil }) {
                    Chart(samples) { sample in
                        if let amount = sample.millimetersPerHour {
                            BarMark(x: .value("Forecast time", sample.date), y: .value("Rain, mm/hour", amount))
                                .foregroundStyle(.cyan.opacity(0.8))
                        }
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(); AxisTick()
                        AxisValueLabel { if let date = value.as(Date.self) { Text(time(date)) } }
                    } }
                    .environment(\.timeZone, forecast.place.timeZone)
                    .frame(height: 100)
                    .accessibilityChartDescriptor(WeatherRainAccessibility(samples: samples, timeZone: forecast.place.timeZone))
                    .accessibilityLabel(nowcast == nil ? "Hourly precipitation forecast" : "Five-minute precipitation forecast")
                    .accessibilityIdentifier("weather-rain-chart")
                } else { Text("Precipitation amounts are unavailable from this source.").font(.caption) }
                if let nowcast {
                    Link(nowcast.sourceName + " · CC BY 4.0", destination: nowcast.sourceURL).font(.caption2)
                    Text("Model estimate; timing can shift. Missing values mean unknown, not dry.").font(.caption2)
                } else {
                    Text(grid == nil ? "Short-term nowcast unavailable. Hourly forecast; no minute-level stopping time." : "Regional nowcast stale or outside coverage. Showing hourly forecast.")
                        .font(.caption2).accessibilityIdentifier("weather-nowcast-unavailable")
                }
                if mode == .rainStop || mode == .dryWindow || mode == .rain {
                    if forecast.isFresh(at: timeline.date) || nowcast != nil {
                        let window = nowcast.flatMap { BrowserRainWindow.dry(samples: Array($0.samples.dropLast()), interval: 300, now: timeline.date, minimum: 1200) }
                            ?? (nowcast == nil ? BrowserRainWindow.hourly(forecast.scene, now: timeline.date) : nil)
                        if let window {
                            Text("\(mode == .rainStop ? "Rain may ease" : "Possible dry window") around \(time(window.start))–\(time(window.end)) · \(nowcast == nil ? "hourly estimate" : "five-minute estimate")")
                                .font(.caption).accessibilityIdentifier("weather-dry-window")
                        } else { Text("No supported dry window in the available forecast.").font(.caption) }
                    } else { Text("Refresh the stale forecast before estimating a dry window.").font(.caption) }
                }
            }
        }
    }
}

/// Audio graphs must describe the forecast's timezone, rather than the Mac's.
private struct WeatherRainAccessibility: AXChartDescriptorRepresentable {
    let samples: [BrowserRainSample]
    let timeZone: TimeZone
    func makeChartDescriptor() -> AXChartDescriptor {
        let times = samples.map { $0.date.timeIntervalSince1970 }
        let start = times.min() ?? 0, end = max(start + 1, times.max() ?? 1)
        let zone = timeZone
        let x = AXNumericDataAxisDescriptor(title: "Forecast time · " + zone.identifier,
            range: start...end, gridlinePositions: []) { value in
                var format = Date.FormatStyle(date: .abbreviated, time: .shortened); format.timeZone = zone
                return Date(timeIntervalSince1970: value).formatted(format)
            }
        let maximum = max(1, samples.compactMap(\.millimetersPerHour).max() ?? 1)
        let y = AXNumericDataAxisDescriptor(title: "Precipitation, millimeters per hour", range: 0...maximum,
            gridlinePositions: []) { "\($0.formatted(.number.precision(.fractionLength(1)))) millimeters per hour" }
        let points = samples.compactMap { sample -> AXDataPoint? in
            guard let value = sample.millimetersPerHour else { return nil }
            return AXDataPoint(x: sample.date.timeIntervalSince1970, y: value)
        }
        return AXChartDescriptor(title: "Precipitation forecast", summary: "Forecast timezone: \(zone.identifier). Missing values are unknown.",
            xAxis: x, yAxis: y, series: [AXDataSeriesDescriptor(name: "Precipitation", isContinuous: false, dataPoints: points)])
    }
}
