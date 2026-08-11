//
//  Straight_Up_BrowserTests.swift
//  Straight Up BrowserTests
//
//  Created by Nathan Fennel on 1/9/26.
//

import Testing
import SwiftUI
import SwiftData
import AppKit
import WebKit
@testable import Browser

struct LoggingPrivacyTests {
    @Test func dynamicLogPayloadsArePrivateByDefault() {
        #expect(Logger.defaultPayloadVisibility == .private)
    }
}

@MainActor
struct PrivateTransferHistoryTests {
    @Test func aNewDownloadFailureProducesOneUserFacingNotice() {
        let id = UUID()
        let downloading = ActiveDownload(
            id: id,
            tabId: UUID(),
            filename: "archive.zip",
            destinationPath: nil,
            source: URL(string: "https://example.com/archive.zip"),
            privacy: .standard,
            startedAt: Date(),
            progress: 0.4,
            state: .downloading,
            errorMessage: nil,
            colorIndex: 0
        )
        var failed = downloading
        failed.state = .failed
        failed.errorMessage = "The network connection was lost."

        #expect(DownloadFailureFeedback.newMessage(
            previous: [downloading],
            current: [failed]
        ) == "archive.zip: The network connection was lost.")
        #expect(DownloadFailureFeedback.newMessage(
            previous: [failed],
            current: [failed]
        ) == nil)
    }

    @Test func privateTransfersNeverEnterPersistentHistory() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-transfer-\(UUID().uuidString).json")
        let manager = DownloadManager(storeURL: storeURL)

        manager.record(
            URL(fileURLWithPath: "/tmp/private-upload.txt"),
            kind: .upload,
            source: URL(string: "https://private.example/form"),
            privacy: .privateSession
        )

        #expect(manager.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    @Test func completedPrivateDownloadsDisappearWithoutAHistoryRecord() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-download-\(UUID().uuidString).json")
        let manager = DownloadManager(storeURL: storeURL)
        let transferId = manager.beginDownload(
            tabId: UUID(),
            source: URL(string: "https://private.example/secret.pdf"),
            privacy: .privateSession
        )

        manager.finish(transferId, at: URL(fileURLWithPath: "/tmp/secret.pdf"))

        #expect(manager.activeDownloads.isEmpty)
        #expect(manager.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    @Test func incompleteStandardDownloadsSurviveManagerReload() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("incomplete-download-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let manager = DownloadManager(storeURL: storeURL)
        let transferId = manager.beginDownload(
            tabId: UUID(),
            source: URL(string: "https://example.com/archive.zip")
        )
        manager.update(transferId, progress: 0.42)
        manager.markFailed(
            transferId,
            error: NSError(domain: "Test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The connection was lost."
            ]),
            canRestart: false
        )

        let reloaded = DownloadManager(storeURL: storeURL)
        #expect(reloaded.records.isEmpty)
        #expect(reloaded.activeDownloads.count == 1)
        #expect(reloaded.activeDownloads.first?.state == .failed)
        #expect(reloaded.activeDownloads.first?.progress == 0.42)
        #expect(reloaded.activeDownloads.first?.errorMessage == "The connection was lost.")
    }
}

@MainActor
struct DurableBrowsingHistoryTests {
    @Test func aNormalVisitSurvivesStoreRecreation() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsing-history-\(UUID().uuidString).json")
        let url = URL(string: "https://example.com/kept-after-tab-close")!
        let store = BrowsingHistoryStore(storeURL: storeURL)

        store.record(url: url, title: "Durable Visit", sessionKind: .normal)

        let reopened = BrowsingHistoryStore(storeURL: storeURL)
        #expect(reopened.recentVisits.map(\.url) == [url])
        #expect(reopened.recentVisits.first?.title == "Durable Visit")
    }

    @Test func anIncognitoVisitNeverEntersTheStore() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-history-\(UUID().uuidString).json")
        let store = BrowsingHistoryStore(storeURL: storeURL)

        store.record(
            url: URL(string: "https://private.example/never-store")!,
            title: "Private",
            sessionKind: .incognito
        )

        #expect(store.visits.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }
}

@MainActor
struct ModelContainerStartupTests {
    private struct PersistentStoreFailure: Error {}

    @Test func persistentStoreFailureFallsBackToAnEphemeralContainer() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let fallback = try ModelContainer(for: Tab.self, configurations: configuration)

        let startup = ModelContainerStartup.recover(
            persistent: { throw PersistentStoreFailure() },
            ephemeral: { fallback }
        )

        #expect(startup.container === fallback)
        #expect(startup.didRecover)
        #expect(startup.errorDescription != nil)
    }
}

@MainActor
struct WebViewLifecycleTests {
    private final class MessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {}
    }

    private final class PopupDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {}

    @Test func scriptMessageProxyDoesNotRetainItsHandler() {
        var handler: MessageHandler? = MessageHandler()
        let proxy = WeakScriptMessageHandler(handler: handler!)

        handler = nil

        #expect(!proxy.hasHandler)
        withExtendedLifetime(proxy) {}
    }

    @Test func persistedInteractionStateIsBoundedByCountAndBytes() {
        var entries: [String: Data] = [:]
        for index in 0..<40 {
            entries[String(format: "%02d", index)] = Data(repeating: 1, count: 300_000)
        }
        entries["oversized"] = Data(
            repeating: 2,
            count: InteractionStatePersistencePolicy.maxEntryBytes + 1
        )

        let bounded = InteractionStatePersistencePolicy.bounded(entries)

        #expect(bounded.count <= InteractionStatePersistencePolicy.maxEntries)
        #expect(bounded.values.reduce(0) { $0 + $1.count }
            <= InteractionStatePersistencePolicy.maxTotalBytes)
        #expect(bounded["oversized"] == nil)
    }

    @Test func mediaSuspensionStateSurvivesUnloadButNotTabClose() {
        let manager = WebViewManager()
        let tabID = UUID()

        manager.setMuted(true, for: tabID)
        #expect(manager.isMediaSuspended(for: tabID))

        manager.removeWebView(for: tabID, notifyClosed: false)
        #expect(manager.isMediaSuspended(for: tabID))

        manager.removeWebView(for: tabID, notifyClosed: true)
        #expect(!manager.isMediaSuspended(for: tabID))
    }

    @Test func adoptedPopupIsDelegatedBeforeItCanReceiveAResponse() {
        let manager = WebViewManager()
        let popup = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let delegate = PopupDelegate()

        manager.adoptWebView(
            popup,
            for: UUID(),
            navigationDelegate: delegate,
            uiDelegate: delegate
        )

        #expect(popup.navigationDelegate === delegate)
        #expect(popup.uiDelegate === delegate)
    }
}

struct BrowserResourcePolicyTests {
    @Test func memoryPressureRespectsEachTabPolicy() {
        #expect(BrowserResourcePolicy.shouldUnload(.always, critical: false))
        #expect(BrowserResourcePolicy.shouldUnload(.whenNeeded, critical: false))
        #expect(!BrowserResourcePolicy.shouldUnload(.lastResort, critical: false))
        #expect(BrowserResourcePolicy.shouldUnload(.lastResort, critical: true))
        #expect(!BrowserResourcePolicy.shouldUnload(.never, critical: true))
    }

    @Test func faviconProgressRequiresSettingActiveTabAndLoading() {
        #expect(BrowserResourcePolicy.showFaviconProgress(
            enabled: true,
            isActive: true,
            isLoading: true
        ))
        #expect(!BrowserResourcePolicy.showFaviconProgress(
            enabled: false,
            isActive: true,
            isLoading: true
        ))
        #expect(!BrowserResourcePolicy.showFaviconProgress(
            enabled: true,
            isActive: false,
            isLoading: true
        ))
        #expect(!BrowserResourcePolicy.showFaviconProgress(
            enabled: true,
            isActive: true,
            isLoading: false
        ))
    }
}

struct FaviconLoadingPolicyTests {
    @Test
    func faviconCacheIsSessionScopedAndPrivateBrowsingLeavesNoEntry() {
        let cache = FaviconCache(countLimit: 8)
        let page = URL(string: "https://accounts.example/profile")!
        let containerID = UUID()
        let normalData = Data([0x01])
        let containerData = Data([0x02])

        #expect(cache.setFavicon(normalData, for: page, scope: .normal))
        #expect(cache.getFavicon(for: page, scope: .normal) == normalData)
        #expect(cache.getFavicon(for: page, scope: .container(containerID)) == nil)

        #expect(cache.setFavicon(
            containerData,
            for: page,
            scope: .container(containerID)
        ))
        #expect(
            cache.getFavicon(for: page, scope: .container(containerID))
                == containerData
        )

        #expect(!cache.setFavicon(normalData, for: page, scope: .privateBrowsing))
        #expect(cache.getFavicon(for: page, scope: .privateBrowsing) == nil)
    }

    @Test
    func faviconPayloadsAreBoundedAndUnsafeSchemesAreRejected() {
        let maximum = FaviconLoadingPolicy.maximumByteCount
        let accepted = Data(repeating: 0x01, count: maximum)
        let oversized = Data(repeating: 0x01, count: maximum + 1)

        #expect(
            FaviconLoadingPolicy.decodedPayload(accepted.base64EncodedString())
                == accepted
        )
        #expect(
            FaviconLoadingPolicy.decodedPayload(oversized.base64EncodedString())
                == nil
        )
        #expect(FaviconLoadingPolicy.allows(
            URL(string: "https://example.com/favicon.ico")!
        ))
        #expect(FaviconLoadingPolicy.allows(
            URL(string: "data:image/png;base64,AQ==")!
        ))
        #expect(!FaviconLoadingPolicy.allows(
            URL(string: "data:text/html;base64,AQ==")!
        ))
        #expect(!FaviconLoadingPolicy.allows(
            URL(string: "file:///tmp/favicon.ico")!
        ))
        #expect(!FaviconLoadingPolicy.allows(
            URL(string: "javascript:alert(1)")!
        ))
    }
}

struct SandboxFileAccessTests {
    @Test
    func securityScopedBookmarkRoundTripsASelectedFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let bookmark = try #require(SecurityScopedBookmark.data(for: folder))
        let resolved = try #require(SecurityScopedBookmark.resolve(bookmark))
        defer { resolved.stopAccessingSecurityScopedResource() }

        #expect(resolved.standardizedFileURL == folder.standardizedFileURL)
    }

    @Test
    func selectedFolderRegistryRestoresAccessAcrossInstances() throws {
        let suiteName = "sandbox-folders-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = SecurityScopedFolderRegistry(defaults: defaults)
        #expect(first.remember(folder))

        let restored = SecurityScopedFolderRegistry(defaults: defaults)
            .accessibleURL(for: folder)

        #expect(restored.standardizedFileURL == folder.standardizedFileURL)
    }
}

// The selection ring in the minimal tab bar traces the favicon's own shape, so
// the shape sniffer has to tell a full-bleed tile from a glyph on transparency.
struct FaviconShapeTests {

    // cornerRadius nil = full circle; 0 = hard square.
    private func icon(cornerRadius: CGFloat?) -> Data {
        let side: CGFloat = 32
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        NSColor.red.setFill()
        let path = cornerRadius.map { NSBezierPath(roundedRect: bounds, xRadius: $0, yRadius: $0) }
            ?? NSBezierPath(ovalIn: bounds)
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    // The measured radius is quantized to whole source pixels (~0.1 of the side
    // on a 32px icon), so it tracks the real corner rather than matching it.
    @Test func measuredRadiusTracksTheTilesOwnCorner() {
        #expect(FaviconShape.cornerRadiusFraction(icon(cornerRadius: 0)) == 0)  // hard square
        for radius in [CGFloat(3), 6, 7.2, 11, 15] {
            let measured = FaviconShape.cornerRadiusFraction(icon(cornerRadius: radius))
            #expect(abs(measured - radius / 32) < 0.06, "radius \(radius) measured \(measured)")
        }
        // Monotonic: a rounder tile never reports a tighter corner.
        let fractions = [CGFloat(0), 3, 6, 11, 15].map { FaviconShape.cornerRadiusFraction(icon(cornerRadius: $0)) }
        #expect(fractions == fractions.sorted())
    }

    @Test func roundAndUnknownIconsResolveToAFullCircle() {
        #expect(FaviconShape.cornerRadiusFraction(icon(cornerRadius: nil)) == 0.5)
        // No favicon, or bytes we can't decode: circle, same as the monogram.
        #expect(FaviconShape.cornerRadiusFraction(nil) == 0.5)
        #expect(FaviconShape.cornerRadiusFraction(Data("not an image".utf8)) == 0.5)
    }
}

@Suite(.serialized)
struct LastTabLifecycleTests {

    @Test func closingBlankLastTabTerminates() {
        var didTerminate = false
        let manager = TabManager(terminateApplication: { didTerminate = true })
        let tab = Tab()
        manager.selectedTabId = tab.id

        manager.closeTab(tab, tabs: [tab])

        #expect(didTerminate)
    }

    @Test func closingNavigatedLastTabTerminates() {
        var didTerminate = false
        let manager = TabManager(terminateApplication: { didTerminate = true })
        let tab = Tab(title: "Example", url: URL(string: "https://example.com"))
        manager.selectedTabId = tab.id

        manager.closeTab(tab, tabs: [tab])

        #expect(didTerminate)
    }

    @Test func closingIncognitoLastTabTerminates() {
        var didTerminate = false
        let manager = TabManager(terminateApplication: { didTerminate = true })
        let tab = manager.createIncognitoTab()

        manager.closeTab(tab, tabs: [tab])

        #expect(didTerminate)
        #expect(manager.incognitoTabs.isEmpty)
    }

    @Test func deletingAContainerPurgesItsClosedTabSnapshots() {
        let deletedSessionId = UUID()
        let manager = TabManager()
        manager.closedTabs = [
            ClosedTabSnapshot(
                title: "Deleted container",
                url: URL(string: "https://container.example"),
                historyStrings: ["https://container.example"],
                sessionKind: .container,
                sessionId: deletedSessionId
            ),
            ClosedTabSnapshot(
                title: "Keep",
                url: URL(string: "https://normal.example"),
                historyStrings: ["https://normal.example"],
                sessionKind: .normal,
                sessionId: nil
            )
        ]

        manager.purgeClosedTabs(forSession: deletedSessionId)

        #expect(manager.closedTabs.map(\.title) == ["Keep"])
    }

    @Test @MainActor func closingPersistedLastTabDeletesItBeforeTerminating() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Browser.Tab.self, configurations: configuration)
        let context = container.mainContext
        let tab = Tab(title: "Example", url: URL(string: "https://example.com"))
        context.insert(tab)
        try context.save()

        var didTerminate = false
        let manager = TabManager(
            modelContext: context,
            terminateApplication: { didTerminate = true }
        )
        manager.selectedTabId = tab.id

        manager.closeTab(tab, tabs: [tab])

        #expect(didTerminate)
        #expect(try context.fetch(FetchDescriptor<Browser.Tab>()).isEmpty)
    }
}

struct TabPeekLabelTests {
    @Test func sameDomainTabsUseDistinctPageTitles() {
        let album = Tab(title: "Summer Album", url: URL(string: "https://facebook.com/albums/123"))
        let post = Tab(title: "Nathan's Post", url: URL(string: "https://facebook.com/posts/456"))
        let tabs = [album, post]

        #expect(album.peekLabel(among: tabs) == "Summer Album")
        #expect(post.peekLabel(among: tabs) == "Nathan's Post")
    }

    @Test func duplicateDomainTitlesFallBackToPathAndStayShort() {
        let album = Tab(title: "Facebook", url: URL(string: "https://facebook.com/photos/album-123"))
        let post = Tab(title: "Facebook", url: URL(string: "https://facebook.com/posts/post-456"))
        let tabs = [album, post]

        #expect(album.peekLabel(among: tabs).contains("album-123"))
        #expect(post.peekLabel(among: tabs).contains("post-456"))
        #expect(album.peekLabel(among: tabs).count < 40)
        #expect(post.peekLabel(among: tabs).count < 40)
    }
}

struct FindBarTests {

    @Test func matchCounterWrapsInBothDirections() {
        // Forward from "nothing found yet" lands on the first match and wraps at the end.
        #expect(FindBar.step(index: 0, count: 3, backwards: false) == 1)
        #expect(FindBar.step(index: 2, count: 3, backwards: false) == 3)
        #expect(FindBar.step(index: 3, count: 3, backwards: false) == 1)

        // Backwards from nothing (or from the first) wraps to the last.
        #expect(FindBar.step(index: 0, count: 3, backwards: true) == 3)
        #expect(FindBar.step(index: 1, count: 3, backwards: true) == 3)
        #expect(FindBar.step(index: 3, count: 3, backwards: true) == 2)

        // A single match stays put; no matches stays at zero.
        #expect(FindBar.step(index: 1, count: 1, backwards: false) == 1)
        #expect(FindBar.step(index: 1, count: 1, backwards: true) == 1)
        #expect(FindBar.step(index: 0, count: 0, backwards: false) == 0)
    }

    @Test func everyPositionMapsToADistinctAlignment() {
        let alignments = FindBar.positions.map { FindBar.alignment($0) }
        for (i, a) in alignments.enumerated() {
            for b in alignments[(i + 1)...] { #expect(a != b) }
        }
        #expect(FindBar.alignment(FindBar.defaultPosition) == .topTrailing)
        #expect(FindBar.alignment("nonsense") == .topTrailing) // unknown value falls back
    }
}

// TabManager works with webViewManager: nil (optional chaining) and needs no
// modelContext for incognito, so its session logic is testable without a GUI.
@Suite(.serialized)
struct SessionIsolationTests {

    @Test func sessionKindAccessorRoundTrips() {
        let tab = Tab()
        #expect(tab.sessionKind == .normal)
        #expect(tab.sessionKindRaw == nil)

        tab.sessionKind = .incognito
        #expect(tab.sessionKind == .incognito)
        #expect(tab.sessionKindRaw == "incognito")

        // Normal stores nil, so existing rows never need migration.
        tab.sessionKind = .normal
        #expect(tab.sessionKindRaw == nil)
    }

    @Test func incognitoTabsAreInMemoryAndIsolated() {
        let manager = TabManager()
        let a = manager.createIncognitoTab()
        let b = manager.createIncognitoTab()

        // Held in the in-memory list (never inserted into SwiftData).
        #expect(manager.incognitoTabs.count == 2)
        #expect(a.sessionKind == .incognito && b.sessionKind == .incognito)
        // Two fresh incognito tabs are isolated: different session jars.
        #expect(a.sessionId != b.sessionId)

        // Opening into an existing session shares its jar id.
        let c = manager.createIncognitoTab(sessionId: a.sessionId)
        #expect(c.sessionId == a.sessionId)
    }

    @Test func closingIncognitoTabRemovesItWithoutSnapshot() {
        let manager = TabManager()
        let a = manager.createIncognitoTab()
        _ = manager.createIncognitoTab()
        let before = manager.closedTabs.count

        manager.closeTab(a, tabs: manager.incognitoTabs)
        #expect(!manager.incognitoTabs.contains { $0.id == a.id })
        #expect(manager.incognitoTabs.count == 1)
        // Incognito closes never hit the reopen stack (ephemeral + private).
        #expect(manager.closedTabs.count == before)
    }

    @Test func createTabInheritsSession() {
        let manager = TabManager()

        // Inheriting incognito → an incognito tab in the same session.
        let sid = UUID()
        let inc = manager.createTab(inheriting: (.incognito, sid))
        #expect(inc.sessionKind == .incognito && inc.sessionId == sid)
        #expect(manager.incognitoTabs.contains { $0.id == inc.id })

        // Inheriting container → a container tab tagged with the session, not in the
        // incognito list.
        let csid = UUID()
        let cont = manager.createTab(inheriting: (.container, csid))
        #expect(cont.sessionKind == .container && cont.sessionId == csid)
        #expect(!manager.incognitoTabs.contains { $0.id == cont.id })

        // Inheriting normal → a plain tab.
        let norm = manager.createTab(inheriting: (.normal, nil))
        #expect(norm.sessionKind == .normal && norm.sessionId == nil)
    }

    @Test @MainActor func duplicateAndReopenPreserveSessionIdentity() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Browser.Tab.self, configurations: configuration)
        let context = container.mainContext
        let manager = TabManager(modelContext: context, terminateApplication: {})

        let privateSession = UUID()
        let privateTab = manager.createIncognitoTab(sessionId: privateSession)
        privateTab.navigateTo(URL(string: "https://private.example")!)
        let privateCopy = manager.duplicateTab(privateTab)
        #expect(privateCopy.sessionKind == .incognito)
        #expect(privateCopy.sessionId == privateSession)
        #expect(manager.incognitoTabs.contains { $0.id == privateCopy.id })
        #expect(try context.fetch(FetchDescriptor<Browser.Tab>()).isEmpty)

        let containerSession = UUID()
        let containerTab = manager.createTab(
            inheriting: (.container, containerSession),
            url: URL(string: "https://work.example")
        )
        let containerCopy = manager.duplicateTab(containerTab)
        #expect(containerCopy.sessionKind == .container)
        #expect(containerCopy.sessionId == containerSession)

        manager.closeTab(containerTab, tabs: [containerTab, containerCopy])
        let reopened = try #require(manager.reopenLastClosedTab())
        #expect(reopened.sessionKind == .container)
        #expect(reopened.sessionId == containerSession)
    }

    @Test func incognitoColorIsStablePerSession() {
        let id = UUID()
        #expect(BrowserSession.incognitoColor(for: id) == BrowserSession.incognitoColor(for: id))
    }

    // Builds the real app schema (with the new BrowserSession model + Tab session
    // fields) in memory to confirm it's valid and container tabs round-trip — a safe
    // proxy for "the app still launches and migrates" without touching real data.
    @Test func schemaBuildsAndPersistsContainerTabs() throws {
        let schema = Schema([Tab.self, TabGroup.self, Bookmark.self, BrowserSession.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = ModelContext(container)

        let session = BrowserSession(name: "Work", color: .blue)
        ctx.insert(session)
        let tab = Tab()
        tab.sessionKind = .container
        tab.sessionId = session.id
        ctx.insert(tab)
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<BrowserSession>()).count == 1)
        let stored = try ctx.fetch(FetchDescriptor<Browser.Tab>()).first
        #expect(stored?.sessionKind == .container)
        #expect(stored?.sessionId == session.id)
    }
}

struct WorkspaceTests {
    @Test @MainActor func savedContainerTabRestoresItsSession() throws {
        let sessionId = UUID()
        let tab = Tab(title: "Work", url: URL(string: "https://work.example"))
        tab.sessionKind = .container
        tab.sessionId = sessionId

        let encoded = try JSONEncoder().encode(SavedWorkspaceTab(from: tab))
        let saved = try JSONDecoder().decode(SavedWorkspaceTab.self, from: encoded)
        let restored = saved.makeTab()

        #expect(restored.sessionKind == .container)
        #expect(restored.sessionId == sessionId)
    }

    @Test @MainActor func replacingWorkspaceDiscardsModelsAndWebViews() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Browser.Tab.self, configurations: configuration)
        let context = container.mainContext
        let webViews = WebViewManager()
        let manager = TabManager(
            modelContext: context,
            webViewManager: webViews,
            terminateApplication: {}
        )
        let sessionId = UUID()
        let tab = manager.createTab(inheriting: (.container, sessionId))
        let unopenedTab = manager.createTab(inheriting: (.container, sessionId))
        _ = webViews.getWebView(for: tab.id)
        #expect(webViews.liveTabIds == [tab.id])

        manager.discardTabsForWorkspaceLoad([tab, unopenedTab])

        #expect(webViews.liveTabIds.isEmpty)
        #expect(webViews.session(for: tab.id).kind == .normal)
        #expect(webViews.session(for: unopenedTab.id).kind == .normal)
        #expect(try context.fetch(FetchDescriptor<Browser.Tab>()).isEmpty)
    }
}

// Serialized: these mutate the shared ShortcutStore singleton, so they must not
// run in parallel with each other.
@Suite(.serialized)
struct ShortcutTests {

    @Test func websiteQuickOpenOverrideIsOptIn() {
        let defaults = UserDefaults.standard
        let key = KeyboardShortcutsManager.overrideWebsiteQuickOpenKey
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(!SettingsManager.shared.overrideWebsiteQuickOpen)

        defaults.set(true, forKey: key)
        #expect(SettingsManager.shared.overrideWebsiteQuickOpen)
    }

    @Test @MainActor func browserCanCaptureQuickOpenBeforeTheWebsite() throws {
        let defaults = UserDefaults.standard
        let key = KeyboardShortcutsManager.overrideWebsiteQuickOpenKey
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        var isOmnibarShowing = false
        let manager = KeyboardShortcutsManager(
            showOmnibar: Binding(
                get: { isOmnibarShowing },
                set: { isOmnibarShowing = $0 }
            ),
            reloadAction: {},
            hardReloadAction: {},
            reloadAllTabsAction: {},
            goBackAction: {},
            goForwardAction: {}
        )
        let commandK = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40
        ))

        defaults.removeObject(forKey: key)
        #expect(!manager.captureQuickOpenIfNeeded(commandK))
        #expect(!isOmnibarShowing)

        defaults.set(true, forKey: key)
        #expect(manager.captureQuickOpenIfNeeded(commandK))
        #expect(isOmnibarShowing)
    }

    @Test func websitePriorityFallsBackFromSiteToGlobalToDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "shortcutPriorityTests"))
        defaults.removePersistentDomain(forName: "shortcutPriorityTests")
        let priority = ShortcutPriorityStore(defaults: defaults)

        // Out of the box: reload is ours, find belongs to the page.
        #expect(priority.browserWins(.reload, host: "example.com"))
        #expect(!priority.browserWins(.findInPage, host: "example.com"))

        // Global setting applies everywhere…
        priority.set(true, for: .findInPage)
        #expect(priority.browserWins(.findInPage, host: "example.com"))

        // …until one site says otherwise. www and case don't make a new site.
        priority.set(false, for: .findInPage, host: "docs.google.com")
        #expect(!priority.browserWins(.findInPage, host: "WWW.docs.google.com"))
        #expect(priority.browserWins(.findInPage, host: "example.com"))

        // Clearing the site override falls back to the global setting.
        priority.set(nil, for: .findInPage, host: "docs.google.com")
        #expect(priority.browserWins(.findInPage, host: "docs.google.com"))
        #expect(priority.customizedHosts.isEmpty)

        // Settings survive a relaunch.
        priority.set(false, for: .reload, host: "figma.com")
        #expect(!ShortcutPriorityStore(defaults: defaults).browserWins(.reload, host: "figma.com"))

        defaults.removePersistentDomain(forName: "shortcutPriorityTests")
    }

    @Test func shortcutValueConversions() {
        let cmdShiftT = Shortcut(key: "t", command: true, shift: true)
        #expect(cmdShiftT.displayString == "⇧⌘T")
        #expect(cmdShiftT.displayTokens == ["⇧", "⌘", "T"])
        #expect(cmdShiftT.eventModifiers.contains(.command))
        #expect(cmdShiftT.eventModifiers.contains(.shift))
        #expect(cmdShiftT.hasModifier)

        // Special keys render as glyphs, not raw characters.
        #expect(ShortcutCommand.nextTab.defaultShortcut.displayTokens == ["⌃", "⇥"])
        #expect(ShortcutCommand.omnibar.defaultShortcut.displayString == "⌃Space")
        #if os(macOS)
        #expect(ShortcutCommand.showDownloads.defaultShortcut.displayString == "⇧⌘J")
        #endif

        // No two defaults collide.
        var seen = Set<String>()
        for command in ShortcutCommand.all {
            let shortcut = command.defaultShortcut
            let signature = [
                shortcut.key,
                shortcut.command ? "command" : "",
                shortcut.shift ? "shift" : "",
                shortcut.option ? "option" : "",
                shortcut.control ? "control" : "",
            ].joined(separator: "|")
            #expect(seen.insert(signature).inserted, "duplicate default for \(command.id)")
        }
    }

    @Test func shortcutStoreRebindResetAndConflicts() {
        let store = ShortcutStore.shared
        store.resetAll()

        // Defaults
        #expect(store.shortcut(for: .newTab).displayString == "⌘T")
        #expect(store.shortcut(for: .closeTab).displayString == "⌘W")
        #expect(store.conflicts().isEmpty)
        #expect(!store.isCustomized(.newTab))

        // Rebind → lookup reflects it and it counts as customized.
        store.rebind(.newTab, to: Shortcut(key: "y", command: true))
        #expect(store.shortcut(for: .newTab).displayString == "⌘Y")
        #expect(store.isCustomized(.newTab))

        // Two commands on the same chord are flagged as conflicting.
        store.rebind(.closeTab, to: Shortcut(key: "y", command: true))
        let conflictIDs = Set(store.conflicts().map(\.id))
        #expect(conflictIDs.contains("newTab"))
        #expect(conflictIDs.contains("closeTab"))

        // Rebinding back to the default drops the customization entirely.
        store.rebind(.newTab, to: ShortcutCommand.newTab.defaultShortcut)
        #expect(!store.isCustomized(.newTab))

        // Per-command reset and reset-all.
        store.reset(.closeTab)
        #expect(store.shortcut(for: .closeTab).displayString == "⌘W")
        store.resetAll()
        #expect(store.custom.isEmpty)
        #expect(store.conflicts().isEmpty)
    }

    @Test func iPadCommandRegistryOnlyAdvertisesDispatchableCommands() {
        let entries = BrowserPlatformCommandRegistry.iPad
        let commandIDs = Set(entries.map(\.command.id))

        #expect(entries.count == commandIDs.count)
        #expect(commandIDs.isSubset(of: Set(ShortcutCommand.all.map(\.id))))
        #expect(commandIDs.contains(ShortcutCommand.newTab.id))
        #expect(commandIDs.contains(ShortcutCommand.findInPage.id))
        #expect(commandIDs.contains(ShortcutCommand.showBookmarks.id))
        #expect(commandIDs.contains(ShortcutCommand.showHistory.id))
        #expect(commandIDs.contains(ShortcutCommand.switchTabs.last!.id))
        #expect(commandIDs.contains(ShortcutCommand.hardReload.id))
        #expect(commandIDs.contains(ShortcutCommand.reloadAll.id))
        #expect(commandIDs.contains(ShortcutCommand.printPage.id))
        #expect(commandIDs.contains(ShortcutCommand.exportPDF.id))
        #expect(commandIDs.contains(ShortcutCommand.toggleTranslation.id))
        #expect(commandIDs.contains(ShortcutCommand.clearSiteData.id))
        #expect(commandIDs.contains(ShortcutCommand.readerMode.id))
        #expect(commandIDs.contains(ShortcutCommand.findNext.id))
        #expect(commandIDs.contains(ShortcutCommand.findPrevious.id))

        for unsupported in [ShortcutCommand.extensionPopup] {
            #expect(!commandIDs.contains(unsupported.id))
        }

        for entry in entries {
            #expect(BrowserPlatformCommandRegistry.iPadEntry(
                notification: entry.notification,
                userInfo: entry.userInfo
            )?.command == entry.command)
        }
    }

    @Test func presetsAndSystemConflicts() {
        let store = ShortcutStore.shared
        store.resetAll()

        // A preset changes the bindings it specifies, leaving the rest at default.
        store.apply(preset: .firefox)
        #expect(store.shortcut(for: .fullScreen).displayString == "⌃⌘F")
        #expect(store.shortcut(for: .showBookmarks).displayString == "⇧⌘O")
        #expect(store.shortcut(for: .newTab).displayString == "⌘T")

        // Applying another preset replaces the previous one wholesale.
        store.apply(preset: .arc)
        #expect(store.shortcut(for: .toggleTabBar).displayString == "⌘S")
        #expect(store.shortcut(for: .showBookmarks).displayString == "⇧⌘B")

        store.resetAll()
        #expect(store.custom.isEmpty)

        // Well-known system chords are recognized; ordinary ones aren't.
        #expect(store.systemConflict(Shortcut(key: " ", command: true)) == "Spotlight")
        #expect(store.systemConflict(Shortcut(key: "q", command: true)) == "Quit")
        #expect(store.systemConflict(Shortcut(key: "t", command: true)) == nil)
    }

    @Test func liveHighlightState() {
        let live = LiveKeyState.shared
        live.deactivate()
        live.isActive = true

        // Holding ⌘ alone lights the ⌘ token but not the key, and the ⌘T chord
        // isn't fully held yet.
        live.command = true
        let cmdT = Shortcut(key: "t", command: true)
        #expect(live.isHeld("⌘", in: cmdT))
        #expect(!live.isHeld("T", in: cmdT))
        #expect(!live.fullyHeld(cmdT))

        // Pressing T completes the chord.
        live.pressedKey = "t"
        #expect(live.isHeld("T", in: cmdT))
        #expect(live.fullyHeld(cmdT))

        // ⌘T held is not ⇧⌘T.
        let shiftCmdT = Shortcut(key: "t", command: true, shift: true)
        #expect(!live.isHeld("⇧", in: shiftCmdT))
        #expect(!live.fullyHeld(shiftCmdT))

        live.deactivate()
        #expect(!live.isActive)
    }
}

// Split view is window view state on TabManager (docs/adr/0001): ordered member
// ids + focused id, no SwiftData entity. Serialized: splitTabIds persists to
// shared UserDefaults on every mutation.
@Suite(.serialized)
struct SplitViewTests {

    private func makeTabs(_ n: Int) -> [Browser.Tab] {
        (0..<n).map { i in
            let tab = Browser.Tab()
            tab.orderIndex = i
            return tab
        }
    }

    private func cleanup(_ manager: TabManager) {
        manager.splitTabIds = []
        UserDefaults.standard.removeObject(forKey: "splitTabIds")
    }

    @Test func toggleAddsRemovesAndCapsAtFour() {
        let manager = TabManager()
        let tabs = makeTabs(6)
        manager.selectedTabId = tabs[0].id

        // First shift-click: split of [selected, clicked], focus moves to clicked
        manager.toggleSplitMembership(tabs[3], tabs: tabs)
        #expect(manager.splitTabIds == [tabs[0].id, tabs[3].id])
        #expect(manager.selectedTabId == tabs[3].id)

        // Members append in add order; the fifth is a no-op (cap = 2x2 grid)
        manager.toggleSplitMembership(tabs[1], tabs: tabs)
        manager.toggleSplitMembership(tabs[4], tabs: tabs)
        manager.toggleSplitMembership(tabs[5], tabs: tabs)
        #expect(manager.splitTabIds == [tabs[0].id, tabs[3].id, tabs[1].id, tabs[4].id])

        // Shift-click on a member removes its pane
        manager.toggleSplitMembership(tabs[1], tabs: tabs)
        #expect(manager.splitTabIds == [tabs[0].id, tabs[3].id, tabs[4].id])

        // Removing down to one pane dissolves the split; focus stays on a survivor
        manager.toggleSplitMembership(tabs[0], tabs: tabs)
        manager.toggleSplitMembership(tabs[3], tabs: tabs)
        #expect(manager.splitTabIds.isEmpty)
        #expect(manager.selectedTabId == tabs[4].id)
        cleanup(manager)
    }

    @Test func removingFocusedMemberMovesFocusToFirstRemaining() {
        let manager = TabManager()
        let tabs = makeTabs(3)
        manager.selectedTabId = tabs[0].id
        manager.toggleSplitMembership(tabs[1], tabs: tabs)
        manager.toggleSplitMembership(tabs[2], tabs: tabs)

        // tabs[2] is focused; removing it hands focus to the first remaining member
        manager.toggleSplitMembership(tabs[2], tabs: tabs)
        #expect(manager.splitTabIds == [tabs[0].id, tabs[1].id])
        #expect(manager.selectedTabId == tabs[0].id)
        cleanup(manager)
    }

    @Test func selectingNonMemberDissolvesSplit() {
        let manager = TabManager()
        let tabs = makeTabs(3)
        manager.selectedTabId = tabs[0].id
        manager.toggleSplitMembership(tabs[1], tabs: tabs)
        #expect(!manager.splitTabIds.isEmpty)

        // Any outside selection (click, Cmd+T, popup, tab cycling) returns to single view
        manager.selectedTabId = tabs[2].id
        #expect(manager.splitTabIds.isEmpty)
        cleanup(manager)
    }

    @Test func gatheringReordersMembersAfterAnchor() {
        let manager = TabManager()
        let tabs = makeTabs(6)
        manager.selectedTabId = tabs[1].id

        // Anchor (tabs[1]) keeps its position; the new member moves next to it
        manager.toggleSplitMembership(tabs[4], tabs: tabs)
        let ordered: [UUID] = tabs.sorted { $0.orderIndex < $1.orderIndex }.map(\.id)
        let expected: [UUID] = [0, 1, 4, 2, 3, 5].map { tabs[$0].id }
        #expect(ordered == expected)
        cleanup(manager)
    }

    @Test func closingFocusedTabSelectsNeighbor() {
        let manager = TabManager()
        let tabs = makeTabs(3)

        manager.selectedTabId = tabs[1].id
        manager.closeTab(tabs[1], tabs: tabs)
        #expect(manager.selectedTabId == tabs[0].id)

        // Closing the first tab has no predecessor: focus moves forward instead
        let remaining = [tabs[0], tabs[2]]
        manager.selectedTabId = tabs[0].id
        manager.closeTab(tabs[0], tabs: remaining)
        #expect(manager.selectedTabId == tabs[2].id)
        cleanup(manager)
    }

    @Test func closingOpenerWalksItsOpenedTabsInClickOrder() {
        let manager = TabManager()
        let tabs = makeTabs(5)   // [other, opener, c1, c2, c3]
        for child in tabs[2...] { child.openerId = tabs[1].id }

        // Closing the opener goes to its first opened tab, not the tab before it
        manager.selectedTabId = tabs[1].id
        manager.closeTab(tabs[1], tabs: tabs)
        #expect(manager.selectedTabId == tabs[2].id)

        // Then each close walks forward through the rest, in click order
        var remaining = [tabs[0], tabs[2], tabs[3], tabs[4]]
        manager.closeTab(tabs[2], tabs: remaining)
        #expect(manager.selectedTabId == tabs[3].id)

        remaining = [tabs[0], tabs[3], tabs[4]]
        manager.closeTab(tabs[3], tabs: remaining)
        #expect(manager.selectedTabId == tabs[4].id)

        // Last one has no siblings left: back to the plain previous-tab rule
        remaining = [tabs[0], tabs[4]]
        manager.closeTab(tabs[4], tabs: remaining)
        #expect(manager.selectedTabId == tabs[0].id)
        cleanup(manager)
    }

    @Test func closingMemberCollapsesOnlyItsPane() {
        let manager = TabManager()
        let tabs = makeTabs(3)
        manager.selectedTabId = tabs[0].id
        manager.toggleSplitMembership(tabs[1], tabs: tabs)
        manager.toggleSplitMembership(tabs[2], tabs: tabs)

        // Closing the focused member: its pane collapses, focus moves to a member,
        // and the rest of the split survives
        manager.closeTab(tabs[2], tabs: tabs)
        #expect(manager.splitTabIds == [tabs[0].id, tabs[1].id])
        #expect(manager.selectedTabId == tabs[0].id)

        // Closing another member leaves one pane: back to a normal single view
        let remaining = [tabs[0], tabs[1]]
        manager.closeTab(tabs[1], tabs: remaining)
        #expect(manager.splitTabIds.isEmpty)
        #expect(manager.selectedTabId == tabs[0].id)
        cleanup(manager)
    }

    @Test func restoreDropsUnresolvedIdsAndRealignsFocus() {
        let tabs = makeTabs(3)
        UserDefaults.standard.set(
            [tabs[1].id.uuidString, UUID().uuidString, tabs[2].id.uuidString],
            forKey: "splitTabIds")

        let manager = TabManager()
        manager.selectedTabId = tabs[0].id
        manager.restoreSplit(from: tabs)
        // The id closed on another device (or an incognito tab that died) is dropped
        #expect(manager.splitTabIds == [tabs[1].id, tabs[2].id])
        // The restored selection wasn't a member, so focus moves into the split
        #expect(manager.selectedTabId == tabs[1].id)
        cleanup(manager)

        // Fewer than 2 survivors: no split, and the stale persisted value is cleared
        UserDefaults.standard.set([UUID().uuidString, UUID().uuidString], forKey: "splitTabIds")
        let manager2 = TabManager()
        manager2.selectedTabId = tabs[0].id
        manager2.restoreSplit(from: tabs)
        #expect(manager2.splitTabIds.isEmpty)
        #expect(UserDefaults.standard.stringArray(forKey: "splitTabIds") == nil)
        cleanup(manager2)
    }
}

// setDisplayedTabs defers its work one runloop hop (to stay off SwiftUI's update
// pass), but WebView.updateNSView reads activeWebView back in that same pass to
// decide which web view to load the tab's URL into. If activeWebView reports the
// *old* focus, the newly selected tab's URL gets loaded into the previous tab's
// web view — pages jumping between tabs, duplicates, panes showing each other's
// content. So activeWebView must answer for the focus most recently requested,
// not the one last applied.
@Suite(.serialized)
@MainActor
struct PaneFocusTests {

    private func drainMainQueue() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func activeWebViewFollowsRequestedFocusBeforeApply() async {
        let webViewManager = WebViewManager()
        let container = WebViewContainer(webViewManager: webViewManager, coordinator: nil)
        let tabA = UUID(), tabB = UUID()

        container.setDisplayedTabs([tabA], focusedTabId: tabA)
        await drainMainQueue()
        let viewA = webViewManager.existingWebView(for: tabA)
        #expect(viewA != nil)
        #expect(container.activeWebView === viewA)

        // Same runloop turn as the request — exactly where updateNSView reads it.
        container.setDisplayedTabs([tabB], focusedTabId: tabB)
        #expect(container.activeWebView !== viewA)
        #expect(container.activeWebView === webViewManager.existingWebView(for: tabB))

        // And still correct once the deferred apply lands.
        await drainMainQueue()
        #expect(container.activeWebView === webViewManager.existingWebView(for: tabB))
    }

    @Test func focusRequestIsNotLostWhenAnUpdateRepeatsTheAppliedState() async {
        let webViewManager = WebViewManager()
        let container = WebViewContainer(webViewManager: webViewManager, coordinator: nil)
        let tabA = UUID(), tabB = UUID()

        container.setDisplayedTabs([tabA], focusedTabId: tabA)
        await drainMainQueue()

        // Rapid clicking produces bursts of updates within one turn. A pass that
        // happens to restate the applied focus must not cancel the pending one.
        container.setDisplayedTabs([tabB], focusedTabId: tabB)
        container.setDisplayedTabs([tabA], focusedTabId: tabA)
        await drainMainQueue()
        #expect(container.activeWebView === webViewManager.existingWebView(for: tabA))
    }
}

@Suite("FastForward")
@MainActor
struct FastForwardTests {

    @Test func destinationQueriesClassifyRegardlessOfWordOrder() {
        for q in ["download slack", "slack download", "get slack for my mac"] {
            let match = FastForwardRule.parse(q)
            #expect(match?.intent == .download)
            #expect(match?.noun == "slack")
            // All three collide onto one learnable signature.
            #expect(match?.signature == "download:slack")
        }
    }

    @Test func otherIntentsClassify() {
        #expect(FastForwardRule.parse("notion pricing")?.signature == "pricing:notion")
        #expect(FastForwardRule.parse("github login")?.signature == "login:github")
        #expect(FastForwardRule.parse("stripe docs")?.signature == "docs:stripe")
        #expect(FastForwardRule.parse("cancel my netflix subscription")?.intent == .support)
    }

    @Test func questionsAndBareTopicsDoNotClassify() {
        // No destination verb → nothing to fast-forward.
        #expect(FastForwardRule.parse("is slack down") == nil)
        #expect(FastForwardRule.parse("weather tomorrow") == nil)
        #expect(FastForwardRule.parse("how do neural networks work") == nil)
        // Verb present but no product left after stripping → don't guess.
        #expect(FastForwardRule.parse("download") == nil)
        // Prose that happens to contain a trigger word is too long to be a destination.
        #expect(FastForwardRule.parse("what is the best way to download large files quickly on a mac") == nil)
    }

    @Test func recipeTableCoversTheClassifiedSignatures() {
        // Every marquee query the parser produces should have a shipped destination.
        for q in ["download slack", "download zoom", "download vscode"] {
            let sig = FastForwardRule.parse(q)!.signature
            #expect(FastForwardRecipes.table[sig] != nil)
        }
    }

    @Test func searchQueryRoundTripsForEveryEngine() {
        // A search built for any engine must parse back to the original query,
        // or Fast Forward can never see the intent. (These prefixes mirror
        // OmnibarView.searchURLPrefix / OmnibarInput.searchURLPrefix.)
        let prefixes = ["https://www.google.com/search?q=",
                        "https://duckduckgo.com/?q=",
                        "https://www.bing.com/search?q=",
                        "https://search.yahoo.com/search?p="]
        for prefix in prefixes {
            let url = URL(string: prefix + "download%20slack")!
            #expect(FastForward.searchQuery(from: url) == "download slack")
        }
        // A plain destination URL is not a search — nothing to recover.
        #expect(FastForward.searchQuery(from: URL(string: "https://slack.com/downloads")!) == nil)
    }

    @Test func memoryBlocksAfterTwoNetStrikesAndForgivesAccepts() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let memory = FastForwardMemory(storeURL: tmp)
        let sig = "download:slack", url = "https://slack.com/downloads/mac"

        #expect(!memory.isBlocked(sig))
        memory.record(signature: sig, url: url, target: nil, accepted: false)
        #expect(!memory.isBlocked(sig))               // one strike: still tries
        memory.record(signature: sig, url: url, target: nil, accepted: false)
        #expect(memory.isBlocked(sig))                // two strikes: gives up

        // An accept a signature usually keeps outweighs a stray dismissal.
        let sig2 = "download:zoom"
        memory.record(signature: sig2, url: url, target: nil, accepted: true)
        memory.record(signature: sig2, url: url, target: nil, accepted: false)
        #expect(!memory.isBlocked(sig2))
    }

    @Test func acceptedDestinationPersistsAndReloads() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sig = "login:github", url = "https://github.com/login"

        let first = FastForwardMemory(storeURL: tmp)
        first.record(signature: sig, url: url, target: "sign in", accepted: true)

        // A fresh instance reads the same file — the correction survives relaunch.
        let reloaded = FastForwardMemory(storeURL: tmp)
        #expect(reloaded.destination(for: sig)?.url.absoluteString == url)
        #expect(reloaded.destination(for: sig)?.target == "sign in")
    }
}

// The nickname rules behind "gmail" -> mail.google.com. Uses a throwaway
// UserDefaults suite so a test run never touches real browsing history.
@Suite(.serialized)
struct SiteHistoryTests {

    private func freshStore() -> SiteHistory {
        let name = "sitehistory-test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SiteHistory(defaults: defaults)
    }

    // Visits have to be recorded oldest-first, the way they actually happen.
    private func visits(_ store: SiteHistory, _ host: String, title: String,
                        count: Int, endingAt end: Date) {
        let url = URL(string: "https://\(host)/")!
        for i in stride(from: count - 1, through: 0, by: -1) {
            store.record(url: url, title: title, now: end.addingTimeInterval(Double(-i) * 86400))
        }
    }

    @Test func clearingHistoryRemovesTabAndSiteVisitHistory() {
        let store = freshStore()
        store.record(url: URL(string: "https://example.com/page")!, title: "Example")
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clear-history-\(UUID().uuidString).json")
        let browsingHistory = BrowsingHistoryStore(storeURL: historyURL)
        browsingHistory.record(
            url: URL(string: "https://example.com/page")!,
            title: "Example",
            sessionKind: .normal
        )
        let tabManager = TabManager()
        tabManager.closedTabs = [
            ClosedTabSnapshot(
                title: "Closed",
                url: URL(string: "https://closed.example"),
                historyStrings: ["https://closed.example"],
                sessionKind: .normal,
                sessionId: nil
            )
        ]

        let normal = Tab(title: "Example", url: URL(string: "https://example.com"))
        normal.navigateTo(URL(string: "https://example.com/next")!)
        let container = Tab(title: "Work", url: URL(string: "https://work.example"))
        container.sessionKind = .container
        container.sessionId = UUID()

        BrowsingDataCleaner.clearHistory(
            in: [normal, container],
            siteHistory: store,
            browsingHistory: browsingHistory
        )

        #expect(normal.historyStrings.isEmpty)
        #expect(normal.currentHistoryIndex == -1)
        #expect(container.historyStrings.isEmpty)
        #expect(container.currentHistoryIndex == -1)
        #expect(store.sites.isEmpty)
        #expect(browsingHistory.visits.isEmpty)
        #expect(tabManager.closedTabs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: historyURL.path))
    }

    @Test func matchRankPrefersHostThenLabelThenTitle() {
        // "giz" starts the host itself; "goog" only starts a later label; "gmail"
        // appears nowhere in mail.google.com and has to come from the page title.
        #expect(SiteHistory.matchRank(host: "gizmodo.com", title: "Gizmodo", query: "giz") == 3)
        #expect(SiteHistory.matchRank(host: "mail.google.com", title: "", query: "goog") == 2)
        #expect(SiteHistory.matchRank(host: "mail.google.com",
                                      title: "Inbox (3) - me@gmail.com - Gmail", query: "gmail") == 1)

        // Prefix-only: a letter from the middle of a word matches nothing, and a
        // multi-word query is a search, not a site.
        #expect(SiteHistory.matchRank(host: "gizmodo.com", title: "Gizmodo", query: "zmo") == nil)
        #expect(SiteHistory.matchRank(host: "gizmodo.com", title: "Gizmodo", query: "giz mo") == nil)
    }

    @Test func habitNeedsFiveVisitsInsideThreeMonths() {
        let store = freshStore()
        visits(store, "woot.com", title: "Woot", count: 4,
               endingAt: Date().addingTimeInterval(-86400))
        #expect(store.habit(for: "woot") == nil)          // 4 visits: still a search
        #expect(!store.matches("woot").isEmpty)           // but already a suggestion

        // The fifth visit, today, on a deep link — the nickname still resolves to
        // the site root.
        store.record(url: URL(string: "https://woot.com/offers")!, title: "Woot")
        #expect(store.habit(for: "woot")?.host == "woot.com")
        #expect(store.habit(for: "woot")?.url?.absoluteString == "https://woot.com/")

        // Same five visits, but they stopped last year — no longer a habit.
        let stale = freshStore()
        visits(stale, "woot.com", title: "Woot", count: 5,
               endingAt: Date().addingTimeInterval(-200 * 86400))
        #expect(stale.habit(for: "woot") == nil)
    }

    @Test func rankingPrefersTheSiteYouUseMost() {
        let now = Date()

        // Equal recency: the site you go to more often wins.
        let byCount = freshStore()
        visits(byCount, "giz-often.com", title: "Often", count: 10, endingAt: now)
        visits(byCount, "giz-rarely.com", title: "Rarely", count: 2, endingAt: now)
        #expect(byCount.matches("giz", now: now).first?.host == "giz-often.com")

        // Equal counts: the one you haven't opened in months loses.
        let byRecency = freshStore()
        visits(byRecency, "giz-recent.com", title: "Recent", count: 5, endingAt: now)
        visits(byRecency, "giz-stale.com", title: "Stale", count: 5,
               endingAt: now.addingTimeInterval(-150 * 86400))
        #expect(byRecency.matches("giz", now: now).first?.host == "giz-recent.com")
    }

    @Test func initialismsComeFromEitherEndOfTheTitle() {
        // Sites put their name at one end or the other; both ends get a candidate.
        #expect(SiteHistory.initialisms(of: "Ask HN: something - Hacker News").contains("hn"))
        #expect(SiteHistory.initialisms(of: "GitHub - user/repo: a thing").contains("gh"))
        #expect(SiteHistory.initialisms(of: "YouTube").contains("yt"))   // camel case is a word break

        // Junk self-filters on the length cap rather than inventing a nickname.
        #expect(SiteHistory.initialisms(of: "Inbox (58,191) - me@gmail.com - Gmail").isEmpty)
        #expect(SiteHistory.initialisms(of: "Gizmodo").isEmpty)          // one letter is not a nickname
    }

    @Test func nicknamesMatchWholeAndAliasesByPrefix() {
        #expect(SiteHistory.matchRank(host: "news.ycombinator.com",
                                      title: "Some Article - Hacker News", query: "hn") == 1)

        // An initialism is all-or-nothing. Needs a title whose words don't also start
        // with the query, or the ordinary title-word rule would answer first.
        #expect(SiteHistory.matchRank(host: "example.com", title: "Wide Open Spaces", query: "wos") == 1)
        #expect(SiteHistory.matchRank(host: "example.com", title: "Wide Open Spaces", query: "wo") == nil)

        // Model-given aliases are words, so they complete like everything else.
        #expect(SiteHistory.matchRank(host: "mail.google.com", title: "",
                                      aliases: ["email"], query: "ema") == 1)
        #expect(SiteHistory.matchRank(host: "mail.google.com", title: "",
                                      aliases: ["email"], query: "xyz") == nil)

        // A nickname never outranks the site whose host you actually typed.
        let byName = SiteHistory.matchRank(host: "mail.google.com", title: "", aliases: ["email"], query: "mail")
        let byAlias = SiteHistory.matchRank(host: "example.com", title: "", aliases: ["mailbox"], query: "mail")
        #expect((byName ?? 0) > (byAlias ?? 0))
    }

    @Test func repeatLoadsOnOneSiteAreOneVisit() {
        let store = freshStore()
        let now = Date()
        // Clicking through 10 articles in one sitting shouldn't out-rank a site you
        // open every morning.
        for i in 0..<10 {
            store.record(url: URL(string: "https://news.example/\(i)")!, title: "News",
                         now: now.addingTimeInterval(Double(i) * 60))
        }
        #expect(store.sites["news.example"]?.count == 1)
    }
}

struct BrowsingDataCleanerTests {
    private struct RemovalFailure: Error {}

    @Test func containerStoreRemovalReportsWebKitFailures() {
        let result = ContainerStoreRemoval.result(for: RemovalFailure())

        guard case .failure = result else {
            Issue.record("Expected the WebKit removal error to be preserved")
            return
        }
    }

    @Test func clearAllScopeIncludesTheDefaultStoreAndEveryContainer() {
        let work = UUID()
        let personal = UUID()

        #expect(BrowsingDataCleaner.allStoreScopes(containerIdentifiers: [work, personal]) == [
            .defaultStore,
            .container(work),
            .container(personal)
        ])
    }

    @Test func eachPrivacyCheckboxMapsOnlyToItsPromisedWebsiteData() {
        #expect(BrowsingDataCleaner.websiteDataTypes(
            cookies: true, cache: false, localStorage: false
        ) == [WKWebsiteDataTypeCookies])

        #expect(BrowsingDataCleaner.websiteDataTypes(
            cookies: false, cache: true, localStorage: false
        ) == [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])

        #expect(BrowsingDataCleaner.websiteDataTypes(
            cookies: false, cache: false, localStorage: true
        ) == [WKWebsiteDataTypeLocalStorage])
    }
}

struct WebExtensionPolicyTests {
    @Test func everyLoadedExtensionPathPersistsAndCanBeRemovedIndividually() {
        let suiteName = "extension-paths-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = URL(fileURLWithPath: "/tmp/first-extension")
        let second = URL(fileURLWithPath: "/tmp/second-extension")

        var registry = ExtensionPathRegistry(defaults: defaults)
        registry.remember(first)
        registry.remember(second)

        registry = ExtensionPathRegistry(defaults: defaults)
        #expect(registry.paths == [first.standardizedFileURL, second.standardizedFileURL])

        registry.forget(first)
        #expect(ExtensionPathRegistry(defaults: defaults).paths == [
            second.standardizedFileURL
        ])
    }

    @Test func theLegacySingleExtensionPathMigratesIntoTheRegistry() {
        let suiteName = "legacy-extension-path-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = URL(fileURLWithPath: "/tmp/legacy-extension")
        defaults.set(legacy.path, forKey: "loadedExtensionPath")

        let registry = ExtensionPathRegistry(defaults: defaults)

        #expect(registry.paths == [legacy.standardizedFileURL])
        #expect(defaults.string(forKey: "loadedExtensionPath") == nil)
    }

    @Test func extensionTabCreationReturnsTheCreatedTabIdentity() {
        let manager = WebViewManager()
        let expectedId = UUID()
        let requestedURL = URL(string: "https://extension.example/new")!
        var receivedURL: URL?
        manager.extensionTabCreationHandler = { url, shouldActivate in
            receivedURL = url
            #expect(shouldActivate)
            return expectedId
        }

        let createdId = manager.createExtensionTab(
            at: requestedURL,
            shouldActivate: true
        )

        #expect(createdId == expectedId)
        #expect(receivedURL == requestedURL)
    }

    @Test func extensionRoutingUsesTheWindowThatOwnsTheTabAndTheFocusedWindow() {
        final class WindowToken {}
        final class Candidate {
            let tabs: [UUID]
            let window: WindowToken

            init(tabs: [UUID], window: WindowToken) {
                self.tabs = tabs
                self.window = window
            }
        }

        let firstTab = UUID()
        let secondTab = UUID()
        let firstWindow = WindowToken()
        let secondWindow = WindowToken()
        let first = Candidate(tabs: [firstTab], window: firstWindow)
        let second = Candidate(tabs: [secondTab], window: secondWindow)
        let candidates = [first, second]

        #expect(ExtensionWindowRouting.owner(
            of: secondTab,
            in: candidates,
            tabIds: { $0.tabs }
        ) === second)
        #expect(ExtensionWindowRouting.focused(
            in: candidates,
            keyWindow: secondWindow,
            window: { $0.window }
        ) === second)
    }

    @Test func privateTabsStayHiddenUntilTheUserOptsIn() {
        let normal = UUID()
        let privateTab = UUID()
        let ids = [normal, privateTab]

        #expect(ExtensionPermissionPolicy.visibleTabIds(
            ids,
            privateAccessAllowed: false,
            isPrivate: { $0 == privateTab }
        ) == [normal])
        #expect(ExtensionPermissionPolicy.visibleTabIds(
            ids,
            privateAccessAllowed: true,
            isPrivate: { $0 == privateTab }
        ) == ids)
    }

    @Test func aDeniedPromptGrantsNothing() {
        let requested = Set(["tabs", "storage"])
        #expect(ExtensionPermissionPolicy.approved(requested, userAllowed: false).isEmpty)
        #expect(ExtensionPermissionPolicy.approved(requested, userAllowed: true) == requested)
    }

    @Test func extensionFingerprintChangesWhenItsImplementationChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("extension-integrity-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = directory.appendingPathComponent("manifest.json")
        let script = directory.appendingPathComponent("content.js")
        try Data(#"{"manifest_version":3,"name":"Test","version":"1"}"#.utf8)
            .write(to: manifest)
        try Data("console.log('first')".utf8).write(to: script)

        let first = try ExtensionIntegrityFingerprint.fingerprint(of: directory)
        let unchanged = try ExtensionIntegrityFingerprint.fingerprint(of: directory)
        try Data("console.log('replacement')".utf8).write(to: script)
        let changed = try ExtensionIntegrityFingerprint.fingerprint(of: directory)

        #expect(first == unchanged)
        #expect(first != changed)
    }
}

@MainActor
struct SitePermissionStoreTests {
    @Test func permissionsPersistPerOriginAndCanBeRevokedIndividually() {
        let suiteName = "site-permissions-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let origin = "https://meet.example"
        var store = SitePermissionStore(defaults: defaults)

        store.set(
            .allowed,
            for: [.camera, .microphone],
            origin: origin
        )
        #expect(store.decision(
            for: [.camera, .microphone],
            origin: origin
        ) == .allowed)

        store.set(.denied, for: [.camera], origin: origin)
        #expect(store.decision(
            for: [.camera, .microphone],
            origin: origin
        ) == nil)

        store.revoke(origin: origin, kind: .camera)
        store = SitePermissionStore(defaults: defaults)
        #expect(store.decision(for: [.camera], origin: origin) == nil)
        #expect(store.decision(
            for: [.microphone],
            origin: origin
        ) == .allowed)
    }
}

struct CLIAuthorizationTests {
    @Test func automationIsOffByDefaultAndSensitiveCapabilitiesAreSeparate() {
        let suiteName = "cli-auth-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let authorization = CLIAuthorization(defaults: defaults)

        #expect(!authorization.allows(action: "open"))
        defaults.set(true, forKey: CLIAuthorization.Key.enabled)
        #expect(authorization.allows(action: "open"))
        #expect(!authorization.allows(action: "tabs"))
        #expect(!authorization.allows(action: "js"))
        #expect(!authorization.allows(action: "screenshot"))

        defaults.set(true, forKey: CLIAuthorization.Key.pageRead)
        defaults.set(true, forKey: CLIAuthorization.Key.pageScript)
        defaults.set(true, forKey: CLIAuthorization.Key.screenshot)
        #expect(authorization.allows(action: "tabs"))
        #expect(authorization.allows(action: "get"))
        #expect(authorization.allows(action: "js"))
        #expect(authorization.allows(action: "screenshot"))
    }

    @Test func agentToolsReuseTheSameLeastPrivilegeCapabilities() {
        #expect(CLIAuthorization.capability(forAgentTool: "list_pages") == .pageRead)
        #expect(CLIAuthorization.capability(forAgentTool: "wait_for_page") == .pageRead)
        #expect(CLIAuthorization.capability(forAgentTool: "evaluate_script") == .pageScript)
        #expect(CLIAuthorization.capability(forAgentTool: "take_screenshot") == .screenshot)
        #expect(CLIAuthorization.capability(forAgentTool: "navigate_page") == .control)
    }
}

@MainActor
struct CLIPageReaderPrivacyTests {
    @Test func offscreenReadsUseAnEphemeralWebsiteDataStore() {
        let configuration = CLIPageReader.makeConfiguration()

        #expect(!configuration.websiteDataStore.isPersistent)
    }
}

struct TabSyncDisclosureTests {
    @Test func everyCloudBackedModelHasAVisibleDataCategory() {
        #expect(TabSync.cloudBackedModelTypeNames == [
            "Tab",
            "TabGroup",
            "Bookmark",
            "BrowserSession",
            "AutofillProfile"
        ])
        #expect(TabSync.syncedDataCategories == [
            .tabs,
            .tabGroups,
            .bookmarks,
            .browserSessions,
            .autofillProfiles
        ])
    }

    @Test func disablingPageStateDeletesExistingSnapshots() {
        let tab = Tab(title: "Sensitive form", url: URL(string: "https://example.com"))
        tab.interactionStateData = Data([1, 2, 3])
        tab.sessionStorageData = Data([4, 5, 6])

        #expect(TabSync.clearPageState(in: [tab]) == 1)
        #expect(tab.interactionStateData == nil)
        #expect(tab.sessionStorageData == nil)
    }
}

struct RedirectLoopGuardTests {
    @Test func blocksTheFourthEquivalentURLInsideTheWindow() {
        var guardrail = RedirectLoopGuard(maxOccurrences: 3, timeWindow: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        let url = URL(string: "https://EXAMPLE.com/path#first")!

        let decisions = [
            guardrail.shouldBlock(url, at: start),
            guardrail.shouldBlock(url, at: start.addingTimeInterval(1)),
            guardrail.shouldBlock(
                URL(string: "https://example.com/path#another")!,
                at: start.addingTimeInterval(2)
            ),
            guardrail.shouldBlock(url, at: start.addingTimeInterval(3))
        ]
        #expect(decisions == [false, false, false, true])
    }

    @Test func expiryAndResetAllowARealRetry() {
        var guardrail = RedirectLoopGuard(maxOccurrences: 2, timeWindow: 5)
        let start = Date(timeIntervalSince1970: 2_000)
        let url = URL(string: "https://example.com/login")!

        let beforeReset = [
            guardrail.shouldBlock(url, at: start),
            guardrail.shouldBlock(url, at: start.addingTimeInterval(1)),
            guardrail.shouldBlock(url, at: start.addingTimeInterval(6.1)),
            guardrail.shouldBlock(url, at: start.addingTimeInterval(7.1)),
            guardrail.shouldBlock(url, at: start.addingTimeInterval(8.1))
        ]
        #expect(beforeReset == [false, false, false, false, true])

        guardrail.reset()
        let afterReset = guardrail.shouldBlock(url, at: start.addingTimeInterval(8.1))
        #expect(!afterReset)
    }
}

struct DownloadNavigationHistoryTests {
    @Test func eachDownloadRestoresOnlyItsOwningTabsLastPage() {
        var history = DownloadNavigationHistory()
        let firstTab = UUID()
        let secondTab = UUID()
        let firstPage = URL(string: "https://example.com/first")!
        let secondPage = URL(string: "https://example.com/second")!

        history.recordSuccessfulLoad(firstPage, for: firstTab)
        history.recordSuccessfulLoad(secondPage, for: secondTab)

        #expect(history.restorationURL(for: firstTab) == firstPage)
        #expect(history.restorationURL(for: secondTab) == secondPage)
        #expect(history.restorationURL(for: UUID()) == nil)

        history.retainOnly([firstTab])
        #expect(history.restorationURL(for: firstTab) == firstPage)
        #expect(history.restorationURL(for: secondTab) == nil)
    }
}

struct PageSecurityStateTests {
    @Test func connectionStateComesFromTheCommittedPage() {
        #expect(PageSecurityEvaluator.level(
            for: nil,
            hasOnlySecureContent: false,
            certificateWasOverridden: false
        ) == .none)
        #expect(PageSecurityEvaluator.level(
            for: URL(string: "http://example.com"),
            hasOnlySecureContent: false,
            certificateWasOverridden: false
        ) == .insecure)
        #expect(PageSecurityEvaluator.level(
            for: URL(string: "https://example.com"),
            hasOnlySecureContent: true,
            certificateWasOverridden: false
        ) == .secure)
        #expect(PageSecurityEvaluator.level(
            for: URL(string: "https://example.com"),
            hasOnlySecureContent: false,
            certificateWasOverridden: false
        ) == .mixed)
        #expect(PageSecurityEvaluator.level(
            for: URL(string: "https://example.com"),
            hasOnlySecureContent: true,
            certificateWasOverridden: true
        ) == .insecure)
    }

    @Test func requestedBlockingIsDistinctFromActiveBlocking() {
        #expect(ContentBlockingStatus.resolve(enabled: false, active: false) == .off)
        #expect(ContentBlockingStatus.resolve(enabled: true, active: false) == .requestedNotActive)
        #expect(ContentBlockingStatus.resolve(enabled: true, active: true) == .active)
    }
}

struct BrowserAccessibilityTests {
    @Test func modalChromeHidesTheUnderlyingWebContent() {
        #expect(!BrowserAccessibility.backgroundIsHidden(
            sidebarPresented: false,
            omnibarPresented: false,
            modalPresented: false
        ))
        #expect(BrowserAccessibility.backgroundIsHidden(
            sidebarPresented: true,
            omnibarPresented: false,
            modalPresented: false
        ))
        #expect(BrowserAccessibility.backgroundIsHidden(
            sidebarPresented: false,
            omnibarPresented: true,
            modalPresented: false
        ))
        #expect(BrowserAccessibility.backgroundIsHidden(
            sidebarPresented: false,
            omnibarPresented: false,
            modalPresented: true
        ))
    }

    @Test func tabDescriptionNamesIdentityAndNonvisualState() {
        let label = BrowserAccessibility.tabLabel(
            title: "Account",
            url: URL(string: "https://example.com"),
            sessionKind: .incognito,
            isPinned: true,
            isMuted: true,
            isInSplit: true
        )
        let value = BrowserAccessibility.tabValue(
            isSelected: true,
            isLoading: true,
            loadProgress: 0.42,
            activeDownloadCount: 2
        )

        #expect(label.contains("Account"))
        #expect(label.contains("Incognito"))
        #expect(label.contains("Pinned"))
        #expect(label.contains("Muted"))
        #expect(label.contains("split"))
        #expect(value.contains("Selected"))
        #expect(value.contains("42%"))
        #expect(value.contains("2 downloads"))
    }
}

struct BrowserLibraryTests {
    @Test @MainActor
    func historyIsUniqueNewestFirstAndCanRemoveOneURL() {
        let first = Tab(title: "First", url: URL(string: "https://one.example/start"))
        first.historyStrings = [
            "https://one.example/start",
            "https://shared.example/page",
        ]
        let second = Tab(title: "Second", url: URL(string: "https://two.example/latest"))
        second.historyStrings = [
            "https://shared.example/page",
            "https://two.example/latest",
        ]

        #expect(BrowserLibrary.historyURLs(from: [first, second]).map(\.absoluteString) == [
            "https://two.example/latest",
            "https://shared.example/page",
            "https://one.example/start",
        ])

        BrowserLibrary.removeHistory(
            url: URL(string: "https://shared.example/page")!,
            from: [first, second]
        )
        #expect(!first.historyStrings.contains("https://shared.example/page"))
        #expect(!second.historyStrings.contains("https://shared.example/page"))
    }

    @Test
    func bookmarkExportEscapesHTMLAndPreservesFolders() {
        let bookmark = Bookmark(
            title: "Research <Notes>",
            url: URL(string: "https://example.com/?a=1&b=2")!,
            category: "Work & Study"
        )

        let html = BrowserLibrary.bookmarkHTML([bookmark])

        #expect(html.contains("Research &lt;Notes&gt;"))
        #expect(html.contains("Work &amp; Study"))
        #expect(html.contains("https://example.com/?a=1&amp;b=2"))
        #expect(html.contains("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
    }

    @Test
    func bookmarkImportDecodesHTMLAndPreservesFolders() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
          <DT><H3>Work &amp; Study</H3>
          <DL><p>
            <DT><A HREF="https://example.com/?a=1&amp;b=2">Research &lt;Notes&gt;</A>
          </DL><p>
        </DL><p>
        """

        let imported = BrowserLibrary.bookmarks(fromHTML: html)

        #expect(imported.count == 1)
        #expect(imported.first?.title == "Research <Notes>")
        #expect(imported.first?.url.absoluteString == "https://example.com/?a=1&b=2")
        #expect(imported.first?.category == "Work & Study")
    }

    @Test @MainActor
    func pinnedTabsSortBeforeRegularTabsWithoutLosingTheirOrder() {
        let regular = Tab(title: "Regular")
        regular.orderIndex = 0
        let secondPinned = Tab(title: "Second pinned")
        secondPinned.isPinned = true
        secondPinned.orderIndex = 2
        let firstPinned = Tab(title: "First pinned")
        firstPinned.isPinned = true
        firstPinned.orderIndex = 1

        #expect(BrowserLibrary.sortedTabs([regular, secondPinned, firstPinned]).map(\.title) == [
            "First pinned",
            "Second pinned",
            "Regular",
        ])
    }

    @Test @MainActor
    func visibleTabOrderMatchesSidebarGroupsPinsAndRows() {
        let laterGroup = TabGroup(name: "Later", color: .blue, orderIndex: 2)
        let earlierGroup = TabGroup(name: "Earlier", color: .red, orderIndex: 1)

        let ungrouped = Tab(title: "Ungrouped")
        ungrouped.orderIndex = 0
        let ungroupedPinned = Tab(title: "Ungrouped pinned")
        ungroupedPinned.isPinned = true
        ungroupedPinned.orderIndex = 3
        let orphaned = Tab(title: "Orphaned")
        orphaned.groupId = UUID()
        orphaned.orderIndex = 4
        let earlierRegular = Tab(title: "Earlier regular")
        earlierRegular.groupId = earlierGroup.id
        earlierRegular.orderIndex = 0
        let earlierPinned = Tab(title: "Earlier pinned")
        earlierPinned.groupId = earlierGroup.id
        earlierPinned.isPinned = true
        earlierPinned.orderIndex = 5
        let later = Tab(title: "Later")
        later.groupId = laterGroup.id

        let sections = BrowserTabOrder.sections(
            tabs: [
                later,
                earlierRegular,
                orphaned,
                ungrouped,
                earlierPinned,
                ungroupedPinned,
            ],
            groups: [laterGroup, earlierGroup]
        )

        #expect(sections.map { $0.group?.name } == [nil, "Earlier", "Later"])
        #expect(sections.flatMap(\.tabs).map(\.title) == [
            "Ungrouped pinned",
            "Ungrouped",
            "Orphaned",
            "Earlier pinned",
            "Earlier regular",
            "Later",
        ])
    }

    @Test
    func readerModeParsesExtractedPageContent() {
        let article = ReaderMode.article(from: [
            "title": "A useful article",
            "byline": "Ada Writer",
            "blocks": [
                [
                    "kind": "heading",
                    "level": 2,
                    "runs": [["text": "A meaningful section"]],
                ],
                [
                    "kind": "paragraph",
                    "runs": [
                        ["text": "Read the "],
                        [
                            "text": "primary source",
                            "href": "https://example.com/source",
                            "strong": true,
                        ],
                        ["text": "."],
                    ],
                ],
                [
                    "kind": "listItem",
                    "ordered": true,
                    "ordinal": 1,
                    "depth": 0,
                    "runs": [["text": "First finding"]],
                ],
                [
                    "kind": "code",
                    "text": "let answer = 42",
                ],
                [
                    "kind": "caption",
                    "runs": [["text": "Figure 1: Results"]],
                ],
            ],
        ])

        let expectedBlocks: [ReaderBlock] = [
            .heading(level: 2, runs: [.plain("A meaningful section")]),
            .paragraph(runs: [
                .plain("Read the "),
                ReaderInline(
                    text: "primary source",
                    link: URL(string: "https://example.com/source"),
                    isStrong: true
                ),
                .plain("."),
            ]),
            .listItem(
                ordered: true,
                ordinal: 1,
                depth: 0,
                runs: [.plain("First finding")]
            ),
            .code("let answer = 42"),
            .caption(runs: [.plain("Figure 1: Results")]),
        ]

        #expect(article?.title == "A useful article")
        #expect(article?.byline == "Ada Writer")
        #expect(article?.blocks == expectedBlocks)
        #expect(article?.plainText.contains("First finding") == true)
        #expect(ReaderMode.article(from: ["title": "Empty", "blocks": []]) == nil)

        let unsafeLinkArticle = ReaderMode.article(from: [
            "title": "Unsafe link",
            "blocks": [[
                "kind": "paragraph",
                "runs": [[
                    "text": "Do not execute",
                    "href": "javascript:alert(document.cookie)",
                ]],
            ]],
        ])
        guard case .paragraph(let unsafeRuns) = unsafeLinkArticle?.blocks.first else {
            Issue.record("Expected the unsafe-link paragraph to remain readable")
            return
        }
        #expect(unsafeRuns.first?.link == nil)
    }
}

@MainActor
private final class WebKitNavigationProbe: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<URL?, Error>?

    func load(_ html: String, baseURL: URL, in webView: WKWebView) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(returning: webView.url)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

struct WebKitNavigationIntegrationTests {
    @Test @MainActor
    func readerExtractionPreservesDocumentSemantics() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let probe = WebKitNavigationProbe()
        let baseURL = try #require(URL(string: "https://reader.test/article"))
        let html = """
            <html>
              <head><title>Semantic Reader</title></head>
              <body>
                <article>
                  <h2>Results</h2>
                  <p>Read <strong><a href="/source">the source</a></strong>.</p>
                  <ol start="3"><li>Third finding</li></ol>
                  <blockquote>Evidence matters.</blockquote>
                  <pre><code>let answer = 42</code></pre>
                  <figure><figcaption>Figure 1</figcaption></figure>
                </article>
              </body>
            </html>
            """

        _ = try await probe.load(html, baseURL: baseURL, in: webView)
        let result = try await webView.evaluateJavaScript(ReaderMode.extractionScript)
        let article = try #require(ReaderMode.article(from: result))

        #expect(article.title == "Semantic Reader")
        #expect(article.blocks == [
            .heading(level: 2, runs: [.plain("Results")]),
            .paragraph(runs: [
                .plain("Read "),
                ReaderInline(
                    text: "the source",
                    link: URL(string: "https://reader.test/source"),
                    isStrong: true
                ),
                .plain("."),
            ]),
            .listItem(
                ordered: true,
                ordinal: 3,
                depth: 0,
                runs: [.plain("Third finding")]
            ),
            .quote(runs: [.plain("Evidence matters.")]),
            .code("let answer = 42"),
            .caption(runs: [.plain("Figure 1")]),
        ])
        webView.navigationDelegate = nil
    }

    @Test @MainActor
    func localNavigationCommitsAndExposesTheLoadedDocument() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let probe = WebKitNavigationProbe()
        let baseURL = try #require(URL(string: "https://integration.test/page"))

        let committedURL = try await probe.load(
            "<html><head><title>Navigation Ready</title></head><body>Loaded</body></html>",
            baseURL: baseURL,
            in: webView
        )
        let title = try await webView.evaluateJavaScript("document.title") as? String

        #expect(committedURL?.host == "integration.test")
        #expect(title == "Navigation Ready")
        webView.navigationDelegate = nil
    }
}
