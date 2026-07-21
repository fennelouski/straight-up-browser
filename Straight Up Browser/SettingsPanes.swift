//
//  SettingsPanes.swift
//  Straight Up Browser
//
//  The panes behind the settings sidebar — one grouped Form each, with a tinted SettingsLabel per
//  section and a caption + "?" popover under every control. The design system lives in
//  SettingsWindow.swift; the demos the popovers show live in SettingsDemos.swift.
//

import AppKit
import SwiftData
import SwiftUI
import WebKit

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage("searchEngine") private var searchEngine = "Google"
    @AppStorage("omnibarPosition") private var omnibarPosition = "Upper"
    @AppStorage("spaceScrollPercent") private var spaceScrollPercent = 90.0
    @AppStorage("cmdPExportsPDF") private var cmdPExportsPDF = true
    @AppStorage(GlobalOmnibarHotkey.defaultsKey) private var globalOmnibarHotkey = GlobalOmnibarHotkey.defaultChord
    @AppStorage(DefaultBrowser.promptEnabledKey) private var defaultBrowserPrompt = true

    @AppStorage(TabSync.Key.enabled) private var tabSyncEnabled = false
    @AppStorage(TabSync.Key.mode) private var tabSyncMode = TabSyncMode.openOnly.rawValue
    @AppStorage(TabSync.Key.cacheState) private var tabSyncCacheState = false
    @State private var iCloudAvailable = false

    private let searchEngines = ["Google", "DuckDuckGo", "Bing", "Yahoo"]
    private let omnibarPositions = ["Top", "Upper", "Center"]

    var body: some View {
        Form {
            // Only offered when the user's iCloud account can back sync.
            if iCloudAvailable {
                Section {
                    Toggle("Sync tabs across your devices", isOn: $tabSyncEnabled)
                    if tabSyncEnabled {
                        Picker("Sync", selection: $tabSyncMode) {
                            ForEach(TabSyncMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                        Toggle("Also sync page state (scroll, history, forms)", isOn: $tabSyncCacheState)
                    }
                } header: {
                    SettingsLabel("Sync", systemImage: "arrow.triangle.2.circlepath", tint: SettingsTint.general)
                } footer: {
                    Text("Uses iCloud. “Just opening tabs” shares the tabs you open but keeps closing a tab a per-device choice; “Opening and closing” keeps one shared set across devices. Turning sync on or off takes effect after you relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Default search engine", selection: $searchEngine) {
                    ForEach(searchEngines, id: \.self) { Text($0) }
                }
                SettingCaptionRow(
                    caption: "Where a plain search from the omnibar goes.",
                    title: "Search Engine",
                    explanation: "Type words rather than a URL into the omnibar and they're handed to this engine. Anything that looks like an address still loads directly.",
                    value: $searchEngine
                ) { SearchEngineDemo(engine: $0) }

                Picker("Omnibar position", selection: $omnibarPosition) {
                    ForEach(omnibarPositions, id: \.self) { Text($0) }
                }
                SettingCaptionRow(
                    caption: "How high the omnibar sits when you summon it.",
                    title: "Omnibar Position",
                    explanation: "The omnibar drops in over the page when you start typing an address. Top pins it to the toolbar; Upper floats it a third of the way down; Center puts it at eye level.",
                    value: $omnibarPosition
                ) { OmnibarPositionDemo(position: $0) }
            } header: {
                SettingsLabel("Search", systemImage: "magnifyingglass", tint: SettingsTint.general)
            }

            Section {
                LabeledContent("Spacebar scrolls") {
                    HStack {
                        Slider(value: $spaceScrollPercent, in: 10...100, step: 5).frame(width: 180)
                        Text("\(Int(spaceScrollPercent))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                }
                SettingCaptionRow(
                    caption: "How much of the page one press of Space jumps. Applies to newly loaded pages.",
                    title: "Spacebar Scroll",
                    explanation: "Pressing Space pages down. This sets how far — 90% leaves a sliver of overlap so you don't lose your place, while 100% is a clean full-screen jump.",
                    value: $spaceScrollPercent
                ) { SpaceScrollDemo(percent: $0) }

                Toggle("⌘P creates a PDF (Print is ⇧⌘P)", isOn: $cmdPExportsPDF)
                SettingCaptionRow(
                    caption: "Make the everyday shortcut save a PDF instead of printing.",
                    title: "⌘P Creates a PDF",
                    explanation: "Most of the time you want a PDF, not paper. With this on, ⌘P exports the page as a PDF and ⇧⌘P opens the print dialog. Turn it off and ⌘P prints, the way it does everywhere else.",
                    value: $cmdPExportsPDF
                ) { CmdPPDFDemo(enabled: $0) }

                Toggle("Offer to make Browser your default", isOn: $defaultBrowserPrompt)
                    .onChange(of: defaultBrowserPrompt) { _, on in
                        DefaultBrowser.setPromptEnabled(on)
                    }
                SettingCaptionRow(
                    caption: "Show the corner nudge on a new tab until Browser is your default.",
                    title: "Default Browser Nudge",
                    explanation: "When Browser isn't your default, a small card appears in the corner of a new tab offering to make it one. It goes away for good once you answer it either way — turn this off to skip it entirely, or back on to see it again.",
                    value: $defaultBrowserPrompt
                ) { DefaultBrowserPromptDemo(enabled: $0) }

                Picker("Global omnibar hotkey", selection: $globalOmnibarHotkey) {
                    Text("⌥ Space").tag("optSpace")
                    Text("⌃⌥ Space").tag("ctrlOptSpace")
                    Text("Off").tag("off")
                }
                SettingCaptionRow(
                    caption: "Opens the omnibar from any app, even when Browser isn't focused.",
                    title: "Global Omnibar Hotkey",
                    explanation: "A system-wide shortcut that brings up the omnibar no matter which app is in front — type an address and Browser comes forward with it loaded. Set it to Off to release the shortcut for something else.",
                    value: $globalOmnibarHotkey
                ) { HotkeyDemo(chord: $0) }
            } header: {
                SettingsLabel("Behavior", systemImage: "slider.horizontal.3", tint: SettingsTint.general)
            }
        }
        .formStyle(.grouped)
        .task { iCloudAvailable = await TabSync.iCloudAvailable() }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    private var store: ShortcutStore { .shared }

    var body: some View {
        // Commands sharing a chord get flagged; nothing collides by default, so
        // a warning only appears once the user creates the overlap.
        let conflictIDs = Set(store.conflicts().map(\.id))
        Form {
            Section {
                HStack(alignment: .top) {
                    Text("Click a shortcut and press the new keys. Esc cancels. Shortcuts need a modifier — ⌘, ⌥, ⌃, or ⇧.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Menu("Import from…") {
                        ForEach(ShortcutPreset.allCases) { preset in
                            Button(preset.title) { store.apply(preset: preset) }
                        }
                    }
                    .fixedSize()
                    Button("Reset All") { store.resetAll() }
                        .disabled(store.custom.isEmpty)
                }
            } header: {
                SettingsLabel("Keyboard Shortcuts", systemImage: "keyboard", tint: SettingsTint.shortcuts)
            }

            ForEach(ShortcutSection.allCases, id: \.self) { section in
                Section {
                    ForEach(ShortcutCommand.all.filter { $0.section == section }) { command in
                        shortcutRow(command, conflicting: conflictIDs.contains(command.id))
                    }
                } header: {
                    Text(section.title)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ command: ShortcutCommand, conflicting: Bool) -> some View {
        HStack(spacing: 8) {
            Text(command.title)
            if store.isCustomized(command) {
                Button { store.reset(command) } label: {
                    Image(systemName: "arrow.uturn.backward").font(.caption)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Reset to default"))
            }
            Spacer(minLength: 12)
            if conflicting {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(String(localized: "This shortcut is used by more than one command"))
            } else if let systemName = store.systemConflict(store.shortcut(for: command)) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                    .help(String(localized: "May conflict with the macOS \(systemName) shortcut"))
            }
            ShortcutRecorder(command: command)
        }
    }
}

// A key-cap-style control: shows the current chord; click to record the next
// one. Reads/writes ShortcutStore.shared so the rest of the app updates live.
struct ShortcutRecorder: View {
    let command: ShortcutCommand
    @State private var recorder = KeyRecorder()

    var body: some View {
        let shortcut = ShortcutStore.shared.shortcut(for: command)
        Button {
            if recorder.isRecording {
                recorder.stop()
            } else {
                recorder.start { ShortcutStore.shared.rebind(command, to: $0) }
            }
        } label: {
            Text(recorder.isRecording ? String(localized: "Press keys…") : shortcut.displayString)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 96)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(recorder.isRecording ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recorder.isRecording ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDisappear { recorder.stop() }
    }
}

// Captures one chord via a temporary local event monitor. Swallows keys while
// recording so nothing else fires; Esc cancels. Only one recorder is ever
// active — starting a new one stops the previous.
@Observable
final class KeyRecorder {
    static weak var active: KeyRecorder?

    var isRecording = false
    private var monitor: Any?

    func start(onCapture: @escaping (Shortcut) -> Void) {
        KeyRecorder.active?.stop()
        KeyRecorder.active = self
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop(); return nil } // Esc cancels
            // ponytail: require a modifier so a bare letter can't hijack typing.
            if let shortcut = Shortcut(event: event), shortcut.hasModifier {
                onCapture(shortcut)
                self.stop()
            }
            return nil // swallow everything while recording
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        isRecording = false
        if KeyRecorder.active === self { KeyRecorder.active = nil }
    }
}

// MARK: - Content

struct ContentSettingsView: View {
    @AppStorage("javaScriptEnabled") private var javaScriptEnabled = true
    @AppStorage("pinchToZoomEnabled") private var pinchToZoomEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Enable JavaScript", isOn: $javaScriptEnabled)
                SettingCaptionRow(
                    caption: "Off makes pages static. Applies to newly loaded pages.",
                    title: "JavaScript",
                    explanation: "JavaScript is what makes pages interactive — menus, forms, live content. Almost every modern site needs it. Turning it off loads pages as plain, static documents, which is faster and quieter but breaks most web apps.",
                    value: $javaScriptEnabled
                ) { JavaScriptDemo(enabled: $0) }
            } header: {
                SettingsLabel("Web Content", systemImage: "curlybraces", tint: SettingsTint.content)
            }

            Section {
                Toggle("Pinch to zoom", isOn: $pinchToZoomEnabled)
                SettingCaptionRow(
                    caption: "Trackpad pinch and two-finger double-tap zoom the page. ⌘0 resets it.",
                    title: "Pinch to Zoom",
                    explanation: "With this on, a trackpad pinch magnifies the page, and a two-finger double-tap zooms the text block under your fingers to fill the width — just like Safari. This is separate from ⌘+ / ⌘− page zoom, which reflows text instead of magnifying. Actual Size (⌘0) resets both.",
                    value: $pinchToZoomEnabled
                ) { PinchZoomDemo(enabled: $0) }
            } header: {
                SettingsLabel("Zoom", systemImage: "plus.magnifyingglass", tint: SettingsTint.content)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Downloads

struct DownloadsSettingsView: View {
    @AppStorage("downloadsFolder") private var downloadsFolder = ""
    @AppStorage("optionClickDownloadEnabled") private var optionClickDownloadEnabled = true
    @AppStorage("optionClickDownloadLinks") private var optionClickDownloadLinks = true
    @AppStorage("optionClickDownloadImages") private var optionClickDownloadImages = true
    @AppStorage("optionClickFileTypes") private var optionClickFileTypes = ""
    @AppStorage("optionClickAlwaysDomains") private var optionClickAlwaysDomains = ""
    @AppStorage("optionClickNeverDomains") private var optionClickNeverDomains = ""

    var body: some View {
        Form {
            Section {
                Toggle("Option-click downloads the linked file", isOn: $optionClickDownloadEnabled)

                if optionClickDownloadEnabled {
                    Toggle("Apply to links", isOn: $optionClickDownloadLinks)
                    Toggle("Apply to images", isOn: $optionClickDownloadImages)

                    LabeledContent("File types") {
                        TokenField(text: $optionClickFileTypes, placeholder: String(localized: "jpg  png  pdf — empty means all"))
                    }
                    LabeledContent("Always on") {
                        TokenField(text: $optionClickAlwaysDomains, placeholder: "example.com")
                    }
                    LabeledContent("Never on") {
                        TokenField(text: $optionClickNeverDomains, placeholder: "example.com")
                    }
                }

                SettingCaptionRow(
                    caption: "Hold ⌥ and click to save instead of open. Type each entry, or paste a list.",
                    title: "Option-Click Downloads",
                    explanation: "With this on, ⌥-clicking a link or image saves it rather than opening it. The rules narrow it down: Never-on domains always open, the per-kind toggles decide links vs images, Always-on domains always download, and file types limit it to the extensions you list (empty means every type). The demo runs your live rules against a sample URL.",
                    value: .constant(0)
                ) { _ in DownloadRuleDemo() }
            } header: {
                SettingsLabel("Option-Click Downloads", systemImage: "arrow.down.circle", tint: SettingsTint.downloads)
            }

            Section {
                LabeledContent("Folder") {
                    HStack {
                        TextField("System Downloads folder", text: $downloadsFolder)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                SettingCaptionRow(
                    caption: "Where downloaded files are saved. Empty uses your system Downloads folder.",
                    title: "Download Folder",
                    explanation: "Every download lands here. Leave it empty to use the standard ~/Downloads folder, or pick another location — a scratch folder, an external drive, wherever you want files to collect.",
                    value: $downloadsFolder
                ) { DownloadFolderDemo(path: $0) }
            } header: {
                SettingsLabel("Download Folder", systemImage: "folder", tint: SettingsTint.downloads)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = String(localized: "Choose Downloads Folder")
        panel.message = "Select a folder to save downloaded files"

        if panel.runModal() == .OK, let url = panel.url {
            downloadsFolder = url.path
        }
    }
}

// MARK: - Window capture permission panel

// Shown as a sheet the first time ⇧⌥⌘S runs, and from the "?" in Settings.
// Two cards, each with a picture of the result: someone who just wants a
// screenshot should be able to pick in a second without reading a paragraph.
// `onCancel` nil = informational (opened from Settings, nothing to commit).
struct WindowCapturePanel: View {
    var onChoose: ((WindowCaptureMode) -> Void)?
    var onCancel: (() -> Void)?

    private var isInformational: Bool { onChoose == nil }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(SettingsTint.screenshots)
                Text("Include the tab bar?")
                    .font(.title3.weight(.semibold))
                Text("Two ways to shoot the window. One needs a macOS permission, one doesn't.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(alignment: .top, spacing: 14) {
                card(
                    mode: .full,
                    icon: "checkmark.seal.fill",
                    title: "Full Window",
                    blurb: "Exactly what you see — your tabs included.",
                    noteIcon: "lock.fill",
                    note: "Needs Screen Recording permission",
                    noteTint: .orange,
                    showsTabs: true
                )
                card(
                    mode: .limited,
                    icon: "bolt.fill",
                    title: "Window & Page",
                    blurb: "The window and the page, right now.",
                    noteIcon: "checkmark.shield.fill",
                    note: "No permission, works anywhere",
                    noteTint: .green,
                    showsTabs: false
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "gearshape").foregroundStyle(.tertiary)
                Text("Change this any time in Settings → Screenshots. The other three screenshot shortcuts never ask for anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let onCancel {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: isInformational ? 560 : 620)
    }

    private func card(
        mode: WindowCaptureMode,
        icon: String,
        title: LocalizedStringKey,
        blurb: LocalizedStringKey,
        noteIcon: String,
        note: LocalizedStringKey,
        noteTint: Color,
        showsTabs: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            preview(showsTabs: showsTabs)

            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(SettingsTint.screenshots)
                Text(title).font(.headline)
            }
            Text(blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Image(systemName: noteIcon).foregroundStyle(noteTint)
                Text(note).foregroundStyle(.secondary)
            }
            .font(.caption2)

            if let onChoose {
                Button(mode == .full ? "Ask for Permission" : "Use This") { onChoose(mode) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
    }

    // A mock of the resulting image: same window either way, but the tab column
    // is either your tabs or a flat block. This is the whole decision, drawn.
    private func preview(showsTabs: Bool) -> some View {
        WindowFrame {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    if showsTabs {
                        ForEach(0..<5, id: \.self) { index in
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(SettingsTint.screenshots.opacity(index == 0 ? 0.9 : 0.5))
                                    .frame(width: 5, height: 5)
                                Capsule().fill(Color.white.opacity(0.45)).frame(height: 4)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(5)
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .background(showsTabs ? Color.black.opacity(0.75) : Color.gray.opacity(0.28))

                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(Color.primary.opacity(0.25)).frame(width: 52, height: 6)
                    ForEach(0..<5, id: \.self) { _ in
                        Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
            }
            .frame(height: 96)
        }
        .overlay(alignment: .bottomLeading) {
            if !showsTabs {
                Text("no tabs")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.10)))
                    .padding(5)
            }
        }
    }
}

// MARK: - Screenshots

// Four capture shortcuts × three destinations × a format each. The grid only
// stays readable because each shortcut is folded into its own DisclosureGroup
// and every control is one ScreenshotSettings.binding call.
struct ScreenshotsSettingsView: View {
    @AppStorage(ScreenshotSettings.Key.sharedFolder) private var sharedFolder = ""
    @AppStorage(ScreenshotSettings.Key.visibleWholeContentArea) private var visibleWholeContentArea = false
    @AppStorage(ScreenshotSettings.Key.windowCaptureMode) private var windowCaptureMode = WindowCaptureMode.ask.rawValue
    // Applied to every destination of every shortcut in one go — the fast path
    // out of touching twelve pickers by hand.
    @State private var bulkFormat = ScreenshotFormat.png
    @State private var showingCaptureHelp = false

    private var settings: ScreenshotSettings { .shared }
    private var store: ShortcutStore { .shared }

    var body: some View {
        Form {
            Section {
                LabeledContent("Shared folder") {
                    HStack {
                        TextField("~/Pictures/Browser Screenshots", text: $sharedFolder)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseFolder(into: $sharedFolder) }
                    }
                }
                SettingCaptionRow(
                    caption: "Where any shortcut set to “save to the shared folder” writes.",
                    title: "Shared Screenshots Folder",
                    explanation: "Each shortcut can save to this one folder, to a folder of its own, or to both. Leave it empty and screenshots collect in ~/Pictures/Browser Screenshots.",
                    value: $sharedFolder
                ) { ScreenshotFolderDemo(path: $0) }

                HStack {
                    Picker("Set every format to", selection: $bulkFormat) {
                        ForEach(ScreenshotFormat.allCases) { Text($0.label).tag($0) }
                    }
                    Button("Apply") { applyToAll(bulkFormat) }
                }
                SettingCaptionRow(
                    caption: "Overwrites the format on every destination below.",
                    title: "Format",
                    explanation: "PNG is lossless and the safe default. JPEG is smaller but softens text. PDF keeps a full-page capture as vector — the text stays selectable — and wraps every other capture as a single page.",
                    value: $bulkFormat
                ) { ScreenshotFormatDemo(format: $0) }

                Picker("⌘S in a split captures", selection: $visibleWholeContentArea) {
                    Text("The focused pane").tag(false)
                    Text("Every pane").tag(true)
                }
                SettingCaptionRow(
                    caption: "Only matters while a split is open.",
                    title: "Split Captures",
                    explanation: "With a split open, ⌘S normally shoots just the pane you're working in. Switch it to every pane and you get the whole content area — all panes side by side, still without the tab bar.",
                    value: $visibleWholeContentArea
                ) { ScreenshotSplitDemo(wholeArea: $0) }
            } header: {
                SettingsLabel("All Screenshots", systemImage: "camera", tint: SettingsTint.screenshots)
            }

            ForEach(ScreenshotKind.allCases) { kind in
                Section {
                    DisclosureGroup {
                        destinationRows(for: kind)
                    } label: {
                        HStack {
                            Text(kind.title)
                            Spacer()
                            Text(store.shortcut(for: kind.command).displayString)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    SettingCaptionRow(
                        caption: kind.summary,
                        title: kind.title,
                        explanation: "Each destination is independent: you can put a PNG on the clipboard, a PDF in the shared folder, and a JPEG in this shortcut's own folder from a single press. Rebind the keys in Settings → Shortcuts.",
                        value: .constant(kind)
                    ) { ScreenshotKindDemo(kind: $0.wrappedValue) }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func destinationRows(for kind: ScreenshotKind) -> some View {
        let ownFolder = settings.binding(kind, \.ownFolder)
        VStack(alignment: .leading, spacing: 8) {
            destinationRow("Copy to clipboard", kind, \.clipboard)
            destinationRow("Save to the shared folder", kind, \.shared)
            destinationRow("Save to its own folder", kind, \.own)

            if settings.config(for: kind).own.enabled {
                HStack {
                    TextField("Choose a folder for this shortcut", text: ownFolder)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseFolder(into: ownFolder) }
                }
                .padding(.leading, 20)
            }

            // Only the window shot can want Screen Recording, so the choice
            // lives with it rather than cluttering the shared section.
            if kind == .window {
                Divider().padding(.vertical, 2)
                HStack {
                    Picker("Capture the tab bar", selection: $windowCaptureMode) {
                        ForEach(WindowCaptureMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Button { showingCaptureHelp = true } label: {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("What's the difference?")
                    .popover(isPresented: $showingCaptureHelp, arrowEdge: .trailing) {
                        WindowCapturePanel()
                    }
                }
                Text(windowCaptureModeExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Only nag when the chosen mode actually needs something the
                // user hasn't given — never when they've picked the limited path.
                if windowCaptureMode == WindowCaptureMode.full.rawValue,
                   !ScreenshotManager.hasScreenRecordingPermission {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Screen Recording isn't granted yet, so this falls back to the limited capture.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Open System Settings") { ScreenshotManager.openScreenRecordingSettings() }
                            .controlSize(.small)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                }
            }
        }
        .padding(.top, 4)
    }

    private var windowCaptureModeExplanation: LocalizedStringKey {
        switch WindowCaptureMode(rawValue: windowCaptureMode) ?? .ask {
        case .ask:
            return "Browser will show you the two options the first time you press this shortcut, and remember what you pick."
        case .full:
            return "Captures the window exactly as you see it. Needs macOS Screen Recording permission — if it isn't granted, you get the limited version instead of nothing."
        case .limited:
            return "Captures the window and the page with no permission at all. The tab bar area comes out as a plain background rather than your tabs."
        }
    }

    private func destinationRow(
        _ label: LocalizedStringKey,
        _ kind: ScreenshotKind,
        _ path: WritableKeyPath<ScreenshotConfig, ScreenshotDestination>
    ) -> some View {
        let destination = settings.binding(kind, path)
        return HStack {
            Toggle(label, isOn: Binding(get: { destination.wrappedValue.enabled },
                                        set: { destination.wrappedValue.enabled = $0 }))
            Spacer()
            Picker("", selection: Binding(get: { destination.wrappedValue.format },
                                          set: { destination.wrappedValue.format = $0 })) {
                ForEach(ScreenshotFormat.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 90)
            .disabled(!destination.wrappedValue.enabled)
        }
    }

    private func applyToAll(_ format: ScreenshotFormat) {
        for kind in ScreenshotKind.allCases {
            settings.update(kind) {
                $0.clipboard.format = format
                $0.shared.format = format
                $0.own.format = format
            }
        }
    }

    // Same NSOpenPanel shape DownloadsSettingsView uses.
    private func chooseFolder(into path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = String(localized: "Choose Screenshots Folder")
        panel.message = "Select a folder to save screenshots"

        if panel.runModal() == .OK, let url = panel.url {
            path.wrappedValue = url.path
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    // Same "theme" defaults key SettingsManager reads — one store, no desync.
    @AppStorage("theme") private var theme = "System"

    // Load progress indicators (any combination).
    @AppStorage("progressBarTop") private var progressBarTop = true
    @AppStorage("progressBarBottom") private var progressBarBottom = false
    @AppStorage("progressBarLeft") private var progressBarLeft = false
    @AppStorage("progressBarRight") private var progressBarRight = false
    @AppStorage("progressFaviconRing") private var progressFaviconRing = false

    // Flicker control.
    @AppStorage("fadeInPages") private var fadeInPages = true
    @AppStorage("fadeInDuration") private var fadeInDuration = 250.0
    @AppStorage("pageWhitePoint") private var pageWhitePoint = 100.0

    private let themes = ["Light", "Dark", "System"]

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $theme) {
                    ForEach(themes, id: \.self) { Text($0) }
                }
                .pickerStyle(.radioGroup)
                SettingCaptionRow(
                    caption: "Light, Dark, or follow your Mac.",
                    title: "Theme",
                    explanation: "Sets the browser's own chrome — toolbar, tabs, menus. System follows your Mac's appearance and switches with it at sunset if you have that on. (Pages render in whatever appearance the site itself chooses.)",
                    value: $theme
                ) { ThemeDemo(theme: $0) }
            } header: {
                SettingsLabel("Theme", systemImage: "paintbrush", tint: SettingsTint.appearance)
            }

            Section {
                Text("Show the loading progress bar on these window edges:")
                    .font(.callout)
                HStack(spacing: 16) {
                    Toggle("Top", isOn: $progressBarTop)
                    Toggle("Bottom", isOn: $progressBarBottom)
                    Toggle("Left", isOn: $progressBarLeft)
                    Toggle("Right", isOn: $progressBarRight)
                }
                .toggleStyle(.checkbox)
                Toggle("Ring around the favicon in the tab bar", isOn: $progressFaviconRing)

                SettingCaptionRow(
                    caption: "Pick any combination — edges, the favicon ring, or both.",
                    title: "Loading Progress",
                    explanation: "While a page loads, Browser can trace progress along any of the window's four edges and/or as a ring that fills around the site's favicon in the tab. Turn them all off for a completely quiet load. The demo animates a fake load so you can see each choice.",
                    value: .constant(0)
                ) { _ in ProgressIndicatorDemo() }
            } header: {
                SettingsLabel("Loading Progress", systemImage: "arrow.triangle.2.circlepath", tint: SettingsTint.appearance)
            }

            Section {
                Toggle("Fade pages in once they've drawn", isOn: $fadeInPages)
                if fadeInPages {
                    LabeledContent("Fade length") {
                        HStack {
                            Slider(value: $fadeInDuration, in: 100...1000, step: 50).frame(width: 180)
                            Text("\(Int(fadeInDuration)) ms").monospacedDigit().frame(width: 60, alignment: .trailing)
                        }
                    }
                }
                SettingCaptionRow(
                    caption: "No white flash between tabs — the page appears only once it has pixels.",
                    title: "Fade Pages In",
                    explanation: "A loading page has nothing to draw yet, so browsers flash their background — usually white — until the first frame arrives. With this on, Browser keeps the page hidden through that gap and fades it in the moment the page actually paints. Pages that can't report a paint (PDFs, downloads, error pages) appear as soon as they finish loading.",
                    value: $fadeInDuration
                ) { FadeInDemo(duration: $0) }
            } header: {
                SettingsLabel("Page Fade", systemImage: "circle.lefthalf.filled", tint: SettingsTint.appearance)
            }

            Section {
                LabeledContent("Max page brightness") {
                    HStack {
                        Slider(value: $pageWhitePoint, in: 50...100, step: 5).frame(width: 180)
                        Text("\(Int(pageWhitePoint))%").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                SettingCaptionRow(
                    caption: "100% leaves pages alone. Lower caps how bright white can get.",
                    title: "White Point",
                    explanation: "Bright pages are the other half of screen flicker — a white page after a dark one is a jolt no fade can hide. This caps how bright the brightest parts of a page can go. Because it scales brightness rather than laying grey over the page, dark text barely moves while backgrounds come down, so text stays readable and roughly half as dimmed as the page around it.",
                    value: $pageWhitePoint
                ) { WhitePointDemo(whitePoint: $0) }
            } header: {
                SettingsLabel("White Point", systemImage: "sun.max", tint: SettingsTint.appearance)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Security

struct SecuritySettingsView: View {
    @AppStorage("sslStrictMode") private var sslStrictMode = true
    @AppStorage("adBlockEnabled") private var adBlockEnabled = false
    @AppStorage("cliRealEventsEnabled") private var cliRealEventsEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Refuse invalid certificates (strict SSL)", isOn: $sslStrictMode)
                SettingCaptionRow(
                    caption: "When off, you're asked whether to proceed on certificate errors.",
                    title: "Strict SSL",
                    explanation: "A site with an invalid or expired certificate can't prove it's who it says it is. Strict mode blocks those connections outright. Turn it off and you'll get a warning with the choice to proceed anyway — handy for a local server with a self-signed cert, riskier out on the open web.",
                    value: $sslStrictMode
                ) { SSLStrictDemo(strict: $0) }
            } header: {
                SettingsLabel("SSL / TLS", systemImage: "lock.shield", tint: SettingsTint.security)
            }

            Section {
                Toggle("Block ads and trackers", isOn: $adBlockEnabled)
                    .onChange(of: adBlockEnabled) { _, _ in
                        NotificationCenter.default.post(name: .adBlockChanged, object: nil)
                    }
                SettingCaptionRow(
                    caption: "Blocks common ad and tracking networks. Open tabs reload when toggled.",
                    title: "Ad Blocking",
                    explanation: "Drops requests to a built-in list of advertising and tracking hosts, so those resources never load. Pages get lighter and quieter. Toggling it reloads your open tabs so the change takes effect everywhere at once.",
                    value: $adBlockEnabled
                ) { AdBlockDemo(enabled: $0) }
            } header: {
                SettingsLabel("Ad Blocking", systemImage: "shield.lefthalf.filled", tint: SettingsTint.security)
            }

            Section {
                Toggle("Allow the CLI to send real mouse clicks", isOn: $cliRealEventsEnabled)
                SettingCaptionRow(
                    caption: "Lets `browser-cli click --real` post genuine mouse events.",
                    title: "CLI Real Clicks",
                    explanation: "By default the CLI's clicks are synthetic — fine for automation, but pages that gate actions behind a real user gesture (autoplay, pop-ups) ignore them. Turning this on lets `browser-cli click --real` post genuine mouse events that count as gestures. The trade-off: any process running as you can then click inside the browser window, so leave it off unless you need it.",
                    value: $cliRealEventsEnabled
                ) { CLIRealClicksDemo(enabled: $0) }
            } header: {
                SettingsLabel("CLI Automation", systemImage: "terminal", tint: SettingsTint.security)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Memory

struct MemorySettingsView: View {
    @AppStorage("memorySaverEnabled") private var memorySaverEnabled = false
    @AppStorage("memorySaverDefaultPolicy") private var defaultPolicy = MemoryPolicy.whenNeeded.rawValue
    @Query(sort: \BrowserTab.orderIndex) private var tabs: [BrowserTab]

    var body: some View {
        Form {
            Section {
                Toggle("Enable memory saving", isOn: $memorySaverEnabled)
                SettingCaptionRow(
                    caption: "Release idle background tabs from RAM when your Mac runs low.",
                    title: "Memory Saving",
                    explanation: "When your Mac runs low on memory, background tabs you allow are released from RAM and reload instantly when you return — scroll position and history are kept, so it's nearly seamless. The tabs you're actively using are never touched.",
                    value: $memorySaverEnabled
                ) { MemorySaverDemo(enabled: $0) }

                Picker("Default for new tabs", selection: $defaultPolicy) {
                    ForEach(MemoryPolicy.allCases, id: \.self) { policy in
                        Text(policy.label).tag(policy.rawValue)
                    }
                }
                .disabled(!memorySaverEnabled)
            } header: {
                SettingsLabel("Memory Saving", systemImage: "memorychip", tint: SettingsTint.memory)
            }

            Section {
                if tabs.isEmpty {
                    Text("No open tabs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tabs, id: \.id) { tab in
                        HStack(spacing: 8) {
                            faviconImage(tab)
                            Text(tabTitle(tab))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Picker("", selection: Binding(
                                get: { tab.memoryPolicy },
                                set: { tab.memoryPolicy = $0 }
                            )) {
                                ForEach(MemoryPolicy.allCases, id: \.self) { policy in
                                    Text(policy.label).tag(policy)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                            .disabled(!memorySaverEnabled)
                        }
                    }
                }
            } header: {
                SettingsLabel("Open Tabs", systemImage: "square.on.square", tint: SettingsTint.memory)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func faviconImage(_ tab: BrowserTab) -> some View {
        if let data = tab.favicon, let img = NSImage(data: data) {
            Image(nsImage: img).resizable().scaledToFit().frame(width: 16, height: 16)
        } else {
            Image(systemName: "globe").frame(width: 16, height: 16).foregroundStyle(.secondary)
        }
    }

    private func tabTitle(_ tab: BrowserTab) -> String {
        tab.title.isEmpty ? BrowserTab.extractDomain(from: tab.url) : tab.title
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    @AppStorage("convertToIncognitoEnabled") private var convertToIncognitoEnabled = false
    @State private var showClearDataDialog = false
    @State private var clearHistory = true
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var clearLocalStorage = true

    @State private var showCookieManager = false

    var body: some View {
        Form {
            Section {
                Toggle("Switch a tab to incognito with a key command", isOn: $convertToIncognitoEnabled)
            } header: {
                SettingsLabel("Incognito", systemImage: "eyeglasses", tint: SettingsTint.privacy)
            } footer: {
                Text("Adds “Switch Tab to Incognito” to the Privacy menu. It moves the current tab into a private session: your logins come along (cookies are copied over), but everything after the switch is kept only in memory and vanishes when the tab closes. What happened before the switch is already in your history, and sites that keep you signed in with local storage may ask you to sign in again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Clear browsing data…") { showClearDataDialog = true }
                    .sheet(isPresented: $showClearDataDialog) {
                        ClearDataDialog(
                            isPresented: $showClearDataDialog,
                            clearHistory: $clearHistory,
                            clearCookies: $clearCookies,
                            clearCache: $clearCache,
                            clearLocalStorage: $clearLocalStorage
                        )
                    }

                Button("Manage cookies…") { showCookieManager = true }
                    .sheet(isPresented: $showCookieManager) {
                        CookieManagerDialog(isPresented: $showCookieManager)
                    }
            } header: {
                SettingsLabel("Data", systemImage: "externaldrive", tint: SettingsTint.privacy)
            } footer: {
                Text("Clearing browsing data removes history, cookies, caches, and local storage for the types you choose. The cookie manager lets you inspect and delete individual cookies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                Button("Cancel") { isPresented = false }
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
            UserDefaults.standard.removeObject(forKey: "normal_session_data")
            UserDefaults.standard.synchronize()
        }

        if clearCookies {
            HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)
            WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                records.forEach { record in
                    WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes, for: [record]) { }
                }
            }
        }

        if clearCache {
            URLCache.shared.removeAllCachedResponses()
            WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: Date.distantPast) { }
        }

        if clearLocalStorage {
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
                Button("Refresh") { loadCookies() }
            }

            List {
                ForEach(filteredCookies, id: \.name) { cookie in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cookie.name).font(.headline)
                            Spacer()
                            Button(action: { deleteCookie(cookie) }) {
                                Image(systemName: "trash").foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                        }

                        Text("Domain: \(cookie.domain)")
                            .font(.subheadline).foregroundColor(.secondary)
                        Text("Path: \(cookie.path)")
                            .font(.subheadline).foregroundColor(.secondary)

                        if let expiresDate = cookie.expiresDate {
                            Text("Expires: \(expiresDate.formatted())")
                                .font(.subheadline).foregroundColor(.secondary)
                        } else {
                            Text("Session cookie")
                                .font(.subheadline).foregroundColor(.secondary)
                        }

                        Text("Value: \(cookie.value)")
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(height: 300)

            HStack(spacing: 16) {
                Button("Delete All Cookies") { deleteAllCookies() }
                    .buttonStyle(.bordered)
                    .tint(.red)

                Spacer()

                Button("Close") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 600, height: 500)
        .onAppear { loadCookies() }
    }

    private func loadCookies() {
        cookies = HTTPCookieStorage.shared.cookies ?? []
    }

    private func deleteCookie(_ cookie: HTTPCookie) {
        HTTPCookieStorage.shared.deleteCookie(cookie)
        loadCookies()
    }

    private func deleteAllCookies() {
        if let allCookies = HTTPCookieStorage.shared.cookies {
            for cookie in allCookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        loadCookies()
    }
}
