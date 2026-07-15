//
//  SettingsWindow.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import WebKit

struct SettingsWindow: View {
    @State private var selectedTab = 0

    private var colorScheme: ColorScheme? {
        SettingsManager.shared.colorScheme
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

            PrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised.fill")
                }
                .tag(1)

            SecuritySettingsView()
                .tabItem {
                    Label("Security", systemImage: "lock.fill")
                }
                .tag(2)

            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush.fill")
                }
                .tag(3)

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "wrench.fill")
                }
                .tag(4)
        }
        .frame(width: 600, height: 560)
        .padding()
        .preferredColorScheme(colorScheme)
    }
}

// MARK: - General Settings
struct GeneralSettingsView: View {
    @AppStorage("searchEngine") private var searchEngine = "Google"
    @AppStorage("omnibarPosition") private var omnibarPosition = "Upper"
    @AppStorage("spaceScrollPercent") private var spaceScrollPercent = 90.0
    @AppStorage("cmdPExportsPDF") private var cmdPExportsPDF = true
    @AppStorage(GlobalOmnibarHotkey.defaultsKey) private var globalOmnibarHotkey = GlobalOmnibarHotkey.defaultChord

    let searchEngines = ["Google", "DuckDuckGo", "Bing", "Yahoo"]
    let omnibarPositions = ["Top", "Upper", "Center"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General")
                .font(.title)
                .fontWeight(.bold)

            GroupBox(label: Text("Search")) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default search engine")
                        Picker("Search Engine", selection: $searchEngine) {
                            ForEach(searchEngines, id: \.self) { engine in
                                Text(engine)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Picker("Omnibar position", selection: $omnibarPosition) {
                        ForEach(omnibarPositions, id: \.self) { position in
                            Text(position)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding()
            }

            GroupBox(label: Text("Behavior")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Spacebar scrolls \(Int(spaceScrollPercent))% of a page")
                        Slider(value: $spaceScrollPercent, in: 10...100, step: 5)
                            .frame(width: 180)
                    }
                    Text("Applies to newly loaded pages.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("⌘P creates a PDF (Print is ⇧⌘P)", isOn: $cmdPExportsPDF)

                    Picker("Global omnibar hotkey", selection: $globalOmnibarHotkey) {
                        Text("⌥ Space").tag("optSpace")
                        Text("⌃⌥ Space").tag("ctrlOptSpace")
                        Text("Off").tag("off")
                    }
                    .pickerStyle(.menu)
                    Text("Opens the omnibar from any app, even when Browser isn't focused.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }

            Spacer()
        }
        .padding()
    }
}

// MARK: - Privacy Settings
struct PrivacySettingsView: View {
    @State private var showClearDataDialog = false
    @State private var clearHistory = true
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var clearLocalStorage = true

    @State private var showCookieManager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Privacy")
                .font(.title)
                .fontWeight(.bold)

            GroupBox(label: Text("Data Management")) {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Clear browsing data...") {
                        showClearDataDialog = true
                    }
                    .sheet(isPresented: $showClearDataDialog) {
                        ClearDataDialog(
                            isPresented: $showClearDataDialog,
                            clearHistory: $clearHistory,
                            clearCookies: $clearCookies,
                            clearCache: $clearCache,
                            clearLocalStorage: $clearLocalStorage
                        )
                    }

                    Button("Manage cookies...") {
                        showCookieManager = true
                    }
                    .sheet(isPresented: $showCookieManager) {
                        CookieManagerDialog(isPresented: $showCookieManager)
                    }
                }
                .padding()
            }

            Spacer()
        }
        .padding()
    }
}

// MARK: - Clear Data Dialog
struct ClearDataDialog: View {
    @Binding var isPresented: Bool
    @Binding var clearHistory: Bool
    @Binding var clearCookies: Bool
    @Binding var clearCache: Bool
    @Binding var clearLocalStorage: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("Clear Browsing Data")
                .font(.title)
                .fontWeight(.bold)

            Text("Select the types of data you want to clear:")
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Browsing history", isOn: $clearHistory)
                Toggle("Cookies and site data", isOn: $clearCookies)
                Toggle("Cached images and files", isOn: $clearCache)
                Toggle("Local storage", isOn: $clearLocalStorage)
            }
            .padding(.horizontal)

            HStack(spacing: 16) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)

                Button("Clear Data") {
                    clearSelectedData()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(32)
        .frame(width: 400)
    }

    private func clearSelectedData() {
        if clearHistory {
            // Clear browsing history from UserDefaults
            UserDefaults.standard.removeObject(forKey: "normal_session_data")
            UserDefaults.standard.synchronize()
        }

        if clearCookies {
            // Clear cookies using HTTPCookieStorage
            HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)

            // Clear website data using WKWebsiteDataStore
            WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                records.forEach { record in
                    WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes, for: [record]) { }
                }
            }
        }

        if clearCache {
            // Clear URL cache
            URLCache.shared.removeAllCachedResponses()

            // Clear WKWebsiteDataStore cache
            WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: Date.distantPast) { }
        }

        if clearLocalStorage {
            // Clear local storage and other website data
            WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeLocalStorage], modifiedSince: Date.distantPast) { }
        }
    }
}

// MARK: - Cookie Manager Dialog
struct CookieManagerDialog: View {
    @Binding var isPresented: Bool
    @State private var cookies: [HTTPCookie] = []
    @State private var searchText = ""

    var filteredCookies: [HTTPCookie] {
        if searchText.isEmpty {
            return cookies
        } else {
            return cookies.filter {
                $0.name.lowercased().contains(searchText.lowercased()) ||
                $0.domain.lowercased().contains(searchText.lowercased()) ||
                $0.path.lowercased().contains(searchText.lowercased())
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Cookie Manager")
                .font(.title)
                .fontWeight(.bold)

            HStack {
                TextField("Search cookies...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Button("Refresh") {
                    loadCookies()
                }
            }

            List {
                ForEach(filteredCookies, id: \.name) { cookie in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cookie.name)
                                .font(.headline)
                            Spacer()
                            Button(action: {
                                deleteCookie(cookie)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                        }

                        Text("Domain: \(cookie.domain)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("Path: \(cookie.path)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if let expiresDate = cookie.expiresDate {
                            Text("Expires: \(expiresDate.formatted())")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Session cookie")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Text("Value: \(cookie.value)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(height: 300)

            HStack(spacing: 16) {
                Button("Delete All Cookies") {
                    deleteAllCookies()
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Spacer()

                Button("Close") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 600, height: 500)
        .onAppear {
            loadCookies()
        }
    }

    private func loadCookies() {
        cookies = HTTPCookieStorage.shared.cookies ?? []
    }

    private func deleteCookie(_ cookie: HTTPCookie) {
        HTTPCookieStorage.shared.deleteCookie(cookie)
        loadCookies() // Refresh the list
    }

    private func deleteAllCookies() {
        if let allCookies = HTTPCookieStorage.shared.cookies {
            for cookie in allCookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        loadCookies() // Refresh the list
    }
}

// MARK: - Security Settings
struct SecuritySettingsView: View {
    @AppStorage("sslStrictMode") private var sslStrictMode = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Security")
                .font(.title)
                .fontWeight(.bold)

            GroupBox(label: Text("SSL/TLS")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Refuse invalid certificates (strict SSL)", isOn: $sslStrictMode)
                    Text("When off, you'll be asked whether to proceed on certificate errors.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }

            Spacer()
        }
        .padding()
    }
}

// MARK: - Appearance Settings
struct AppearanceSettingsView: View {
    // Same "theme" defaults key SettingsManager reads - one store, no desync
    @AppStorage("theme") private var theme = "System"

    // Load progress indicators (any combination)
    @AppStorage("progressBarTop") private var progressBarTop = true
    @AppStorage("progressBarBottom") private var progressBarBottom = false
    @AppStorage("progressBarLeft") private var progressBarLeft = false
    @AppStorage("progressBarRight") private var progressBarRight = false
    @AppStorage("progressFaviconRing") private var progressFaviconRing = false

    let themes = ["Light", "Dark", "System"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Appearance")
                .font(.title)
                .fontWeight(.bold)

            GroupBox(label: Text("Theme")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Theme", selection: $theme) {
                        ForEach(themes, id: \.self) { theme in
                            Text(theme)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
                .padding()
            }

            GroupBox(label: Text("Loading Progress")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Show the progress bar on these window edges:")
                    HStack(spacing: 16) {
                        Toggle("Top", isOn: $progressBarTop)
                        Toggle("Bottom", isOn: $progressBarBottom)
                        Toggle("Left", isOn: $progressBarLeft)
                        Toggle("Right", isOn: $progressBarRight)
                    }
                    Divider()
                    Toggle("Show progress as a ring around the favicon in the tab bar", isOn: $progressFaviconRing)
                }
                .padding()
            }

            Spacer()
        }
        .padding()
    }
}

// MARK: - Advanced Settings
struct AdvancedSettingsView: View {
    @AppStorage("javaScriptEnabled") private var javaScriptEnabled = true
    @AppStorage("downloadsFolder") private var downloadsFolder = ""
    @AppStorage("optionClickDownloadEnabled") private var optionClickDownloadEnabled = true
    @AppStorage("optionClickDownloadLinks") private var optionClickDownloadLinks = true
    @AppStorage("optionClickDownloadImages") private var optionClickDownloadImages = true
    @AppStorage("optionClickFileTypes") private var optionClickFileTypes = ""
    @AppStorage("optionClickAlwaysDomains") private var optionClickAlwaysDomains = ""
    @AppStorage("optionClickNeverDomains") private var optionClickNeverDomains = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Advanced")
                .font(.title)
                .fontWeight(.bold)

            GroupBox(label: Text("Content")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable JavaScript", isOn: $javaScriptEnabled)
                    Text("Applies to newly loaded pages.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }

            GroupBox(label: Text("Downloads")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Option-click downloads the linked file", isOn: $optionClickDownloadEnabled)

                    if optionClickDownloadEnabled {
                        Toggle("Apply to links", isOn: $optionClickDownloadLinks)
                        Toggle("Apply to images", isOn: $optionClickDownloadImages)

                        HStack {
                            Text("File types:")
                            TextField("e.g. jpg png gif pdf (empty = all)", text: $optionClickFileTypes)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Always on:")
                            TextField("domains, comma or space separated", text: $optionClickAlwaysDomains)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Never on:")
                            TextField("domains, comma or space separated", text: $optionClickNeverDomains)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    Divider()

                    HStack {
                        Text("Download folder:")
                        TextField("Downloads folder path", text: $downloadsFolder)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose...") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.canCreateDirectories = true
                            panel.title = "Choose Downloads Folder"
                            panel.message = "Select a folder to save downloaded files"

                            if panel.runModal() == .OK, let url = panel.url {
                                downloadsFolder = url.path
                            }
                        }
                    }
                }
                .padding()
            }

            Spacer()
        }
        .padding()
    }
}

#Preview {
    SettingsWindow()
}