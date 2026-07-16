//
//  Settings_iOS.swift
//  Internet (iPadOS)
//
//  iPad settings, presented as a sheet. Bound to the same @AppStorage keys the
//  Mac settings panes use, so preferences read identically across platforms.
//  Mac-only rows are dropped (global hotkey, ⌘P-as-PDF, CLI automation,
//  downloads folder — iPad downloads go to Files via the share sheet).
//

import SwiftUI
import SwiftData
import WebKit

struct Settings_iOS: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("searchEngine") private var searchEngine = "Google"
    @AppStorage("spaceScrollPercent") private var spaceScrollPercent = 90.0
    @AppStorage("javaScriptEnabled") private var javaScriptEnabled = true
    @AppStorage("optionClickDownloadEnabled") private var optionClickDownloadEnabled = false
    @AppStorage("optionClickDownloadLinks") private var optionClickDownloadLinks = true
    @AppStorage("optionClickDownloadImages") private var optionClickDownloadImages = true
    @AppStorage("theme") private var theme = "System"
    @AppStorage("progressBarTop") private var progressBarTop = true
    @AppStorage("progressBarBottom") private var progressBarBottom = false
    @AppStorage("progressBarLeft") private var progressBarLeft = false
    @AppStorage("progressBarRight") private var progressBarRight = false
    @AppStorage("progressFaviconRing") private var progressFaviconRing = false
    @AppStorage("sslStrictMode") private var sslStrictMode = true
    @AppStorage("adBlockEnabled") private var adBlockEnabled = false
    @AppStorage("memorySaverEnabled") private var memorySaverEnabled = false
    @AppStorage("memorySaverDefaultPolicy") private var memorySaverDefaultPolicy = MemoryPolicy.whenNeeded.rawValue

    @State private var showClearConfirm = false
    @State private var clearedNote = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Search") {
                    Picker("Search engine", selection: $searchEngine) {
                        ForEach(["Google", "DuckDuckGo", "Bing", "Yahoo"], id: \.self) { Text($0).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Spacebar scrolls")
                            Spacer()
                            Text("\(Int(spaceScrollPercent))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $spaceScrollPercent, in: 50...100, step: 5)
                    }
                }

                Section("Web Content") {
                    Toggle("Enable JavaScript", isOn: $javaScriptEnabled)
                }

                Section {
                    Toggle("⌥-click downloads the link", isOn: $optionClickDownloadEnabled)
                    if optionClickDownloadEnabled {
                        Toggle("Apply to links", isOn: $optionClickDownloadLinks)
                        Toggle("Apply to images", isOn: $optionClickDownloadImages)
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Downloads are saved to the app's Downloads folder and shared via the system share sheet (Save to Files, AirDrop, …). ⌥-click needs a keyboard or trackpad (iPadOS 18.4+).")
                }

                Section("Appearance") {
                    Picker("Theme", selection: $theme) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }
                    Toggle("Progress bar: top", isOn: $progressBarTop)
                    Toggle("Progress bar: bottom", isOn: $progressBarBottom)
                    Toggle("Progress bar: left", isOn: $progressBarLeft)
                    Toggle("Progress bar: right", isOn: $progressBarRight)
                    Toggle("Ring around the favicon", isOn: $progressFaviconRing)
                }

                Section("Security") {
                    Toggle("Refuse invalid certificates (strict SSL)", isOn: $sslStrictMode)
                    Toggle("Block ads and trackers", isOn: $adBlockEnabled)
                        .onChange(of: adBlockEnabled) { _, _ in
                            NotificationCenter.default.post(name: .adBlockChanged, object: nil)
                        }
                }

                Section("Memory") {
                    Toggle("Enable memory saving", isOn: $memorySaverEnabled)
                    Picker("Default for new tabs", selection: $memorySaverDefaultPolicy) {
                        ForEach(MemoryPolicy.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                    .disabled(!memorySaverEnabled)
                }

                Section {
                    Button(role: .destructive) { showClearConfirm = true } label: {
                        Text("Clear browsing data…")
                    }
                    if clearedNote {
                        Label("Browsing data cleared", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Removes history, cookies, caches, and local storage.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear all browsing data?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear Browsing Data", role: .destructive, action: clearBrowsingData)
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func clearBrowsingData() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: Date(timeIntervalSince1970: 0)) {
            clearedNote = true
        }
    }
}
