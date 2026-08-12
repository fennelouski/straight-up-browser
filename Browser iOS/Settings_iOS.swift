//
//  Settings_iOS.swift
//  Browser (iOS and iPadOS)
//
//  Mobile settings, presented as a sheet. Bound to the same @AppStorage keys the
//  Mac settings panes use, so preferences read identically across platforms.
//  Mac-only rows are dropped (global hotkey, ⌘P-as-PDF, CLI automation,
//  downloads folder — mobile downloads go to Files via the share sheet).
//

import SwiftUI
import SwiftData
import UIKit
import WebKit

struct Settings_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var tabs: [Tab]
    @ObservedObject private var permissionStore = SitePermissionStore.shared
    @StateObject private var agentSync = AgentDefinitionSyncViewModel_iOS()

    @AppStorage(TabSync.Key.enabled) private var tabSyncEnabled = false
    @AppStorage(TabSync.Key.mode) private var tabSyncMode = TabSyncMode.openOnly.rawValue
    @AppStorage(TabSync.Key.cacheState) private var tabSyncCacheState = false

    @AppStorage(AgentDefinitionSyncSettings.Key.schedules)
    private var syncAgentSchedules = false
    @AppStorage(AgentDefinitionSyncSettings.Key.providerPresets)
    private var syncAgentProviderPresets = false
    @AppStorage(AgentDefinitionSyncSettings.Key.userAuthoredMemory)
    private var syncAgentUserAuthoredMemory = false

    @AppStorage("searchEngine") private var searchEngine = "Google"
    @AppStorage(FastForward.Key.enabled) private var fastForwardEnabled = true
    @AppStorage("spaceScrollPercent") private var spaceScrollPercent = 90.0
    @AppStorage("javaScriptEnabled") private var javaScriptEnabled = true
    @AppStorage("autoTranslateEnabled") private var autoTranslateEnabled = true
    @AppStorage("translationPreferredLanguages") private var translationPreferredLanguages = ""
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
    @AppStorage("iPadTabRailVisibility") private var tabRailVisibility = TabRailVisibility_iOS.off.rawValue
    @AppStorage("iPadTabRailPortraitEdge") private var tabRailPortraitEdge = PortraitTabRailEdge_iOS.top.rawValue
    @AppStorage("iPadTabRailLandscapeEdge") private var tabRailLandscapeEdge = LandscapeTabRailEdge_iOS.left.rawValue

    @State private var showClearConfirm = false
    @State private var showCookieManager = false
    @State private var clearedNote = false
    @State private var iCloudAvailable: Bool?
    @State private var pendingAgentSyncDisableCategory: AgentDefinitionSyncCategory?
    @State private var showingAgentSyncDisableChoices = false

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
                            Text("Live page state additionally includes scroll position, back/forward state, and form fields. Cookies, local storage, session storage, and saved logins never sync. Turning it off deletes saved page-state snapshots.")
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

                agentDefinitionSyncSection

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
                    Toggle("Fast Forward searches", isOn: $fastForwardEnabled)
                } header: {
                    Text("Fast Forward")
                } footer: {
                    Text("When a search clearly names a destination, keep the results visible and open that destination in a split pane.")
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
                        .onChange(of: javaScriptEnabled) { _, _ in
                            NotificationCenter.default.post(name: .javaScriptChanged, object: nil)
                        }
                    Toggle("Automatically offer page translation", isOn: $autoTranslateEnabled)
                    TextField("Languages you read (en, es, fr)", text: $translationPreferredLanguages)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Reading") {
                    NavigationLink {
                        NewspaperSettingsView()
                    } label: {
                        Label("Newspaper", systemImage: "newspaper")
                    }
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
                    Text("Downloads are saved to the app's Downloads folder and shared via the system share sheet (Save to Files, AirDrop, …). ⌥-click needs a keyboard or trackpad (iOS or iPadOS 18.4+).")
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

                if UIDevice.current.userInterfaceIdiom == .pad {
                    Section {
                        Picker("Show tab rail", selection: $tabRailVisibility) {
                            ForEach(TabRailVisibility_iOS.allCases) {
                                Text($0.title).tag($0.rawValue)
                            }
                        }
                        Picker("Portrait edge", selection: $tabRailPortraitEdge) {
                            ForEach(PortraitTabRailEdge_iOS.allCases) {
                                Text($0.title).tag($0.rawValue)
                            }
                        }
                        Picker("Landscape edge", selection: $tabRailLandscapeEdge) {
                            ForEach(LandscapeTabRailEdge_iOS.allCases) {
                                Text($0.title).tag($0.rawValue)
                            }
                        }
                    } header: {
                        Text("iPad Tab Rail")
                    } footer: {
                        Text("The rail follows the short edge of the current app window. It overlays the page and retracts before moving to another edge.")
                    }
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
                    if permissionStore.records.isEmpty {
                        Text("No saved site permissions.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(permissionStore.records) { record in
                            HStack(spacing: 10) {
                                Image(systemName: record.kind.systemImage)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.origin)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(
                                        "\(record.kind.title) · \(record.decision.title)"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    permissionStore.revoke(
                                        origin: record.origin,
                                        kind: record.kind
                                    )
                                } label: {
                                    Label("Revoke", systemImage: "trash")
                                }
                            }
                        }
                        Button("Revoke All", role: .destructive) {
                            permissionStore.clear()
                        }
                    }
                } header: {
                    Text("Site Permissions")
                } footer: {
                    Text("Camera and microphone choices are stored per website. Revoked sites ask again. Private tabs never add entries here.")
                }

                Section {
                    Button(role: .destructive) { showClearConfirm = true } label: {
                        Text("Clear browsing data…")
                    }
                    Button("Manage cookies…") { showCookieManager = true }
                    if clearedNote {
                        Label("Browsing data cleared", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Removes history, cookies, caches, and local storage.")
                }
            }
            .task {
                async let availability = TabSync.iCloudAvailable()
                await agentSync.synchronize()
                iCloudAvailable = await availability
            }
            .confirmationDialog(
                "Turn Off \(pendingAgentSyncDisableCategory.map(agentSyncCategoryLabel) ?? "Agent Definition") Sync?",
                isPresented: $showingAgentSyncDisableChoices,
                titleVisibility: .visible
            ) {
                Button("Keep Copies on This \(mobileDeviceName)") {
                    confirmAgentSyncDisable(.keepLocalCopies)
                }
                Button("Delete Copies from iCloud", role: .destructive) {
                    confirmAgentSyncDisable(.deleteCloudCopies)
                }
                Button("Cancel", role: .cancel) {
                    pendingAgentSyncDisableCategory = nil
                }
            } message: {
                Text("Either choice stops new cloud writes. Unsupported Mac automation remains retained on this \(mobileDeviceName) but can never execute here.")
            }
            .sheet(isPresented: $showCookieManager) {
                CookieManager_iOS()
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear all browsing data?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear Browsing Data", role: .destructive, action: clearBrowsingData)
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var agentDefinitionSyncSection: some View {
        Section {
            Toggle(
                "Sync scheduled task definitions",
                isOn: agentSyncBinding(for: .schedules)
            )
            .accessibilityIdentifier("settings.agentSync.schedules")
            .disabled(
                agentSync.isSyncing
                    || (iCloudAvailable != true && !syncAgentSchedules)
            )
            Toggle(
                "Sync provider presets",
                isOn: agentSyncBinding(for: .providerPresets)
            )
            .accessibilityIdentifier("settings.agentSync.providerPresets")
            .disabled(
                agentSync.isSyncing
                    || (iCloudAvailable != true && !syncAgentProviderPresets)
            )
            Toggle(
                "Sync user-authored memory",
                isOn: agentSyncBinding(for: .userAuthoredMemory)
            )
            .accessibilityIdentifier("settings.agentSync.userMemory")
            .disabled(
                agentSync.isSyncing
                    || (iCloudAvailable != true && !syncAgentUserAuthoredMemory)
            )

            if agentSync.isSyncing {
                ProgressView("Syncing safe definitions…")
                    .accessibilityIdentifier("settings.agentSync.progress")
            } else {
                LabeledContent("Last sync") {
                    Text(
                        agentSync.lastSyncAt?.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ) ?? String(localized: "Not yet synced")
                    )
                    .foregroundStyle(.secondary)
                }
                Button("Refresh Safe Definitions", systemImage: "arrow.clockwise") {
                    Task { await agentSync.synchronize() }
                }
                .accessibilityIdentifier("settings.agentSync.refresh")
            }

            if let error = agentSync.lastError {
                Label(error, systemImage: "exclamationmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.agentSync.error")
            }

            if !agentSync.unavailableSchedules.isEmpty {
                DisclosureGroup(
                    "Retained schedules (\(agentSync.unavailableSchedules.count))"
                ) {
                    ForEach(
                        agentSync.unavailableSchedules.keys.sorted {
                            $0.uuidString < $1.uuidString
                        },
                        id: \.self
                    ) { id in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agentSync.scheduleName(id))
                                .font(.subheadline.weight(.semibold))
                            Text(agentSync.scheduleReasonText(id))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Label("Retained but never executed here", systemImage: "lock.shield")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .accessibilityIdentifier("settings.agentSync.schedule.\(id.uuidString)")
                    }
                }
            }

            let presets = agentSync.providerPresets()
            if !presets.isEmpty {
                DisclosureGroup("Retained provider presets (\(presets.count))") {
                    ForEach(presets) { preset in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name)
                                .font(.subheadline.weight(.semibold))
                            Text("\(preset.providerID) · \(preset.model)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Credentials never sync. Configure provider access independently on a Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            let memories = agentSync.memories()
            if !memories.isEmpty {
                DisclosureGroup("Retained user memory (\(memories.count))") {
                    ForEach(memories) { memory in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(memory.text)
                                .lineLimit(4)
                                .textSelection(.enabled)
                            Text(memory.sensitivity == .sensitive ? "Sensitive" : "User-authored")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(
                                    memory.sensitivity == .sensitive
                                        ? Color.orange : Color.secondary
                                )
                            if agentSync.sensitiveMemoryAwaitingReview.contains(memory.id) {
                                Text("Review this sensitive value before accepting it on this device. It remains inactive because agent execution is macOS-only.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Mark Reviewed on This \(mobileDeviceName)") {
                                    agentSync.markSensitiveMemoryReviewed(memory.id)
                                }
                                .accessibilityIdentifier(
                                    "settings.agentSync.reviewMemory.\(memory.id.uuidString)"
                                )
                            } else if memory.sensitivity == .sensitive {
                                Label("Reviewed on this device", systemImage: "checkmark.shield")
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        } header: {
            Text("Agent Definition Sync")
        } footer: {
            Text("Each category is separately opt in and uses your private iCloud database. This device can retain and review safe definitions, but scheduled tasks and agent tools run only on macOS. Credentials, page handles, runs, transcripts, approvals, and artifacts never sync.")
        }
    }

    private func agentSyncBinding(
        for category: AgentDefinitionSyncCategory
    ) -> Binding<Bool> {
        Binding(
            get: { agentSyncValue(for: category) },
            set: { enabled in
                if enabled {
                    setAgentSyncValue(true, for: category)
                    Task {
                        if !(await agentSync.enable(category)) {
                            setAgentSyncValue(false, for: category)
                        }
                    }
                } else {
                    pendingAgentSyncDisableCategory = category
                    showingAgentSyncDisableChoices = true
                }
            }
        )
    }

    private func confirmAgentSyncDisable(
        _ disposition: AgentDefinitionSyncDisableDisposition
    ) {
        guard let category = pendingAgentSyncDisableCategory else { return }
        pendingAgentSyncDisableCategory = nil
        Task {
            if await agentSync.disable(category, disposition: disposition) {
                setAgentSyncValue(false, for: category)
            }
        }
    }

    private func agentSyncValue(for category: AgentDefinitionSyncCategory) -> Bool {
        switch category {
        case .schedules: syncAgentSchedules
        case .providerPresets: syncAgentProviderPresets
        case .userAuthoredMemory: syncAgentUserAuthoredMemory
        }
    }

    private func setAgentSyncValue(
        _ value: Bool,
        for category: AgentDefinitionSyncCategory
    ) {
        switch category {
        case .schedules: syncAgentSchedules = value
        case .providerPresets: syncAgentProviderPresets = value
        case .userAuthoredMemory: syncAgentUserAuthoredMemory = value
        }
    }

    private func agentSyncCategoryLabel(
        _ category: AgentDefinitionSyncCategory
    ) -> String {
        switch category {
        case .schedules: "Scheduled Task"
        case .providerPresets: "Provider Preset"
        case .userAuthoredMemory: "User Memory"
        }
    }

    private var mobileDeviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
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

private struct CookieManager_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cookies: [HTTPCookie] = []
    @State private var searchText = ""

    private var filteredCookies: [HTTPCookie] {
        guard !searchText.isEmpty else { return cookies }
        return cookies.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.domain.localizedCaseInsensitiveContains(searchText)
                || $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredCookies.isEmpty {
                    ContentUnavailableView(
                        "No Cookies",
                        systemImage: "shippingbox",
                        description: Text(searchText.isEmpty ? "No cookies are stored in regular browsing." : "No cookies match your search.")
                    )
                } else {
                    ForEach(filteredCookies, id: \.cookieIdentifier) { cookie in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cookie.name).font(.headline)
                            Text(cookie.domain + cookie.path)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(cookie.expiresDate?.formatted() ?? String(localized: "Session cookie"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { delete(cookie) }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search cookies")
            .navigationTitle("Cookie Manager")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Refresh", systemImage: "arrow.clockwise", action: load)
                        Button("Delete All Cookies", systemImage: "trash", role: .destructive, action: deleteAll)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task { load() }
        }
    }

    private func load() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { values in
            cookies = values.sorted {
                ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name)
            }
        }
    }

    private func delete(_ cookie: HTTPCookie) {
        WKWebsiteDataStore.default().httpCookieStore.delete(cookie) { load() }
    }

    private func deleteAll() {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let remaining = cookies.count
        guard remaining > 0 else { return }
        for cookie in cookies { store.delete(cookie) }
        cookies.removeAll()
    }
}

private extension HTTPCookie {
    var cookieIdentifier: String { "\(domain)|\(path)|\(name)" }
}
