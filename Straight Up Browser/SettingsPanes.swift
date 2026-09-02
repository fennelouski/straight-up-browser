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
import Translation
import WebKit

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var tabs: [Tab]

    @AppStorage("searchEngine") private var searchEngine = "Google"
    @AppStorage("omnibarPosition") private var omnibarPosition = "Upper"
    @AppStorage(FindBar.positionKey) private var findBarPosition = FindBar.defaultPosition
    @AppStorage(FindBar.intensityKey) private var findFlashIntensity = FindBar.defaultIntensity
    @AppStorage("spaceScrollPercent") private var spaceScrollPercent = 90.0
    @AppStorage("cmdPExportsPDF") private var cmdPExportsPDF = true
    @AppStorage("expandBackForwardShortcuts") private var expandBackForwardShortcuts = true
    @AppStorage(KeyboardShortcutsManager.overrideWebsiteQuickOpenKey) private var overrideWebsiteQuickOpen = false
    @AppStorage(GlobalOmnibarHotkey.defaultsKey) private var globalOmnibarHotkey = GlobalOmnibarHotkey.defaultChord
    @AppStorage(DefaultBrowser.promptEnabledKey) private var defaultBrowserPrompt = true
    @AppStorage(KeyboardShortcutsManager.quitHoldPercentKey) private var quitHoldPercent = KeyboardShortcutsManager.quitHoldDefaultPercent

    @AppStorage(TabSync.Key.enabled) private var tabSyncEnabled = false
    @AppStorage(TabSync.Key.mode) private var tabSyncMode = TabSyncMode.openOnly.rawValue
    @AppStorage(TabSync.Key.cacheState) private var tabSyncCacheState = false
    @AppStorage(FastForward.Key.enabled) private var fastForwardEnabled = true
    @AppStorage(SiteHistory.useAppleIntelligenceKey) private var siteNicknamesUseAI = true
    @AppStorage(Prefetcher.enabledKey) private var prefetchEnabled = true
    @AppStorage(SettingsManager.automaticLinkMitosisKey) private var automaticLinkMitosis = true
    @AppStorage(SettingsManager.automaticLinkSplitKey) private var automaticLinkSplit = false
    // Phase 2 (design §6.4): what clicking an anchor pill in a document does.
    @AppStorage("anchorLinkOpenBehavior") private var anchorLinkOpenBehavior = "peek"
    @State private var iCloudAvailable: Bool?

    private let searchEngines = ["Google", "DuckDuckGo", "Bing", "Yahoo"]
    private let omnibarPositions = ["Top", "Upper", "Center"]

    var body: some View {
        Form {
            CollapsibleSection(searchID: "general.sync") {
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
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(TabSync.syncedDataCategories, id: \.self) { category in
                                Label(category.label, systemImage: category.systemImage)
                            }
                            Text("Live page state additionally includes scroll position, back/forward state, and form fields. Cookies, local storage, session storage, and saved logins never sync. Turning it off deletes saved page-state snapshots.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                if iCloudAvailable == nil {
                    Label("Checking iCloud availability…", systemImage: "icloud")
                        .foregroundStyle(.secondary)
                } else if iCloudAvailable == false {
                    Label(
                        tabSyncEnabled
                            ? "iCloud is unavailable. You can turn sync off; turning it back on requires iCloud."
                            : "Sign in to iCloud to enable sync.",
                        systemImage: "icloud.slash"
                    )
                    .foregroundStyle(.secondary)
                }
            } header: {
                SettingsLabel("Sync", systemImage: "arrow.triangle.2.circlepath", tint: SettingsTint.general)
            } footer: {
                Text("Sync uses your private iCloud database. Incognito tabs, cookies, cache, website storage, saved logins, and downloads stay on this device. Changes to the main sync switch take effect after you relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            CollapsibleSection(searchID: "general.fast-forward") {
                Toggle("Fast Forward searches", isOn: $fastForwardEnabled)
                SettingCaptionRow(
                    caption: "A search that means a destination opens it beside the results.",
                    title: "Fast Forward",
                    explanation: "When a search clearly means a destination — “download slack”, “notion pricing”, “github login” — Fast Forward keeps the results on the left and opens the page you were heading for on the right, scrolled to the part you wanted. Nothing is lost: the real results are still there. If the guess is wrong, just close the pane — that also teaches Fast Forward to stop guessing for that search.",
                    value: $fastForwardEnabled
                ) { FastForwardDemo(enabled: $0) }
            } header: {
                SettingsLabel("Fast Forward", systemImage: "forward.fill", tint: SettingsTint.general)
            } footer: {
                Text("Runs on your Mac. The left pane always holds your actual search results, so Fast Forward only ever adds a head start — it never replaces what you asked for.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            CollapsibleSection(searchID: "general.new-tab-links") {
                Toggle("Show a mitosis animation in the sidebar", isOn: $automaticLinkMitosis)
                Toggle("Open the new tab beside its source", isOn: $automaticLinkSplit)
            } header: {
                SettingsLabel("Links That Open New Tabs", systemImage: "arrow.up.right.square", tint: SettingsTint.general)
            } footer: {
                Text("These apply when a website makes a clicked link open in another tab. They are independent, and Command-click is unaffected.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            CollapsibleSection(searchID: "general.research-anchors") {
                Picker("Anchor links open", selection: $anchorLinkOpenBehavior) {
                    Text("Peek first, then open beside the document").tag("peek")
                    Text("Beside the document").tag("split")
                    Text("As a tab").tag("tab")
                }
            } header: {
                SettingsLabel("Research Anchors", systemImage: "link.badge.plus", tint: SettingsTint.general)
            } footer: {
                Text("What clicking an anchor link in a workspace document does. Peek shows the quote and source first; opening beside the document reuses the source's tab in a split pane, scrolled or seeked to the anchored spot.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            CollapsibleSection(searchID: "general.head-start") {
                Toggle("Start loading before you press Return", isOn: $prefetchEnabled)
            } header: {
                SettingsLabel("Head Start", systemImage: "bolt.horizontal", tint: SettingsTint.general)
            } footer: {
                Text("When what you've typed can only mean one site you already go to often, that page starts loading while you're still typing. It never runs for a page you already have open, in a private or container tab, or when your Mac is short on memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            CollapsibleSection(searchID: "general.site-nicknames") {
                Toggle("Learn what you call your sites", isOn: $siteNicknamesUseAI)
            } header: {
                SettingsLabel("Site Nicknames", systemImage: "text.magnifyingglass", tint: SettingsTint.general)
            } footer: {
                Text("Type “gmail” for mail.google.com or “hn” for news.ycombinator.com. Sites you visit often are recognized by name either way; with this on, Apple Intelligence names them once, on your Mac, the first time a site becomes a regular. Nothing leaves the device.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            CollapsibleSection(searchID: "general.search") {
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
                    ForEach(omnibarPositions, id: \.self) { Text($0.localized) }
                }
                SettingCaptionRow(
                    caption: "How high the omnibar sits when you summon it.",
                    title: "Omnibar Position",
                    explanation: "The omnibar drops in over the page when you start typing an address. Top pins it to the toolbar; Upper floats it a third of the way down; Center puts it at eye level.",
                    value: $omnibarPosition
                ) { OmnibarPositionDemo(position: $0) }

                Picker("Find bar position", selection: $findBarPosition) {
                    ForEach(FindBar.positions, id: \.self) { Text($0.localized) }
                }
                SettingCaptionRow(
                    caption: "Which corner or edge the ⌘F bar docks to.",
                    title: "Find Bar Position",
                    explanation: "The find bar floats over the page, so it can cover whatever you were reading. Move it to the corner or edge that's out of your way — bottom placements suit long articles, side placements suit wide monitors.",
                    value: $findBarPosition
                ) { FindBarPositionDemo(position: $0) }

                LabeledContent("Find emphasis") {
                    HStack {
                        Slider(value: $findFlashIntensity, in: 0...100, step: 5).frame(width: 180)
                        Text("\(Int(findFlashIntensity))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                }
                SettingCaptionRow(
                    caption: "How hard the found match announces itself.",
                    title: "Find Emphasis",
                    explanation: "Every match gets a ring around it when you land on it. Low is a quiet glow. Turn it up and the ring zooms in and dims the rest of the page — worth it on a large display, in a long document, or any time a subtle highlight is easy to miss. At 0 there's no animation at all, just the normal selection.",
                    value: $findFlashIntensity
                ) { FindFlashDemo(intensity: $0) }
            } header: {
                SettingsLabel("Search", systemImage: "magnifyingglass", tint: SettingsTint.general)
            }

            CollapsibleSection(searchID: "general.behavior") {
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

                Toggle("⌘P and ⌘\\ navigate Back/Forward (no keyboard Print)", isOn: $expandBackForwardShortcuts)
                SettingCaptionRow(
                    caption: "Free the print chords for navigation instead.",
                    title: "Expand Back/Forward Shortcuts",
                    explanation: "With this on, ⌘P goes Back and ⌘\\ goes Forward — the same as ⌘[ and ⌘] — and neither Print nor Export as PDF has a keyboard shortcut anymore (both are still in the menu). Turn it off to get the print shortcuts back.",
                    value: $expandBackForwardShortcuts
                ) { ExpandBackForwardDemo(enabled: $0) }

                Toggle("Let Quick Open override website shortcuts", isOn: $overrideWebsiteQuickOpen)
                SettingCaptionRow(
                    caption: "Make Browser’s Quick Open shortcut take priority over the page.",
                    title: "Override Website Shortcuts",
                    explanation: "Websites often use ⌘K for their own search or command palette. With this on, Browser handles your configured Quick Open shortcut first, so it always opens the omnibar. With it off, the focused website can handle the shortcut instead.",
                    value: $overrideWebsiteQuickOpen
                ) { QuickOpenOverrideDemo(enabled: $0) }

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

            BackGuardSection()

            CollapsibleSection(searchID: "general.quit-safety") {
                LabeledContent("Hold ⌘Q to quit") {
                    HStack {
                        Text("Quick").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $quitHoldPercent,
                               in: KeyboardShortcutsManager.quitHoldMinPercent...KeyboardShortcutsManager.quitHoldMaxPercent)
                            .frame(width: 160)
                        Text("Slow").font(.caption).foregroundStyle(.secondary)
                    }
                }
                SettingCaptionRow(
                    caption: "How long you need to hold ⌘Q before Browser quits.",
                    title: "Quit Safety",
                    explanation: "⌘Q doesn't quit on tap — you hold it, and a bar fills to show you're about to quit. Letting go before it fills cancels. This sets how long that hold takes: quick if you're confident, slow if you'd rather it take real effort to close the app by accident.",
                    value: $quitHoldPercent
                ) { QuitHoldDemo(percent: $0) }
            } header: {
                SettingsLabel("Quit Safety", systemImage: "power", tint: SettingsTint.general)
            }
        }
        .formStyle(.grouped)
        .task { iCloudAvailable = await TabSync.iCloudAvailable() }
    }
}

// MARK: - Shortcuts

// Which page states make ⌘[ ask first, plus per-site always/never overrides.
struct BackGuardSection: View {
    @ObservedObject private var store = BackGuardStore.shared
    @State private var newHost = ""

    var body: some View {
        CollapsibleSection(searchID: "general.back-guard") {
            ForEach(BackGuardStore.Trigger.allCases) { trigger in
                Toggle(trigger.title, isOn: Binding(
                    get: { store.triggers.contains(trigger) },
                    set: { store.set(trigger, enabled: $0) }
                ))
            }

            ForEach(store.customizedHosts, id: \.self) { host in
                HStack {
                    Text(host).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { store.override(for: host) ?? true },
                        set: { store.set($0, host: host) }
                    )) {
                        Text("Always ask").tag(true)
                        Text("Never ask").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button { store.set(nil, host: host) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Add a site (meet.google.com)", text: $newHost)
                    .onSubmit(addHost)
                Button("Add", action: addHost)
                    .disabled(ShortcutPriorityStore.normalize(newHost) == nil)
                Button("Reset") { store.resetAll() }
                    .disabled(store.triggers == BackGuardStore.defaultTriggers && store.byHost.isEmpty)
            }
        } header: {
            SettingsLabel("Confirm Before Going Back", systemImage: "arrow.uturn.backward.circle", tint: SettingsTint.general)
        } footer: {
            Text("With the wrong split pane focused, ⌘[ can drop you out of a meeting. When a page matches a checked state, Browser asks before going back. Sites listed here always or never ask, whatever the page is doing; “Don't ask again” in the dialog adds a site as Never.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addHost() {
        guard let host = ShortcutPriorityStore.normalize(newHost) else { return }
        store.set(true, host: host)
        newHost = ""
    }
}

struct ShortcutsSettingsView: View {
    private var store: ShortcutStore { .shared }
    @AppStorage(SettingsManager.recentTabCyclingKey) private var recentTabCycling = false
    @State private var searchText = ""

    private func matches(_ command: ShortcutCommand) -> Bool {
        searchText.isEmpty || String(localized: command.title).localizedCaseInsensitiveContains(searchText)
    }

    var body: some View {
        // Commands sharing a chord get flagged; nothing collides by default, so
        // a warning only appears once the user creates the overlap.
        let conflictIDs = Set(store.conflicts().map(\.id))
        Form {
            CollapsibleSection(searchID: "shortcuts.keyboard") {
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

            CollapsibleSection(searchID: "shortcuts.tab-switching") {
                Toggle("⌃Tab cycles tabs in the order you used them", isOn: $recentTabCycling)
                Text("Off, ⌃Tab steps down the sidebar. On, it works like ⌘Tab between apps: the tab you're on is first, the one you came from is second, and letting go of Control puts whatever you landed on back at the front.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                SettingsLabel("Tab Switching", systemImage: "arrow.left.arrow.right", tint: SettingsTint.shortcuts)
            }

            if searchText.isEmpty {
                WebsiteShortcutPriorityView()
            }

            ForEach(ShortcutSection.allCases, id: \.self) { section in
                let commands = ShortcutCommand.availableOnCurrentPlatform.filter { $0.section == section && matches($0) }
                if !commands.isEmpty {
                    CollapsibleSection(searchID: "shortcuts.section.\(section.rawValue)") {
                        ForEach(commands) { command in
                            shortcutRow(command, conflicting: conflictIDs.contains(command.id))
                        }
                    } header: {
                        Text(section.title)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $searchText, prompt: Text("Filter Shortcuts"))
    }

    private func shortcutRow(_ command: ShortcutCommand, conflicting: Bool) -> some View {
        HStack(spacing: 8) {
            Text(command.title)
            if store.isCustomized(command) {
                Button { store.reset(command) } label: {
                    Image(systemName: "arrow.uturn.backward").font(.caption)
                }
                .buttonStyle(.borderless)
                .delayedHelp(String(localized: "Reset to default"))
            }
            Spacer(minLength: 12)
            if conflicting {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .delayedHelp(String(localized: "This shortcut is used by more than one command"))
            } else if let systemName = store.systemConflict(store.shortcut(for: command)) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                    .delayedHelp(String(localized: "May conflict with the macOS \(systemName) shortcut"))
            }
            ShortcutRecorder(command: command)
        }
    }
}

// Which chords the browser takes back from websites — globally, or for one
// site. Only the commands the event monitor can actually claim are listed;
// see ShortcutPriorityStore for why the menu bar alone isn't enough.
struct WebsiteShortcutPriorityView: View {
    private var store: ShortcutStore { .shared }
    private var priority: ShortcutPriorityStore { .shared }

    // nil = every site. Otherwise the host these rows apply to.
    @State private var host: String?
    @State private var newHost = ""
    @State private var pendingHost: String?

    var body: some View {
        CollapsibleSection(searchID: "shortcuts.website-priority") {
            Picker("These settings apply to", selection: $host) {
                Text("All sites").tag(String?.none)
                ForEach(hosts, id: \.self) { host in
                    Text(host).tag(String?.some(host))
                }
            }

            HStack {
                TextField("Add a site (example.com)", text: $newHost)
                    .onSubmit(addHost)
                Button("Add", action: addHost)
                    .disabled(ShortcutPriorityStore.normalize(newHost) == nil)
            }

            ForEach(ShortcutPriorityStore.contestable) { command in
                Picker(selection: binding(for: command)) {
                    if host != nil { Text("Use setting for all sites").tag(Bool?.none) }
                    Label("Browser", systemImage: "command").tag(Bool?.some(true))
                    Label("Website", systemImage: "safari").tag(Bool?.some(false))
                } label: {
                    HStack(spacing: 8) {
                        Text(command.title)
                        HStack(spacing: 3) {
                            ForEach(Array(store.shortcut(for: command).displayTokens.enumerated()), id: \.offset) { _, token in
                                keycap(token)
                            }
                        }
                    }
                }
            }

            HStack {
                if let host {
                    Button("Clear Settings for \(host)") {
                        priority.clear(host: host)
                        self.host = nil
                    }
                }
                Spacer()
                Button("Reset All Sites") { priority.resetAll() }
                    .disabled(priority.global.isEmpty && priority.byHost.isEmpty)
            }
        } header: {
            Text("When a Website Uses the Same Shortcut")
        } footer: {
            Text("Websites see a keypress before the menu bar does, so a page can take ⌘R or ⌘T for itself. Anything set to Browser is claimed before the page ever sees it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // Whatever the user has customized, plus the site they're on, plus one just
    // typed in — a site only reaches the store once a row is actually set.
    private var hosts: [String] {
        var hosts = priority.customizedHosts
        for host in [priority.currentHost, pendingHost].compactMap({ $0 }) where !hosts.contains(host) {
            hosts.insert(host, at: 0)
        }
        return hosts
    }

    private func addHost() {
        guard let normalized = ShortcutPriorityStore.normalize(newHost) else { return }
        pendingHost = normalized
        host = normalized
        newHost = ""
    }

    // Global rows always show a concrete choice; per-site rows can inherit.
    private func binding(for command: ShortcutCommand) -> Binding<Bool?> {
        Binding(
            get: {
                host == nil
                    ? (priority.override(for: command) ?? priority.browserWins(command))
                    : priority.override(for: command, host: host)
            },
            set: { priority.set($0, for: command, host: host) }
        )
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
    @AppStorage("autoTranslateEnabled") private var autoTranslateEnabled = true
    @AppStorage("translationPreferredLanguages") private var translationPreferredLanguages = ""

    // Owns only prefetch downloads triggered from this window — separate from
    // the per-browser-window PageTranslator that actually translates pages.
    @StateObject private var packDownloader = PageTranslator()
    @State private var showLanguageManager = false
    @State private var showTranslationHistory = false

    var body: some View {
        Form {
            CollapsibleSection(searchID: "content.web-content") {
                Toggle("Enable JavaScript", isOn: $javaScriptEnabled)
                    .onChange(of: javaScriptEnabled) { _, _ in
                        NotificationCenter.default.post(name: .javaScriptChanged, object: nil)
                    }
                SettingCaptionRow(
                    caption: "Off makes pages static. Open tabs reload when changed.",
                    title: "JavaScript",
                    explanation: "JavaScript is what makes pages interactive — menus, forms, live content. Almost every modern site needs it. Turning it off loads pages as plain, static documents, which is faster and quieter but breaks most web apps.",
                    value: $javaScriptEnabled
                ) { JavaScriptDemo(enabled: $0) }
            } header: {
                SettingsLabel("Web Content", systemImage: "curlybraces", tint: SettingsTint.content)
            }

            CollapsibleSection(searchID: "content.zoom") {
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

            CollapsibleSection(searchID: "content.translation") {
                Toggle("Auto-translate pages", isOn: $autoTranslateEnabled)
                LabeledContent("Languages you read") {
                    TokenField(text: $translationPreferredLanguages, placeholder: "en  es  fr")
                }
                Button("Manage Languages…") { showLanguageManager = true }
                    .sheet(isPresented: $showLanguageManager) {
                        LanguageManagerDialog(isPresented: $showLanguageManager, downloader: packDownloader)
                    }
                Button("Translation History…") { showTranslationHistory = true }
                    .sheet(isPresented: $showTranslationHistory) {
                        TranslationHistoryDialog(isPresented: $showTranslationHistory)
                    }
            } header: {
                SettingsLabel("Translation", systemImage: "character.bubble", tint: SettingsTint.content)
            } footer: {
                Text("On-device — nothing leaves your Mac. A page in a language outside this list translates automatically. ⌥⌘T flips original/translated; hold ⌥ over any text to peek at the original; ⇧⌥⌘T opens a translated copy in a split pane; View ▸ Translate Page To/From picks the languages; right-click selected text to translate just that, in place. ISO codes — leave empty to use your system languages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .translationTask(packDownloader.configuration) { session in
            await packDownloader.perform(session: session)
        }
    }
}

// Every language macOS can translate into your language: which are already
// installed, which are one tap away, plus a nudge to offload ones that have
// sat installed and unused for a while. Apple's Translation framework has no
// API for an app to delete a model itself, so "offload" opens System
// Settings' own language manager instead of trying to do it in-process.
struct LanguageManagerDialog: View {
    @Binding var isPresented: Bool
    @ObservedObject var downloader: PageTranslator

    @State private var packs: [PageTranslator.LanguagePackStatus] = []
    @State private var isLoading = true

    private var staleUsage: [LanguagePackUsage] { TranslationLanguageUsage.shared.staleCandidates() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translation Languages", comment: "Title of the language pack management sheet")
                .font(.title2).bold()

            if !staleUsage.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(staleUsage.count) language\(staleUsage.count == 1 ? "" : "s") installed for 60+ days and unused in the last 60 days.",
                             comment: "Offload nudge on the language pack management sheet")
                        Button("Manage in System Settings…") { openSystemLanguageSettings() }
                            .buttonStyle(.link)
                    }
                    Spacer()
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if packs.isEmpty {
                Text("No downloadable languages — your reading languages cover everything.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(packs) { pack in
                    HStack {
                        Text(pack.name)
                        Spacer()
                        switch pack.status {
                        case .installed:
                            Text("Installed", comment: "Language pack already downloaded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .supported:
                            Button("Download") { downloader.downloadLanguage(pack.id) }
                                .buttonStyle(.borderless)
                        case .unsupported:
                            EmptyView()
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 480)
        .task {
            packs = await downloader.languagePackStatuses()
            isLoading = false
        }
    }

    private func openSystemLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

// What auto-translate has noticed and done: pages it detected in another
// language, and which of those it actually translated. Without this the
// feature is invisible when it's working and unaccountable when it isn't.
struct TranslationHistoryDialog: View {
    @Binding var isPresented: Bool
    @State private var records: [TranslationHistoryRecord] = TranslationHistoryStore.shared.recent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translation History", comment: "Title of the translation history sheet")
                .font(.title2).bold()
            Text("Pages this Mac noticed were in another language, and whether it translated them.",
                 comment: "Explanation on the translation history sheet")
                .font(.caption)
                .foregroundStyle(.secondary)

            if records.isEmpty {
                Text("No translation activity yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(records) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title).lineLimit(1)
                            Text("\(record.host) · \(record.sourceLanguage) → \(record.targetLanguage)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Label(
                                record.translatedAt != nil ? "Translated" : "Detected",
                                systemImage: record.translatedAt != nil ? "checkmark.circle.fill" : "text.magnifyingglass"
                            )
                            .font(.caption)
                            .foregroundStyle(record.translatedAt != nil ? .green : .secondary)
                            Text((record.translatedAt ?? record.detectedAt).formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Clear History", role: .destructive) {
                    TranslationHistoryStore.shared.clear()
                    records = []
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 480)
    }
}

// MARK: - Downloads

struct DownloadsSettingsView: View {
    @AppStorage("downloadsFolder") private var downloadsFolder = ""
    @AppStorage("optionClickDownloadEnabled") private var optionClickDownloadEnabled = true
    @AppStorage("optionClickDownloadImages") private var optionClickDownloadImages = true
    @AppStorage("optionClickFileTypes") private var optionClickFileTypes = ""
    @AppStorage("optionClickAlwaysDomains") private var optionClickAlwaysDomains = ""
    @AppStorage("optionClickNeverDomains") private var optionClickNeverDomains = ""
    @State private var folderAccessError: String?

    var body: some View {
        Form {
            CollapsibleSection(searchID: "downloads.option-click") {
                Toggle("Option-click downloads images", isOn: $optionClickDownloadEnabled)

                if optionClickDownloadEnabled {
                    Toggle("Download bare images", isOn: $optionClickDownloadImages)

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
                    caption: "Hold ⌥ over a bare image to save it; ⌥-clicking a link opens it in a split pane.",
                    title: "Option-Click Image Downloads",
                    explanation: "With this on, ⌥-clicking an image that is not itself a link saves it. Never-on and Always-on domains refine the behavior, and file types limit it to the extensions you list (empty means every image type). Linked targets always use the browser's split-pane gesture.",
                    value: .constant(0)
                ) { _ in DownloadRuleDemo() }
            } header: {
                SettingsLabel("Option-Click Image Downloads", systemImage: "arrow.down.circle", tint: SettingsTint.downloads)
            }

            CollapsibleSection(searchID: "downloads.folder") {
                LabeledContent("Folder") {
                    HStack {
                        TextField("System Downloads folder", text: $downloadsFolder)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        Button("Choose…") { chooseFolder() }
                        if !downloadsFolder.isEmpty {
                            Button("Use System Folder") {
                                DownloadFolderAccess.shared
                                    .useSystemDownloadsFolder()
                                downloadsFolder = ""
                            }
                        }
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
        .alert(
            "Folder Access Couldn’t Be Saved",
            isPresented: Binding(
                get: { folderAccessError != nil },
                set: { isPresented in
                    if !isPresented {
                        folderAccessError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderAccessError ?? "")
        }
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
            if DownloadFolderAccess.shared.remember(url) {
                downloadsFolder = url.path
            } else {
                folderAccessError = String(
                    localized: "Choose the folder again, or keep using the system Downloads folder."
                )
            }
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
    @State private var folderAccessError: String?

    private var settings: ScreenshotSettings { .shared }
    private var store: ShortcutStore { .shared }

    var body: some View {
        Form {
            CollapsibleSection(searchID: "screenshots.all") {
                LabeledContent("Shared folder") {
                    HStack {
                        TextField("~/Pictures/Browser Screenshots", text: $sharedFolder)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        Button("Choose…") { chooseFolder(into: $sharedFolder) }
                        if !sharedFolder.isEmpty {
                            Button("Use Pictures Folder") {
                                SecurityScopedFolderRegistry.shared.forget(
                                    URL(fileURLWithPath: sharedFolder)
                                )
                                sharedFolder = ""
                            }
                        }
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
                // ponytail: scroll target only, no highlight glow here — this one's a raw
                // Section (not CollapsibleSection), and duplicating the highlight styling for
                // one dynamic call site isn't worth it.
                .id("screenshots.kind.\(kind.rawValue)")
            }
        }
        .formStyle(.grouped)
        .alert(
            "Folder Access Couldn’t Be Saved",
            isPresented: Binding(
                get: { folderAccessError != nil },
                set: { isPresented in
                    if !isPresented {
                        folderAccessError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderAccessError ?? "")
        }
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
                        .disabled(true)
                    Button("Choose…") { chooseFolder(into: ownFolder) }
                    Button("Clear") {
                        SecurityScopedFolderRegistry.shared.forget(
                            URL(fileURLWithPath: ownFolder.wrappedValue)
                        )
                        ownFolder.wrappedValue = ""
                    }
                    .disabled(ownFolder.wrappedValue.isEmpty)
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
            if SecurityScopedFolderRegistry.shared.remember(url) {
                path.wrappedValue = url.path
            } else {
                folderAccessError = String(
                    localized: "Choose the folder again, or leave the destination disabled."
                )
            }
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    // Same "theme" defaults key SettingsManager reads — one store, no desync.
    @AppStorage("theme") private var theme = "System"
    // Matches the app logo's blue by default. Stored as hex because Color itself
    // is not a stable UserDefaults value across all supported OS releases.
    @AppStorage("aiSearchEffectColorHex") private var aiSearchEffectColorHex = "#007AFF"

    // Load progress indicators (any combination).
    @AppStorage("progressBarTop") private var progressBarTop = true
    @AppStorage("progressBarBottom") private var progressBarBottom = false
    @AppStorage("progressBarLeft") private var progressBarLeft = false
    @AppStorage("progressBarRight") private var progressBarRight = false
    @AppStorage("progressFaviconRing") private var progressFaviconRing = false
    @AppStorage("showTraditionalTopTabs") private var showTraditionalTopTabs = false
    @AppStorage("topTabsAutoHide") private var topTabsAutoHide = true
    @AppStorage("adaptiveLargeSidebarTabs") private var adaptiveLargeSidebarTabs = true
    @AppStorage(VisualTabPreferences.aspectRatioKey)
    private var visualTabAspectRatio = VisualTabPreferences.defaultAspectRatio
    @AppStorage(VisualTabPreferences.livePreviewsKey)
    private var visualTabLivePreviews = true
    @AppStorage(VisualTabPreferences.switcherKey)
    private var visualTabSwitcher = true
    #if os(macOS)
    @AppStorage(TabPeekPlacement.enabledKey) private var tabPeekEnabled = true
    @AppStorage(TabPeekPlacement.defaultsKey) private var tabPeekPlacementRaw = TabPeekPlacement.screenTop.rawValue
    #endif
    @AppStorage(TabCardNames.useAppleIntelligenceKey)
    private var tabCardNamesUseAI = true
    @AppStorage(NewTabButtonVisibility.visibleKey) private var showNewTabButton = true
    @AppStorage(SettingsManager.aiFeaturesKey) private var aiFeaturesEnabled = true
    @AppStorage(BrowserChromePlacementSettings.Key.tabSidebarSide)
    private var tabSidebarSideRaw = BrowserChromeSide.left.rawValue
    #if os(macOS)
    @AppStorage(DeveloperToolsPlacement.defaultsKey) private var developerToolsPlacementRaw = DeveloperToolsPlacement.bottom.rawValue
    #endif

    // Flicker control.
    @AppStorage("fadeInPages") private var fadeInPages = true
    @AppStorage("fadeInDuration") private var fadeInDuration = 250.0
    @AppStorage("pageWhitePoint") private var pageWhitePoint = 100.0
    @AppStorage("pageBlackPoint") private var pageBlackPoint = 0.0
    @AppStorage("toneExtendedRange") private var toneExtendedRange = false
    @AppStorage("toneScheduleMode") private var toneScheduleMode = "always"
    @AppStorage("toneFixedStart") private var toneFixedStart = 20.0 * 60
    @AppStorage("toneFixedEnd") private var toneFixedEnd = 7.0 * 60
    @AppStorage("toneSunsetOffset") private var toneSunsetOffset = 0.0
    @AppStorage("toneSunriseOffset") private var toneSunriseOffset = 0.0
    @ObservedObject private var toneSchedule = ToneSchedule.shared

    private var whitePointRange: ClosedRange<Double> { toneExtendedRange ? 10...200 : 25...100 }
    private var blackPointRange: ClosedRange<Double> { toneExtendedRange ? -50...50 : -15...15 }

    // Window shape and where it lands on launch.
    @AppStorage(WindowLayout.Key.launchEnabled) private var launchLayoutEnabled = false
    @AppStorage(WindowLayout.Key.width) private var launchLayoutWidth = "full"
    @AppStorage(WindowLayout.Key.position) private var launchLayoutPosition = "center"
    @AppStorage(WindowLayout.Key.squareCorners) private var squareWindowCorners = false

    private let themes = ["Light", "Dark", "System"]

    var body: some View {
        Form {
            CollapsibleSection(searchID: "appearance.tabs") {
                Picker("Tab sidebar side", selection: $tabSidebarSideRaw) {
                    ForEach(BrowserChromeSide.allCases) { side in
                        Label(side.title, systemImage: side.systemImage).tag(side.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Show traditional tabs across the top", isOn: $showTraditionalTopTabs)
                Toggle("Hide top tabs until the pointer reaches the top", isOn: $topTabsAutoHide)
                    .disabled(!showTraditionalTopTabs)
                Toggle("Use adaptive preview cards in the widest sidebar", isOn: $adaptiveLargeSidebarTabs)
                Text("Preview cards grow into spare vertical space when only a few tabs are open, then compress automatically as the tab count increases.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Visual tab shape", selection: $visualTabAspectRatio) {
                    Text("Square").tag(1.0)
                    Text("4:3").tag(4.0 / 3.0)
                    Text("16:10").tag(1.6)
                    Text("16:9").tag(16.0 / 9.0)
                    Text("2:1").tag(2.0)
                }
                Toggle("Keep visual tab previews live", isOn: $visualTabLivePreviews)
                Text("Compact and wide sidebars always show visual cards. Live previews refresh the page you're on, load the rest in the background for their first card, and re-capture whichever tab you point at.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show tab thumbnails while switching with ⌃Tab", isOn: $visualTabSwitcher)
                #if os(macOS)
                Toggle("Peek at a tab by holding Control and hovering it", isOn: $tabPeekEnabled)
                Picker("Show the peek", selection: $tabPeekPlacementRaw) {
                    ForEach(TabPeekPlacement.allCases) { placement in
                        Text(placement.label).tag(placement.rawValue)
                    }
                }
                .disabled(!tabPeekEnabled)
                Text("Checks in on a background tab without switching to it. Top middle of the screen puts the page right under the webcam, so glancing at it still looks like eye contact on a call.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                Toggle("Show the new tab button above the sidebar", isOn: $showNewTabButton)
                Text("⌘T always opens a tab. The button retires itself if a week and ten launches go by without a click; this puts it back.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Name visual tabs with Apple Intelligence", isOn: $tabCardNamesUseAI)
                Text("Gives each card two different lines — the site and the page — and puts whichever one tells the tab apart from its neighbors on top. Off, cards fall back to the page title and domain.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                SettingsLabel("Tabs", systemImage: "rectangle.topthird.inset.filled", tint: SettingsTint.appearance)
            }

            #if os(macOS)
                CollapsibleSection(searchID: "appearance.developer-tools") {
                    Picker("Open Developer Tools", selection: $developerToolsPlacementRaw) {
                        ForEach(DeveloperToolsPlacement.allCases) { placement in
                            Label(placement.title, systemImage: placement.symbol).tag(placement.rawValue)
                        }
                    }
                    Text("Choose a bottom, left, or right dock, or keep Developer Tools in its own window.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    SettingsLabel("Developer Tools", systemImage: "wrench.and.screwdriver", tint: SettingsTint.appearance)
                }
            #endif

            CollapsibleSection(searchID: "appearance.window") {
                Toggle("Place the window on launch", isOn: $launchLayoutEnabled)
                Picker("Width", selection: $launchLayoutWidth) {
                    ForEach(WindowLayout.widths, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("Position", selection: $launchLayoutPosition) {
                    ForEach(WindowLayout.positions, id: \.id) { Text($0.label).tag($0.id) }
                }
                Toggle("Square corners", isOn: $squareWindowCorners)
                SettingCaptionRow(
                    caption: "Full screen height, and as wide and as far across as you like.",
                    title: "Window",
                    explanation: "The window always fills the screen's height; the width is either the whole screen or a multiple of that height, which keeps the same shape on any display. Position slides it anywhere between flush left and flush right. ⇧⌘F snaps the window to these settings and back again, whether or not it launches there. The window has no title bar at all — macOS only rounds corners for windows that have one, so this app rounds its own edges to match by default; Square corners turns that off, and takes effect immediately. Since there's no title bar, native full screen isn't available, so ⌃⌘F does nothing — ⇧⌘F is the replacement.",
                    value: $launchLayoutPosition
                ) { WindowLayoutDemo(position: $0, width: launchLayoutWidth, square: squareWindowCorners) }
            } header: {
                SettingsLabel("Window", systemImage: "macwindow", tint: SettingsTint.appearance)
            } footer: {
                Text("With placement off, the window opens wherever you last left it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            CollapsibleSection(searchID: "appearance.theme") {
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

            if aiFeaturesEnabled {
                CollapsibleSection(searchID: "appearance.ai-search") {
                    ColorPicker("Effect color", selection: aiSearchEffectColorBinding, supportsOpacity: false)
                        .onDisappear { NSColorPanel.shared.close() }
                    Text("Used for the sparkles when AI Search is enabled. Defaults to the app logo blue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    SettingsLabel("AI Search", systemImage: "sparkles", tint: aiSearchEffectColor)
                }
            }

            CollapsibleSection(searchID: "appearance.loading-progress") {
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

            CollapsibleSection(searchID: "appearance.page-fade") {
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

            CollapsibleSection(searchID: "appearance.white-point") {
                LabeledContent("Max page brightness") {
                    HStack {
                        Slider(value: $pageWhitePoint, in: whitePointRange, step: 5).frame(width: 180)
                        Text("\(Int(pageWhitePoint))%").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                Toggle("Extended range", isOn: $toneExtendedRange)
                    .onChange(of: toneExtendedRange) { _, _ in clampToneToRanges() }
                SettingCaptionRow(
                    caption: "100% leaves pages alone. Lower caps how bright white can get.",
                    title: "White Point",
                    explanation: "Bright pages are the other half of screen flicker — a white page after a dark one is a jolt no fade can hide. This caps how bright the brightest parts of a page can go. Because it scales brightness rather than laying grey over the page, dark text barely moves while backgrounds come down, so text stays readable and roughly half as dimmed as the page around it. Extended range widens both this and the black point well past what most screens want — down to 10% or up to a 200% boost — for dim rooms and odd displays.",
                    value: $pageWhitePoint
                ) { WhitePointDemo(whitePoint: $0, range: whitePointRange) }
            } header: {
                SettingsLabel("White Point", systemImage: "sun.max", tint: SettingsTint.appearance)
            }

            CollapsibleSection(searchID: "appearance.black-point") {
                LabeledContent("Black level") {
                    HStack {
                        Slider(value: $pageBlackPoint, in: blackPointRange, step: 1).frame(width: 180)
                        Text(pageBlackPoint == 0 ? "Off" : String(format: "%+d%%", Int(pageBlackPoint)))
                            .monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                SettingCaptionRow(
                    caption: "Below zero deepens near-blacks; above zero lifts them to grey.",
                    title: "Black Point",
                    explanation: "Where the white point decides how bright a page can get, this decides how dark it can get. Negative values subtract light, so dark greys fall to true black and dark pages stop looking washed out — while white barely moves. Positive values add light, lifting black to a soft grey, which some people find far easier to read against at night than pure black text. The default range is deliberately gentle; the extended range in White Point above unlocks the heavy-handed settings.",
                    value: $pageBlackPoint
                ) { BlackPointDemo(blackPoint: $0, range: blackPointRange) }
            } header: {
                SettingsLabel("Black Point", systemImage: "circle.righthalf.filled", tint: SettingsTint.appearance)
            }

            CollapsibleSection(searchID: "appearance.schedule") {
                Picker("Apply", selection: $toneScheduleMode) {
                    Text("Always").tag("always")
                    Text("Between set times").tag("fixed")
                    Text("Sunset to sunrise").tag("sun")
                    Text("While any Focus is on").tag("sleepFocus")
                    Text("While the Mac is in dark mode").tag("darkMode")
                }
                if toneScheduleMode == "fixed" {
                    DatePicker("From", selection: minuteBinding($toneFixedStart), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minuteBinding($toneFixedEnd), displayedComponents: .hourAndMinute)
                }
                if toneScheduleMode == "sun" {
                    LabeledContent("Start") { offsetSlider($toneSunsetOffset, anchor: "sunset") }
                    LabeledContent("End") { offsetSlider($toneSunriseOffset, anchor: "sunrise") }
                }
                LabeledContent(toneSchedule.isActive ? "On now" : "Off now") {
                    Text(toneSchedule.status).foregroundStyle(.secondary)
                }
                SettingCaptionRow(
                    caption: "When the white and black point adjustments above are in effect.",
                    title: "Schedule",
                    explanation: "Dimming that helps at midnight is just a dull screen at noon, so the adjustments can turn themselves on and off. Set times work anywhere; sunset-to-sunrise follows the calendar, and looks your city up once a week from your IP address — coarse, no location permission, and only ever fetched while this mode is selected. The Focus option covers any Focus you have on — macOS won't tell an app which one, so a bedtime Sleep Focus counts the same as Do Not Disturb, and it asks permission the first time you pick it. Dark mode follows whatever the Mac (or this browser's own theme) is doing.",
                    value: $toneScheduleMode
                ) { ToneScheduleDemo(mode: $0) }
            } header: {
                SettingsLabel("Schedule", systemImage: "clock", tint: SettingsTint.appearance)
            }
        }
        .formStyle(.grouped)
        .onChange(of: toneScheduleMode) { _, _ in notifyScheduleChanged() }
        .onChange(of: toneFixedStart) { _, _ in notifyScheduleChanged() }
        .onChange(of: toneFixedEnd) { _, _ in notifyScheduleChanged() }
        .onChange(of: toneSunsetOffset) { _, _ in notifyScheduleChanged() }
        .onChange(of: toneSunriseOffset) { _, _ in notifyScheduleChanged() }
    }

    private func notifyScheduleChanged() {
        NotificationCenter.default.post(name: .toneScheduleChanged, object: nil)
    }

    private var aiSearchEffectColor: Color {
        Color(hex: aiSearchEffectColorHex) ?? .blue
    }

    private var aiSearchEffectColorBinding: Binding<Color> {
        Binding(
            get: { aiSearchEffectColor },
            set: { aiSearchEffectColorHex = $0.toHex() ?? "#007AFF" }
        )
    }

    // DatePicker wants a Date; the schedule only cares about minutes-of-day.
    private func minuteBinding(_ minutes: Binding<Double>) -> Binding<Date> {
        Binding(get: { ToneSchedule.date(minutes: minutes.wrappedValue) },
                set: { minutes.wrappedValue = ToneSchedule.minutesOfDay($0) })
    }

    private func offsetSlider(_ offset: Binding<Double>, anchor: String) -> some View {
        HStack {
            Slider(value: offset, in: -120...120, step: 15).frame(width: 180)
            Text(offset.wrappedValue == 0
                 ? "at \(anchor)"
                 : String(format: "%+d min from \(anchor)", Int(offset.wrappedValue)))
                .monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // Leaving the extended range mustn't strand a value outside the narrow one —
    // the slider would clamp its knob but the page would stay at 200%.
    private func clampToneToRanges() {
        pageWhitePoint = min(max(pageWhitePoint, whitePointRange.lowerBound), whitePointRange.upperBound)
        pageBlackPoint = min(max(pageBlackPoint, blackPointRange.lowerBound), blackPointRange.upperBound)
    }
}

// MARK: - Security

struct SecuritySettingsView: View {
    @AppStorage("sslStrictMode") private var sslStrictMode = true
    @AppStorage("adBlockEnabled") private var adBlockEnabled = false
    @AppStorage(CLIAuthorization.Key.enabled) private var cliAutomationEnabled = false
    @AppStorage(CLIAuthorization.Key.pageRead) private var cliPageReadEnabled = false
    @AppStorage(CLIAuthorization.Key.pageScript) private var cliPageScriptEnabled = false
    @AppStorage(CLIAuthorization.Key.screenshot) private var cliScreenshotEnabled = false
    @AppStorage("cliRealEventsEnabled") private var cliRealEventsEnabled = false
    @State private var copiedMCPConfiguration = false

    private var authorizedRealEvents: Binding<Bool> {
        Binding(
            get: { cliAutomationEnabled && cliPageScriptEnabled && cliRealEventsEnabled },
            set: { cliRealEventsEnabled = $0 && cliAutomationEnabled && cliPageScriptEnabled }
        )
    }

    var body: some View {
        Form {
            CollapsibleSection(searchID: "security.ssl") {
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

            CollapsibleSection(searchID: "security.ad-blocking") {
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

            CollapsibleSection(searchID: "security.agent-automation") {
                Toggle("Enable agent automation (CLI & MCP)", isOn: $cliAutomationEnabled)
                Toggle("Allow tab and page reading", isOn: $cliPageReadEnabled)
                    .disabled(!cliAutomationEnabled)
                Toggle("Allow JavaScript and synthetic interaction", isOn: $cliPageScriptEnabled)
                    .disabled(!cliAutomationEnabled)
                Toggle("Allow screenshots", isOn: $cliScreenshotEnabled)
                    .disabled(!cliAutomationEnabled)
                Toggle("Allow genuine mouse clicks", isOn: $cliRealEventsEnabled)
                    .disabled(!cliAutomationEnabled || !cliPageScriptEnabled)
                SettingCaptionRow(
                    caption: "Automation is off by default. Grant sensitive capabilities separately.",
                    title: "Agent Authorization",
                    explanation: "The master switch permits navigation and tab control from browser-cli and its bundled MCP server. Reading page content, running JavaScript or synthetic interaction, taking screenshots, and posting genuine mouse events each require the corresponding permission. File permissions limit access to processes running as you, while these switches decide what those processes may do.",
                    value: authorizedRealEvents
                ) { CLIRealClicksDemo(enabled: $0) }
            } header: {
                SettingsLabel("Agent Automation", systemImage: "cpu", tint: SettingsTint.security)
            }

            CollapsibleSection(searchID: "security.mcp") {
                HStack {
                    Button(copiedMCPConfiguration ? "Copied" : "Copy MCP Configuration") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpConfiguration, forType: .string)
                        copiedMCPConfiguration = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedMCPConfiguration = false
                        }
                    }
                    Button("Show Agent Audit Logs") {
                        let directory = BrowserCLI.supportDirectory
                            .appendingPathComponent("agent-audit", isDirectory: true)
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([directory])
                    }
                }
                Text("Run `browser-cli install-mcp all` once to connect installed Codex and Claude Code clients. Other clients can use the copied stdio configuration. The server exposes 53 browser tools and each client session gets a local audit timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                SettingsLabel("Model Context Protocol", systemImage: "point.3.connected.trianglepath.dotted", tint: SettingsTint.security)
            }
        }
        .formStyle(.grouped)
    }

    private var mcpConfiguration: String {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/browser-cli")
            .path
        let object: [String: Any] = [
            "mcpServers": [
                "straight-up-browser": ["command": helper, "args": ["mcp"]],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Memory

struct MemorySettingsView: View {
    @AppStorage("memorySaverEnabled") private var memorySaverEnabled = false
    @AppStorage("memorySaverDefaultPolicy") private var defaultPolicy = MemoryPolicy.whenNeeded.rawValue
    @Query(sort: \BrowserTab.orderIndex) private var tabs: [BrowserTab]
    @State private var pinnedHosts = MemoryPinnedSites.hosts
    @State private var newHost = ""

    private func addPinnedHost() {
        MemoryPinnedSites.hosts = pinnedHosts + [newHost]
        pinnedHosts = MemoryPinnedSites.hosts
        newHost = ""
    }

    var body: some View {
        Form {
            CollapsibleSection(searchID: "memory.saving") {
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

            CollapsibleSection(searchID: "memory.pinned-sites") {
                if pinnedHosts.isEmpty {
                    Text("No pinned sites.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pinnedHosts, id: \.self) { host in
                        HStack {
                            Image(systemName: "pin.fill").foregroundStyle(.secondary)
                            Text(host)
                            Spacer(minLength: 8)
                            Button {
                                MemoryPinnedSites.hosts = pinnedHosts.filter { $0 != host }
                                pinnedHosts = MemoryPinnedSites.hosts
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("Add a site (spotify.com)", text: $newHost)
                        .onSubmit(addPinnedHost)
                    Button("Add", action: addPinnedHost)
                        .disabled(MemoryPinnedSites.normalized(newHost).isEmpty)
                    Button("Reset") {
                        MemoryPinnedSites.hosts = MemoryPinnedSites.starterHosts
                        pinnedHosts = MemoryPinnedSites.hosts
                    }
                }
                Text("Tabs on these sites are never released, whatever their policy above — streaming, calls, anything you leave running in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsLabel("Never Release These Sites", systemImage: "pin", tint: SettingsTint.memory)
            }

            CollapsibleSection(searchID: "memory.open-tabs") {
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

struct SignedInGroup: Identifiable {
    let scope: WebsiteDataStoreScope
    let name: String
    let hosts: [String]

    // Two sessions can share a name; the scope can't.
    var id: String {
        switch scope {
        case .defaultStore: return "default"
        case .container(let identifier): return identifier.uuidString
        }
    }
}

struct PrivacySettingsView: View {
    @Query private var browserSessions: [BrowserSession]
    @State private var signedInGroups: [SignedInGroup] = []
    @ObservedObject private var permissionStore = SitePermissionStore.shared
    @AppStorage("convertToIncognitoEnabled") private var convertToIncognitoEnabled = false
    @State private var showClearDataDialog = false
    @State private var clearHistory = true
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var clearLocalStorage = true

    @State private var showCookieManager = false

    var body: some View {
        Form {
            CollapsibleSection(searchID: "privacy.incognito") {
                Toggle("Switch a tab to incognito with a key command", isOn: $convertToIncognitoEnabled)
            } header: {
                SettingsLabel("Incognito", systemImage: "eyeglasses", tint: SettingsTint.privacy)
            } footer: {
                Text("Adds “Switch Tab to Incognito” to the Privacy menu. It moves the current tab into a private session: your logins come along (cookies are copied over), but everything after the switch is kept only in memory and vanishes when the tab closes. What happened before the switch is already in your history, and sites that keep you signed in with local storage may ask you to sign in again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            CollapsibleSection(searchID: "privacy.signed-in") {
                if signedInGroups.isEmpty {
                    Text("No sites appear to be signed in.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(signedInGroups) { group in
                        ForEach(group.hosts, id: \.self) { host in
                            HStack(spacing: 10) {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if signedInGroups.count > 1 {
                                        Text(group.name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Sign Out") {
                                    BrowsingDataCleaner.clearSite(
                                        host: host,
                                        in: BrowsingDataCleaner.store(for: group.scope)
                                    ) { refreshSignedIn() }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            } header: {
                SettingsLabel(
                    "Signed In",
                    systemImage: "person.crop.circle.badge.checkmark",
                    tint: SettingsTint.privacy
                )
            } footer: {
                Text("Sites that left a sign-in cookie behind. Signing out here deletes that site's cookies, caches, and storage in that session — the site itself still has your account. Sites that keep you signed in with local storage instead of cookies won't be listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            CollapsibleSection(searchID: "privacy.site-permissions") {
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
                                Text("\(record.kind.title) · \(record.decision.title)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke") {
                                permissionStore.revoke(
                                    origin: record.origin,
                                    kind: record.kind
                                )
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Revoke All", role: .destructive) {
                        permissionStore.clear()
                    }
                }
            } header: {
                SettingsLabel(
                    "Site Permissions",
                    systemImage: "video.badge.ellipsis",
                    tint: SettingsTint.privacy
                )
            } footer: {
                Text("Camera and microphone choices are stored per website. Revoked sites ask again. Private tabs never add entries here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            CollapsibleSection(searchID: "privacy.data") {
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
        .onAppear { refreshSignedIn() }
    }

    private func refreshSignedIn() {
        let sessions = browserSessions
        let identifiers = sessions.map(\.id)
        // signedInHosts returns one entry per scope, in allStoreScopes order.
        let scopes = BrowsingDataCleaner.allStoreScopes(containerIdentifiers: identifiers)
        BrowsingDataCleaner.signedInHosts(containerIdentifiers: identifiers) { hostsPerScope in
            signedInGroups = zip(scopes, hostsPerScope).compactMap { scope, hosts in
                guard !hosts.isEmpty else { return nil }
                let name: String
                switch scope {
                case .defaultStore:
                    name = "Main"
                case .container(let identifier):
                    name = sessions.first { $0.id == identifier }?.name ?? "Session"
                }
                return SignedInGroup(scope: scope, name: name, hosts: hosts)
            }
        }
    }
}

// MARK: - Clear Data Dialog

struct ClearDataDialog: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var tabs: [Tab]
    @Query private var browserSessions: [BrowserSession]

    @Binding var isPresented: Bool
    @Binding var clearHistory: Bool
    @Binding var clearCookies: Bool
    @Binding var clearCache: Bool
    @Binding var clearLocalStorage: Bool
    @State private var clearPageArchives = false
    @State private var pageArchiveBytes = 0

    /// Snapshots of pages captured for research. Deleting them loses the offline
    /// copy an anchor falls back to; the extracted text and the ledger survive.
    private var pageArchiveSizeDescription: String {
        pageArchiveBytes == 0
            ? String(localized: "Nothing saved yet")
            : String(
                localized: "\(ByteCountFormatter.string(fromByteCount: Int64(pageArchiveBytes), countStyle: .file)) of research page snapshots"
            )
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Clear Browsing Data")
                .font(.title)
                .fontWeight(.bold)

            Text("Select the types of data you want to clear:")
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Browsing history", isOn: $clearHistory)
                Toggle("Cookies", isOn: $clearCookies)
                Toggle("Cached images and files", isOn: $clearCache)
                Toggle("Local storage", isOn: $clearLocalStorage)
                // Research page archives are local-only and can grow large, so
                // they get their own opt-in rather than riding on "cache".
                Toggle(isOn: $clearPageArchives) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved page archives")
                        Text(pageArchiveSizeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
        .onAppear { pageArchiveBytes = LedgerStore(modelContext: modelContext).totalArchiveBytes() }
    }

    private func clearSelectedData() {
        if clearHistory {
            BrowsingDataCleaner.clearHistory(in: tabs)
        }
        if clearPageArchives {
            LedgerStore(modelContext: modelContext).clearArchives()
        }

        BrowsingDataCleaner.clearSelectedWebsiteData(
            cookies: clearCookies,
            cache: clearCache,
            localStorage: clearLocalStorage,
            containerIdentifiers: browserSessions.map(\.id)
        )
    }
}

// MARK: - Cookie Manager Dialog

struct CookieManagerDialog: View {
    @Binding var isPresented: Bool
    @State private var cookies: [HTTPCookie] = []
    @State private var searchText = ""

    private var cookieStore: WKHTTPCookieStore {
        WKWebsiteDataStore.default().httpCookieStore
    }

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
        cookieStore.getAllCookies { loadedCookies in
            DispatchQueue.main.async {
                cookies = loadedCookies.sorted {
                    ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name)
                }
            }
        }
    }

    private func deleteCookie(_ cookie: HTTPCookie) {
        cookieStore.delete(cookie) {
            loadCookies()
        }
    }

    private func deleteAllCookies() {
        let store = cookieStore
        store.getAllCookies { allCookies in
            guard !allCookies.isEmpty else {
                DispatchQueue.main.async { loadCookies() }
                return
            }
            let group = DispatchGroup()
            for cookie in allCookies {
                group.enter()
                store.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) { loadCookies() }
        }
    }
}
