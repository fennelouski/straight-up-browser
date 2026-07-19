//
//  ShortcutCommand.swift
//  Straight Up Browser
//
//  Single source of truth for every rebindable keyboard shortcut. Replaces the
//  literals that used to be scattered across the menu .commands, the NSEvent
//  monitor, and the hand-maintained ShortcutReference cheat sheet. All four
//  surfaces now read one ShortcutStore, so a rebinding shows up everywhere and
//  the cheat sheet can never drift from the real bindings.
//
//  Shared by the macOS and iPadOS targets; NSEvent-specific bits are gated.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Shortcut value type

// A key plus its modifiers. `key` is the base character produced with no
// modifiers ("t", "=", "["), or "\t"/" " for Tab/Space. Everything the four
// mechanisms need is derived from here so there's one representation to reason
// about.
struct Shortcut: Codable, Equatable, Hashable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    var hasModifier: Bool { command || shift || option || control }

    // SwiftUI menus (macOS + iOS)
    var keyEquivalent: KeyEquivalent {
        switch key {
        case "\t": return .tab
        case " ": return .space
        default: return KeyEquivalent(key.first ?? "?")
        }
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    // Cheat sheet: modifier glyphs in Apple's canonical order, then the key.
    var displayTokens: [String] {
        var t: [String] = []
        if control { t.append("⌃") }
        if option { t.append("⌥") }
        if shift { t.append("⇧") }
        if command { t.append("⌘") }
        t.append(keyGlyph)
        return t
    }

    var keyGlyph: String {
        switch key {
        case "\t": return "⇥"
        case " ": return "Space"
        case "`": return "`"
        default: return key.uppercased()
        }
    }

    var displayString: String { displayTokens.joined() }

    #if canImport(AppKit)
    var nsModifiers: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    // Match a live NSEvent (used by the local monitor). Tab is compared by
    // keyCode because its character varies; everything else compares the
    // modifier-independent character.
    func matches(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == nsModifiers else { return false }
        if key == "\t" { return event.keyCode == 48 }
        return event.charactersIgnoringModifiers?.lowercased() == key.lowercased()
    }

    // Build from a captured NSEvent (press-to-record). Returns nil for a bare
    // modifier press (no base key yet).
    init?(event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
            if event.keyCode == 48 { self.init(key: "\t"); self.apply(event.modifierFlags); return }
            return nil
        }
        let key = event.keyCode == 48 ? "\t" : chars.lowercased()
        self.init(key: key)
        apply(event.modifierFlags)
    }

    private mutating func apply(_ flags: NSEvent.ModifierFlags) {
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        control = flags.contains(.control)
    }
    #endif
}

// MARK: - Sections

enum ShortcutSection: String, CaseIterable {
    case tabs, navigation, page, tabBar, bookmarks, privacy, app

    var title: LocalizedStringResource {
        switch self {
        case .tabs: return "Tabs"
        case .navigation: return "Navigation"
        case .page: return "Page"
        case .tabBar: return "Tab Bar"
        case .bookmarks: return "Bookmarks"
        case .privacy: return "Privacy"
        case .app: return "App"
        }
    }
}

// MARK: - Commands

// One descriptor per user-facing command. `id` is the stable persistence key.
// Dispatch (which notification/closure fires) stays in the menu and monitor
// code that already owns it — this type only supplies the key and its display.
struct ShortcutCommand: Identifiable, Hashable {
    let id: String
    let title: LocalizedStringResource
    let section: ShortcutSection
    let defaultShortcut: Shortcut

    static func == (lhs: ShortcutCommand, rhs: ShortcutCommand) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    private init(_ id: String, _ title: LocalizedStringResource, _ section: ShortcutSection, _ s: Shortcut) {
        self.id = id; self.title = title; self.section = section; self.defaultShortcut = s
    }
}

extension ShortcutCommand {
    // Tabs
    static let newTab       = Self("newTab", "New Tab", .tabs, Shortcut(key: "t", command: true))
    static let closeTab     = Self("closeTab", "Close Tab", .tabs, Shortcut(key: "w", command: true))
    static let reopenTab    = Self("reopenTab", "Reopen Last Closed Tab", .tabs, Shortcut(key: "t", command: true, shift: true))
    static let nextTab      = Self("nextTab", "Next Tab", .tabs, Shortcut(key: "\t", control: true))
    static let previousTab  = Self("previousTab", "Previous Tab", .tabs, Shortcut(key: "\t", shift: true, control: true))
    static let newIncognitoTab = Self("newIncognitoTab", "New Incognito Tab", .tabs, Shortcut(key: "n", command: true, shift: true))

    // Privacy
    static let clearSiteData = Self("clearSiteData", "Clear This Site's Data", .privacy, Shortcut(key: "e", command: true, shift: true))

    // Navigation
    static let openLocation = Self("openLocation", "Open Location", .navigation, Shortcut(key: "l", command: true))
    static let back         = Self("back", "Back", .navigation, Shortcut(key: "[", command: true))
    static let forward      = Self("forward", "Forward", .navigation, Shortcut(key: "]", command: true))
    static let reload       = Self("reload", "Reload", .navigation, Shortcut(key: "r", command: true))
    static let hardReload   = Self("hardReload", "Hard Reload (bypass cache)", .navigation, Shortcut(key: "r", command: true, shift: true))
    static let reloadAll    = Self("reloadAll", "Reload All Tabs", .navigation, Shortcut(key: "r", command: true, shift: true, option: true))

    // Page
    static let findInPage   = Self("findInPage", "Find on Page", .page, Shortcut(key: "f", command: true))
    static let findNext     = Self("findNext", "Find Next", .page, Shortcut(key: "g", command: true))
    static let findPrevious = Self("findPrevious", "Find Previous", .page, Shortcut(key: "g", command: true, shift: true))
    static let zoomIn       = Self("zoomIn", "Zoom In", .page, Shortcut(key: "=", command: true))
    static let zoomOut      = Self("zoomOut", "Zoom Out", .page, Shortcut(key: "-", command: true))
    static let actualSize   = Self("actualSize", "Actual Size", .page, Shortcut(key: "0", command: true))
    static let printPage    = Self("printPage", "Print", .page, Shortcut(key: "p", command: true, shift: true))
    static let exportPDF    = Self("exportPDF", "Export as PDF", .page, Shortcut(key: "p", command: true))
    static let fullScreen   = Self("fullScreen", "Toggle Full Screen", .page, Shortcut(key: "f", command: true, shift: true))

    // Tab Bar
    static let toggleTabBar = Self("toggleTabBar", "Toggle Tab Bar", .tabBar, Shortcut(key: "l", command: true, shift: true))
    static let hideTabBar   = Self("hideTabBar", "Hide Tab Bar", .tabBar, Shortcut(key: "`", command: true, option: true))
    static let minimalTabBar = Self("minimalTabBar", "Minimal Tab Bar", .tabBar, Shortcut(key: "1", command: true, option: true))
    static let compactTabBar = Self("compactTabBar", "Compact Tab Bar", .tabBar, Shortcut(key: "2", command: true, option: true))
    static let wideTabBar   = Self("wideTabBar", "Wide Tab Bar", .tabBar, Shortcut(key: "3", command: true, option: true))

    // Bookmarks
    static let addBookmark  = Self("addBookmark", "Add Bookmark", .bookmarks, Shortcut(key: "d", command: true))
    static let showBookmarks = Self("showBookmarks", "Show Bookmarks", .bookmarks, Shortcut(key: "b", command: true, shift: true))

    // App
    static let omnibar      = Self("omnibar", "Omnibar", .app, Shortcut(key: " ", control: true))
    static let quickOpen    = Self("quickOpen", "Quick Open", .app, Shortcut(key: "k", command: true))
    static let shortcutOverlay = Self("shortcutOverlay", "Keyboard Shortcuts", .app, Shortcut(key: "h", command: true, shift: true))
    static let settings     = Self("settings", "Settings", .app, Shortcut(key: ",", command: true))
    static let help         = Self("help", "Help", .app, Shortcut(key: "?", command: true))
    static let extensionPopup = Self("extensionPopup", "Open Extension Popup", .app, Shortcut(key: "e", command: true, option: true))

    // Jump to tab 1–9 (generated; ids "switchTab1"…"switchTab9").
    static let switchTabs: [ShortcutCommand] = (1...9).map { i in
        Self("switchTab\(i)", "Show Tab \(i)", .tabs, Shortcut(key: "\(i)", command: true))
    }

    static let all: [ShortcutCommand] =
        [newTab, closeTab, reopenTab, nextTab, previousTab, newIncognitoTab]
        + switchTabs
        + [openLocation, back, forward, reload, hardReload, reloadAll,
           findInPage, findNext, findPrevious, zoomIn, zoomOut, actualSize, printPage, exportPDF, fullScreen,
           toggleTabBar, hideTabBar, minimalTabBar, compactTabBar, wideTabBar,
           addBookmark, showBookmarks, clearSiteData,
           omnibar, quickOpen, shortcutOverlay, settings, help, extensionPopup]

    static func by(id: String) -> ShortcutCommand? { all.first { $0.id == id } }
}

// MARK: - Store

// Holds the current bindings, persists customizations, and is the reactive
// source for the settings UI. Only entries that differ from the default are
// stored, so tweaking a default later still reaches users who never rebound it.
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()

    private static let storeKey = "customShortcuts"
    // Bumped on every mutation; the App reads it via @AppStorage to force the
    // menu .commands to rebuild (same trigger the cmdPExportsPDF toggle uses).
    static let revisionKey = "shortcutsRevision"

    private(set) var custom: [String: Shortcut] = [:]

    private init() { load() }

    func shortcut(for command: ShortcutCommand) -> Shortcut {
        custom[command.id] ?? command.defaultShortcut
    }

    func isCustomized(_ command: ShortcutCommand) -> Bool { custom[command.id] != nil }

    func rebind(_ command: ShortcutCommand, to shortcut: Shortcut) {
        if shortcut == command.defaultShortcut {
            custom.removeValue(forKey: command.id)
        } else {
            custom[command.id] = shortcut
        }
        persist()
    }

    func reset(_ command: ShortcutCommand) {
        guard custom[command.id] != nil else { return }
        custom.removeValue(forKey: command.id)
        persist()
    }

    func resetAll() {
        guard !custom.isEmpty else { return }
        custom.removeAll()
        persist()
    }

    // Commands sharing a chord (the same Shortcut bound to 2+ commands).
    func conflicts() -> [ShortcutCommand] {
        var seen: [Shortcut: [ShortcutCommand]] = [:]
        for command in ShortcutCommand.all {
            seen[shortcut(for: command), default: []].append(command)
        }
        return seen.values.filter { $0.count > 1 }.flatMap { $0 }
    }

    func commandsSharing(_ shortcut: Shortcut, excluding command: ShortcutCommand) -> [ShortcutCommand] {
        ShortcutCommand.all.filter { $0.id != command.id && self.shortcut(for: $0) == shortcut }
    }

    // Display projection for the cheat sheet, grouped and ordered by section.
    var groupedForDisplay: [(section: ShortcutSection, commands: [ShortcutCommand])] {
        ShortcutSection.allCases.compactMap { section in
            let commands = ShortcutCommand.all.filter { $0.section == section }
            return commands.isEmpty ? nil : (section, commands)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data) else { return }
        custom = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
        let rev = UserDefaults.standard.integer(forKey: Self.revisionKey) + 1
        UserDefaults.standard.set(rev, forKey: Self.revisionKey)
    }
}

// MARK: - Cheat sheet projection

// One rendered row: title on the left, a keys string on the right. The nine
// "Show Tab N" commands collapse into a single "Jump to Tab 1–9" row so the
// compact overlay stays short.
struct CheatRow: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let keys: String
    // The single shortcut this row represents, for per-symbol live highlighting.
    // nil for the collapsed "Jump to Tab 1–9" summary row.
    let shortcut: Shortcut?
}

extension ShortcutStore {
    func cheatRows(for section: ShortcutSection) -> [CheatRow] {
        var rows: [CheatRow] = []
        var addedTabSummary = false
        for command in ShortcutCommand.all where command.section == section {
            if command.id.hasPrefix("switchTab") {
                guard !addedTabSummary else { continue }
                addedTabSummary = true
                let lo = shortcut(for: ShortcutCommand.switchTabs.first!).displayString
                let hi = shortcut(for: ShortcutCommand.switchTabs.last!).displayString
                rows.append(CheatRow(id: "switchTabs", title: "Jump to Tab 1–9", keys: "\(lo) – \(hi)", shortcut: nil))
                continue
            }
            let s = shortcut(for: command)
            rows.append(CheatRow(id: command.id, title: command.title, keys: s.displayString, shortcut: s))
        }
        if section == .tabs {
            // Not a rebindable command — a mouse gesture, documented here so it's discoverable
            rows.append(CheatRow(id: "splitPane", title: "Add/Remove Split Pane", keys: "⇧Click", shortcut: nil))
        }
        return rows
    }
}

// MARK: - Live key state (responsive cheat sheet)

// Mirrors the modifiers/key currently held down, but only while a cheat sheet is
// visible (isActive). The macOS event monitor feeds it; the ⇧⌘H overlay reads it
// to light up matching symbols. macOS-only in practice — nothing sets isActive
// on iPad.
@Observable
final class LiveKeyState {
    static let shared = LiveKeyState()
    private init() {}

    var isActive = false
    var command = false
    var shift = false
    var option = false
    var control = false
    var pressedKey: String?

    #if canImport(AppKit)
    func update(from event: NSEvent) {
        guard isActive else { return }
        let flags = event.modifierFlags
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        control = flags.contains(.control)
        switch event.type {
        case .keyDown: pressedKey = event.keyCode == 48 ? "\t" : event.charactersIgnoringModifiers?.lowercased()
        case .keyUp: pressedKey = nil
        default: break
        }
    }
    #endif

    func activate() { isActive = true }
    func deactivate() {
        isActive = false
        command = false; shift = false; option = false; control = false; pressedKey = nil
    }

    // Is this display glyph (a modifier symbol, or the shortcut's key) held now?
    func isHeld(_ token: String, in shortcut: Shortcut) -> Bool {
        switch token {
        case "⌘": return command
        case "⇧": return shift
        case "⌥": return option
        case "⌃": return control
        default: return pressedKey != nil && pressedKey == shortcut.key.lowercased()
        }
    }

    // Whole chord currently held → the row lights up.
    func fullyHeld(_ shortcut: Shortcut) -> Bool {
        command == shortcut.command && shift == shortcut.shift
            && option == shortcut.option && control == shortcut.control
            && pressedKey == shortcut.key.lowercased()
    }
}

// MARK: - Browser presets

// "Import from another browser" delivered as curated presets: adopt a browser's
// macOS muscle memory in one tap. Only the bindings that differ from our own
// defaults are listed — the browsers share most shortcuts on macOS. Full Screen
// is the big one: every mainstream browser uses ⌃⌘F, while our default is ⇧⌘F.
enum ShortcutPreset: String, CaseIterable, Identifiable {
    case chrome, firefox, safari, arc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chrome: return "Chrome"
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        case .arc: return "Arc"
        }
    }

    // command.id → shortcut, for the bindings this browser does differently.
    var overrides: [String: Shortcut] {
        let fullScreenCtrlCmd = Shortcut(key: "f", command: true, control: true)
        switch self {
        case .chrome:
            return [
                ShortcutCommand.fullScreen.id: fullScreenCtrlCmd,
                ShortcutCommand.showBookmarks.id: Shortcut(key: "b", command: true, option: true), // Bookmark Manager
            ]
        case .firefox:
            return [
                ShortcutCommand.fullScreen.id: fullScreenCtrlCmd,
                ShortcutCommand.showBookmarks.id: Shortcut(key: "o", command: true, shift: true), // Library
            ]
        case .safari:
            return [
                ShortcutCommand.fullScreen.id: fullScreenCtrlCmd,
                ShortcutCommand.showBookmarks.id: Shortcut(key: "b", command: true, option: true), // Show All Bookmarks
            ]
        case .arc:
            return [
                ShortcutCommand.fullScreen.id: fullScreenCtrlCmd,
                ShortcutCommand.toggleTabBar.id: Shortcut(key: "s", command: true), // toggle sidebar
            ]
        }
    }
}

extension ShortcutStore {
    // Adopt a preset wholesale: clear existing customizations, then apply the
    // preset's deltas (dropping any that already equal our default).
    func apply(preset: ShortcutPreset) {
        var next = preset.overrides
        for (id, shortcut) in next where ShortcutCommand.by(id: id)?.defaultShortcut == shortcut {
            next.removeValue(forKey: id)
        }
        custom = next
        persist()
    }
}

// MARK: - System conflicts

extension ShortcutStore {
    // Well-known macOS system-wide chords. Best-effort: macOS lets users remap
    // system shortcuts, so this can't be exhaustive — it's a curated warning
    // list, extend as reported.
    // ponytail: curated denylist; no public API enumerates the real set.
    static let reservedSystemChords: [Shortcut: String] = [
        Shortcut(key: " ", command: true): "Spotlight",
        Shortcut(key: " ", command: true, option: true): "Finder search",
        Shortcut(key: "\t", command: true): "app switcher",
        Shortcut(key: "\t", command: true, shift: true): "app switcher",
        Shortcut(key: "3", command: true, shift: true): "screenshot",
        Shortcut(key: "4", command: true, shift: true): "screenshot",
        Shortcut(key: "5", command: true, shift: true): "screenshot",
        Shortcut(key: "q", command: true): "Quit",
        Shortcut(key: "h", command: true): "Hide",
        Shortcut(key: "m", command: true): "Minimize",
    ]

    // The name of the system shortcut this chord collides with, if any.
    func systemConflict(_ shortcut: Shortcut) -> String? {
        Self.reservedSystemChords[shortcut]
    }
}

#if DEBUG
// ponytail: one runnable check that the value-type conversions and conflict
// detection hold; call ShortcutStore.selfCheck() from a #if DEBUG init.
extension ShortcutStore {
    static func selfCheck() {
        let t = Shortcut(key: "t", command: true)
        assert(t.displayString == "⌘T", "displayString: \(t.displayString)")
        assert(t.eventModifiers.contains(.command))
        let ctrlTab = ShortcutCommand.nextTab.defaultShortcut
        assert(ctrlTab.displayTokens == ["⌃", "⇥"], "\(ctrlTab.displayTokens)")
        // No two defaults collide.
        var seen = Set<Shortcut>()
        for c in ShortcutCommand.all {
            assert(seen.insert(c.defaultShortcut).inserted, "duplicate default: \(c.id) \(c.defaultShortcut.displayString)")
        }
    }
}
#endif
