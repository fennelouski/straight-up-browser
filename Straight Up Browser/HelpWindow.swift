//
//  HelpWindow.swift
//  Straight Up Browser
//

import SwiftUI

struct HelpWindow: View {
    @State private var selectedTab = 0
    // @AppStorage (not SettingsManager.shared.colorScheme) so this window re-renders
    // when Theme changes instead of waiting for an unrelated update.
    @AppStorage("theme") private var themePreference = "System"

    private var colorScheme: ColorScheme? {
        switch themePreference {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GettingStartedView()
                .tabItem {
                    Label("Getting Started", systemImage: "sparkles")
                }
                .tag(0)

            ShortcutsHelpView()
                .tabItem {
                    Label("Keyboard Shortcuts", systemImage: "keyboard")
                }
                .tag(1)

            CLIHelpView()
                .tabItem {
                    Label("Tips & CLI", systemImage: "terminal")
                }
                .tag(2)
        }
        .frame(width: 952, height: 690)
        .padding()
        .preferredColorScheme(colorScheme)
    }
}

// MARK: - Getting Started
private struct GettingStartedView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Window to the Internet")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("The simplest way to use the internet — here's everything you need to get browsing.")
                        .foregroundStyle(.secondary)
                }

                GroupBox(label: Text("The Omnibar")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Everything starts at the omnibar. Press ⌃Space, ⌘K, or ⌘L to open it, then type a web address or a search — your browser figures out which one you meant.")
                        Text("It also matches your open tabs, history, and bookmarks as you type, so it doubles as a quick switcher.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox(label: Text("Tabs")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Open a new tab with ⌘T, close one with ⌘W, and bring back the last closed tab with ⇧⌘T. Cycle through tabs with ⌃Tab, or jump straight to one with ⌘1 through ⌘9.")
                        Text("The tab bar has several sizes — toggle it with ⇧⌘L or pick a style from the View menu.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox(label: Text("Split View")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("See two pages at once — mail next to your calendar, two documents side by side. Hold ⇧ (Shift) and click another tab to show it beside the current one. Add up to four: three tabs sit in columns, four make a 2×2 grid.")
                        Text("Drag the divider between panes to resize them. Shift-click a shown tab to remove its pane, or click any tab normally to return to a single page. You can also right-click a tab and choose Open in Split.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox(label: Text("Bookmarks")) {
                    Text("Bookmark the current page with ⌘D and browse your bookmarks with ⇧⌘B. You can import bookmarks from another browser via Bookmarks → Import Bookmarks.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }

                GroupBox(label: Text("From Anywhere")) {
                    Text("A system-wide hotkey (⌥Space by default) opens the omnibar even when your browser isn't the front app. Change the hotkey in Settings (⌘,).")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }

                GroupBox(label: Text("Quitting")) {
                    Text("To avoid losing your tabs to a mistyped shortcut, quitting requires holding ⌘Q for two seconds.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
            // The window is sized by the shortcut columns; prose stays at a
            // readable measure instead of stretching the full width.
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}

// MARK: - Keyboard Shortcuts
// Rendered from ShortcutStore so the list always reflects the live (and
// customizable) bindings — see ShortcutCommand.swift. Customize any of these in
// Settings → Shortcuts.
private struct ShortcutsHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Keyboard Shortcuts")
                    .font(.title2)
                    .fontWeight(.bold)

                ShortcutColumnsView()

                Text("The omnibar also opens from any app with ⌥Space (configurable), and quitting holds ⌘Q for two seconds. Customize any shortcut in Settings → Shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
    }
}

// MARK: - Shortcut columns
// Every command on one screen: the sections are packed into columns balanced by
// row count, so no column runs long while its neighbour sits half empty. Shared
// by the Help tab and the ⇧⌘H overlay — one layout, one place to change it.
enum ShortcutColumnPacking {
    static let columnWidth: CGFloat = 288

    /// A section costs its rows plus its header and the gap above it. `rows` is
    /// injectable so the packing can be exercised without the live store.
    static func balanced(
        into count: Int,
        rows: (ShortcutSection) -> Int = { ShortcutStore.shared.cheatRows(for: $0).count }
    ) -> [[ShortcutSection]] {
        func height(_ section: ShortcutSection) -> Int { rows(section) + 2 }
        var remaining = ShortcutSection.allCases.reduce(0) { $0 + height($1) }
        var columns: [[ShortcutSection]] = []
        var current: [ShortcutSection] = []
        var used = 0
        for section in ShortcutSection.allCases {
            let target = Double(remaining) / Double(count - columns.count)
            // Close the column when this section would overshoot the target by
            // more than stopping short of it does.
            if !current.isEmpty, columns.count < count - 1,
               abs(Double(used + height(section)) - target) > abs(Double(used) - target) {
                columns.append(current)
                remaining -= used
                current = []
                used = 0
            }
            current.append(section)
            used += height(section)
        }
        columns.append(current)
        return columns
    }
}

struct ShortcutColumnsView: View {
    var columnCount = 3
    var searchQuery = ""
    var searchOpacity = 1.0

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(ShortcutColumnPacking.balanced(into: columnCount), id: \.first) { sections in
                // One Grid per column, not per section, so every key in the
                // column shares a right edge instead of jumping around.
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                        GridRow {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.top, index == 0 ? 0 : 12)
                                .gridCellColumns(2)
                        }
                        ForEach(ShortcutStore.shared.cheatRows(for: section)) { row in
                            GridRow {
                                CheatSheetTitleCell(
                                    row: row,
                                    searchQuery: searchQuery,
                                    searchOpacity: searchOpacity
                                )
                                CheatSheetKeysCell(row: row)
                            }
                        }
                    }
                }
                .frame(minWidth: ShortcutColumnPacking.columnWidth, maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Responsive cheat-sheet cells (⇧⌘H overlay)
// Leaf views that observe LiveKeyState.shared, so only the changed cell
// re-renders as keys are pressed — never the whole ContentView.

struct HighlightedChord: View {
    let shortcut: Shortcut
    private var live: LiveKeyState { .shared }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(shortcut.displayTokens.enumerated()), id: \.offset) { _, token in
                let held = live.isActive && live.isHeld(token, in: shortcut)
                Text(token)
                    .foregroundStyle(held ? Color.accentColor : Color.secondary)
                    .fontWeight(held ? .bold : .regular)
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

struct CheatSheetKeysCell: View {
    let row: CheatRow

    var body: some View {
        if let shortcut = row.shortcut {
            HStack(spacing: 0) {
                HighlightedChord(shortcut: shortcut)
                // Anything the row lists past the primary chord — the ⌃ twin
                // that gets a page-proof second binding. Dim: it's the fallback.
                if row.keys.hasPrefix(shortcut.displayString) {
                    Text(row.keys.dropFirst(shortcut.displayString.count))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Text(row.keys)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

struct CheatSheetTitleCell: View {
    let row: CheatRow
    var searchQuery = ""
    var searchOpacity = 1.0
    private var live: LiveKeyState { .shared }

    var body: some View {
        let held = row.shortcut.map { live.isActive && live.fullyHeld($0) } ?? false
        let title = String(localized: row.title)
        let matches = ShortcutSearchMatcher.matchIndices(query: searchQuery, in: title)
        HStack(spacing: 0) {
            ForEach(Array(title.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .fontWeight(held || matches?.contains(index) == true ? .semibold : .regular)
                    .foregroundStyle(
                        held || matches?.contains(index) == true ? Color.accentColor : Color.primary
                    )
            }
        }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background {
                if matches != nil && !searchQuery.isEmpty {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.12 * searchOpacity))
                }
            }
            .opacity(!searchQuery.isEmpty && matches == nil ? max(0.38, searchOpacity) : 1)
    }
}

enum ShortcutSearchMatcher {
    /// Returns the character offsets that form an ordered fuzzy match.
    static func matchIndices(query: String, in candidate: String) -> Set<Int>? {
        let needle = Array(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        guard !needle.isEmpty else { return nil }
        let haystack = Array(candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        var result = Set<Int>()
        var needleIndex = 0
        for (index, character) in haystack.enumerated() where needleIndex < needle.count {
            if character == needle[needleIndex] {
                result.insert(index)
                needleIndex += 1
            }
        }
        return needleIndex == needle.count ? result : nil
    }
}

#if os(macOS)
struct ShortcutCheatSheetOverlay: View {
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var candidate = ""
    @State private var candidateStartedAt: TimeInterval?
    @State private var lastCharacterAt: TimeInterval?
    @State private var forceNewWord = false
    @State private var hasActivatedSearch = false
    @State private var searchOpacity = 1.0
    @State private var keyMonitor: Any?
    @State private var clearTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Label("Keyboard Shortcuts", systemImage: "keyboard")
                        .font(.headline)
                    Spacer()
                    if !query.isEmpty {
                        Label(query, systemImage: "text.magnifyingglass")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .opacity(searchOpacity)
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }
                }

                // Three columns when the window is wide enough for them, fewer
                // when it isn't — the overlay is sized to its content.
                ViewThatFits(in: .horizontal) {
                    ShortcutColumnsView(columnCount: 3, searchQuery: query, searchOpacity: searchOpacity)
                    ShortcutColumnsView(columnCount: 2, searchQuery: query, searchOpacity: searchOpacity)
                    ShortcutColumnsView(columnCount: 1, searchQuery: query, searchOpacity: searchOpacity)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 14)
        }
        .transition(.opacity)
        .onExitCommand { isPresented = false }
        .onAppear {
            LiveKeyState.shared.activate()
            installKeyMonitor()
        }
        .onDisappear {
            LiveKeyState.shared.deactivate()
            removeKeyMonitor()
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                isPresented = false
                return nil
            }

            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard modifiers.isEmpty,
                  !event.isARepeat,
                  let characters = event.charactersIgnoringModifiers,
                  characters.count == 1,
                  let character = characters.first else { return event }

            if character.isWhitespace {
                forceNewWord = true
                return nil
            }
            guard character.isLetter || character.isNumber else { return event }

            accept(character: String(character).lowercased(), at: event.timestamp)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        clearTask?.cancel()
        clearTask = nil
    }

    private func accept(character: String, at timestamp: TimeInterval) {
        let gap = lastCharacterAt.map { timestamp - $0 } ?? .infinity
        let startsNewWord = forceNewWord || gap >= 1.0
        forceNewWord = false

        if startsNewWord {
            candidate = character
            candidateStartedAt = timestamp
            if startsNewWord && hasActivatedSearch {
                query = character
                searchOpacity = 1
            } else {
                query = ""
            }
        } else {
            candidate += character
            let duration = max(timestamp - (candidateStartedAt ?? timestamp), 0.001)
            let charactersPerSecond = Double(max(candidate.count - 1, 0)) / duration
            if charactersPerSecond >= 5 {
                query = candidate
                searchOpacity = 1
                hasActivatedSearch = true
            }
        }
        lastCharacterAt = timestamp
        scheduleFade()
    }

    private func scheduleFade() {
        clearTask?.cancel()
        clearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.28)) { searchOpacity = 0 }
            try? await Task.sleep(for: .seconds(0.28))
            guard !Task.isCancelled else { return }
            query = ""
            candidate = ""
            candidateStartedAt = nil
            searchOpacity = 1
        }
    }
}
#endif

// MARK: - Tips & CLI
private struct CLIHelpView: View {
    private static let commands: [(String, String)] = [
        ("open <url>", "Open a URL"),
        ("search <query>", "Search the web"),
        ("new", "Create a new tab"),
        ("close", "Close the active tab"),
        ("tabs", "List open tabs (JSON)"),
        ("get [url]", "Get page data (JSON)"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Tips & CLI")
                    .font(.title)
                    .fontWeight(.bold)

                GroupBox(label: Text("Shortcuts & Siri")) {
                    Text("Your browser's actions — Open URL, Search the Web, New Tab — appear in the Shortcuts app, Spotlight, and Siri. Try saying “New tab in Browser.”")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }

                GroupBox(label: Text("Command Line")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your browser can be driven from the terminal with browser-cli (see CLI_USAGE.md in the project for setup):")
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            ForEach(Self.commands, id: \.0) { command, purpose in
                                GridRow {
                                    Text(command)
                                        .font(.system(.body, design: .monospaced))
                                    Text(purpose.localized)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}
