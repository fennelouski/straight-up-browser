import Foundation
import SwiftData
import Testing
@testable import Browser

@MainActor
struct ScratchPadTests {
    @Test func clipsKeepPortableContentAndSourceAttribution() {
        let item = ScratchPadItem(
            kind: .text,
            text: "A useful passage",
            sourceURL: URL(string: "https://example.com/story"),
            sourceTitle: "Example Story"
        )

        #expect(item.kind == .text)
        #expect(item.agentContext == "Source: Example Story\nURL: https://example.com/story\nA useful passage")
    }

    @Test func scratchItemsPersistAlongsideOtherSyncedBrowserData() throws {
        let schema = Schema(TabSync.cloudBackedModelTypes)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let item = ScratchPadItem(kind: .note, text: "Follow this thread")
        container.mainContext.insert(item)
        try container.mainContext.save()

        let stored = try container.mainContext.fetch(FetchDescriptor<ScratchPadItem>())
        #expect(stored.count == 1)
        #expect(stored.first?.text == "Follow this thread")
        #expect(TabSync.cloudBackedModelTypeNames.contains("ScratchPadItem"))
        #expect(TabSync.syncedDataCategories.contains(.scratchPad))
    }

    @Test func imagesAreOnlyNamedForTheAgentWhenExplicitlySelected() {
        let item = ScratchPadItem(
            kind: .image,
            sourceURL: URL(string: "https://example.com/gallery"),
            sourceTitle: "Gallery",
            imageData: Data([0x01, 0x02])
        )

        #expect(item.agentContext.contains("[Clipped image]"))
        #expect(item.agentContext.contains("https://example.com/gallery"))
    }

    @Test func scratchPadHasARebindableCrossPlatformShortcut() {
        #expect(ShortcutCommand.scratchPad.defaultShortcut == Shortcut(
            key: "n",
            command: true,
            option: true
        ))
        #expect(ShortcutCommand.all.contains(.scratchPad))
        #expect(BrowserPlatformCommandRegistry.iPad.contains {
            $0.command == .scratchPad
                && $0.notification == .browserToggleScratchPad
        })
    }
}
