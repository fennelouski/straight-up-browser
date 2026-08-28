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

    // The ⌃ twin of a ⌘ chord (⌘R → ⌃R). Websites can bind ⌘R and swallow it
    // before we see it; the twin is a second way in that pages don't take.
    // nil when the chord isn't ⌘-based, or when the twin would land on an
    // AppKit text-editing binding (⌃A/⌃E/⌃K…) — only bare ⌃+key is at risk,
    // ⌃⇧K and friends are free.
    var controlTwin: Shortcut? {
        guard command, !control else { return nil }
        var twin = self
        twin.command = false
        twin.control = true
        if !shift && !option && Self.textEditingControlKeys.contains(key) { return nil }
        return twin
    }

    // ponytail: curated; AppKit's emacs-style bindings have no public listing.
    private static let textEditingControlKeys: Set<String> = [
        "a", "b", "d", "e", "f", "h", "k", "n", "o", "p", "t", "v", "y",
        "[", "]", "\\", " ", "\t",
    ]

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
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
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
    case tabs, navigation, page, screenshots, tabBar, bookmarks, privacy, app

    var title: LocalizedStringResource {
        switch self {
        case .tabs: return "Tabs"
        case .navigation: return "Navigation"
        case .page: return "Page"
        case .screenshots: return "Screenshots"
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
    // Two meanings that never coexist: inside a workspace this closes the
    // workspace, outside one it closes the split's tab set.
    static let closeTabSet  = Self("closeTabSet", "Close Workspace or Tab Set", .tabs, Shortcut(key: "w", command: true, shift: true))
    static let reopenTab    = Self("reopenTab", "Reopen Last Closed Tab", .tabs, Shortcut(key: "t", command: true, shift: true))
    static let nextTab      = Self("nextTab", "Next Tab", .tabs, Shortcut(key: "\t", control: true))
    static let previousTab  = Self("previousTab", "Previous Tab", .tabs, Shortcut(key: "\t", shift: true, control: true))
    static let newIncognitoTab = Self("newIncognitoTab", "New Incognito Tab", .tabs, Shortcut(key: "n", command: true, shift: true, option: true))

    // Privacy
    static let clearSiteData = Self("clearSiteData", "Clear This Site's Data", .privacy, Shortcut(key: "e", command: true, shift: true))
    static let convertToIncognito = Self("convertToIncognito", "Switch Tab to Incognito", .privacy, Shortcut(key: "i", command: true, shift: true, option: true))

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
    static let fullScreen   = Self("fullScreen", "Toggle Full Screen", .page, Shortcut(key: "f", command: true, control: true))
    static let toggleTranslation = Self("toggleTranslation", "Toggle Page Translation", .page, Shortcut(key: "t", command: true, option: true))
    static let translateInSplit  = Self("translateInSplit", "Open Translation in Split Pane", .page, Shortcut(key: "t", command: true, shift: true, option: true))
    static let readerMode    = Self("readerMode", "Reader Mode", .page, Shortcut(key: "r", command: true, option: true))
    static let toggleAutofill = Self("toggleAutofill", "Toggle Autofill", .page, Shortcut(key: "a", command: true, option: true))

    // Element/window capture remains desktop-only, but visible and full-page
    // capture use WKWebView snapshots on iOS.
    static let screenshotVisible  = Self("screenshotVisible", "Screenshot Visible Area", .screenshots, Shortcut(key: "s", command: true))
    static let screenshotFullPage = Self("screenshotFullPage", "Screenshot Full Page", .screenshots, Shortcut(key: "s", command: true, shift: true))
    #if os(macOS)
    static let screenshotElement  = Self("screenshotElement", "Screenshot Element Under Cursor", .screenshots, Shortcut(key: "s", command: true, option: true))
    static let screenshotWindow   = Self("screenshotWindow", "Screenshot Window and Tab Bar", .screenshots, Shortcut(key: "s", command: true, shift: true, option: true))
    #endif

    // Tab Bar
    static let toggleTabBar = Self("toggleTabBar", "Toggle Tab Bar", .tabBar, Shortcut(key: "l", command: true, shift: true))
    static let hideTabBar   = Self("hideTabBar", "Hide Tab Bar", .tabBar, Shortcut(key: "`", command: true, option: true))
    static let minimalTabBar = Self("minimalTabBar", "Minimal Tab Bar", .tabBar, Shortcut(key: "1", command: true, option: true))
    static let compactTabBar = Self("compactTabBar", "Compact Tab Bar", .tabBar, Shortcut(key: "2", command: true, option: true))
    static let wideTabBar   = Self("wideTabBar", "Wide Tab Bar", .tabBar, Shortcut(key: "3", command: true, option: true))

    // Bookmarks
    static let addBookmark  = Self("addBookmark", "Add Bookmark", .bookmarks, Shortcut(key: "d", command: true))
    // The deliberate "keep this one" gesture inside a research workspace,
    // next to Add Bookmark because it is the same instinct in a different register.
    static let captureSource = Self("captureSource", "Capture Source to Workspace", .bookmarks, Shortcut(key: "d", command: true, shift: true))
    // Phase 2 research commands. Anchor is capture's precise sibling, so it
    // lives on capture's chord plus Option. DEVIATION from phase2-design §6.1
    // (⌥⌘A, ⌥⌘N, ⌥⌘T all turned out taken): recorded in the design doc.
    static let anchorSelection = Self("anchorSelection", "Anchor Selection to Document", .bookmarks, Shortcut(key: "d", command: true, shift: true, option: true))
    static let newWorkspaceDocument = Self("newWorkspaceDocument", "New Workspace Document", .bookmarks, Shortcut(key: "n", command: true, control: true))
    static let transcriptPanel = Self("transcriptPanel", "Toggle Video Transcript", .page, Shortcut(key: "t", command: true, control: true))
    static let auditView = Self("auditView", "Graph & Audit View", .page, Shortcut(key: "g", command: true, control: true))
    static let bibliographySearch = Self("bibliographySearch", "Search Bibliography", .page, Shortcut(key: "b", command: true, control: true))
    static let claimsPanel = Self("claimsPanel", "Claims & Research Plan", .page, Shortcut(key: "c", command: true, control: true))
    static let importReport = Self("importReport", "Import Research Report", .page, Shortcut(key: "i", command: true, control: true))
    static let showBookmarks = Self("showBookmarks", "Show Bookmarks", .bookmarks, Shortcut(key: "b", command: true, shift: true))
    static let showHistory = Self("showHistory", "Show History", .bookmarks, Shortcut(key: "y", command: true))

    // App
    static let omnibar      = Self("omnibar", "Omnibar", .app, Shortcut(key: " ", control: true))
    static let quickOpen    = Self("quickOpen", "Quick Open", .app, Shortcut(key: "k", command: true))
    static let quickOpenNewTab = Self("quickOpenNewTab", "New Tab (Quick Open Alt)", .app, Shortcut(key: "k", command: true, option: true))
    static let tabGrid      = Self("tabGrid", "Show All Tabs", .tabs, Shortcut(key: "o", command: true))
    static let shortcutOverlay = Self("shortcutOverlay", "Keyboard Shortcuts", .app, Shortcut(key: "h", command: true, shift: true))
    static let settings     = Self("settings", "Settings", .app, Shortcut(key: ",", command: true))
    // ponytail: "/" not "?" — Shortcut.key is the unshifted character, so a
    // "?" default only ever matched an event that also carried ⇧ (it never did).
    static let help         = Self("help", "Help", .app, Shortcut(key: "/", command: true))
    static let extensionPopup = Self("extensionPopup", "Open Extension Popup", .app, Shortcut(key: "e", command: true, option: true))
    static let scratchPad = Self("scratchPad", "Scratch Pad", .app, Shortcut(key: "n", command: true, option: true))
    // Listed like any other command so it can be rebound — and so turning AI
    // features off can take it out of the overview (see availableOnCurrentPlatform).
    static let agentPanel = Self("agentPanel", "AI Agent", .app, Shortcut(key: "a", command: true, shift: true))
    #if os(macOS)
    static let windowLayout = Self("windowLayout", "Snap Window to Size", .app, Shortcut(key: "f", command: true, shift: true))
    // Arrow-key half-screen snapping. The key strings are the private-use
    // codes AppKit hands back via charactersIgnoringModifiers for the arrow
    // keys (NSUpArrowFunctionKey and friends) — see Shortcut.keyGlyph for the
    // matching display symbols. Repeat presses of the same arrow cycle
    // through smaller sizes at the same edge; see WindowLayout.snap.
    // ⌘⌥⌃ (not ⌘⇧) because ⇧ collides with AppKit's own text-editing
    // selection chords (⌘⇧←/→/↑/↓ select to line/document start/end) — a
    // menu-bound shortcut always wins that race over a focused text field,
    // native or in a web page, so the reserved arrow chords stay off ⇧.
    static let windowSnapLeft   = Self("windowSnapLeft", "Snap Window Left", .app, Shortcut(key: "\u{F702}", command: true, option: true, control: true))
    static let windowSnapRight  = Self("windowSnapRight", "Snap Window Right", .app, Shortcut(key: "\u{F703}", command: true, option: true, control: true))
    static let windowSnapTop    = Self("windowSnapTop", "Snap Window Top", .app, Shortcut(key: "\u{F700}", command: true, option: true, control: true))
    static let windowSnapBottom = Self("windowSnapBottom", "Snap Window Bottom", .app, Shortcut(key: "\u{F701}", command: true, option: true, control: true))
    #endif
    static let showDownloads = Self("showDownloads", "Show Downloads", .app, Shortcut(key: "j", command: true, shift: true))

    // Jump to tab 1–9 (generated; ids "switchTab1"…"switchTab9").
    static let switchTabs: [ShortcutCommand] = (1...9).map { i in
        Self("switchTab\(i)", "Show Tab \(i)", .tabs, Shortcut(key: "\(i)", command: true))
    }

    #if os(macOS)
    private static let screenshots: [ShortcutCommand] =
        [screenshotVisible, screenshotFullPage, screenshotElement, screenshotWindow]
    #else
    private static let screenshots: [ShortcutCommand] = [screenshotVisible, screenshotFullPage]
    #endif

    #if os(macOS)
    private static let platformCommands: [ShortcutCommand] =
        [showDownloads, windowLayout, windowSnapLeft, windowSnapRight, windowSnapTop, windowSnapBottom]
    #else
    private static let platformCommands: [ShortcutCommand] = [showDownloads]
    #endif

    static let all: [ShortcutCommand] =
        [newTab, closeTab, closeTabSet, reopenTab, nextTab, previousTab, newIncognitoTab]
        + switchTabs
        + screenshots
        + [openLocation, back, forward, reload, hardReload, reloadAll,
           findInPage, findNext, findPrevious, zoomIn, zoomOut, actualSize, printPage, exportPDF, fullScreen,
           toggleTranslation, translateInSplit, readerMode, toggleAutofill,
           toggleTabBar, hideTabBar, minimalTabBar, compactTabBar, wideTabBar,
           addBookmark, captureSource, anchorSelection, newWorkspaceDocument, transcriptPanel, auditView, bibliographySearch, claimsPanel, importReport,
           showBookmarks, showHistory, clearSiteData, convertToIncognito,
           omnibar, quickOpen, quickOpenNewTab, tabGrid, scratchPad, agentPanel, shortcutOverlay, settings, help, extensionPopup]
        + platformCommands

    static func by(id: String) -> ShortcutCommand? { all.first { $0.id == id } }

    // Commands that only exist because AI features do; Settings > AI Features
    // takes them out of every list the user can see.
    static let aiCommandIDs: Set<String> = [agentPanel.id]

    static var availableOnCurrentPlatform: [ShortcutCommand] {
        #if os(iOS)
        let commands = BrowserPlatformCommandRegistry.iPad.map(\.command)
        #else
        let commands = all
        #endif
        guard !SettingsManager.shared.aiFeaturesEnabled else { return commands }
        return commands.filter { !aiCommandIDs.contains($0.id) }
    }
}

// MARK: - Platform command registry

enum BrowserPlatformCommandGroup: Hashable {
    case file
    case go
    case view
    case bookmarks
    case tabs
}

enum BrowserPlatformCommandAction: Hashable {
    case newTab
    case newIncognitoTab
    case closeTab
    case closeTabSet
    case reopenTab
    case openLocation
    case back
    case forward
    case reload
    case hardReload
    case reloadAll
    case findInPage
    case findNext
    case findPrevious
    case printPage
    case exportPDF
    case toggleTranslation
    case translateInSplit
    case readerMode
    case screenshotVisible
    case screenshotFullPage
    case toggleSidebar
    case zoomIn
    case zoomOut
    case actualSize
    case settings
    case shortcutOverlay
    case addBookmark
    case captureSource
    case anchorSelection
    case newWorkspaceDocument
    case transcriptPanel
    case auditView
    case bibliographySearch
    case claimsPanel
    case importReport
    case showBookmarks
    case showHistory
    case showDownloads
    case scratchPad
    case clearSiteData
    case convertToIncognito
    case showAllTabs
    case nextTab
    case previousTab
    case switchTab(Int)
}

struct BrowserPlatformCommandEntry: Identifiable {
    var id: String { command.id }
    let group: BrowserPlatformCommandGroup
    let command: ShortcutCommand
    let action: BrowserPlatformCommandAction

    var notification: Notification.Name {
        switch action {
        case .newTab: .browserNewTab
        case .newIncognitoTab: .browserNewIncognitoTab
        case .closeTab: .browserCloseTab
        case .closeTabSet: .browserCloseTabSet
        case .reopenTab: .reopenLastClosedTab
        case .openLocation: .showOmnibar
        case .back: .browserGoBack
        case .forward: .browserGoForward
        case .reload: .browserReload
        case .hardReload: .browserHardReload
        case .reloadAll: .browserReloadAll
        case .findInPage: .browserFindInPage
        case .findNext: .browserFindNext
        case .findPrevious: .browserFindPrevious
        case .printPage: .browserPrint
        case .exportPDF: .browserExportPDF
        case .toggleTranslation: .browserToggleTranslation
        case .translateInSplit: .browserTranslateInSplit
        case .readerMode: .browserToggleReader
        case .screenshotVisible: .browserScreenshotVisible
        case .screenshotFullPage: .browserScreenshotFullPage
        case .toggleSidebar: .browserToggleTabBar
        case .zoomIn: .browserZoomIn
        case .zoomOut: .browserZoomOut
        case .actualSize: .browserZoomReset
        case .settings: .browserShowSettings
        case .shortcutOverlay: .browserToggleShortcutOverlay
        case .addBookmark: .browserAddBookmark
        case .captureSource: .browserCaptureSource
        case .anchorSelection: .browserAnchorSelection
        case .newWorkspaceDocument: .browserNewWorkspaceDocument
        case .transcriptPanel: .browserToggleTranscript
        case .auditView: .browserToggleAuditView
        case .bibliographySearch: .browserToggleBibliography
        case .claimsPanel: .browserToggleClaims
        case .importReport: .browserImportReport
        case .showBookmarks: .browserShowBookmarks
        case .showHistory: .browserShowHistory
        case .showDownloads: .browserShowDownloads
        case .scratchPad: .browserToggleScratchPad
        case .clearSiteData: .browserClearSiteData
        case .convertToIncognito: .browserConvertTabToIncognito
        case .showAllTabs: .browserShowTabGrid
        case .nextTab: .browserNextTab
        case .previousTab: .browserPreviousTab
        case .switchTab: .browserSwitchTab
        }
    }

    var userInfo: [AnyHashable: Any]? {
        guard case .switchTab(let index) = action else { return nil }
        return ["index": index]
    }
}

enum BrowserPlatformCommandRegistry {
    private static let iPadFileCommands: [BrowserPlatformCommandEntry] = [
        .init(group: .file, command: .newTab, action: .newTab),
        .init(group: .file, command: .newIncognitoTab, action: .newIncognitoTab),
        .init(group: .file, command: .closeTab, action: .closeTab),
        .init(group: .file, command: .closeTabSet, action: .closeTabSet),
        .init(group: .file, command: .reopenTab, action: .reopenTab),
        .init(group: .file, command: .openLocation, action: .openLocation),
        .init(group: .file, command: .printPage, action: .printPage),
        .init(group: .file, command: .exportPDF, action: .exportPDF),
        .init(group: .file, command: .screenshotVisible, action: .screenshotVisible),
        .init(group: .file, command: .screenshotFullPage, action: .screenshotFullPage),
        .init(group: .file, command: .showDownloads, action: .showDownloads),
        .init(group: .file, command: .clearSiteData, action: .clearSiteData),
        .init(group: .file, command: .convertToIncognito, action: .convertToIncognito),
    ]

    private static let iPadGoCommands: [BrowserPlatformCommandEntry] = [
        .init(group: .go, command: .back, action: .back),
        .init(group: .go, command: .forward, action: .forward),
        .init(group: .go, command: .reload, action: .reload),
        .init(group: .go, command: .hardReload, action: .hardReload),
        .init(group: .go, command: .reloadAll, action: .reloadAll),
        .init(group: .go, command: .findInPage, action: .findInPage),
        .init(group: .go, command: .findNext, action: .findNext),
        .init(group: .go, command: .findPrevious, action: .findPrevious),
    ]

    private static let iPadViewCommands: [BrowserPlatformCommandEntry] = [
        .init(group: .view, command: .toggleTabBar, action: .toggleSidebar),
        .init(group: .view, command: .scratchPad, action: .scratchPad),
        .init(group: .view, command: .zoomIn, action: .zoomIn),
        .init(group: .view, command: .zoomOut, action: .zoomOut),
        .init(group: .view, command: .actualSize, action: .actualSize),
        .init(group: .view, command: .settings, action: .settings),
        .init(group: .view, command: .shortcutOverlay, action: .shortcutOverlay),
        .init(group: .view, command: .toggleTranslation, action: .toggleTranslation),
        .init(group: .view, command: .translateInSplit, action: .translateInSplit),
        .init(group: .view, command: .readerMode, action: .readerMode),
    ]

    private static let iPadBookmarkCommands: [BrowserPlatformCommandEntry] = [
        .init(group: .bookmarks, command: .addBookmark, action: .addBookmark),
        .init(group: .bookmarks, command: .captureSource, action: .captureSource),
        .init(group: .bookmarks, command: .anchorSelection, action: .anchorSelection),
        .init(group: .bookmarks, command: .newWorkspaceDocument, action: .newWorkspaceDocument),
        .init(group: .bookmarks, command: .transcriptPanel, action: .transcriptPanel),
        .init(group: .bookmarks, command: .auditView, action: .auditView),
        .init(group: .bookmarks, command: .bibliographySearch, action: .bibliographySearch),
        .init(group: .bookmarks, command: .claimsPanel, action: .claimsPanel),
        .init(group: .bookmarks, command: .importReport, action: .importReport),
        .init(group: .bookmarks, command: .showBookmarks, action: .showBookmarks),
        .init(group: .bookmarks, command: .showHistory, action: .showHistory),
    ]

    private static let iPadTabCommands: [BrowserPlatformCommandEntry] = [
        .init(group: .tabs, command: .tabGrid, action: .showAllTabs),
        .init(group: .tabs, command: .nextTab, action: .nextTab),
        .init(group: .tabs, command: .previousTab, action: .previousTab),
    ]

    private static let iPadSwitchTabCommands: [BrowserPlatformCommandEntry] =
        ShortcutCommand.switchTabs.enumerated().map { index, command in
        .init(group: .tabs, command: command, action: .switchTab(index + 1))
    }

    static let iPad: [BrowserPlatformCommandEntry] =
        iPadFileCommands
        + iPadGoCommands
        + iPadViewCommands
        + iPadBookmarkCommands
        + iPadTabCommands
        + iPadSwitchTabCommands

    static func iPadEntries(in group: BrowserPlatformCommandGroup) -> [BrowserPlatformCommandEntry] {
        iPad.filter { $0.group == group }
    }

    static var iPadNotificationNames: [Notification.Name] {
        iPad.reduce(into: []) { names, entry in
            if !names.contains(entry.notification) {
                names.append(entry.notification)
            }
        }
    }

    static func iPadEntry(
        notification: Notification.Name,
        userInfo: [AnyHashable: Any]?
    ) -> BrowserPlatformCommandEntry? {
        let index = userInfo?["index"] as? Int
        return iPad.first { entry in
            guard entry.notification == notification else { return false }
            switch entry.action {
            case .switchTab(let entryIndex): return entryIndex == index
            default: return true
            }
        }
    }
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
    // Every chord currently in use, so a ⌃ twin never steals a real binding.
    private var boundShortcuts: Set<Shortcut> = []

    private init() { load(); rebuildBound() }

    func shortcut(for command: ShortcutCommand) -> Shortcut {
        custom[command.id] ?? command.defaultShortcut
    }

    /// Automatic backup chord: ⌘R also answers to ⌃R, unless that chord is
    /// already spoken for. Lets a page that hijacks the ⌘ combo be worked around
    /// without rebinding anything.
    func alternate(for command: ShortcutCommand) -> Shortcut? {
        guard Self.twinEligible.contains(command.id),
              let twin = shortcut(for: command).controlTwin,
              !boundShortcuts.contains(twin),
              systemConflict(twin) == nil else { return nil }
        return twin
    }

    // Only commands the local event monitor dispatches can honor a twin — a
    // menu item carries exactly one key equivalent.
    private static var twinEligible: Set<String> {
        Set(ShortcutPriorityStore.contestable.map(\.id) + [ShortcutCommand.omnibar.id])
    }

    private func rebuildBound() {
        boundShortcuts = Set(ShortcutCommand.availableOnCurrentPlatform.map { shortcut(for: $0) })
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
        for command in ShortcutCommand.availableOnCurrentPlatform {
            seen[shortcut(for: command), default: []].append(command)
        }
        return seen.values.filter { $0.count > 1 }.flatMap { $0 }
    }

    func commandsSharing(_ shortcut: Shortcut, excluding command: ShortcutCommand) -> [ShortcutCommand] {
        ShortcutCommand.availableOnCurrentPlatform.filter {
            $0.id != command.id && self.shortcut(for: $0) == shortcut
        }
    }

    // Display projection for the cheat sheet, grouped and ordered by section.
    var groupedForDisplay: [(section: ShortcutSection, commands: [ShortcutCommand])] {
        ShortcutSection.allCases.compactMap { section in
            let commands = ShortcutCommand.availableOnCurrentPlatform.filter { $0.section == section }
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
        rebuildBound()
    }
}

#if canImport(AppKit)
extension ShortcutStore {
    // Does this event fire the command — via its chord or its ⌃ backup?
    func matches(_ event: NSEvent, _ command: ShortcutCommand) -> Bool {
        shortcut(for: command).matches(event) || alternate(for: command)?.matches(event) == true
    }
}
#endif

// MARK: - Website shortcut priority

// Who wins a chord that both we and the page want.
//
// AppKit gives the key window's view tree performKeyEquivalent: before the main
// menu, and WKWebView answers it by handing the key to the web process — so a
// page that preventDefault()s ⌘T takes New Tab away and the menu item never
// fires. The local event monitor runs earlier than any of that, so it's the one
// place we can win. This store says which commands it should claim there:
// per host if there's an entry, else globally, else the default below.
@Observable
final class ShortcutPriorityStore {
    static let shared = ShortcutPriorityStore()

    // Commands the monitor can claim. Everything else stays menu-only — a menu
    // item is enough when no page competes for the chord.
    static let contestable: [ShortcutCommand] = [
        .newTab, .closeTab, .closeTabSet, .reopenTab, .nextTab, .previousTab,
        .reload, .hardReload, .reloadAll, .back, .forward,
        .openLocation, .findInPage, .addBookmark, .printPage, .quickOpen,
        .toggleTabBar,
    ]

    // Browser chrome you'd never want a page to eat. The rest (find, print,
    // Quick Open, address bar) start off, because plenty of web apps have a
    // legitimate claim on ⌘F/⌘P/⌘K — turn them on per site when one doesn't.
    static let defaultWins: Set<String> = [
        ShortcutCommand.newTab.id, ShortcutCommand.closeTab.id, ShortcutCommand.closeTabSet.id,
        ShortcutCommand.reopenTab.id, ShortcutCommand.nextTab.id, ShortcutCommand.previousTab.id,
        ShortcutCommand.reload.id, ShortcutCommand.hardReload.id, ShortcutCommand.reloadAll.id,
        ShortcutCommand.back.id, ShortcutCommand.forward.id,
        ShortcutCommand.toggleTabBar.id,
    ]

    private static let globalKey = "shortcutPriorityGlobal"
    private static let hostKey = "shortcutPriorityByHost"

    private(set) var global: [String: Bool] = [:]
    private(set) var byHost: [String: [String: Bool]] = [:]

    // The host of the page that last saw a keystroke, so Settings can offer
    // "this site" without plumbing the active tab across windows.
    // ponytail: the monitor already looks the host up on every key event.
    var currentHost: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        global = (defaults.dictionary(forKey: Self.globalKey) as? [String: Bool]) ?? [:]
        byHost = (defaults.dictionary(forKey: Self.hostKey) as? [String: [String: Bool]]) ?? [:]
    }

    // "www.example.com" and "Example.com" are the same site to a person.
    static func normalize(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Should the monitor claim this chord before the page sees it?
    func browserWins(_ command: ShortcutCommand, host: String? = nil) -> Bool {
        if let host = Self.normalize(host), let perSite = byHost[host]?[command.id] { return perSite }
        if let value = global[command.id] { return value }
        #if os(macOS)
        // Quick Open shipped with its own toggle before this store existed.
        if command.id == ShortcutCommand.quickOpen.id {
            return SettingsManager.shared.overrideWebsiteQuickOpen
        }
        #endif
        return Self.defaultWins.contains(command.id)
    }

    /// The explicit setting at this level, or nil when it inherits.
    func override(for command: ShortcutCommand, host: String? = nil) -> Bool? {
        guard let host = Self.normalize(host) else { return global[command.id] }
        return byHost[host]?[command.id]
    }

    /// Pass nil to clear the override and inherit the level above.
    func set(_ value: Bool?, for command: ShortcutCommand, host: String? = nil) {
        if let host = Self.normalize(host) {
            byHost[host, default: [:]][command.id] = value
            if byHost[host]?.isEmpty ?? false { byHost.removeValue(forKey: host) }
        } else {
            global[command.id] = value
        }
        persist()
    }

    var customizedHosts: [String] { byHost.keys.sorted() }

    func clear(host: String) {
        guard let host = Self.normalize(host) else { return }
        byHost.removeValue(forKey: host)
        persist()
    }

    func resetAll() {
        global.removeAll()
        byHost.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(global, forKey: Self.globalKey)
        defaults.set(byHost, forKey: Self.hostKey)
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
        for command in ShortcutCommand.availableOnCurrentPlatform where command.section == section {
            if command.id.hasPrefix("switchTab") {
                guard !addedTabSummary else { continue }
                addedTabSummary = true
                let lo = shortcut(for: ShortcutCommand.switchTabs.first!).displayString
                let hi = shortcut(for: ShortcutCommand.switchTabs.last!).displayString
                rows.append(CheatRow(id: "switchTabs", title: "Jump to Tab 1–9", keys: "\(lo) – \(hi)", shortcut: nil))
                continue
            }
            let s = shortcut(for: command)
            var keys = s.displayString
            if let alt = alternate(for: command) { keys += " / \(alt.displayString)" }
            #if os(macOS)
            if command == .shortcutOverlay { keys += " / ⇧⌘K" }
            #endif
            rows.append(CheatRow(id: command.id, title: command.title, keys: keys, shortcut: s))
        }
        if section == .tabs {
            // Not rebindable commands — mouse gestures and the omnibar's modified
            // Return, documented here so they're discoverable
            rows.append(CheatRow(id: "splitPane", title: "Open Link in Split Pane", keys: "⌥Click", shortcut: nil))
            rows.append(CheatRow(id: "newspaperLink", title: "Add Link to Newspaper", keys: "⇧Click", shortcut: nil))
            rows.append(CheatRow(id: "omnibarNewTab", title: "Omnibar: Open in New Tab", keys: "⇧Return", shortcut: nil))
            rows.append(CheatRow(id: "omnibarSplitPane", title: "Omnibar: Open in Split Pane", keys: "⌘Return", shortcut: nil))
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
            var overrides = [
                ShortcutCommand.fullScreen.id: fullScreenCtrlCmd,
                ShortcutCommand.toggleTabBar.id: Shortcut(key: "s", command: true), // toggle sidebar
            ]
            #if os(macOS)
            // Arc's ⌘S is the sidebar, which is our Screenshot Visible Area —
            // move the screenshot rather than hand the preset a live conflict.
            overrides[ShortcutCommand.screenshotVisible.id] = Shortcut(key: "s", command: true, control: true)
            #endif
            return overrides
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
        Shortcut(key: "w", command: true, shift: true): "Close Window",
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
        // ⌘R gets a ⌃R backup; ⌘[ doesn't (⌃[ is Escape / text editing), but
        // ⇧⌘[ does. Menu-owned commands are never eligible.
        assert(Shortcut(key: "r", command: true).controlTwin?.displayString == "⌃R")
        assert(Shortcut(key: "[", command: true).controlTwin == nil)
        assert(Shortcut(key: "[", command: true, shift: true).controlTwin?.displayString == "⌃⇧[")
        assert(Shortcut(key: "r", control: true).controlTwin == nil, "no twin of a twin")
        assert(!twinEligible.contains(ShortcutCommand.showBookmarks.id), "menu-only commands get no twin")
        // No two defaults collide.
        var seen = Set<Shortcut>()
        for c in ShortcutCommand.all {
            assert(seen.insert(c.defaultShortcut).inserted, "duplicate default: \(c.id) \(c.defaultShortcut.displayString)")
        }
    }
}
#endif
