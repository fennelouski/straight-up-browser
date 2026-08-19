//
//  TabDashboard.swift
//  Straight Up Browser
//
//  One window that answers "what is this website actually doing to my
//  computer" — the cost, the media, the trackers, the time. Sampling starts
//  when the window opens and stops when it closes.
//

import SwiftUI
import AppKit

struct TabDashboardWindow: View {
    @ObservedObject private var insights = TabInsights.shared
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if insights.rows.isEmpty {
                ContentUnavailableView(
                    "Nothing to Measure",
                    systemImage: "gauge.with.dots.needle.bottom.50percent",
                    description: Text("Open a browser window to see what its tabs are costing you.")
                )
            } else {
                table
            }
            Divider()
            footer
        }
        .frame(minWidth: 960, minHeight: 420)
        .onAppear { insights.addObserver() }
        .onDisappear { insights.removeObserver() }
    }

    private var table: some View {
        Table(insights.rows, selection: $selection) {
            TableColumn("Tab") { row in
                HStack(spacing: 6) {
                    favicon(row)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).lineLimit(1)
                        Text(row.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 190, ideal: 240)

            TableColumn("Memory") { row in
                Text(row.memoryBytes.map(Format.bytes) ?? "—")
                    .foregroundStyle(row.isLoaded ? .primary : .secondary)
                    .monospacedDigit()
            }
            .width(80)

            TableColumn("CPU") { row in
                Text(row.cpuPercent.map(Format.percent) ?? "—").monospacedDigit()
            }
            .width(60)

            TableColumn("CPU 5 min") { row in
                Text(row.cpuPercentFiveMinutes.map(Format.percent) ?? "—").monospacedDigit()
            }
            .width(74)

            TableColumn("CPU total") { row in
                Text(row.cpuTotalSeconds.map(Format.duration) ?? "—").monospacedDigit()
            }
            .width(74)

            TableColumn("On screen") { row in
                Text(Format.duration(row.screenSeconds)).monospacedDigit()
            }
            .width(74)

            TableColumn("Avg load") { row in
                Text(row.averageLoadSeconds.map { String(format: "%.2fs", $0) } ?? "—")
                    .monospacedDigit()
                    .help(row.loadCount > 0 ? "Across \(row.loadCount) loads" : "Not loaded yet")
            }
            .width(74)

            TableColumn("Playing") { row in
                HStack(spacing: 4) {
                    if row.playingVideo { Image(systemName: "play.rectangle.fill") }
                    if row.playingAudio { Image(systemName: "speaker.wave.2.fill") }
                    if !row.playingVideo && !row.playingAudio {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.tint)
            }
            .width(60)

            // Ads / other companies / stored keys. One column because Table
            // stops at ten, and these three are read together anyway.
            TableColumn("Ads · Others · Stored") { row in
                HStack(spacing: 4) {
                    count(row.adRequests, help: "Requests to known ad and tracking networks")
                    Text("·").foregroundStyle(.tertiary)
                    count(row.thirdPartyHosts, help: "Distinct other companies this page loaded from")
                    Text("·").foregroundStyle(.tertiary)
                    count(row.cookieCount + row.storageKeys,
                          help: "Cookies plus local and session storage keys")
                }
            }
            .width(min: 130, ideal: 150)

            TableColumn("Account") { row in
                if let label = row.accountLabel {
                    HStack(spacing: 4) {
                        favicon(row)
                        Text(label).lineLimit(1)
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 140)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("Browser itself: \(Format.bytes(insights.appMemoryBytes))", systemImage: "memorychip")
            if !insights.processMetricsAvailable {
                Label("Per-tab memory and CPU aren't readable right now.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Updates every 2 seconds").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func count(_ value: Int, help: String) -> some View {
        Text(value == 0 ? "—" : "\(value)")
            .monospacedDigit()
            .foregroundStyle(value == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .help(help)
    }

    @ViewBuilder
    private func favicon(_ row: TabInsight) -> some View {
        if let data = row.favicon, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "globe").frame(width: 14, height: 14).foregroundStyle(.secondary)
        }
    }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func percent(_ value: Double) -> String {
        value < 0.05 ? "0%" : String(format: value < 10 ? "%.1f%%" : "%.0f%%", value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "—" }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        if seconds < 3600 { return String(format: "%.0fm %.0fs", seconds / 60, seconds.truncatingRemainder(dividingBy: 60)) }
        return String(format: "%.0fh %.0fm", seconds / 3600, seconds.truncatingRemainder(dividingBy: 3600) / 60)
    }
}
