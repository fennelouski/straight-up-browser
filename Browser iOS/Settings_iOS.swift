//
//  Settings_iOS.swift
//  Browser (iPadOS)
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
    @Environment(\.modelContext) private var modelContext
    @Query private var tabs: [Tab]

    @AppStorage(TabSync.Key.enabled) private var tabSyncEnabled = false
    @AppStorage(TabSync.Key.mode) private var tabSyncMode = TabSyncMode.openOnly.rawValue
    @AppStorage(TabSync.Key.cacheState) private var tabSyncCacheState = false

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
    @State private var iCloudAvailable: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Sync browser data across your devices", isOn: $tabSyncEnabled)
                        .disabled(iCloudAvailable != true && !tabSyncEnabled)
                    if tabSyncEnabled {
                        Picker("Tab closing", selection: $tabSyncMode) {
                            ForEach(TabSyncMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                        Toggle("Also sync live page state", isOn: $tabSyncCacheState)
                            .onChange(of: tabSyncCacheState) { _, enabled in
                                guard !enabled else { return }
                                TabSync.clearPageState(in: tabs)
                                try? modelContext.save()
                            }

                        DisclosureGroup("What syncs to iCloud") {
                            ForEach(TabSync.syncedDataCategories, id: \.self) { category in
                                Label(category.label, systemImage: category.systemImage)
                            }
                            Text("Live page state additionally includes scroll position, back/forward state, form fields, and session storage. Turning it off deletes those saved snapshots.")
                        }
                    }
                    if iCloudAvailable == nil {
                        Label("Checking iCloud availability…", systemImage: "icloud")
                    } else if iCloudAvailable == false {
                        Label(
                            tabSyncEnabled
                                ? "iCloud is unavailable. You can turn sync off; turning it back on requires iCloud."
                                : "Sign in to iCloud to enable sync.",
                            systemImage: "icloud.slash"
                        )
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Sync uses your private iCloud database. Incognito tabs, cookies, cache, website storage, saved logins, and downloads stay on this device. Changes to the main sync switch take effect after you relaunch.")
                }

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

                Section {
                    Menu {
                        ForEach(ShortcutPreset.allCases) { preset in
                            Button(preset.title) { ShortcutStore.shared.apply(preset: preset) }
                        }
                        Divider()
                        Button("Reset to Defaults") { ShortcutStore.shared.resetAll() }
                    } label: {
                        Label("Match another browser…", systemImage: "keyboard")
                    }
                } header: {
                    Text("Keyboard Shortcuts")
                } footer: {
                    Text("Adopt another browser's keyboard shortcut scheme on this device. See ⇧⌘H for the full list.")
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
            .task { iCloudAvailable = await TabSync.iCloudAvailable() }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear all browsing data?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear Browsing Data", role: .destructive, action: clearBrowsingData)
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func clearBrowsingData() {
        BrowsingDataCleaner.clearHistory(in: tabs)
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: Date(timeIntervalSince1970: 0)) {
            clearedNote = true
        }
    }
}
