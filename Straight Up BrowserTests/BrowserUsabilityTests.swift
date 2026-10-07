import Foundation
import Testing
import SwiftUI
@testable import Browser

@MainActor
struct BrowserUsabilityTests {
    @Test func quitBarAndReleaseShareTheSameDeadline() {
        for duration in [0.16, 1.6, 2.0] {
            let timing = QuitHoldTiming(startUptime: 100, duration: duration)
            #expect(timing.progress(at: 99) == 0)
            #expect(timing.progress(at: 100 + duration / 2) < 1)
            #expect(!timing.isReady(at: timing.deadline - 0.001))
            #expect(timing.isReady(at: timing.deadline))
            #expect(timing.progress(at: timing.deadline) == 1)
            // Readiness never expires while the user continues holding.
            #expect(timing.isReady(at: timing.deadline + 60))
            #expect(timing.progress(at: timing.deadline + 60) == 1)
        }
    }

    @Test func developmentAndTestBuildsDoNotUpdateThemselves() {
        #expect(!AppDelegate.startsUpdater)
    }

    @Test func searchTextRemainsOneQueryValueForEveryEngine() throws {
        for engine in ["Google", "DuckDuckGo", "Bing", "Yahoo"] {
            for query in ["C++ & C#", "a=b? c#d", "100% café + tea", "日本語 & emoji 🦊"] {
                let raw = NavigationManager.searchURL(for: query, engine: engine)
                let components = try #require(URLComponents(string: raw))
                #expect(components.queryItems?.count == 1)
                #expect(components.queryItems?.first?.value == query)
                #expect(components.queryItems?.first?.name == (engine == "Yahoo" ? "p" : "q"))
                #expect(components.fragment == nil)
                #expect(!raw.contains("+"))
            }
        }
    }

    @Test func tabOverviewColumnsFitTheAvailableWidth() {
        for (width, columns) in [(0, 1), (160, 1), (220, 1), (455, 1), (456, 2), (692, 3), (928, 4), (1164, 5), (1600, 6)] {
            #expect(TabGridView.columnCount(for: CGFloat(width)) == columns)
        }
    }

    @Test func visualTabKeepsItsSelectionBorderInsideTheSidebar() throws {
        let tab = Tab(title: "Preview", url: URL(string: "https://example.com"))
        for size in [NSSize(width: 1600, height: 900), NSSize(width: 1600, height: 100), NSSize(width: 100, height: 1600)] {
            let thumbnail = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()
                rect.fill()
                return true
            }
            let row = TabRowView(
                tab: tab, selectedTabId: tab.id, availableWidth: 300,
                showOnlyIcons: false, tabBarWidth: 300, onSelect: {}, onReorder: nil,
                thumbnail: thumbnail, expandedHeight: 140
            )
            .frame(width: 300, height: 140)
            .clipped()
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: row)
            let pixels = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            for (x, y) in [(7, 70), (292, 70), (150, 1), (150, 138)] {
                let color = try #require(pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                #expect(color.blueComponent > 0.6 && color.redComponent < 0.2,
                        "Missing selection edge at (\(x), \(y)) for thumbnail \(size)")
            }
        }
    }

    @Test func concurrentStartupWaitsForRecoveryBeforeCreatingConversations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await AgentRunStoreRegistry.store(baseDirectory: root)
        async let sameStore = AgentRunStoreRegistry.store(baseDirectory: root)
        #expect(try await sameStore === store)
        let startup = Task { try await AgentRunStoreRegistry.recoverIfNeeded(store, baseDirectory: root) }
        await Task.yield()
        try await AgentRunStoreRegistry.recoverIfNeeded(store, baseDirectory: root)
        let conversation = try await store.createConversation(title: "First request")
        try await startup.value
        let run = try await store.createRun(conversationID: conversation.id, entryPoint: .attended)
        #expect(run.conversationID == conversation.id)
    }
}

@MainActor
@Suite(.serialized)
struct QuitHoldLifecycleTests {
    @Test func releaseDoesNotRepeatThePageStateSaveCompletedDuringHolding() {
        let manager = QuitPersistenceProbe()
        manager.prepareInteractionStatesForTermination()
        manager.persistInteractionStatesAtTermination()
        #expect(manager.saveCount == 1)
    }

    @Test func failedPreparationIsRetriedAtTermination() {
        let manager = QuitPersistenceProbe()
        manager.saveSucceeds = false
        manager.prepareInteractionStatesForTermination()
        manager.persistInteractionStatesAtTermination()
        #expect(manager.saveCount == 2)
    }

    @Test func cancelledHoldingStillSavesFreshPageStateOnALaterQuit() {
        let manager = QuitPersistenceProbe()
        manager.prepareInteractionStatesForTermination()
        manager.cancelInteractionStateTerminationPreparation()
        manager.persistInteractionStatesAtTermination()
        #expect(manager.saveCount == 2)
    }

    @Test func earlyReleaseLeavesTheBrowserOpen() {
        checkRelease(elapsed: 0.01, shouldQuit: false)
    }

    @Test func releaseAtFullProgressQuitsExactlyOnce() {
        checkRelease(elapsed: 2, shouldQuit: true)
    }

    @Test func releaseAfterExtendedHoldingStillQuitsExactlyOnce() {
        checkRelease(elapsed: 62, shouldQuit: true)
    }

    private func checkRelease(elapsed: TimeInterval, shouldQuit: Bool) {
        let previous = UserDefaults.standard.object(forKey: KeyboardShortcutsManager.quitHoldPercentKey)
        UserDefaults.standard.set(1.0, forKey: KeyboardShortcutsManager.quitHoldPercentKey)
        defer { UserDefaults.standard.set(previous, forKey: KeyboardShortcutsManager.quitHoldPercentKey) }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var quitCount = 0
        let manager = KeyboardShortcutsManager(
            showOmnibar: .constant(false), reloadAction: {}, hardReloadAction: {},
            reloadAllTabsAction: {}, goBackAction: {}, goForwardAction: {},
            windowsForQuit: { [window] }, terminateApplication: { quitCount += 1 }
        )
        defer { manager.teardown() }
        let start = ProcessInfo.processInfo.systemUptime
        manager.startQuitHold(at: start)
        manager.handleQuitKeyRelease(at: start + elapsed)
        manager.handleQuitKeyRelease(at: start + elapsed + 1)
        #expect(quitCount == (shouldQuit ? 1 : 0))
        #expect(window.isVisible == !shouldQuit)
    }

    @Test(arguments: [0.1, 0.45])
    func cancellingAfterWindowsFadeRestoresTheirOriginalOpacity(fadeWait: Double) async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.8
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var quitCount = 0
        let manager = KeyboardShortcutsManager(
            showOmnibar: .constant(false), reloadAction: {}, hardReloadAction: {},
            reloadAllTabsAction: {}, goBackAction: {}, goForwardAction: {},
            windowsForQuit: { [window] }, terminateApplication: { quitCount += 1 }
        )
        defer { manager.teardown() }
        manager.startQuitHold(at: ProcessInfo.processInfo.systemUptime)
        manager.fadeWindowsForQuit()
        try await Task.sleep(for: .seconds(fadeWait))
        if fadeWait >= 0.35 { #expect(window.alphaValue == 0) }
        manager.cancelQuitHold()
        try await Task.sleep(for: .seconds(0.45))
        #expect(abs(window.alphaValue - 0.8) < 0.001)
        #expect(window.isVisible)
        #expect(quitCount == 0)
    }
}

@MainActor
private final class QuitPersistenceProbe: WebViewManager {
    private(set) var saveCount = 0
    var saveSucceeds = true

    override func persistInteractionStates() -> Bool {
        saveCount += 1
        return saveSucceeds
    }
}
