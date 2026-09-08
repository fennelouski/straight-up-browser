import Foundation
import Testing
import SwiftUI
@testable import Browser

@MainActor
struct BrowserUsabilityTests {
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
        let store = try AgentRunStoreRegistry.store(baseDirectory: root)
        let startup = Task { try await AgentRunStoreRegistry.recoverIfNeeded(store, baseDirectory: root) }
        await Task.yield()
        try await AgentRunStoreRegistry.recoverIfNeeded(store, baseDirectory: root)
        let conversation = try await store.createConversation(title: "First request")
        try await startup.value
        let run = try await store.createRun(conversationID: conversation.id, entryPoint: .attended)
        #expect(run.conversationID == conversation.id)
    }
}
