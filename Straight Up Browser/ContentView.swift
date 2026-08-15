//
//  ContentView.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import SwiftData
import AppKit
import WebKit
import Combine
import Translation
import UniformTypeIdentifiers

// Type alias to disambiguate our Tab model from SwiftUI's Tab view
typealias BrowserTab = Tab

// A favicon is either a tile that paints its own corners — sharp, rounded, or
// squircled — or a glyph floating on transparency. The selection ring traces
// whichever it is, so measure the tile's corner radius rather than guessing.
enum FaviconShape {
    // ponytail: plain dictionary, read/written from SwiftUI body on the main
    // thread only. Make it an NSCache if it ever gets touched off-main.
    private static var known = [Data: CGFloat]()

    /// Corner radius as a fraction of the icon's side: 0 for a hard-edged tile,
    /// 0.5 for a circle — which is also the answer for a glyph on transparency,
    /// bytes we can't decode, and no favicon at all.
    static func cornerRadiusFraction(_ data: Data?) -> CGFloat {
        guard let data else { return 0.5 }
        if let cached = known[data] { return cached }
        let fraction = measure(data)
        known[data] = fraction
        return fraction
    }

    // Walk in from each corner along the diagonal to the first pixel that's more
    // painted than not. On a rounded rect of radius r that pixel sits r·(1 − 1/√2)
    // from the corner, so the length of the walk gives back r.
    private static func measure(_ data: Data) -> CGFloat {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 3, rep.pixelsHigh > 3 else {
            return 0.5
        }
        let side = CGFloat(min(rep.pixelsWide, rep.pixelsHigh))
        // A circle leaves a 0.146·side diagonal gap; a deeper one isn't a tile.
        let limit = Int(side * 0.16) + 1
        var deepest = 0
        for (fromLeft, fromTop) in [(true, true), (false, true), (true, false), (false, false)] {
            guard let gap = (0...limit).first(where: { k in
                let x = fromLeft ? k : rep.pixelsWide - 1 - k
                let y = fromTop ? k : rep.pixelsHigh - 1 - k
                return (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            }) else { return 0.5 }
            deepest = max(deepest, gap)
        }
        return min(0.5, CGFloat(deepest) / (1 - 1 / 2.0.squareRoot()) / side)
    }
}

private struct FloatingDownloadRings: View {
    let downloads: [ActiveDownload]

    var body: some View {
        ForEach(Array(downloads.enumerated()), id: \.element.id) { layer, transfer in
            let diameter = CGFloat(28 + min(layer, 4) * 3)
            Circle()
                .trim(from: 0, to: max(0.015, transfer.progress))
                .stroke(
                    DownloadVisuals.color(for: transfer.colorIndex),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
        }
    }
}

private struct FloatingFaviconItem: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let tab: BrowserTab
    let isSelected: Bool
    let isInSplit: Bool
    let downloads: [ActiveDownload]
    let onSelect: () -> Void
    let onReorder: ((UUID, UUID) -> Void)?
    let onDragBegan: (UUID) -> Void
    let onDropFinished: () -> Void
    let draggedTabId: UUID?
    let dropTargetTabId: UUID?
    let automaticLinkBirthCue: AutomaticLinkBirthCue?

    private let cell: CGFloat = 26
    private var isBeingDragged: Bool { draggedTabId == tab.id }
    private var isDropTarget: Bool { draggedTabId != nil && dropTargetTabId == tab.id && !isBeingDragged }

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                faviconBackground
                favicon
                FloatingDownloadRings(downloads: downloads)
            }
            .frame(width: cell, height: cell)
        }
        .buttonStyle(.plain)
        .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Select this tab")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onDrag {
            Logger.log("FloatingFaviconOverlay onDrag called for tab: \(tab.id)", type: "ContentView")
            onDragBegan(tab.id)
            return tabDragItemProvider(for: tab.id)
        }
        .onDrop(
            of: [.straightUpBrowserTab],
            delegate: TabDropDelegate(
                tabId: tab.id,
                draggedTabId: draggedTabId,
                onReorder: onReorder,
                onDropFinished: onDropFinished
            )
        )
        .contentShape(Rectangle())
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: ringRadius)
                    .stroke(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: cell + 4, height: cell + 4)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(isBeingDragged ? 1.12 : 1)
        .opacity(isBeingDragged ? 0.62 : 1)
        .zIndex(isBeingDragged ? 2 : (isDropTarget ? 1 : 0))
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.68),
                   value: isBeingDragged)
        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.74),
                   value: isDropTarget)
        .automaticLinkMitosis(cue: automaticLinkBirthCue, tabId: tab.id)
    }

    private var ringRadius: CGFloat {
        FaviconShape.cornerRadiusFraction(tab.favicon) * cell
    }

    private var inset: CGFloat { isSelected ? 1 : 0.5 }

    private var faviconBackground: some View {
        RoundedRectangle(cornerRadius: ringRadius)
            .fill(Color(.windowBackgroundColor))
            .frame(width: cell, height: cell)
            .overlay(
                RoundedRectangle(cornerRadius: max(0, ringRadius - inset))
                    .stroke(
                        isSelected ? Color.blue : Color.gray.opacity(0.4),
                        lineWidth: isSelected ? 2 : 1
                    )
                    .padding(inset)
            )
    }

    @ViewBuilder
    private var favicon: some View {
        if let faviconData = tab.favicon, let nsImage = NSImage(data: faviconData) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .clipped()
        } else if tab.url != nil {
            Image(systemName: "globe")
                .font(.system(size: 14))
                .foregroundColor(.primary)
        } else {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundColor(.primary)
        }
    }

    private var accessibilityLabel: String {
        BrowserAccessibility.tabLabel(
            title: tab.title,
            url: tab.url,
            sessionKind: tab.sessionKind,
            isPinned: tab.isPinned,
            isInSplit: isInSplit
        )
    }

    private var accessibilityValue: String {
        BrowserAccessibility.tabValue(
            isSelected: isSelected,
            isLoading: false,
            loadProgress: 0,
            activeDownloadCount: downloads.count
        )
    }
}

// Floating favicon overlay for compact mode
struct FloatingFaviconOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let tabs: [BrowserTab]
    let selectedTabId: UUID?
    let onTabSelect: (UUID) -> Void
    let onReorder: ((UUID, UUID) -> Void)?
    let tabManager: TabManager?
    let downloads: [ActiveDownload]
    let draggedTabId: UUID?
    let dropTargetTabId: UUID?
    let onDragBegan: (UUID) -> Void
    let onDropFinished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tabs) { tab in
                let isSelected = (tabManager?.selectedTabId ?? selectedTabId) == tab.id
                let isInSplit = tabManager?.splitTabIds.contains(tab.id) ?? false
                let tabDownloads = downloads.filter { $0.tabId == tab.id }

                FloatingFaviconItem(
                    tab: tab,
                    isSelected: isSelected,
                    isInSplit: isInSplit,
                    downloads: tabDownloads,
                    onSelect: { onTabSelect(tab.id) },
                    onReorder: onReorder,
                    onDragBegan: onDragBegan,
                    onDropFinished: onDropFinished,
                    draggedTabId: draggedTabId,
                    dropTargetTabId: dropTargetTabId,
                    automaticLinkBirthCue: tabManager?.automaticLinkBirthCue
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .tabPoof
                ))
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 3)
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8),
            value: tabs.map(\.id)
        )
    }
}

private struct TabDownloadBars: View {
    let downloads: [ActiveDownload]

    var body: some View {
        VStack(spacing: 1) {
            ForEach(downloads) { transfer in
                GeometryReader { geometry in
                    let color = DownloadVisuals.color(for: transfer.colorIndex)
                    ZStack(alignment: .leading) {
                        color.opacity(0.18)
                        color.opacity(transfer.state == .downloading ? 0.9 : 0.55)
                            .frame(width: geometry.size.width * max(0.015, transfer.progress))
                        HStack(spacing: 6) {
                            Text(transfer.filename)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(
                                transfer.state == .downloading
                                    ? "\(Int(transfer.progress * 100))%"
                                    : transfer.state.label
                            )
                            .monospacedDigit()
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5)
                    }
                }
                .frame(height: 14)
            }
        }
        .background(.ultraThinMaterial)
    }
}

// Workspace data structures for persistence
struct SavedWorkspace: Codable, Identifiable {
    let id: UUID
    let name: String
    let createdAt: Date
    let groups: [SavedTabGroup]
    let tabs: [SavedWorkspaceTab]

    init(name: String, groups: [TabGroup], tabs: [BrowserTab]) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.groups = groups.map { SavedTabGroup(from: $0) }
        self.tabs = tabs.map { SavedWorkspaceTab(from: $0) }
    }
}

struct SavedTabGroup: Codable {
    let id: UUID
    let name: String
    let colorHex: String
    let orderIndex: Int

    init(from group: TabGroup) {
        self.id = group.id
        self.name = group.name
        self.colorHex = group.colorHex
        self.orderIndex = group.orderIndex
    }
}

struct SavedWorkspaceTab: Codable {
    let id: UUID
    let title: String
    let urlString: String?
    let groupId: UUID?
    let isPinned: Bool
    let isMuted: Bool
    let zoomLevel: Double
    let orderIndex: Int
    // Optional so workspaces saved before container support decode as normal tabs.
    let sessionKind: SessionKind?
    let sessionId: UUID?

    init(from tab: Tab) {
        self.id = tab.id
        self.title = tab.title
        self.urlString = tab.url?.absoluteString
        self.groupId = tab.groupId
        self.isPinned = tab.isPinned
        self.isMuted = tab.isMuted
        self.zoomLevel = tab.zoomLevel
        self.orderIndex = tab.orderIndex
        self.sessionKind = tab.sessionKind == .normal ? nil : tab.sessionKind
        self.sessionId = tab.sessionId
    }

    func makeTab() -> Tab {
        let tab = Tab(title: title, url: urlString.flatMap(URL.init(string:)), isActive: false)
        tab.id = id
        tab.groupId = groupId
        tab.isPinned = isPinned
        tab.isMuted = isMuted
        tab.zoomLevel = zoomLevel
        tab.orderIndex = orderIndex
        tab.sessionKind = sessionKind ?? .normal
        tab.sessionId = sessionId
        return tab
    }
}

/// Where the find bar sits and how loudly it flashes a match. Shared by the bar itself
/// (ContentView) and the controls in Settings.
enum FindBar {
    static let positionKey = "findBarPosition"
    static let intensityKey = "findFlashIntensity"
    static let defaultPosition = "Top Right"
    static let defaultIntensity = 25.0
    static let positions = ["Top Left", "Top Right", "Left Side", "Right Side", "Bottom Left", "Bottom Right"]

    /// Next 1-based match position, wrapping in both directions. `index` 0 means "haven't landed yet".
    static func step(index: Int, count: Int, backwards: Bool) -> Int {
        guard count > 0 else { return 0 }
        if backwards { return index <= 1 ? count : index - 1 }
        return index >= count ? 1 : index + 1
    }

    static func alignment(_ position: String) -> Alignment {
        switch position {
        case "Top Left": return .topLeading
        case "Left Side": return .leading
        case "Right Side": return .trailing
        case "Bottom Left": return .bottomLeading
        case "Bottom Right": return .bottomTrailing
        default: return .topTrailing
        }
    }
}

private enum ContentAccessibilityFocus: Hashable {
    case page
    case omnibar
    case library
    case reader
}

private enum ContentModal: Identifiable, Equatable {
    case library
    case reader(ReaderArticle)

    var id: String {
        switch self {
        case .library: "library"
        case .reader: "reader"
        }
    }
}

private struct ReaderBlockRow: View {
    let block: ReaderBlock

    @ViewBuilder
    var body: some View {
        switch block {
        case .heading(let level, let runs):
            Text(attributedText(for: runs))
                .font(headingFont(level))
                .fontWeight(.semibold)
                .accessibilityHeading(headingLevel(level))
                .padding(.top, level <= 2 ? 14 : 8)
        case .paragraph(let runs):
            Text(attributedText(for: runs))
        case .listItem(let ordered, let ordinal, let depth, let runs):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ordered ? "\(ordinal ?? 1)." : "•")
                    .fontWeight(.semibold)
                    .frame(width: 30, alignment: .trailing)
                    .accessibilityHidden(true)
                Text(attributedText(for: runs))
            }
            .padding(.leading, CGFloat(depth) * 24)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                ordered
                    ? "Item \(ordinal ?? 1), \(runs.map(\.text).joined())"
                    : "List item, \(runs.map(\.text).joined())"
            )
        case .quote(let runs):
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 4)
                    .accessibilityHidden(true)
                Text(attributedText(for: runs))
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 15, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Code block")
            .accessibilityValue(code)
        case .caption(let runs):
            Text(attributedText(for: runs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("Caption, \(runs.map(\.text).joined())")
        }
    }

    private func attributedText(for runs: [ReaderInline]) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var fragment = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.isStrong {
                intent.insert(.stronglyEmphasized)
            }
            if run.isEmphasized {
                intent.insert(.emphasized)
            }
            if run.isCode {
                intent.insert(.code)
            }
            if !intent.isEmpty {
                fragment.inlinePresentationIntent = intent
            }
            fragment.link = run.link
            result.append(fragment)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        case 4: .headline
        case 5: .subheadline
        default: .caption
        }
    }

    private func headingLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \BrowserTab.orderIndex) private var tabs: [BrowserTab]
    @Query(sort: \TabGroup.orderIndex) private var tabGroups: [TabGroup]
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var allBookmarks: [Bookmark]
    @Query(sort: \NewspaperArticle.addedAt, order: .reverse)
    private var newspaperArticles: [NewspaperArticle]
    @Query(sort: \BrowserSession.createdAt) private var browserSessions: [BrowserSession]

    // Managers
    @StateObject private var tabManager: TabManager
    @StateObject private var linkPreview = LinkPreviewManager()
    @StateObject private var autofill = AutofillManager()
    @StateObject private var pageTranslator = PageTranslator()
    @StateObject private var fastForward = FastForward()
    @StateObject private var browserAgent: BrowserAgent
    @ObservedObject private var downloadManager = DownloadManager.shared
    #if os(macOS)
    @ObservedObject private var autofillContactsRoster = AutofillContactsRoster.shared
    #endif
    @ObservedObject private var persistenceDiagnostics = PersistenceDiagnostics.shared
    @ObservedObject private var protectionStore = PageProtectionStore.shared
    @State private var navigationManager: NavigationManager?
    @State private var notificationManager: NotificationManager?
    @State private var keyboardShortcutsManager: KeyboardShortcutsManager?
    @State private var bookmarkManager: BookmarkManager?
    @State private var webViewManager: WebViewManager?
    @State private var managersInitialized = false

    // UI State
    @State private var showOmnibar = false
    @State private var showTabGrid = false
    @State private var showAgentPanel = false
    @AppStorage(AgentSettingsRuntimeKey.adjustsPageLayout) private var agentAdjustsPageLayout = false
    @AppStorage(AgentSettingsRuntimeKey.loadsMorePageContent) private var agentLoadsMorePageContent = true
    @AppStorage(AgentSettingsRuntimeKey.panelSide) private var agentPanelSideRaw = BrowserChromeSide.left.rawValue
    @State private var agentLassoSelection: AgentLassoSelection?
    @State private var showDeveloperTools = false
    @StateObject private var developerTools = DeveloperToolsModel()
    @AppStorage(DeveloperToolsPlacement.defaultsKey) private var developerToolsPlacementRaw = DeveloperToolsPlacement.bottom.rawValue
    @State private var showFindBar = false
    @State private var findText = ""
    @State private var findMatchIndex = 0 // 1-based position of the current match, 0 before the first hit
    @State private var findMatchCount = 0
    @AppStorage(FindBar.positionKey) private var findBarPosition = FindBar.defaultPosition
    @AppStorage(FindBar.intensityKey) private var findFlashIntensity = FindBar.defaultIntensity
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var currentTitle = ""
    @State private var isLoading = false
    @State private var isImportBookmarksDialogPresented = false
    @State private var availableBrowsers: [BrowserType] = []
    @State private var librarySection = BrowserLibrarySection.bookmarks
    @State private var contentModal: ContentModal?
    @AccessibilityFocusState private var accessibilityFocus: ContentAccessibilityFocus?
    @State private var showCreateGroupDialog = false
    @State private var newGroupName = ""
    @State private var newGroupColor = Color.blue
    @State private var showCreateContainerDialog = false
    @State private var newContainerName = ""
    @State private var newContainerColor = Color.purple
    @State private var showWorkspaceMenu = false
    @State private var showSaveWorkspaceDialog = false
    @State private var workspaceName = ""
    @State private var savedWorkspaces: [SavedWorkspace] = []
    @AppStorage("tabBarWidth") private var tabBarWidth: Double = 200.0
    @AppStorage(BrowserChromePlacementSettings.Key.tabSidebarSide) private var tabSidebarSideRaw = BrowserChromeSide.left.rawValue
    @State private var tabBarResizeStartWidth: Double?
    @AppStorage("showTraditionalTopTabs") private var showTraditionalTopTabs = false
    @AppStorage("topTabsAutoHide") private var topTabsAutoHide = true
    @AppStorage("adaptiveLargeSidebarTabs") private var adaptiveLargeSidebarTabs = true
    @State private var topTabsRevealed = false

    // Force view updates when tab selection changes
    @State private var tabSelectionRefreshTrigger = UUID()
    @State private var tabTitleDisplayRefreshTrigger = UUID()
    @State private var sidebarDraggedTabId: UUID?
    @State private var sidebarDropTargetTabId: UUID?
    @State private var sidebarLastCrossedTabId: UUID?
    @State private var sidebarDragMonitorTask: Task<Void, Never>?

    // Progress Bar State
    @State private var showProgressBar = false
    @State private var progressValue: Double = 0.0
    @State private var hasRenderedContent = false

    // Which window edges show the load progress bar (any combination)
    @AppStorage("progressBarTop") private var progressBarTop = true
    @AppStorage("progressBarBottom") private var progressBarBottom = false
    @AppStorage("progressBarLeft") private var progressBarLeft = false
    @AppStorage("progressBarRight") private var progressBarRight = false
    // Show progress as a ring around the favicon in the tab bar
    @AppStorage("progressFaviconRing") private var progressFaviconRing = false

    // Memory saving: release background tabs from RAM under memory pressure
    @AppStorage("memorySaverEnabled") private var memorySaverEnabled = false
    @AppStorage("javaScriptEnabled") private var javaScriptEnabled = true
    @AppStorage("adBlockEnabled") private var adBlockEnabled = false

    // Hold-Cmd+Q-to-quit HUD. quitHoldActive gates the overlay; quitHoldProgress
    // is animated 0→1 by Core Animation over the hold duration.
    @State private var quitHoldProgress: Double = 0
    @State private var quitHoldActive = false

    // Cmd+Shift+H shortcut cheat sheet
    @State private var showShortcutCheatSheet = false

    // Favicon peek shown when the active tab changes while the tab bar is hidden.
    @State private var showFaviconPeek = false
    @State private var faviconPeekTask: Task<Void, Never>?

    // Shutter flash marking what a screenshot just captured.
    @State private var flashRect: CGRect?
    @State private var flashOpacity: Double = 0

    // Autofill: the ⌥⌘A confirmation HUD, and the saved profiles the sidebar and
    // menu-bar autofill menus offer.
    @State private var autofillHUD: String?
    @State private var autofillHUDTask: Task<Void, Never>?
    @Query(sort: \AutofillProfile.createdAt) private var autofillProfiles: [AutofillProfile]

    /// Reading `displayName` here is what makes a renamed profile reach the menus:
    /// it registers observation on the underlying fields.
    private var autofillProfileSummaries: [AutofillProfileSummary] {
        #if os(macOS)
        let contacts = autofillContactsRoster.people.map {
            AutofillProfileSummary(person: $0.reference, name: $0.name)
        }
        #else
        let contacts: [AutofillProfileSummary] = []
        #endif
        return contacts + autofillProfiles.map {
            AutofillProfileSummary(person: .manual($0.id), name: $0.displayName)
        }
    }

    private var currentURL: URL? { activeTab?.url }

    private var agentPanelSide: BrowserChromeSide {
        BrowserChromeSide(rawValue: agentPanelSideRaw) ?? .left
    }

    private var tabSidebarSide: BrowserChromeSide {
        BrowserChromeSide(rawValue: tabSidebarSideRaw) ?? .left
    }

    private var effectiveTabSidebarWidth: CGFloat {
        guard tabBarWidth > 0 else { return 0 }
        return tabBarWidth <= 30 ? 32 : max(80, tabBarWidth)
    }

    private func reservedChromeWidth(on side: BrowserChromeSide) -> CGFloat {
        BrowserChromeLayout.reservedWidth(
            on: side,
            tabWidth: effectiveTabSidebarWidth,
            tabSide: tabSidebarSide,
            agentVisible: showAgentPanel,
            agentResizesPage: agentAdjustsPageLayout,
            agentWidth: BrowserAgentPanel.width,
            agentSide: agentPanelSide
        )
    }

    private var currentAgentPageTarget: AgentPageTarget? {
        guard let tab = activeTab, let manager = notificationManager, let url = tab.url,
              let scheme = url.scheme, let host = url.host else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        let session: AgentBrowserSession = switch tab.sessionKind {
        case .normal: .normal
        case .incognito: .incognito
        case .container: tab.sessionId.map(AgentBrowserSession.container) ?? .normal
        }
        return AgentPageTarget(
            pageID: "\(manager.automationWindowId.uuidString):\(tab.id.uuidString)",
            origin: "\(scheme.lowercased())://\(host.lowercased())\(port)",
            session: session
        )
    }

    private var pageProtectionSummary: PageProtectionSummary? {
        guard let tab = activeTab, tab.url != nil else { return nil }
        return PageProtectionSummary(
            securityLevel: tab.securityLevel,
            contentBlocking: .resolve(
                enabled: adBlockEnabled,
                active: protectionStore.isContentBlockingActive(for: tab.id)
            ),
            javaScriptEnabled: javaScriptEnabled
        )
    }



    init() {
        // CLI is now initialized lazily when first used
        _tabManager = StateObject(wrappedValue: TabManager())
        _browserAgent = StateObject(wrappedValue: BrowserAgent())
    }

    // MARK: - Memory pressure

    private func handleMemoryPressure(critical: Bool) {
        guard memorySaverEnabled else {
            maybeNudgeMemorySaver()
            return
        }
        // Exempt every displayed tab: in a split, the non-focused panes are
        // visible too and must not go blank under pressure.
        let displayed = displayedTabIds
        for tab in tabs where !displayed.contains(tab.id)
            && BrowserResourcePolicy.shouldUnload(tab.memoryPolicy, critical: critical) {
            webViewManager?.unloadWebView(for: tab.id)
        }
    }

    // At most once a week, when memory is tight and the feature is off, offer to enable it.
    private func maybeNudgeMemorySaver() {
        let key = "memorySaverPromptLastShown"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 24 * 3600 else { return }
        UserDefaults.standard.set(Date(), forKey: key)

        let alert = NSAlert()
        alert.messageText = String(localized: "Running low on memory?")
        alert.informativeText = String(localized: "Browser can free up RAM by releasing background tabs you're not using and reloading them instantly when you return. You choose which tabs stay live. Turn on Memory Saving?")
        alert.addButton(withTitle: String(localized: "Enable Memory Saving"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                UserDefaults.standard.set(true, forKey: "memorySaverEnabled")
            }
        }
        if let window = webViewManager?.activeWebView?.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }



    private var bookmarks: [Bookmark] {
        return bookmarkManager?.fetchAllBookmarks() ?? []
    }

    private var bookmarkSuggestions: [(title: String, url: URL)] {
        return bookmarks.map { (title: $0.title, url: $0.url) }
    }

    // The working set of tabs visible on this device: persisted normal/container
    // tabs (excluding open-only sync closes) plus the in-memory incognito tabs.
    // Used for selection, switching, active-tab lookup, and rendering.
    private var visiblePersistedTabs: [BrowserTab] { TabSync.visible(tabs) }
    private var allTabs: [BrowserTab] { visiblePersistedTabs + tabManager.incognitoTabs }

    // The tabs visible in the window: the split members, or just the focused tab.
    private var displayedTabIds: [UUID] {
        tabManager.splitTabIds.isEmpty ? [tabManager.selectedTabId].compactMap { $0 } : tabManager.splitTabIds
    }

    // The tint for a tab's isolated session (nil for a normal tab): a container's
    // chosen color, or an auto hue for an incognito session.
    private func sessionColor(for tab: BrowserTab) -> Color? {
        switch tab.sessionKind {
        case .normal: return nil
        case .incognito: return tab.sessionId.map(BrowserSession.incognitoColor(for:))
        case .container: return browserSessions.first { $0.id == tab.sessionId }?.color
        }
    }

    private var groupedTabs: [(group: TabGroup?, tabs: [BrowserTab])] {
        BrowserTabOrder.sections(tabs: allTabs, groups: tabGroups).map {
            (group: $0.group, tabs: $0.tabs)
        }
    }

    private var visibleTabOrder: [BrowserTab] {
        groupedTabs.flatMap(\.tabs)
    }

    private func beginSidebarTabDrag(_ tabId: UUID) {
        sidebarDragMonitorTask?.cancel()
        sidebarDraggedTabId = tabId
        sidebarDropTargetTabId = nil
        sidebarLastCrossedTabId = tabId

        // SwiftUI exposes drag start/drop but no cancellation callback. Polling
        // the primary button prevents a cancelled drag outside the sidebar from
        // leaving the source row translucent indefinitely.
        sidebarDragMonitorTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    finishSidebarTabDrag()
                    return
                }
            }
        }
    }

    private func hoverSidebarTab(_ targetTabId: UUID, dragging sourceTabId: UUID) {
        guard sidebarDraggedTabId == sourceTabId else { return }

        if sourceTabId == targetTabId {
            sidebarDropTargetTabId = nil
            sidebarLastCrossedTabId = sourceTabId
            return
        }

        // Reordering across a group boundary would appear to do nothing because
        // group membership determines the section. Keep this gesture scoped to
        // the section the drag began in; moving groups remains a separate action.
        guard let source = allTabs.first(where: { $0.id == sourceTabId }),
              let target = allTabs.first(where: { $0.id == targetTabId }),
              source.groupId == target.groupId else {
            sidebarDropTargetTabId = nil
            return
        }

        sidebarDropTargetTabId = targetTabId
        guard sidebarLastCrossedTabId != targetTabId else { return }
        sidebarLastCrossedTabId = targetTabId

        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
            tabManager.reorderTabs(
                sourceTabId: sourceTabId,
                targetTabId: targetTabId,
                tabs: tabBarWidth <= 30 ? allTabs : visibleTabOrder
            )
        }
    }

    private func finishSidebarTabDrag() {
        sidebarDragMonitorTask?.cancel()
        sidebarDragMonitorTask = nil
        withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78)) {
            sidebarDraggedTabId = nil
            sidebarDropTargetTabId = nil
        }
        sidebarLastCrossedTabId = nil
    }

    private func sidebarY(for tabId: UUID, availableHeight: CGFloat) -> CGFloat {
        var y: CGFloat = 36 // expanded sidebar header + top breathing room
        for section in groupedTabs {
            if section.group != nil { y += 30 }
            for tab in section.tabs {
                if tab.id == tabId {
                    return min(max(y + 20, 24), availableHeight - 24)
                }
                y += 40
            }
        }
        return availableHeight / 2
    }

    private func peekLabelWidth(_ label: String) -> CGFloat {
        let baseFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let descriptor = baseFont.fontDescriptor.withDesign(.rounded) ?? baseFont.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: 11) ?? baseFont
        // A couple of points beyond the glyph bounds keep antialiasing and the
        // final character from being clipped after the Text is rotated.
        return ceil((label as NSString).size(withAttributes: [.font: font]).width) + 4
    }

    private var isCurrentPageBookmarked: Bool {
        guard let currentURL = currentURL else { return false }
        return bookmarkManager?.isBookmarked(currentURL) ?? false
    }

    private var isCurrentPageInNewspaper: Bool {
        guard let currentURL else { return false }
        let key = NewspaperStore.sourceKey(for: currentURL)
        return newspaperArticles.contains { $0.sourceKey == key }
    }

    private var tabBarHeaderButtons: some View {
        HStack(spacing: 4) {
            Button(action: createNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab")
            .accessibilityLabel("New Tab")

            Button(action: { showAgentPanel.toggle() }) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("AI Agent")
            .accessibilityLabel("AI Agent")

            Button(action: { showCreateGroupDialog = true }) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Group")
            .accessibilityLabel("New Group")

            Menu {
                Button("Save Workspace", action: { showSaveWorkspaceDialog = true })
                Divider()
                ForEach(savedWorkspaces) { workspace in
                    Button(workspace.name) {
                        loadWorkspace(workspace)
                    }
                }
                if savedWorkspaces.isEmpty {
                    Text("No saved workspaces")
                        .foregroundColor(.secondary)
                }
            } label: {
                Image(systemName: "square.stack")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Workspaces")
            .accessibilityLabel("Workspaces")

            Menu {
                Button("Open Newspaper") { openWindow(id: "newspaper") }
                Button(
                    isCurrentPageInNewspaper ? "Refresh Saved Article" : "Add Current Page",
                    action: addCurrentPageToNewspaper
                )
                .disabled(activeTab?.url == nil || activeTab?.sessionKind == .incognito)
            } label: {
                Image(systemName: "newspaper")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Newspaper")
            .accessibilityLabel("Newspaper")

            Menu {
                Button("New Incognito Tab") {
                    _ = tabManager.createIncognitoTab()
                    showOmnibar = true
                }
                Divider()
                ForEach(browserSessions) { session in
                    Menu(session.name) {
                        Button("Open Tab") {
                            _ = tabManager.createTab(inheriting: (.container, session.id))
                            showOmnibar = true
                        }
                        Button("Delete Container & Data", role: .destructive) {
                            deleteContainer(session)
                        }
                    }
                }
                if !browserSessions.isEmpty { Divider() }
                Button("New Container…") { showCreateContainerDialog = true }
            } label: {
                Image(systemName: "person.2")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Containers & Incognito")
            .accessibilityLabel("Containers and Incognito")

            // Same items as the menu bar's Autofill submenu — see AutofillMenu.swift.
            // The glyph dims when autofill is off so the state reads at a glance.
            Menu {
                AutofillMenuContent()
            } label: {
                Image(systemName: "text.append")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .opacity(AutofillPreferences.shared.isEnabled ? 1 : 0.4)
            .help(AutofillPreferences.shared.isEnabled ? "Autofill" : "Autofill (off)")
            .accessibilityLabel("Autofill")

            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .padding(.horizontal, 6)
        .background(Color(.windowBackgroundColor))
        .zIndex(10) // Ensure buttons are above overlay
    }

    private func groupHeaderView(for group: TabGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(group.color)
                    .frame(width: 8, height: 8)
                Text(group.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { deleteGroup(group) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Delete Group")
                .accessibilityLabel("Delete \(group.name) group")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.controlBackgroundColor).opacity(0.5))
        }
        .padding(.vertical, 2)
    }

    private func tabListView(geometry: GeometryProxy) -> some View {
        let adaptiveHeight: CGFloat? = if adaptiveLargeSidebarTabs && tabBarWidth >= 300 && !allTabs.isEmpty {
            min(140, max(36, (geometry.size.height - 52) / CGFloat(allTabs.count)))
        } else {
            nil
        }
        return ScrollView {
            VStack(spacing: 0) {
                // Add a spacer at the top to allow dragging without scroll interference
                Color.clear.frame(height: 1)
                // Force refresh when tab selection or title display mode changes
                let _ = tabSelectionRefreshTrigger
                let _ = tabTitleDisplayRefreshTrigger
                ForEach(groupedTabs, id: \.group?.id) { groupSection in
                    if let group = groupSection.group {
                        groupHeaderView(for: group)
                    }

                    // Tabs in this group
                    ForEach(groupSection.tabs) { tab in
                        TabRowView(
                            tab: tab,
                            selectedTabId: tabManager.selectedTabId,
                            availableWidth: geometry.size.width,
                            showOnlyIcons: tabBarWidth <= 30,
                            tabBarWidth: tabBarWidth,
                            onSelect: {
                                // Shift-click toggles split pane membership; plain click selects
                                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                                    tabManager.toggleSplitMembership(tab, tabs: allTabs)
                                } else {
                                    Logger.log("Tab clicked: \(tab.id), setting selectedTabId", type: "ContentView")
                                    tabManager.selectedTabId = tab.id
                                }
                            },
                            onReorder: { sourceTabId, targetTabId in
                                hoverSidebarTab(targetTabId, dragging: sourceTabId)
                            },
                            onDragBegan: beginSidebarTabDrag,
                            onDropFinished: finishSidebarTabDrag,
                            draggedTabId: sidebarDraggedTabId,
                            dropTargetTabId: sidebarDropTargetTabId,
                            loadingProgress: progressFaviconRing && showProgressBar
                                && tab.id == tabManager.selectedTabId ? progressValue : nil,
                            downloads: downloadManager.downloads(for: tab.id),
                            sessionColor: sessionColor(for: tab),
                            isIncognito: tab.sessionKind == .incognito,
                            isDisplayedInSplit: tabManager.splitTabIds.contains(tab.id),
                            automaticLinkBirthCue: tabManager.automaticLinkBirthCue,
                            thumbnail: webViewManager?.thumbnail(for: tab.id),
                            expandedHeight: adaptiveHeight
                        )
                        .contextMenu {
                            let webView = webViewManager?.existingWebView(for: tab.id)

                            Button("Reload") { webView?.reload() }.disabled(tab.url == nil)
                            Button("Back") { webView?.goBack() }.disabled(!(webView?.canGoBack ?? false))
                            Button("Forward") { webView?.goForward() }.disabled(!(webView?.canGoForward ?? false))
                            Divider()

                            Button("Close Tab", action: { tabManager.closeTab(tab, tabs: allTabs) })
                            Button("Duplicate Tab", action: { _ = tabManager.duplicateTab(tab) })
                            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
                                tab.isPinned.toggle()
                                try? modelContext.save()
                            }
                            Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") {
                                tab.isMuted.toggle()
                                webViewManager?.setMuted(tab.isMuted, for: tab.id)
                                try? modelContext.save()
                            }
                            Button("Move to Top", action: { tabManager.reorderTabs(sourceTabId: tab.id, targetTabId: groupSection.tabs[0].id, tabs: allTabs) })
                                .disabled(groupSection.tabs.first?.id == tab.id)
                            Divider()

                            if tab.sessionKind == .incognito {
                                Button("Remove from Incognito", action: { tabManager.convertToNormal(tab) })
                            } else {
                                Button("Convert to Incognito", action: { tabManager.convertToIncognito(tab) })
                            }
                            if tabManager.splitTabIds.contains(tab.id) {
                                Button("Remove from Split", action: { tabManager.toggleSplitMembership(tab, tabs: allTabs) })
                            } else if tabManager.splitTabIds.count < TabManager.maxSplitTabs {
                                Button(tabManager.splitTabIds.isEmpty ? "Open in Split" : "Add to Split",
                                       action: { tabManager.toggleSplitMembership(tab, tabs: allTabs) })
                            }
                            Divider()

                            let newspaperSourceKey = tab.url.map {
                                NewspaperStore.sourceKey(for: $0)
                            }
                            let tabIsInNewspaper = newspaperSourceKey.map { key in
                                newspaperArticles.contains { $0.sourceKey == key }
                            } ?? false
                            Button(
                                tabIsInNewspaper ? "Refresh Saved Article" : "Add to Newspaper",
                                action: { addTabToNewspaper(tab) }
                            )
                            .disabled(tab.url == nil || tab.sessionKind == .incognito)
                            Button("Share…", action: { shareTab(tab) }).disabled(tab.url == nil)
                            Button("Copy URL", action: { copyURL(of: tab) }).disabled(tab.url == nil)
                            Divider()

                            Menu("Memory Saving") {
                                ForEach(MemoryPolicy.allCases, id: \.self) { policy in
                                    Button {
                                        tab.memoryPolicy = policy
                                    } label: {
                                        if tab.memoryPolicy == policy {
                                            Label(policy.label, systemImage: "checkmark")
                                        } else {
                                            Text(policy.label)
                                        }
                                    }
                                }
                            }

                            // Move to group submenu
                            Menu("Move to Group") {
                                Button("Ungrouped") {
                                    moveTabToGroup(tab, groupId: nil)
                                }
                                ForEach(tabGroups.filter { $0.id != groupSection.group?.id }) { availableGroup in
                                    Button(availableGroup.name) {
                                        moveTabToGroup(tab, groupId: availableGroup.id)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .tabPoof
                        ))
                    }
                }
            }
            .padding(.vertical, 4)
            // A tab opened in the background (Cmd+click) slides its row in from the
            // leading edge, so you see it land instead of guessing whether it opened.
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8),
                       value: visibleTabOrder.map(\.id))
        }
    }

    private var tabSidebar: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Tab bar header with buttons - only show when not in minimal mode
                if tabBarWidth > 30 {
                    tabBarHeaderButtons
                }

                // Tab list or vertical favicon stack
                if tabBarWidth <= 30 {
                    // Vertical favicon stack for compact mode
                    FloatingFaviconOverlay(
                        tabs: allTabs,
                        selectedTabId: tabManager.selectedTabId,
                        onTabSelect: { tabId in
                            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
                               let tab = allTabs.first(where: { $0.id == tabId }) {
                                tabManager.toggleSplitMembership(tab, tabs: allTabs)
                            } else {
                                tabManager.selectedTabId = tabId
                            }
                        },
                        onReorder: { sourceTabId, targetTabId in
                            hoverSidebarTab(targetTabId, dragging: sourceTabId)
                        },
                        tabManager: tabManager,
                        downloads: downloadManager.activeDownloads,
                        draggedTabId: sidebarDraggedTabId,
                        dropTargetTabId: sidebarDropTargetTabId,
                        onDragBegan: beginSidebarTabDrag,
                        onDropFinished: finishSidebarTabDrag
                    )
                } else {
                    // Regular tab list view
                    tabListView(geometry: geometry)
                }
            }
            // Fill the width the call site sets (32 minimal / max(80, tabBarWidth) otherwise)
            // and pin content to the leading edge. A previous `minWidth: 80` here fought that
            // outer width in minimal mode and, on a persisted view (e.g. compact→minimal),
            // center-aligned the favicons off to the right. ponytail: leading fill, not minWidth.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.windowBackgroundColor))
            .clipped() // Ensure content doesn't overflow beyond tab bar bounds
        }
        .background(Color(.windowBackgroundColor)) // Solid background to cover web view
    }

    private var webViewContent: some View {
        Group {
            if managersInitialized {
                WebView(url: webViewURLBinding,
                        canGoBack: webViewCanGoBackBinding,
                        canGoForward: webViewCanGoForwardBinding,
                        title: webViewTitleBinding,
                        isLoading: $isLoading,
                        progressValue: $progressValue,
                        hasRenderedContent: $hasRenderedContent,
                        webViewManager: webViewManager,
                        tabManager: tabManager,
                        pageTranslator: pageTranslator,
                        fastForward: fastForward,
                        tabs: allTabs,
                        activeTabId: tabManager.selectedTabId,
                        displayedTabIds: displayedTabIds,
                        onURLChange: { _ in })
                        .allowsHitTesting(true)
                        .focusable(true)
            } else {
                // Show loading state when managers are not yet initialized
                VStack {
                    Image(systemName: "globe")
                        .font(.system(size: 64))
                        .foregroundColor(.gray)
                    Text("Loading...")
                        .font(.title)
                        .foregroundColor(.gray)
                }
            }
        }
    }

    // The active tab's URL is the single source of truth for what the WebView
    // shows. (A separate @State copy meant omnibar/CLI navigation updated the
    // model but never reached the WebView.) WebView.updateNSView dedupes
    // against what the webview already displays, so this can't loop.
    private var webViewURLBinding: Binding<URL?> {
        Binding(
            get: { self.activeTab?.url },
            set: { newURL in
                // Update the tab URL directly, don't call navigateTo to avoid
                // recursion. The title comes from the page via webViewTitleBinding.
                if let url = newURL, let activeTab = self.activeTab {
                    activeTab.url = url
                }
            }
        )
    }

    private var webViewCanGoBackBinding: Binding<Bool> {
        Binding(
            get: { self.webViewManager?.canGoBack ?? false },
            set: { _ in }
        )
    }

    private var webViewCanGoForwardBinding: Binding<Bool> {
        Binding(
            get: { self.webViewManager?.canGoForward ?? false },
            set: { _ in }
        )
    }

    private var webViewTitleBinding: Binding<String> {
        Binding(
            get: { self.currentTitle },
            set: { newTitle in
                self.currentTitle = newTitle
                // Also update the active tab's title
                if let activeTab = self.activeTab {
                    activeTab.title = newTitle
                }
            }
        )
    }

    private var progressBarOverlay: some View {
        ZStack {
            if progressBarTop {
                VStack(spacing: 0) { horizontalProgressBar; Spacer() }
            }
            if progressBarBottom {
                VStack(spacing: 0) { Spacer(); horizontalProgressBar }
            }
            if progressBarLeft {
                HStack(spacing: 0) { verticalProgressBar; Spacer() }
            }
            if progressBarRight {
                HStack(spacing: 0) { Spacer(); verticalProgressBar }
            }
        }
        .edgesIgnoringSafeArea(.all)
    }

    private var newTabPageOverlay: some View {
        Group {
            if activeTab == nil {
                VStack {
                    Image(systemName: "globe")
                        .font(.system(size: 64))
                        .foregroundColor(.gray)
                    Text("New Tab")
                        .font(.title)
                        .foregroundColor(.gray)
                    Text("Press ⌃Space to navigate")
                        .font(.subheadline)
                        .foregroundColor(.gray.opacity(0.8))
                        .padding(.top, 8)
                }
            }
        }
    }

    // Fraction of the window height above the omnibar. Fixed (not centered)
    // so the bar never moves while suggestions appear below it.
    private var omnibarTopFraction: CGFloat {
        switch UserDefaults.standard.string(forKey: "omnibarPosition") {
        case "Top": return 0.08
        case "Center": return 0.45
        default: return 0.25 // "Upper": about 3/4 of the way up the window
        }
    }

    private var omnibarOverlay: some View {
        Group {
            if showOmnibar {
                ZStack {
                    // Background with tap to close
                    Color.black.opacity(0.3)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            showOmnibar = false
                        }

                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer()
                                .frame(height: geometry.size.height * omnibarTopFraction)
                            OmnibarView(
                                isPresented: $showOmnibar,
                                urlString: .constant(currentURL?.absoluteString ?? ""),
                                onNavigate: { urlString, commit in
                                    guard let navigationManager else { return }
                                    switch commit {
                                    case .navigate:
                                        _ = navigationManager.navigateToURL(urlString, activeTab: activeTab)
                                        if let activeTab {
                                            tabManager.updateTabTitle(activeTab)
                                        }
                                    case .newTab, .newSplitPane:
                                        // Shift+Return / Cmd+Return: skip navigating the
                                        // current tab, land the result in a fresh one instead.
                                        guard let url = URL(string: urlString) else {
                                            navigationManager.omnibarError = String(localized: "Invalid URL")
                                            return
                                        }
                                        let session = activeTab.map { (kind: $0.sessionKind, sessionId: $0.sessionId) }
                                            ?? (kind: SessionKind.normal, sessionId: nil)
                                        let newTab = tabManager.createTab(inheriting: session, url: url, select: commit == .newTab)
                                        if commit == .newSplitPane {
                                            tabManager.toggleSplitMembership(newTab, tabs: tabs + [newTab])
                                        }
                                    }
                                },
                                errorMessage: navigationManager?.omnibarError,
                                tabs: tabs,
                                bookmarkSuggestions: bookmarkSuggestions,
                                currentTabId: tabManager.selectedTabId,
                                onSwitchToTab: { tabManager.selectedTabId = $0 },
                                thumbnail: { webViewManager?.thumbnail(for: $0) },
                                pageProtection: pageProtectionSummary
                            )
                            .allowsHitTesting(true)
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(.isModal)
                            .accessibilityFocused(
                                $accessibilityFocus,
                                equals: .omnibar
                            )
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var findBarOverlay: some View {
        Group {
            if showFindBar {
                findBar
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: FindBar.alignment(findBarPosition))
                    .onChange(of: findText) { _, newValue in
                        findMatchIndex = 0
                        if newValue.isEmpty {
                            findMatchCount = 0
                            clearFindHighlights() // emptied field: drop the highlight
                        } else {
                            countFindMatches()
                            performFind() // incremental find while typing
                        }
                    }
            }
        }
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            OmnibarTextField(
                text: $findText,
                placeholder: String(localized: "Find in page"),
                shouldFocus: true,
                onCommit: { _ in performFind() },
                onCancel: { closeFindBar() }
            )
            .frame(width: 180)

            Text(findCountLabel)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(findMatchCount == 0 && findMatchIndex == 0 && !findText.isEmpty ? Color.red : .secondary)
                .frame(minWidth: 60, alignment: .trailing)

            Divider().frame(height: 16)

            Button(action: { performFind(backwards: true) }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help("Previous Match")
            .accessibilityLabel("Previous Match")

            Button(action: { performFind() }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Next Match")
            .accessibilityLabel("Next Match")

            Button(action: { closeFindBar() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close Find Bar")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(radius: 6, y: 2)
    }

    private var findCountLabel: String {
        if findText.isEmpty { return "" }
        if findMatchCount > 0 { return String(localized: "\(max(findMatchIndex, 1)) of \(findMatchCount)") }
        return findMatchIndex > 0 ? "" : String(localized: "No results")
    }

    private func closeFindBar() {
        showFindBar = false
        findMatchIndex = 0
        clearFindHighlights()
    }

    private func performFind(backwards: Bool = false) {
        guard let webView = webViewManager?.activeWebView, !findText.isEmpty else { return }
        if findMatchCount == 0 { countFindMatches() } // ⌘G with a bar we haven't counted yet
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(findText, configuration: configuration) { result in
            guard result.matchFound else {
                findMatchIndex = 0
                findMatchCount = 0
                return
            }
            // ponytail: WKWebView won't tell us which match it landed on, so we step a
            // counter alongside it. It desyncs only if the page already had a selection
            // mid-document when the search started — the next wrap re-aligns it.
            // max(count, 1): a match exists even if the text count hasn't landed (or missed it),
            // so the label falls back to blank rather than claiming "No results".
            findMatchIndex = FindBar.step(index: findMatchIndex, count: max(findMatchCount, 1), backwards: backwards)
            flashFoundMatch(in: webView)
        }
    }

    /// Total matches on the page, counted over the visible text — WKFindConfiguration has no count.
    private func countFindMatches() {
        guard let webView = webViewManager?.activeWebView,
              let data = try? JSONSerialization.data(withJSONObject: findText, options: .fragmentsAllowed),
              let needle = String(data: data, encoding: .utf8) else { return }
        let js = """
        (function(n) {
            n = n.toLowerCase();
            var t = (document.body.innerText || '').toLowerCase(), c = 0, i = 0;
            while (n && (i = t.indexOf(n, i)) >= 0) { c++; i += n.length; }
            return c;
        })(\(needle));
        """
        webView.evaluateJavaScript(js) { value, _ in
            findMatchCount = (value as? NSNumber)?.intValue ?? 0
        }
    }

    // Pulse a ring around the found match so the eye can locate it. How loud the pulse is
    // — ring, glow, zoom-in, and dimming of everything else — rides the Find Emphasis slider.
    private func flashFoundMatch(in webView: WKWebView) {
        // Same ring Fast Forward draws over its scroll target, so both ride this
        // one slider (see PulseRing in FastForward.swift).
        guard let js = PulseRing.script(intensity: findFlashIntensity,
                                        rectJS: PulseRing.selectionRectJS) else { return }
        webView.evaluateJavaScript(js)
    }

    // The native find API highlights via the selection; clearing it un-highlights
    private func clearFindHighlights() {
        webViewManager?.activeWebView?.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    private var createGroupDialogOverlay: some View {
        Group {
            if showCreateGroupDialog {
                Color.black.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        showCreateGroupDialog = false
                    }

                VStack {
                    Spacer()
                    VStack(spacing: 20) {
                        Text("Create Tab Group")
                            .font(.title2)
                            .bold()

                        VStack(spacing: 16) {
                            TextField("Group Name", text: $newGroupName)
                                .textFieldStyle(.roundedBorder)
                                .padding(.horizontal)

                            ColorPicker("Group Color", selection: $newGroupColor)
                                .padding(.horizontal)
                        }

                        HStack(spacing: 16) {
                            Button("Cancel") {
                                showCreateGroupDialog = false
                                newGroupName = ""
                                newGroupColor = Color.blue
                            }
                            .buttonStyle(.bordered)

                            Button("Create") {
                                createTabGroup(name: newGroupName, color: newGroupColor)
                                showCreateGroupDialog = false
                                newGroupName = ""
                                newGroupColor = Color.blue
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(32)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 20)
                    .frame(maxWidth: 300)
                    Spacer()
                }
            }
        }
    }

    private var createContainerDialogOverlay: some View {
        Group {
            if showCreateContainerDialog {
                Color.black.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture { showCreateContainerDialog = false }

                VStack {
                    Spacer()
                    VStack(spacing: 20) {
                        Text("New Container")
                            .font(.title2)
                            .bold()

                        Text("An isolated, persistent session with its own cookies and logins — stay signed in under a different account, side by side.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        VStack(spacing: 16) {
                            TextField("Container Name", text: $newContainerName)
                                .textFieldStyle(.roundedBorder)
                                .padding(.horizontal)

                            ColorPicker("Container Color", selection: $newContainerColor)
                                .padding(.horizontal)
                        }

                        HStack(spacing: 16) {
                            Button("Cancel") {
                                showCreateContainerDialog = false
                                newContainerName = ""
                                newContainerColor = Color.purple
                            }
                            .buttonStyle(.bordered)

                            Button("Create") {
                                createContainer(name: newContainerName, color: newContainerColor)
                                showCreateContainerDialog = false
                                newContainerName = ""
                                newContainerColor = Color.purple
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newContainerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(32)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 20)
                    .frame(maxWidth: 300)
                    Spacer()
                }
            }
        }
    }

    private var saveWorkspaceDialogOverlay: some View {
        Group {
            if showSaveWorkspaceDialog {
                Color.black.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        showSaveWorkspaceDialog = false
                    }

                VStack {
                    Spacer()
                    VStack(spacing: 20) {
                        Text("Save Workspace")
                            .font(.title2)
                            .bold()

                        TextField("Workspace Name", text: $workspaceName)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal)

                        HStack(spacing: 16) {
                            Button("Cancel") {
                                showSaveWorkspaceDialog = false
                                workspaceName = ""
                            }
                            .buttonStyle(.bordered)

                            Button("Save") {
                                saveCurrentWorkspace(name: workspaceName)
                                showSaveWorkspaceDialog = false
                                workspaceName = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(32)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 20)
                    .frame(maxWidth: 300)
                    Spacer()
                }
            }
        }
    }


    private var importBookmarksDialogOverlay: some View {
        Group {
            if isImportBookmarksDialogPresented {
                Color.black.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        isImportBookmarksDialogPresented = false
                    }

                VStack {
                    Spacer()
                    VStack(spacing: 20) {
                        Text("Import Bookmarks")
                            .font(.title2)
                            .bold()

                        Text("Choose a browser to import bookmarks from:")
                            .multilineTextAlignment(.center)

                        VStack(spacing: 12) {
                            ForEach(availableBrowsers, id: \.self) { browser in
                                Button(action: {
                                    importBookmarks(from: browser)
                                }) {
                                    HStack {
                                        Image(systemName: "globe")
                                            .foregroundColor(.blue)
                                        Text(browser.displayName)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.gray)
                                    }
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color(.controlBackgroundColor))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)

                        Button("Cancel") {
                            isImportBookmarksDialogPresented = false
                        }
                        .padding(.top, 8)
                    }
                    .padding(32)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 20)
                    .frame(maxWidth: 400)
                    Spacer()
                }
            }
        }
    }

    private var librarySheet: some View {
        BrowserLibraryView(
            bookmarks: allBookmarks,
            initialSection: librarySection,
            onOpen: openFromLibrary,
            onClose: { contentModal = nil },
            onUpdateBookmark: { bookmark, title, url, category in
                bookmarkManager?.updateBookmark(
                    bookmark,
                    title: title,
                    url: url,
                    category: category
                )
            },
            onDeleteBookmark: { bookmarkManager?.removeBookmark($0) },
            onDeleteHistory: removeHistoryURL,
            onClearHistory: clearHistoryFromLibrary
        )
        .accessibilityFocused(
            $accessibilityFocus,
            equals: .library
        )
    }

    private func readerSheet(_ article: ReaderArticle) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.title)
                        .font(.title2.bold())
                        .lineLimit(2)
                    if let byline = article.byline, !byline.isEmpty {
                        Text(byline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    contentModal = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Reader Mode")
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(
                        Array(article.blocks.enumerated()),
                        id: \.offset
                    ) { _, block in
                        ReaderBlockRow(block: block)
                    }
                }
                .font(.system(size: 18, design: .serif))
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: 700, alignment: .leading)
                .padding(32)
            }
        }
        .frame(width: 820, height: 650)
        .background(Color(.textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reader Mode")
        .accessibilityAddTraits(.isModal)
        .accessibilityFocused(
            $accessibilityFocus,
            equals: .reader
        )
        .onKeyPress(.escape) {
            contentModal = nil
            return .handled
        }
        .environment(\.openURL, OpenURLAction { url in
            openFromLibrary(url)
            return .handled
        })
    }

    private var linkPreviewOverlay: some View {
        Group {
            if linkPreview.isShowing {
                ZStack {
                    Color.black.opacity(0.3)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            linkPreview.dismiss()
                        }

                    StaticWebView(webView: linkPreview.webView)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 20)
                        .padding(60)
                }
            }
        }
    }

    private var quitHoldOverlay: some View {
        Group {
            if quitHoldActive {
                VStack(spacing: 12) {
                    Text(quitHoldProgress >= 0.99 ? "Release ⌘Q now to quit" : "Keep holding ⌘Q to quit")
                        .font(.headline)
                    ProgressView(value: min(quitHoldProgress, 1))
                        .frame(width: 220)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 10)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        // The quit HUD is deliberately a fast, tactile affordance. Keep its
        // entry/exit animation independent of the app-wide reduced-motion
        // transaction; the hold-length setting still controls only the bar.
        .transaction {
            $0.disablesAnimations = false
            $0.animation = .easeInOut(duration: 0.08)
        }
        .animation(.easeInOut(duration: 0.08), value: quitHoldActive)
    }

    // Brief confirmation that ⌥⌘A landed. Driven by observing the preference
    // rather than the shortcut, so flipping autofill from the sidebar menu, the
    // menu bar, or Settings all read the same.
    private var autofillHUDOverlay: some View {
        Group {
            if let autofillHUD {
                Label(autofillHUD, systemImage: preferencesEnabledIcon)
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.12), value: autofillHUD)
    }

    private var preferencesEnabledIcon: String {
        AutofillPreferences.shared.isEnabled ? "text.append" : "nosign"
    }

    private func showAutofillHUD(enabled: Bool) {
        autofillHUDTask?.cancel()
        autofillHUD = enabled
            ? String(localized: "Autofill On")
            : String(localized: "Autofill Off")
        autofillHUDTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            autofillHUD = nil
        }
    }

    // The autofill suggestion list, anchored under the focused field. Same
    // coordinate story as the shutter flash below: the rect arrives in AppKit
    // window coordinates and SwiftUI counts y downward, hence the flip.
    //
    // Suppressed while another overlay owns the screen — three of them competing
    // for Escape is a bug — and only ever for the frontmost tab, so a background
    // split pane can't pop a list.
    private var autofillSuggestionOverlay: some View {
        GeometryReader { geo in
            if let presentation = autofill.presentation,
               presentation.tabID == tabManager.selectedTabId,
               !autofill.suggestions.isEmpty,
               !showOmnibar, contentModal == nil, !linkPreview.isShowing {
                let size = autofillListSize(fieldWidth: presentation.fieldRect.width)
                let origin = AutofillGeometry.listOrigin(
                    fieldRect: presentation.fieldRect,
                    listSize: size,
                    windowHeight: geo.size.height
                )
                AutofillSuggestionList(autofill: autofill)
                    .frame(width: size.width, height: size.height)
                    .position(
                        x: origin.x + size.width / 2,
                        y: geo.size.height - (origin.y + size.height / 2)
                    )
            }
        }
    }

    private func autofillListSize(fieldWidth: CGFloat) -> CGSize {
        CGSize(
            width: max(AutofillSuggestionList.minimumWidth, fieldWidth),
            height: AutofillSuggestionList.height(rows: autofill.suggestions.count)
        )
    }

    // Screenshot shutter flash, sized to exactly what was captured. The rect
    // arrives in AppKit window coordinates (origin bottom-left); SwiftUI's root
    // fills the same content view but counts y downward, hence the flip.
    private var screenshotFlashOverlay: some View {
        GeometryReader { geo in
            if let rect = flashRect {
                Rectangle()
                    .fill(.white)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: geo.size.height - rect.midY)
                    .opacity(flashOpacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // With the tab bar fully hidden, changing the active tab slides its favicon
    // out of the left edge for ~1s so you can see where you landed.
    // The blob is only as wide as it needs to be and rounds off on the exposed
    // side, so no hard edge ever crosses the page.
    @ViewBuilder
    private var faviconPeekOverlay: some View {
        if tabBarWidth == 0, let tab = activeTab {
            GeometryReader { geometry in
                let peekSide = BrowserChromeLayout.faviconPeekSide(
                    tabSide: tabSidebarSide,
                    agentVisible: showAgentPanel,
                    agentSide: agentPanelSide
                )
                let isLeft = peekSide == .left
                let panelInset = BrowserChromeLayout.faviconPeekInset(
                    agentVisible: showAgentPanel,
                    agentWidth: BrowserAgentPanel.width
                )
                let edgeX = isLeft ? panelInset : geometry.size.width - panelInset
                let iconY = sidebarY(for: tab.id, availableHeight: geometry.size.height)
                let label = tab.peekLabel(among: allTabs)
                let labelWidth = peekLabelWidth(label)
                let labelPadding: CGFloat = 10
                let labelSpan = labelWidth + labelPadding * 2
                let totalHeight = 40 + labelSpan
                let spaceNeededOnOneSide = totalHeight - 20
                let fitsAbove = iconY >= spaceNeededOnOneSide
                let fitsBelow = geometry.size.height - iconY >= spaceNeededOnOneSide
                let runsDown = !fitsAbove && (fitsBelow || iconY < geometry.size.height / 2)
                let direction: CGFloat = runsDown ? 1 : -1
                let backgroundY = iconY + direction * labelSpan / 2
                let textY = iconY + direction * (20 + labelPadding + labelWidth / 2)

                ZStack(alignment: .topLeading) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: isLeft ? 0 : 20,
                        bottomLeadingRadius: isLeft ? 0 : 20,
                        bottomTrailingRadius: isLeft ? 20 : 0,
                        topTrailingRadius: isLeft ? 20 : 0
                    )
                        .fill(Color(.windowBackgroundColor))
                        .frame(width: 44, height: totalHeight)
                        .position(x: edgeX + (isLeft ? 22 : -22), y: backgroundY)

                    Text(label)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(.primary)
                        .frame(width: labelWidth, height: 16)
                        .rotationEffect(.degrees(runsDown ? 90 : -90))
                        .position(x: edgeX + (isLeft ? 20 : -20), y: textY)

                    Group {
                        if let data = tab.favicon, let icon = NSImage(data: data) {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: tab.url != nil ? "globe" : "plus.circle")
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(.primary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .position(x: edgeX + (isLeft ? 28 : -28), y: iconY)
                }
                .shadow(color: .black.opacity(0.35), radius: 6, x: isLeft ? 2 : -2, y: 0)
                .offset(x: showFaviconPeek ? 0 : (isLeft ? -48 : 48))
                .opacity(showFaviconPeek ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    // Cancels any in-flight peek so a fast run of switches keeps one blob out
    // rather than stuttering it closed mid-sequence.
    private func peekFavicon() {
        guard tabBarWidth == 0 else { return }
        faviconPeekTask?.cancel()
        // duration: here is the perceptual travel time; `response:` is an
        // oscillator period, which lands the blob in ~165ms, not 300ms.
        if reduceMotion {
            showFaviconPeek = true
        } else {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { showFaviconPeek = true }
        }
        faviconPeekTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            if reduceMotion {
                showFaviconPeek = false
            } else {
                withAnimation(.easeInOut(duration: 0.3)) { showFaviconPeek = false }
            }
        }
    }

    private var mainContent: some View {
        ZStack {
            webViewContent
                .accessibilityHidden(
                    BrowserAccessibility.backgroundIsHidden(
                        sidebarPresented: false,
                        omnibarPresented: showOmnibar,
                        modalPresented: contentModal != nil
                    )
                )
                .accessibilityFocused(
                    $accessibilityFocus,
                    equals: .page
                )
                .zIndex(0)
        }
        .overlay(progressBarOverlay.zIndex(1))
        .overlay(downloadProgressOverlay.zIndex(1.5))
        .overlay(newTabPageOverlay.zIndex(2))
        .overlay(linkPreviewOverlay.zIndex(3))
        .overlay(omnibarOverlay.zIndex(3))
        .overlay(findBarOverlay.zIndex(3))
        .overlay(createGroupDialogOverlay.zIndex(4))
        .overlay(createContainerDialogOverlay.zIndex(4))
        .overlay(saveWorkspaceDialogOverlay.zIndex(5))
        .overlay(importBookmarksDialogOverlay.zIndex(6))
        .overlay(quitHoldOverlay.zIndex(7))
        .overlay(autofillHUDOverlay.zIndex(7))
        .overlay(shortcutCheatSheetOverlay.zIndex(8))
        .overlay(tabGridOverlay.zIndex(8))
        .overlay(alignment: .bottomTrailing, content: { defaultBrowserOverlay.zIndex(9) })
    }

    private var agentPanelView: some View {
        BrowserAgentPanel(
            agent: browserAgent,
            side: agentPanelSide,
            pageTitle: currentTitle,
            pageURL: currentURL?.absoluteString ?? "",
            pageTarget: currentAgentPageTarget,
            lassoSelection: agentLassoSelection,
            onClose: { showAgentPanel = false },
            onStartLasso: startAgentLasso,
            onClearLasso: { agentLassoSelection = nil },
            onAddSourceToNewspaper: addScratchSourceToNewspaper,
            onAISearch: performAgentAISearch,
            onPrepareLocalContext: prepareAgentLocalContext,
            resolvePageAuthority: { pageIDs in
                guard let manager = notificationManager else { return nil }
                return await manager.automationPageAuthoritySnapshots(pageIDs: pageIDs)
            },
            execute: { tool, arguments, permit, pageBindings in
                guard let manager = notificationManager else {
                    return "{\"error\":\"Browser automation is not ready.\"}"
                }
                return await manager.automationJSONResult(
                    tool: tool,
                    arguments: arguments,
                    permit: permit,
                    authorizedPageBindings: pageBindings
                )
            }
        )
    }

    private var browserAndDeveloperTools: some View {
        Group {
            if !showDeveloperTools || developerToolsPlacement == .window {
                mainContent
            } else {
                switch developerToolsPlacement {
                case .bottom:
                    VSplitView {
                        mainContent.frame(minHeight: 180)
                        developerToolsView.frame(minHeight: 170, idealHeight: 320, maxHeight: 620)
                    }
                case .left:
                    HSplitView {
                        developerToolsView.frame(minWidth: 320, idealWidth: 460, maxWidth: 720)
                        mainContent.frame(minWidth: 360)
                    }
                case .right:
                    HSplitView {
                        mainContent.frame(minWidth: 360)
                        developerToolsView.frame(minWidth: 320, idealWidth: 460, maxWidth: 720)
                    }
                case .window:
                    mainContent
                }
            }
        }
        .overlay(alignment: .top) { traditionalTopTabBarOverlay }
    }

    private var developerToolsPlacement: DeveloperToolsPlacement {
        DeveloperToolsPlacement(rawValue: developerToolsPlacementRaw) ?? .bottom
    }

    private var developerToolsView: some View {
        DeveloperToolsView(
            model: developerTools,
            webView: webViewManager?.activeWebView,
            tabID: tabManager.selectedTabId,
            onClose: closeDeveloperTools
        )
    }

    private func closeDeveloperTools() {
        withAnimation(.easeInOut(duration: 0.16)) {
            showDeveloperTools = false
        }
    }

    private func synchronizeDeveloperToolsWindow() {
        guard showDeveloperTools, developerToolsPlacement == .window else { return }
        DeveloperToolsDetachedWindowState.shared.configure(
            model: developerTools,
            webView: webViewManager?.activeWebView,
            tabID: tabManager.selectedTabId,
            onClose: closeDeveloperTools
        )
        openWindow(id: "developer-tools")
    }

    @ViewBuilder
    private var traditionalTopTabBarOverlay: some View {
        if showTraditionalTopTabs {
            VStack(spacing: 0) {
                if topTabsRevealed || !topTabsAutoHide {
                    HStack(spacing: 5) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(visibleTabOrder) { tab in
                                    Button {
                                        tabManager.selectedTabId = tab.id
                                    } label: {
                                        HStack(spacing: 6) {
                                            if let data = tab.favicon, let image = NSImage(data: data) {
                                                Image(nsImage: image).resizable().scaledToFit().frame(width: 15, height: 15)
                                            } else {
                                                Image(systemName: "globe").frame(width: 15)
                                            }
                                            Text(tab.title.isEmpty ? Tab.extractDomain(from: tab.url) : tab.title)
                                                .lineLimit(1)
                                            Button { tabManager.closeTab(tab, tabs: allTabs) } label: {
                                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Close tab")
                                        }
                                        .font(.system(size: 11))
                                        .padding(.horizontal, 10)
                                        .frame(minWidth: 120, maxWidth: 220, minHeight: 30)
                                        .background(
                                            tab.id == tabManager.selectedTabId
                                                ? (sessionColor(for: tab) ?? Color.accentColor).opacity(0.18)
                                                : Color(nsColor: .controlBackgroundColor).opacity(0.88),
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Button(action: createNewTab) { Image(systemName: "plus").frame(width: 26, height: 26) }
                            .buttonStyle(.plain).accessibilityLabel("New Tab")
                    }
                    .padding(5)
                    .background(.ultraThickMaterial)
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                    .onHover { hovering in
                        if !hovering && topTabsAutoHide {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                if topTabsAutoHide { topTabsRevealed = false }
                            }
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    Color.clear
                        .frame(height: 9)
                        .contentShape(Rectangle())
                        .onHover { if $0 { withAnimation(.easeOut(duration: 0.14)) { topTabsRevealed = true } } }
                }
                Spacer(minLength: 0)
            }
            .zIndex(30)
        }
    }

    @ViewBuilder
    private func downloadPane(for tabId: UUID) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            let transfers = downloadManager.downloads(for: tabId)
            if !transfers.isEmpty {
                TabDownloadBars(downloads: transfers)
            }
        }
    }

    private var downloadProgressOverlay: some View {
        Group {
            if displayedTabIds.count == 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        downloadPane(for: displayedTabIds[0])
                        downloadPane(for: displayedTabIds[1])
                    }
                    HStack(spacing: 0) {
                        downloadPane(for: displayedTabIds[2])
                        downloadPane(for: displayedTabIds[3])
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(displayedTabIds, id: \.self) { tabId in
                        downloadPane(for: tabId)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var defaultBrowserOverlay: some View {
        Group {
            if tabManager.offerDefaultBrowser {
                DefaultBrowserPrompt { tabManager.offerDefaultBrowser = false }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: tabManager.offerDefaultBrowser)
    }

    // Card grid of every open tab, ⌘O (arrows to steer, Return to jump)
    private var tabGridOverlay: some View {
        Group {
            if showTabGrid {
                TabGridView(
                    isPresented: $showTabGrid,
                    tabs: allTabs,
                    selectedTabId: tabManager.selectedTabId,
                    thumbnail: { webViewManager?.thumbnail(for: $0) },
                    onSelect: { tabManager.selectedTabId = $0 }
                )
            }
        }
    }

    // Full shortcut reference, toggled with Cmd+Shift+H (or Esc/click to close)
    private var shortcutCheatSheetOverlay: some View {
        Group {
            if showShortcutCheatSheet {
                ZStack {
                    Color.black.opacity(0.25)
                        .contentShape(Rectangle())
                        .onTapGesture { showShortcutCheatSheet = false }

                    HStack(alignment: .top, spacing: 28) {
                        let sections = ShortcutSection.allCases
                        let mid = (sections.count + 1) / 2
                        ForEach([Array(sections.prefix(mid)), Array(sections.suffix(from: mid))], id: \.first) { column in
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(column, id: \.self) { section in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(section.title)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .textCase(.uppercase)
                                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                                            ForEach(ShortcutStore.shared.cheatRows(for: section)) { row in
                                                GridRow {
                                                    CheatSheetTitleCell(row: row)
                                                    CheatSheetKeysCell(row: row)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(width: 290, alignment: .topLeading)
                        }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 14)
                }
                .transition(.opacity)
                .onExitCommand { showShortcutCheatSheet = false }
                .onAppear { LiveKeyState.shared.activate() }
                .onDisappear { LiveKeyState.shared.deactivate() }
            }
        }
    }

    private var colorScheme: ColorScheme? {
        SettingsManager.shared.colorScheme
    }

    // Inset from both ends by the window's corner radius: a 1pt line can't
    // trace the curve, so rather than run flush into it and vanish under the
    // clip (a straight bar has no pixels left inside a rounded corner), it
    // stops short and lands cleanly on the straight part of the edge.
    private var horizontalProgressBar: some View {
        GeometryReader { geometry in
            if showProgressBar {
                let barWidth = max(0, geometry.size.width - WindowLayout.windowCornerRadius * 2)
                ZStack(alignment: .leading) {
                    // Background track
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: barWidth, height: 1)

                    // Progress fill
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: max(0, progressValue * barWidth), height: 1)
                        .animation(.linear(duration: max(0.02, 0.1)), value: progressValue)
                }
                .padding(.horizontal, WindowLayout.windowCornerRadius)
                .transition(.opacity.animation(.easeIn(duration: max(0.02, 0.2))))
                .frame(height: 1)
            }
        }
        .frame(height: showProgressBar ? 1 : 0)
    }

    // Same bar rotated onto a side edge; fills top-down
    private var verticalProgressBar: some View {
        GeometryReader { geometry in
            if showProgressBar {
                let barHeight = max(0, geometry.size.height - WindowLayout.windowCornerRadius * 2)
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 1, height: barHeight)

                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: 1, height: max(0, progressValue * barHeight))
                        .animation(.linear(duration: max(0.02, 0.1)), value: progressValue)
                }
                .padding(.vertical, WindowLayout.windowCornerRadius)
                .transition(.opacity.animation(.easeIn(duration: max(0.02, 0.2))))
                .frame(width: 1)
            }
        }
        .frame(width: showProgressBar ? 1 : 0)
    }

    private var tabSidebarResizeGrip: some View {
        Color.clear
            .frame(width: 5)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("Resize Tab Sidebar")
            .accessibilityValue("\(Int(tabBarWidth)) points wide")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    tabBarWidth = min(400, tabBarWidth + 20)
                case .decrement:
                    tabBarWidth = max(0, tabBarWidth - 20)
                @unknown default:
                    break
                }
                UserDefaults.standard.set(tabBarWidth, forKey: "tabBarWidth")
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let startWidth = tabBarResizeStartWidth ?? tabBarWidth
                        if tabBarResizeStartWidth == nil {
                            tabBarResizeStartWidth = startWidth
                        }
                        let newWidth = BrowserChromeLayout.resizedTabWidth(
                            currentWidth: startWidth,
                            translationX: value.translation.width,
                            side: tabSidebarSide
                        )
                        tabBarWidth = newWidth
                        UserDefaults.standard.set(newWidth, forKey: "tabBarWidth")
                    }
                    .onEnded { _ in
                        tabBarResizeStartWidth = nil
                    }
            )
            .onHover { isHovering in
                if isHovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }

    private var tabSidebarResizeOverlay: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: tabBarWidth <= 30 ? 0 : 38)
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                if tabSidebarSide == .right {
                    tabSidebarResizeGrip
                }
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
                if tabSidebarSide == .left {
                    tabSidebarResizeGrip
                }
            }
            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
        .frame(width: effectiveTabSidebarWidth)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Spacer().frame(width: reservedChromeWidth(on: .left))
                browserAndDeveloperTools
                    .clipped()
                Spacer().frame(width: reservedChromeWidth(on: .right))
            }
        }
        .overlay(alignment: tabSidebarSide.alignment) {
            if tabBarWidth > 0 {
                tabSidebar
                    .frame(width: effectiveTabSidebarWidth)
                    .background(Color(.windowBackgroundColor))
                    .clipped()
            }
        }
        .overlay(alignment: tabSidebarSide.alignment) {
            if tabBarWidth > 0 {
                tabSidebarResizeOverlay
            }
        }
        .preferredColorScheme(colorScheme)
        .transaction {
            if reduceMotion { $0.disablesAnimations = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all) // Ignore safe areas to extend to edges
        .background(Color(.windowBackgroundColor)) // Set explicit background
        .overlay(screenshotFlashOverlay)
        .overlay(autofillSuggestionOverlay)
        // The autofill menus live in two places that can't share a @Query — the
        // sidebar header and the menu bar, which never sees the model container.
        // This window owns the query and publishes a name-only projection.
        .modifier(AutofillWindowBridge(
            profiles: autofillProfileSummaries,
            pageURL: currentURL,
            onEnabledChange: showAutofillHUD(enabled:)
        ))
        .overlay { faviconPeekOverlay }
        .overlay(alignment: agentPanelSide.alignment) {
            if showAgentPanel {
                agentPanelView
                    .transition(.move(edge: agentPanelSide.edge).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        // One session, serialized by pageTranslator's own queue: it advances
        // `configuration` to the next pending request as each one finishes.
        .translationTask(pageTranslator.configuration) { session in
            await pageTranslator.perform(session: session)
        }
        .contentViewTypeErased()
        .onAppear {
            // One-time setup; onAppear can fire again (window reopen) and must
            // not recreate managers or stack observers
            if !managersInitialized {
                initializeManagers()
                loadWorkspacesFromDisk()

                // Load favicons for all tabs BEFORE web views are loaded
                preloadFaviconsForAllTabs()

                // Setup observer for tab title display mode changes
                NotificationCenter.default.addMainActorObserver(
                    forName: .browserTabTitleDisplayModeChanged,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    tabTitleDisplayRefreshTrigger = UUID()
                }

                NotificationCenter.default.addMainActorObserver(
                    forName: .browserAgentLassoSelected,
                    object: nil,
                    queue: .main
                ) { [self] note in
                    captureAgentLasso(note)
                }

                // Find in page (Cmd+F)
                NotificationCenter.default.addMainActorObserver(
                    forName: .browserFindInPage,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    showFindBar.toggle()
                    if showFindBar {
                        countFindMatches()
                    } else {
                        closeFindBar()
                    }
                }

                // Cmd+G / Cmd+Shift+G cycle through matches
                NotificationCenter.default.addMainActorObserver(
                    forName: .browserFindNext,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    performFind()
                }

                NotificationCenter.default.addMainActorObserver(
                    forName: .browserFindPrevious,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    performFind(backwards: true)
                }

                // Hold-Cmd+Q progress HUD. The manager sends a target and the
                // hold duration; Core Animation sweeps the bar smoothly, so it
                // can't stutter the way the old per-frame feed did.
                NotificationCenter.default.addMainActorObserver(
                    forName: .browserQuitHoldProgress,
                    object: nil,
                    queue: .main
                ) { [self] notification in
                    let target = notification.userInfo?["progress"] as? Double ?? 0
                    let duration = notification.userInfo?["duration"] as? Double ?? 0
                    if target > 0 {
                        // Mount the HUD at 0, then animate to full next tick — a
                        // freshly inserted view won't animate from a value it
                        // never had, so it would otherwise snap straight to full.
                        quitHoldActive = true
                        quitHoldProgress = 0
                        DispatchQueue.main.async {
                            withAnimation(.linear(duration: duration)) { quitHoldProgress = 1 }
                        }
                    } else {
                        quitHoldActive = false
                        quitHoldProgress = 0
                    }
                }

                // Screenshot shutter flash
                NotificationCenter.default.addMainActorObserver(
                    forName: .browserScreenshotFlash,
                    object: nil,
                    queue: .main
                ) { [self] notification in
                    guard let rect = notification.userInfo?["rect"] as? CGRect else { return }
                    flashRect = rect
                    flashOpacity = 0.8
                    withAnimation(.easeOut(duration: 0.22)) { flashOpacity = 0 }
                }

                // Cmd+Shift+H shortcut cheat sheet
                NotificationCenter.default.addMainActorObserver(
                    forName: .browserToggleShortcutOverlay,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    showShortcutCheatSheet.toggle()
                }

                NotificationCenter.default.addMainActorObserver(
                    forName: .browserToggleAgent,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    withAnimation(.easeInOut(duration: 0.2)) { showAgentPanel.toggle() }
                }

                // Toggle tab bar between hidden and last visible width (Cmd+Shift+L)
                NotificationCenter.default.addMainActorObserver(
                    forName: .browserToggleTabBar,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    if tabBarWidth > 0 {
                        UserDefaults.standard.set(tabBarWidth, forKey: "lastTabBarWidth")
                        tabBarWidth = 0
                    } else {
                        let last = UserDefaults.standard.double(forKey: "lastTabBarWidth")
                        tabBarWidth = last > 0 ? last : 200
                    }
                }

                NotificationCenter.default.addMainActorObserver(forName: .browserShowTabGrid, object: nil, queue: .main) { [self] _ in
                    // Snapshot the tab you're on first; every other tab was captured
                    // when you switched away from it.
                    webViewManager?.captureThumbnail(for: tabManager.selectedTabId)
                    showTabGrid.toggle()
                }

                // Privacy & session commands (Privacy menu + ⇧⌘N / ⇧⌘E)
                NotificationCenter.default.addMainActorObserver(forName: .browserNewIncognitoTab, object: nil, queue: .main) { [self] _ in
                    _ = tabManager.createIncognitoTab()   // fresh, isolated private session
                    showOmnibar = true
                }
                NotificationCenter.default.addMainActorObserver(forName: .browserNewRegularTab, object: nil, queue: .main) { [self] _ in
                    _ = tabManager.createNewTab()          // force a normal tab, leaving any session
                    showOmnibar = true
                }
                NotificationCenter.default.addMainActorObserver(forName: .browserConvertTabToIncognito, object: nil, queue: .main) { [self] _ in
                    if let tab = allTabs.first(where: { $0.id == tabManager.selectedTabId }) {
                        tabManager.convertToIncognito(tab)
                    }
                }
                NotificationCenter.default.addMainActorObserver(forName: .browserClearSiteData, object: nil, queue: .main) { [self] _ in
                    clearActiveSite()
                }
                NotificationCenter.default.addMainActorObserver(forName: .browserClearSessionData, object: nil, queue: .main) { [self] _ in
                    clearActiveSession()
                }
                NotificationCenter.default.addMainActorObserver(forName: .browserClearAllData, object: nil, queue: .main) { [self] _ in
                    clearAllData()
                }

                // SwiftData is the session store: tabs are already loaded via @Query.
                // Register any restored container tabs' sessions before they activate.
                webViewManager?.syncSessions(from: tabs)
                // Select the tab that was active last time, tabs load lazily on
                // selection. If every synced record is locally hidden, that is
                // also an empty local session.
                if visiblePersistedTabs.isEmpty {
                    _ = tabManager.createNewTab()
                    showOmnibar = true
                } else {
                    tabManager.selectedTabId =
                        visiblePersistedTabs.first(where: { $0.isActive })?.id
                        ?? visiblePersistedTabs.first?.id
                    // Restore last session's split (drops ids that no longer resolve)
                    tabManager.restoreSplit(from: visiblePersistedTabs)
                }
            }

            // Safe to re-run: observer setup is balanced by cleanup/teardown in onDisappear
            notificationManager?.setupNotificationObservers()
            keyboardShortcutsManager?.setupKeyboardShortcuts()
        }
        // Every way the active tab changes writes selectedTabId, so peek from
        // here rather than the individual switch/close/reopen paths: Cmd+W and
        // Cmd+Shift+T get it too, and a no-op switch (Cmd+5 with 3 tabs open)
        // doesn't peek because the value never changed.
        .onChange(of: tabManager.selectedTabId) { _, _ in peekFavicon() }
        .onChange(of: showOmnibar) { _, isShowing in
            // Dismissing the omnibar (Esc, click-away) without navigating takes
            // the blank tab it was opened for with it. Navigating first gives the
            // tab a URL, so this no-ops there.
            if isShowing {
                DispatchQueue.main.async {
                    accessibilityFocus = .omnibar
                }
            } else {
                tabManager.closePendingNewTab(tabs: allTabs)
                accessibilityFocus = .page
            }
        }
        .onChange(of: contentModal) { _, modal in
            DispatchQueue.main.async {
                switch modal {
                case .library: accessibilityFocus = .library
                case .reader: accessibilityFocus = .reader
                case nil: accessibilityFocus = .page
                }
            }
        }
        .onChange(of: tabManager.selectedTabId) { oldValue, newValue in
            Logger.log("ContentView onChange selectedTabId: \(oldValue?.uuidString ?? "nil") -> \(newValue?.uuidString ?? "nil")", type: "ContentView")

            // Switching away from the blank tab the last new-tab command
            // created closes it automatically, so repeated ⌘T doesn't pile
            // up abandoned blank tabs.
            tabManager.handleSelectionChanged(from: oldValue, tabs: allTabs)

            // Persist which tab is active so relaunch restores the selection
            tabManager.updateActiveTab(in: allTabs)

            // Update the WebViewManager with the new active tab. The WebView's
            // URL binding reads from the active tab, so nothing else to sync.
            webViewManager?.setActiveTab(newValue)
            if showDeveloperTools && developerToolsPlacement == .window {
                DispatchQueue.main.async { synchronizeDeveloperToolsWindow() }
            }
        }
        .onChange(of: showDeveloperTools) { _, isPresented in
            if isPresented {
                synchronizeDeveloperToolsWindow()
            } else {
                dismissWindow(id: "developer-tools")
            }
        }
        .onChange(of: developerToolsPlacementRaw) { oldValue, _ in
            if oldValue == DeveloperToolsPlacement.window.rawValue,
               developerToolsPlacement != .window {
                dismissWindow(id: "developer-tools")
            }
            synchronizeDeveloperToolsWindow()
        }
        .contentViewTypeErased()
        .onReceive(NotificationCenter.default.publisher(for: .memoryPressure)) { note in
            let critical = (note.userInfo?["critical"] as? Bool) ?? false
            handleMemoryPressure(critical: critical)
        }
        .modifier(DeveloperToolsCommandModifier(
            isPresented: $showDeveloperTools,
            model: developerTools
        ))
        .onReceive(NotificationCenter.default.publisher(for: .browserShowHistory)) { _ in
            showHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserToggleReader)) { _ in
            showReaderMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserAddToNewspaper)) { notification in
            guard BrowserWindowCommandRouting.matches(
                target: notification.object as AnyObject?,
                recipient: webViewManager?.activeWebView?.window
            ) else { return }
            addCurrentPageToNewspaper()
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserShowNewspaper)) { _ in
            openWindow(id: "newspaper")
        }
        .onChange(of: isLoading) { oldValue, newValue in
            if newValue {
                // Page started loading: show the loading bar right away
                hasRenderedContent = false
                withAnimation(.easeIn(duration: 0.2)) {
                    showProgressBar = true
                }
            } else {
                // Page finished loading
                if showProgressBar {
                    // First animate progress to 100% if not already complete
                    if progressValue < 1.0 {
                        withAnimation(.linear(duration: max(0.02, 1.0 - progressValue) * 0.1)) {
                            self.progressValue = 1.0
                        }
                        // Then fade out after a brief delay to show 100%
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.35)) {
                                self.showProgressBar = false
                            }
                        }
                    } else {
                        // Progress already at 100%, fade out immediately
                        withAnimation(.easeOut(duration: 0.35)) {
                            self.showProgressBar = false
                        }
                    }
                }
            }
        }
        .onChange(of: tabs) { oldTabs, newTabs in
            // Keep container-tab sessions registered, and keep a valid selection across
            // the merged working set (incognito tabs included).
            webViewManager?.syncSessions(from: newTabs)
            tabManager.ensureSelectedTab(from: allTabs)
        }
        .onDisappear(perform: handleContentViewDisappear)
        .contentViewTypeErased()
        .sheet(item: $contentModal) { modal in
            switch modal {
            case .library:
                librarySheet
            case .reader(let article):
                readerSheet(article)
            }
        }
        .alert(item: $persistenceDiagnostics.latestIssue, content: persistenceAlert)
        // Matches the window's own (unexposed) corner rounding so full-bleed
        // overlays — the screenshot flash, the agent panel, anything else that
        // paints edge to edge — follow the same curve instead of squaring off
        // a corner the real window already clips.
        .clipShape(
            WindowLayout.isSquareCorners
                ? AnyShape(Rectangle())
                : AnyShape(RoundedRectangle(cornerRadius: WindowLayout.windowCornerRadius, style: .continuous))
        )
        // Hides the traffic lights and titlebar on the window actually hosting this
        // view, once it has one — see WindowChrome for why this isn't done at onAppear.
        .background(WindowChrome())
    }

    private func handleContentViewDisappear() {
        finishSidebarTabDrag()
        notificationManager?.cleanup()
        keyboardShortcutsManager?.teardown()
    }

    private func persistenceAlert(for issue: PersistenceIssue) -> Alert {
        Alert(
            title: Text("Browser Data Couldn’t Be Saved"),
            message: Text(issue.operation + ": " + issue.message),
            dismissButton: .default(Text("OK"))
        )
    }

    private func initializeManagers() {
        if TabSync.clearLegacySessionStorage(in: tabs) > 0 {
            try? modelContext.save()
        }
        let webViewManager = WebViewManager()
        let navigationManager = NavigationManager()
        self.webViewManager = webViewManager
        self.navigationManager = navigationManager
        tabManager.setModelContext(modelContext)
        tabManager.setWebViewManager(webViewManager)
        #if os(macOS)
        webViewManager.extensionTabCreationHandler = {
            [weak tabManager, weak webViewManager] url, shouldActivate in
            guard let tabManager, let webViewManager else { return nil }
            let session = webViewManager.activeTabId
                .map(webViewManager.session(for:)) ?? (.normal, nil)
            let tab = tabManager.createTab(
                inheriting: session,
                url: url,
                select: shouldActivate
            )
            let webView = webViewManager.getWebView(for: tab.id)
            if let url {
                webView.loadURL(url)
            }
            return tab.id
        }
        #endif
        tabManager.fastForward = fastForward
        fastForward.configure(tabManager: tabManager,
                              webViewManager: webViewManager,
                              tabs: { self.allTabs })
        bookmarkManager = BookmarkManager(modelContext: modelContext)
        autofill.configure(webViewManager: webViewManager, modelContext: modelContext)
        managersInitialized = true

            notificationManager = NotificationManager(
                tabManager: tabManager,
                navigationManager: navigationManager,
                webViewManager: webViewManager,
                modelContext: modelContext,
                pageTranslator: pageTranslator,
                showOmnibar: $showOmnibar,
                tabs: { self.allTabs },
                closeTabAction: { tab, tabs in
                    // The omnibar edits the current tab's address; once that tab is
                    // gone it's pointing at nothing, so dismiss it with the tab.
                    self.showOmnibar = false
                    tabManager.closeTab(tab, tabs: tabs)
                },
                closeTabSetAction: {
                    self.showOmnibar = false
                    tabManager.closeTabSet(tabs: allTabs)
                },
                createNewTabAction: {
                    // Inherit the active tab's session so Cmd+T stays in the current
                    // container/incognito (a fresh incognito comes from ⇧⌘N instead).
                    // A second press while still on the blank tab undoes it instead
                    // of creating another (see TabManager.newTabOrUndo).
                if tabManager.newTabOrUndo(tabs: allTabs, inheriting: self.activeSession()) != nil {
                    self.showOmnibar = true
                }
            },
            setTabBarWidth: { width in
                self.tabBarWidth = width
                UserDefaults.standard.set(width, forKey: "tabBarWidth")
            },
            switchToTabAction: { index in self.switchToTab(at: index) },
            switchToNextTabAction: { self.switchToNextTab() },
            switchToPreviousTabAction: { self.switchToPreviousTab() },
            addBookmarkAction: { self.toggleBookmark() },
            showBookmarksAction: { self.showBookmarks() },
            importBookmarksAction: { self.presentImportBookmarksDialog() },
            createWindowAction: { self.openWindow(id: "browser") }
        )

        keyboardShortcutsManager = KeyboardShortcutsManager(
            showOmnibar: $showOmnibar,
            reloadAction: { self.reload() },
            hardReloadAction: { self.hardReload() },
            reloadAllTabsAction: { self.reloadAllTabs() },
            goBackAction: { self.goBack() },
            goForwardAction: { self.goForward() },
            webViewManager: webViewManager
        )
    }

    private func createNewTab() {
        // Inherit the active tab's session (matches Cmd+T). A second press
        // while still on the blank tab undoes it instead of creating another.
        if tabManager.newTabOrUndo(tabs: allTabs, inheriting: activeSession()) != nil {
            showOmnibar = true
        }
    }

    // The active tab's session, so a new tab (Cmd+T / +) stays in the same
    // container/incognito.
    private func activeSession() -> (kind: SessionKind, sessionId: UUID?) {
        guard let active = tabManager.getActiveTab(from: allTabs) else { return (.normal, nil) }
        return (active.sessionKind, active.sessionId)
    }

    // WebKit deletes are irreversible, so warn before any destructive clear.
    private func confirmClear(_ message: String, informative: String, perform: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Clear"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { perform() }
    }

    private func clearActiveSite() {
        guard let webView = webViewManager?.activeWebView, let host = webView.url?.host else { return }
        confirmClear(
            String(localized: "Clear data for \(host)?"),
            informative: String(localized: "Removes cookies, cache, and storage for this site in the current session. This can’t be undone.")
        ) {
            BrowsingDataCleaner.clearSite(host: host, in: webView.configuration.websiteDataStore) {
                DispatchQueue.main.async { webView.reloadFromOrigin() }
            }
        }
    }

    private func clearActiveSession() {
        guard let webView = webViewManager?.activeWebView else { return }
        confirmClear(
            String(localized: "Clear this session’s data?"),
            informative: String(localized: "Wipes all cookies, cache, and storage in the current tab’s session. This can’t be undone.")
        ) {
            BrowsingDataCleaner.clearStore(webView.configuration.websiteDataStore) {
                DispatchQueue.main.async { webView.reloadFromOrigin() }
            }
        }
    }

    private func clearAllData() {
        confirmClear(
            String(localized: "Clear all browsing data?"),
            informative: String(localized: "Removes cookies, cache, and storage from normal browsing and every container. This can’t be undone.")
        ) {
            BrowsingDataCleaner.clearEverything(
                containerIdentifiers: browserSessions.map(\.id)
            )
        }
    }

    private func createTabGroup(name: String, color: Color) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let newGroup = TabGroup(name: trimmedName, color: color, orderIndex: tabGroups.count)
        modelContext.insert(newGroup)
    }

    private func createContainer(name: String, color: Color) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let session = BrowserSession(name: trimmed, color: color)
        modelContext.insert(session)
        _ = tabManager.createTab(inheriting: (.container, session.id))
        showOmnibar = true
    }

    private func deleteContainer(_ session: BrowserSession) {
        // Close its tabs, forget the definition, and wipe its on-disk jar.
        let toClose = tabs.filter { $0.sessionKind == .container && $0.sessionId == session.id }
        for tab in toClose { tabManager.closeTab(tab, tabs: allTabs) }
        let id = session.id
        tabManager.purgeClosedTabs(forSession: id)
        ContainerStoreRemoval.remove(identifier: id) { result in
            switch result {
            case .success:
                modelContext.delete(session)
            case .failure(let error):
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = String(localized: "Container Data Couldn’t Be Removed")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func deleteGroup(_ group: TabGroup) {
        // Move all tabs in this group to ungrouped
        for tab in tabs where tab.groupId == group.id {
            tab.groupId = nil
        }
        modelContext.delete(group)
    }

    private func moveTabToGroup(_ tab: Tab, groupId: UUID?) {
        tab.groupId = groupId
    }

    private func saveCurrentWorkspace(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let workspace = SavedWorkspace(name: trimmedName, groups: tabGroups, tabs: tabs)
        savedWorkspaces.append(workspace)
        saveWorkspacesToDisk()
    }

    private func loadWorkspace(_ workspace: SavedWorkspace) {
        // Workspace replacement is not a normal user close: discard views and
        // models without adding every old tab to the reopen stack.
        tabManager.discardTabsForWorkspaceLoad(tabs)
        for group in tabGroups {
            modelContext.delete(group)
        }

        // Restore groups
        var restoredGroups: [UUID: TabGroup] = [:]
        for savedGroup in workspace.groups {
            let group = TabGroup(name: savedGroup.name, color: Color(hex: savedGroup.colorHex) ?? Color.blue, orderIndex: savedGroup.orderIndex)
            group.id = savedGroup.id
            modelContext.insert(group)
            restoredGroups[group.id] = group
        }

        // Restore tabs
        var restoredTabs: [Tab] = []
        for savedTab in workspace.tabs {
            let tab = savedTab.makeTab()
            modelContext.insert(tab)
            restoredTabs.append(tab)
        }
        webViewManager?.syncSessions(from: restoredTabs)

        // Select the first tab if available
        DispatchQueue.main.async {
            if let firstTab = try? modelContext.fetch(FetchDescriptor<Tab>()).first {
                tabManager.selectedTabId = firstTab.id
            }
        }
    }

    private func saveWorkspacesToDisk() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(savedWorkspaces) {
            UserDefaults.standard.set(data, forKey: "saved_workspaces")
            UserDefaults.standard.synchronize()
        }
    }

    private func loadWorkspacesFromDisk() {
        if let data = UserDefaults.standard.data(forKey: "saved_workspaces") {
            let decoder = JSONDecoder()
            if let workspaces = try? decoder.decode([SavedWorkspace].self, from: data) {
                savedWorkspaces = workspaces
            }
        }
    }

    private func preloadFaviconsForAllTabs() {
        Logger.log("Preloading favicons for all tabs before web views are loaded...", type: "ContentView")
        
        for tab in tabs {
            // Skip if tab already has a favicon
            if tab.favicon != nil {
                Logger.log("Tab \(tab.url?.absoluteString ?? "no url") already has favicon", type: "ContentView")
                continue
            }
            
            guard let url = tab.url else {
                // Generate domain initial for tabs without URLs
                if let domainInitial = DomainInitialsGenerator.shared.generateInitialImage(for: "newtab") {
                    tab.favicon = domainInitial
                }
                continue
            }
            
            Logger.log("Preloading favicon for tab: \(url.absoluteString)", type: "ContentView")
            
            // First check cache
            if let cachedFavicon = FaviconCache.shared.getFavicon(
                for: url,
                scope: FaviconCacheScope.forTab(tab)
            ) {
                Logger.log("Found cached favicon for \(url.absoluteString), setting on tab", type: "ContentView")
                tab.favicon = cachedFavicon
                continue
            }

            // Network favicon loads happen only after the tab's WKWebView exists,
            // so they inherit that tab's normal/container/private data store.
            if let host = url.host,
               let domainInitial = DomainInitialsGenerator.shared.generateInitialImage(
                   for: host
               ) {
                tab.favicon = domainInitial
            }
        }
    }

    private func updateTabTitle(_ tab: BrowserTab) {
        tabManager.updateTabTitle(tab)
    }

    private var activeTab: BrowserTab? {
        let active = tabManager.getActiveTab(from: allTabs)
        if active == nil && tabManager.selectedTabId != nil {
            Logger.log("ContentView activeTab: selectedTabId is \(tabManager.selectedTabId?.uuidString ?? "nil") but no matching tab found in \(tabs.count) tabs", type: "ContentView")
            for tab in tabs {
                Logger.log("  Tab: \(tab.id) - \(tab.title)", type: "ContentView")
            }
        }
        return active
    }




    // WKWebView's back-forward list is the single source of truth;
    // the tab's URL/title update via the navigation delegate.
    private func goBack() {
        guard let webViewManager else { return }
        if !webViewManager.canGoBack {
            var closedChild = false
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                closedChild = tabManager.closeAutomaticallyOpenedLinkOnBack(tabs: allTabs)
            }
            if closedChild { return }
        }
        webViewManager.goBack()
    }

    private func goForward() {
        webViewManager?.goForward()
    }

    private func reload() {
        if isLoading {
            webViewManager?.stopLoading()
        } else {
            webViewManager?.reload()
        }
    }

    private func hardReload() {
        // For hard reload, we need to access the active web view directly
        if let webView = webViewManager?.activeWebView {
            webView.reloadFromOrigin()
        }
    }

    private func reloadAllTabs() {
        webViewManager?.reloadAllTabs()
    }

    private func copyURL(of tab: Tab) {
        guard let url = tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func shareTab(_ tab: Tab) {
        guard let url = tab.url, let window = NSApp.keyWindow, let contentView = window.contentView else { return }
        let point = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [url]).show(relativeTo: NSRect(origin: point, size: .zero), of: contentView, preferredEdge: .minY)
    }

    private func toggleBookmark() {
        guard let activeTab = activeTab,
              let url = activeTab.url,
              let bookmarkManager = bookmarkManager else { return }

        if isCurrentPageBookmarked {
            // Remove bookmark
            if let bookmark = bookmarks.first(where: { $0.url.absoluteString == url.absoluteString }) {
                bookmarkManager.removeBookmark(bookmark)
            }
        } else {
            // Add bookmark
            _ = bookmarkManager.addBookmark(from: activeTab)
        }
    }

    private func showBookmarks() {
        librarySection = .bookmarks
        contentModal = .library
    }

    private func showHistory() {
        librarySection = .history
        contentModal = .library
    }

    private func openFromLibrary(_ url: URL) {
        _ = navigationManager?.navigateToURL(url.absoluteString, activeTab: activeTab)
        contentModal = nil
    }

    private func removeHistoryURL(_ url: URL) {
        BrowserLibrary.removeHistory(url: url, from: allTabs)
        SiteHistory.shared.remove(url: url)
        BrowsingHistoryStore.shared.remove(url: url)
        try? modelContext.save()
    }

    private func clearHistoryFromLibrary() {
        confirmClear(
            String(localized: "Clear all browsing history?"),
            informative: String(localized: "Removes visited URLs and site suggestions. This can’t be undone.")
        ) {
            BrowsingDataCleaner.clearHistory(in: allTabs)
        }
    }

    private func showReaderMode() {
        guard let webViewManager else { return }
        webViewManager.evaluateJavaScript(ReaderMode.extractionScript) { value, error in
            if let article = ReaderMode.article(from: value) {
                contentModal = .reader(article)
            } else {
                let alert = NSAlert()
                alert.messageText = String(localized: "Reader Mode Unavailable")
                alert.informativeText = error?.localizedDescription
                    ?? String(localized: "This page does not contain readable text.")
                alert.runModal()
            }
        }
    }

    private func addCurrentPageToNewspaper() {
        guard let tab = activeTab else { return }
        addTabToNewspaper(tab)
    }

    private func addTabToNewspaper(_ tab: Tab) {
        guard tab.sessionKind != .incognito else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Newspaper Is Unavailable in Incognito")
            alert.informativeText = String(localized: "Saving an article would persist its title, source, and readable text. Open it in a regular tab first.")
            alert.runModal()
            return
        }
        guard let url = tab.url,
              url.scheme == "http" || url.scheme == "https",
              let webView = webViewManager?.existingWebView(for: tab.id) else { return }

        let store = NewspaperStore(modelContext: modelContext)
        let result = store.enqueue(url: url, title: tab.title)
        NewspaperCaptureCoordinator.capture(
            result.article,
            from: webView,
            expectedURL: url,
            store: store
        )
    }

    /// Scratch clips keep source attribution, but they do not pretend that a
    /// quote or thumbnail is the whole article. Open (or reuse) the ordinary
    /// source Tab and pass its real WebKit document through Newspaper's normal
    /// capture path.
    private func addScratchSourceToNewspaper(_ url: URL, _ title: String) {
        let key = NewspaperStore.sourceKey(for: url)
        let sourceTab = allTabs.first { tab in
            guard tab.sessionKind != .incognito, let tabURL = tab.url else { return false }
            return NewspaperStore.sourceKey(for: tabURL) == key
        } ?? tabManager.createNewTab(url: url)

        tabManager.selectedTabId = sourceTab.id
        if sourceTab.title == String(localized: "New Tab"), !title.isEmpty {
            sourceTab.title = title
        }

        Task { @MainActor in
            // A newly-created Tab receives its WKWebView on the next layout.
            // Once it exists, NewspaperCaptureCoordinator owns load waiting,
            // document binding, retries, and failure reporting.
            for _ in 0..<20 {
                if webViewManager?.existingWebView(for: sourceTab.id) != nil {
                    addTabToNewspaper(sourceTab)
                    openWindow(id: "newspaper")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func presentImportBookmarksDialog() {
        availableBrowsers = BookmarkImporter.detectAvailableBrowsers()
        if !availableBrowsers.isEmpty {
            isImportBookmarksDialogPresented = true
        } else {
            // Show alert that no browsers were found
            let alert = NSAlert()
            alert.messageText = String(localized: "No Browsers Found")
            alert.informativeText = String(localized: "No compatible browsers with bookmarks were found on your system.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
    }

    private func importBookmarks(from browser: BrowserType) {
        isImportBookmarksDialogPresented = false

        let importedBookmarks = BookmarkImporter.importBookmarks(from: browser)
        guard !importedBookmarks.isEmpty else {
            let alert = NSAlert()
            alert.messageText = String(localized: "No Bookmarks Found")
            alert.informativeText = String(localized: "No bookmarks were found in \(browser.displayName).")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return
        }

        // Import the bookmarks (deduped, single save)
        let addedCount = bookmarkManager?.importBookmarks(
            importedBookmarks.map { (title: $0.title, url: $0.url) }
        ) ?? 0

        // Show success message
        let alert = NSAlert()
        alert.messageText = String(localized: "Import Complete")
        // ponytail: simple %lld interpolation, not per-language plural rules — one-time import dialog; add plural variants if it matters
        alert.informativeText = String(localized: "Imported \(addedCount) new bookmarks from \(browser.displayName) (\(importedBookmarks.count - addedCount) already existed).")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private func switchToNextTab() {
        tabManager.switchToNextTab(tabs: visibleTabOrder)
        // TabManager is now observed directly, no manual sync needed
    }

    private func switchToPreviousTab() {
        tabManager.switchToPreviousTab(tabs: visibleTabOrder)
        // TabManager is now observed directly, no manual sync needed
    }

    private func switchToTab(at index: Int) {
        tabManager.switchToTab(at: index, tabs: visibleTabOrder)
    }

    private func closeCurrentTab() {
        if let activeTab = activeTab {
            tabManager.closeTab(activeTab, tabs: allTabs)
        }
    }

    private func startAgentLasso() {
        webViewManager?.activeWebView?.evaluateJavaScript(
            "window.__subAgentLasso && window.__subAgentLasso.start()"
        )
    }

    private func captureAgentLasso(_ note: Notification) {
        guard let tabID = note.userInfo?["tabID"] as? UUID,
              tabID == tabManager.selectedTabId,
              let requested = note.userInfo?["rect"] as? CGRect,
              let webView = webViewManager?.activeWebView else { return }
        let bounds = CGRect(origin: .zero, size: webView.bounds.size)
        let rect = requested.intersection(bounds)
        guard rect.width >= 4, rect.height >= 4 else { return }

        let script = """
        (function() {
            var r={left:\(rect.minX),top:\(rect.minY),right:\(rect.maxX),bottom:\(rect.maxY)};
            var values=[];
            document.querySelectorAll('body *').forEach(function(el) {
                var b=el.getBoundingClientRect();
                if (b.right<r.left||b.left>r.right||b.bottom<r.top||b.top>r.bottom) return;
                if (el.children.length && !/^(BUTTON|A|INPUT|TEXTAREA|SELECT)$/.test(el.tagName)) return;
                var text=(el.innerText||el.getAttribute('aria-label')||el.getAttribute('alt')||'').replace(/\\s+/g,' ').trim();
                if (text && !values.includes(text)) values.push(text.slice(0,500));
            });
            return values.join('\\n').slice(0,8000);
        })();
        """
        webView.evaluateJavaScript(script) { value, _ in
            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect
            configuration.snapshotWidth = max(1, min(800, rect.width * 2)) as NSNumber
            webView.takeSnapshot(with: configuration) { image, _ in
                guard let image else { return }
                DispatchQueue.main.async {
                    agentLassoSelection = AgentLassoSelection(
                        image: image,
                        extractedText: value as? String ?? "",
                        sourceURL: webView.url
                    )
                }
            }
        }
    }

    private func performAgentAISearch(_ query: String) async -> Bool {
        guard let webView = webViewManager?.activeWebView else { return false }
        let script = """
        (function() {
            function selector(el) {
                if (el.id) return '#' + CSS.escape(el.id);
                var parts=[];
                while(el&&el.nodeType===1&&el!==document.documentElement){
                    var part=el.tagName.toLowerCase();
                    if(el.parentElement){var same=Array.from(el.parentElement.children).filter(function(x){return x.tagName===el.tagName;});if(same.length>1)part+=':nth-of-type('+(same.indexOf(el)+1)+')';}
                    parts.unshift(part);el=el.parentElement;
                }
                return 'html > '+parts.join(' > ');
            }
            var items=[];
            document.querySelectorAll('a,button,input,textarea,select,[role],h1,h2,h3,h4,p,li,label').forEach(function(el){
                var r=el.getBoundingClientRect(),s=getComputedStyle(el);
                if(r.width<2||r.height<2||s.display==='none'||s.visibility==='hidden')return;
                var text=(el.innerText||el.value||el.getAttribute('aria-label')||el.title||el.placeholder||'').replace(/\\s+/g,' ').trim();
                if(text)items.push({selector:selector(el),text:text.slice(0,500)});
            });
            return JSON.stringify(items.slice(0,500));
        })();
        """
        guard let raw = try? await webView.evaluateJavaScript(script) as? String,
              let data = raw.data(using: .utf8),
              let candidates = try? JSONDecoder().decode([AgentPageSearchCandidate].self, from: data),
              let match = await AgentPageAISearch.bestMatch(query: query, candidates: candidates) else {
            return false
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: [match.selector]),
              let array = String(data: encoded, encoding: .utf8) else { return false }
        let selector = String(array.dropFirst().dropLast())
        let highlight = """
        (function(){
            document.getElementById('__sub-ai-search-style')?.remove();
            var el;try{el=document.querySelector(\(selector));}catch(_){return false;}if(!el)return false;
            var style=document.createElement('style');style.id='__sub-ai-search-style';
            style.textContent='@keyframes sub-ai-found{0%,100%{outline:3px solid rgba(124,120,255,.2);outline-offset:2px}50%{outline:5px solid rgb(124,120,255);outline-offset:7px}}.__sub-ai-found{animation:sub-ai-found .8s ease-in-out 3!important}';
            document.documentElement.appendChild(style);el.classList.remove('__sub-ai-found');void el.offsetWidth;el.classList.add('__sub-ai-found');
            el.scrollIntoView({behavior:'smooth',block:'center',inline:'center'});setTimeout(function(){el.classList.remove('__sub-ai-found');style.remove();},2600);return true;
        })();
        """
        return (try? await webView.evaluateJavaScript(highlight) as? Bool) ?? false
    }

    /// Runs the local router before a remote provider is given page material.
    /// Each command has an explicit output bound, keeping routine questions
    /// small while leaving richer browser tools available to the agent later.
    private func prepareAgentLocalContext(_ prompt: String) async -> AgentLocalPageContext {
        guard let webView = webViewManager?.activeWebView else {
            return AgentLocalPageContext(command: .none, content: "")
        }
        let command = await AgentLocalPageRouter.command(for: prompt)
        guard command != .none,
              let promptData = try? JSONSerialization.data(
                withJSONObject: prompt,
                options: [.fragmentsAllowed]
              ),
              let encodedPrompt = String(data: promptData, encoding: .utf8) else {
            return AgentLocalPageContext(command: command, content: "")
        }
        if agentLoadsMorePageContent {
            _ = try? await AgentPageLoadExpander.expand(webView)
        }
        let script: String
        switch command {
        case .matchingText:
            script = """
            (function(query) {
                const words = query.toLowerCase().split(/[^\\p{L}\\p{N}]+/u).filter(word => word.length >= 3).slice(0, 12);
                if (!words.length) return '';
                const lines = (document.body?.innerText || '').split(/\\n+/).map(line => line.trim()).filter(Boolean);
                const matches = lines.filter(line => {
                    const value = line.toLowerCase();
                    return words.some(word => value.includes(word));
                }).slice(0, 40).map(line => line.slice(0, 420));
                return matches.join('\\n');
            })(\(encodedPrompt));
            """
        case .links:
            script = """
            (function() {
                const links = Array.from(document.querySelectorAll('a[href]')).map(link => ({
                    text: (link.innerText || link.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim(),
                    url: link.href
                })).filter(link => link.text || link.url);
                const unique = Array.from(new Map(links.map(link => [link.url, link])).values()).slice(0, 80);
                return unique.map(link => link.text.slice(0, 180) + ' — ' + link.url).join('\\n');
            })();
            """
        case .headings:
            script = """
            Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6,[role=heading]'))
                .map(item => item.tagName.toLowerCase() + ': ' + (item.innerText || '').replace(/\\s+/g, ' ').trim())
                .filter(Boolean).slice(0, 100).join('\\n');
            """
        case .articleIndex, .articleResearch:
            script = """
            (function() {
                const root = document.body;
                if (!root) return '[]';
                const clean = value => String(value || '').replace(/\\s+/g, ' ').trim();
                const rendered = element => {
                    const style = getComputedStyle(element);
                    return style.display !== 'none' && style.visibility !== 'hidden'
                        && style.contentVisibility !== 'hidden';
                };
                const rows = [];
                const identities = new Set();
                const add = (title, url, context) => {
                    title = clean(title).slice(0, 320);
                    url = String(url || '').slice(0, 1000);
                    const identity = (url || title).toLowerCase();
                    if (!title || identities.has(identity)) return;
                    identities.add(identity);
                    rows.push({
                        title,
                        url,
                        context: clean(context).slice(0, 700)
                    });
                };
                root.querySelectorAll('article').forEach(article => {
                    if (!rendered(article)) return;
                    const heading = article.querySelector('h1,h2,h3,h4,[role=heading]');
                    const link = heading?.closest('a[href]') || article.querySelector('a[href]');
                    add(heading?.innerText || link?.innerText, link?.href, article.innerText);
                });
                root.querySelectorAll('h1,h2,h3,h4,[role=heading]').forEach(heading => {
                    if (!rendered(heading)) return;
                    const link = heading.closest('a[href]') || heading.querySelector('a[href]')
                        || heading.parentElement?.querySelector('a[href]');
                    if (!link?.href) return;
                    const contextRoot = heading.closest('article,li,section') || heading.parentElement;
                    add(heading.innerText, link.href, contextRoot?.innerText || heading.innerText);
                });
                root.querySelectorAll('a[href]').forEach(link => {
                    if (!rendered(link) || link.closest('nav,header,footer')) return;
                    let url;
                    try { url = new URL(link.href, document.baseURI); } catch { return; }
                    if (!/^https?:$/.test(url.protocol) || url.origin !== location.origin) return;
                    const container = link.closest('article,li,[class*=card],[class*=story],section')
                        || link.parentElement;
                    const heading = container?.querySelector('h1,h2,h3,h4,[role=heading]');
                    const linkText = clean(link.innerText || link.getAttribute('aria-label'));
                    const title = clean(heading?.innerText) || linkText;
                    if (title.length < 18 || /^(read more|learn more|more stories)$/i.test(title)) return;
                    add(title, url.href, container?.innerText || linkText);
                });
                return JSON.stringify({
                    candidates: rows.slice(0, 240),
                    pageText: String(document.body?.innerText || '').slice(0, 36000)
                });
            })();
            """
        case .offerValidity:
            script = """
            (function() {
                const root = document.querySelector('main,[role=main]') || document.body;
                if (!root) return '';
                const lines = (root.innerText || '').split(/\\n+/)
                    .map(line => line.replace(/\\s+/g, ' ').trim())
                    .filter(Boolean);
                const relevant = /\\b(valid|active|expire|expires|expiration|until|through|after today|before|good for|offer|redeem|use by|full week|full month)\\b/i;
                const selected = new Set();
                lines.forEach((line, index) => {
                    if (!relevant.test(line)) return;
                    for (let nearby = Math.max(0, index - 1); nearby <= Math.min(lines.length - 1, index + 1); nearby++) {
                        selected.add(nearby);
                    }
                });
                const result = Array.from(selected).sort((a, b) => a - b)
                    .slice(0, 60).map(index => lines[index].slice(0, 500));
                const dates = Array.from(root.querySelectorAll('time,[datetime]'))
                    .map(element => {
                        const label = (element.innerText || '').replace(/\\s+/g, ' ').trim();
                        const value = element.getAttribute('datetime') || '';
                        return [label, value].filter(Boolean).join(' — ');
                    }).filter(Boolean).slice(0, 20);
                if (dates.length) result.push('Page date markers:', ...dates);
                return result.join('\\n').slice(0, 12000);
            })();
            """
        case .mainText:
            script = """
            (document.body?.innerText || '').slice(0, 36000);
            """
        case .none:
            return AgentLocalPageContext(command: .none, content: "")
        }
        let rawContent = (try? await webView.evaluateJavaScript(script) as? String) ?? ""
        let content: String
        if command == .articleIndex || command == .articleResearch,
           let data = rawContent.data(using: .utf8),
           let evidence = try? JSONDecoder().decode(AgentArticlePageEvidence.self, from: data) {
            if command == .articleResearch {
                content = AgentArticleIndexFormatter.researchContent(
                    evidence: evidence,
                    prompt: prompt
                )
            } else {
                content = AgentArticleIndexFormatter.content(
                    candidates: evidence.candidates,
                    prompt: prompt
                )
            }
        } else {
            content = rawContent
        }
        let maximumCharacters = command == .articleResearch || command == .mainText
            ? 40_000
            : 12_000
        return AgentLocalPageContext(
            command: command,
            content: String(content.prefix(maximumCharacters))
        )
    }

}

private extension View {
    /// Keeps the very feature-rich browser root from creating one enormous
    /// generic SwiftUI type that can exceed the compiler's type-check budget.
    func contentViewTypeErased() -> AnyView {
        AnyView(self)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Tab.self, inMemory: true)
}
