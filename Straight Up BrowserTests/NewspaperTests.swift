import Foundation
import SwiftData
import Testing
@testable import Browser

struct NewspaperDocumentTests {
    @Test func structuredDocumentRoundTripsWithoutFlatteningContent() throws {
        let article = makeStructuredArticle()
        let document = NewspaperDocument(article: article)

        let payload = try document.encoded()
        let decoded = try NewspaperDocument.decoder.decode(
            NewspaperDocument.self,
            from: payload
        )

        #expect(decoded == document)
        #expect(decoded.blocks.map(\.content) == article.blocks)
        #expect(decoded.images == article.images)
        #expect(decoded.plainText == "A structured story\n\nLinked and bold prose.\n\nFirst item\n\nA quotation.\n\nlet answer = 42\n\nPhoto caption")
    }

    @Test func equivalentDocumentsHaveStablePayloadsBlockIDsAndDigests() throws {
        let first = NewspaperDocument(article: makeStructuredArticle())
        let second = NewspaperDocument(article: makeStructuredArticle())

        let firstPayload = try first.encoded()
        let secondPayload = try second.encoded()

        #expect(firstPayload == secondPayload)
        #expect(first.blocks.map(\.id) == second.blocks.map(\.id))
        #expect(NewspaperDocument.digest(firstPayload) == NewspaperDocument.digest(secondPayload))
        #expect(NewspaperDocument.digest(firstPayload).count == 64)
    }

    @Test func blockIDsRemainStableWhenAnUnrelatedBlockIsInsertedBeforeThem() {
        let original = NewspaperDocument(article: ReaderArticle(
            title: "Story",
            byline: nil,
            blocks: [
                .heading(level: 2, runs: [.plain("Heading")]),
                .paragraph(runs: [.plain("Body")])
            ]
        ))
        let revised = NewspaperDocument(article: ReaderArticle(
            title: "Story",
            byline: nil,
            blocks: [
                .paragraph(runs: [.plain("New introduction")]),
                .heading(level: 2, runs: [.plain("Heading")]),
                .paragraph(runs: [.plain("Body")])
            ]
        ))

        #expect(Array(revised.blocks.dropFirst().map(\.id)) == original.blocks.map(\.id))
    }

    private func makeStructuredArticle() -> ReaderArticle {
        ReaderArticle(
            title: "A structured story",
            byline: "Ada Reader",
            blocks: [
                .heading(level: 2, runs: [.plain("A structured story")]),
                .paragraph(runs: [
                    ReaderInline(
                        text: "Linked",
                        link: URL(string: "https://example.com/reference"),
                        isEmphasized: true
                    ),
                    .plain(" and "),
                    ReaderInline(text: "bold", isStrong: true),
                    .plain(" prose.")
                ]),
                .listItem(
                    ordered: true,
                    ordinal: 1,
                    depth: 0,
                    runs: [.plain("First item")]
                ),
                .quote(runs: [.plain("A quotation.")]),
                .code("let answer = 42"),
                .caption(runs: [.plain("Photo caption")])
            ],
            publication: "The Example",
            section: "Technology",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            images: [
                ReaderImage(
                    url: URL(string: "https://example.com/photo.jpg")!,
                    altText: "A useful description"
                )
            ]
        )
    }
}

@MainActor
struct NewspaperStoreTests {
    @Test func enqueueDeduplicatesEquivalentArticleURLs() throws {
        let fixture = try makeFixture()
        let firstURL = URL(string: "https://example.com/story#opening")!
        let secondURL = URL(string: "https://example.com/story#comments")!

        let first = fixture.store.enqueue(url: firstURL, title: "Original title")
        let second = fixture.store.enqueue(url: secondURL, title: "Replacement title")
        let stored = try fixture.context.fetch(FetchDescriptor<NewspaperArticle>())

        #expect(first.wasInserted)
        #expect(!second.wasInserted)
        #expect(first.article === second.article)
        #expect(stored.count == 1)
        #expect(second.article.title == "Original title")
        #expect(second.article.url == secondURL)
    }

    @Test func markReadUpdatesCompletionAndProgressState() throws {
        let fixture = try makeFixture()
        let item = fixture.store.enqueue(
            url: URL(string: "https://example.com/read-state")!,
            title: "Reading state"
        ).article
        item.readingProgress = 0.4

        fixture.store.markRead(item, isRead: true)

        #expect(item.isRead)
        #expect(item.finishedAt != nil)
        #expect(item.readingProgress == 1)

        fixture.store.markRead(item, isRead: false)

        #expect(!item.isRead)
        #expect(item.finishedAt == nil)
        #expect(item.readingProgress == 0.99)
    }

    @Test func ratingIsClampedToTheSupportedRange() throws {
        let fixture = try makeFixture()
        let item = fixture.store.enqueue(
            url: URL(string: "https://example.com/rating")!,
            title: "Rating"
        ).article

        fixture.store.setRating(99, for: item)
        #expect(item.rating == 5)

        fixture.store.setRating(-1, for: item)
        #expect(item.rating == 0)
    }

    @Test func priorityUpdatesThroughTheStore() throws {
        let fixture = try makeFixture()
        let item = fixture.store.enqueue(
            url: URL(string: "https://example.com/priority")!,
            title: "Priority"
        ).article

        fixture.store.setPriority(.next, for: item)

        #expect(item.priority == .next)
        #expect(item.priorityRaw == NewspaperPriority.next.rawValue)
    }

    @Test func captureStoresStructuredPayloadAndBoundedCardMetadata() throws {
        let fixture = try makeFixture()
        let item = fixture.store.enqueue(
            url: URL(string: "https://example.com/capture")!,
            title: "Pending"
        ).article
        let image = ReaderImage(
            url: URL(string: "https://example.com/lead.jpg")!,
            altText: "Lead description"
        )
        let article = ReaderArticle(
            title: "Captured",
            byline: "A. Writer",
            blocks: [
                .heading(level: 2, runs: [.plain("Section")]),
                .quote(runs: [.plain(String(repeating: "voice ", count: 300))])
            ],
            publication: "Example Daily",
            section: "Ideas",
            images: [image]
        )

        fixture.store.finishCapture(item, article: article)

        #expect(item.captureState == .ready)
        #expect(item.document?.blocks.map(\.content) == article.blocks)
        #expect(item.leadImage == image)
        #expect(item.cardExcerpt.count == 1_200)
        #expect(item.originalPayloadData?.count ?? 0 <= NewspaperDocumentLimits.maximumEncodedBytes)
    }

    @Test func changedCaptureInvalidatesOnlyDerivedRenditionsForTheOldDigest() throws {
        let fixture = try makeFixture()
        let item = fixture.store.enqueue(
            url: URL(string: "https://example.com/refresh")!,
            title: "Refresh"
        ).article
        let first = ReaderArticle(
            title: "Refresh",
            byline: nil,
            blocks: [.paragraph(runs: [.plain("Original body text.")])]
        )
        fixture.store.finishCapture(item, article: first)
        let firstDigest = item.sourceDigest
        let rendition = NewspaperCondensedDocument(
            version: NewspaperCondensedDocument.currentVersion,
            promptVersion: NewspaperCondensationService.promptVersion,
            sourceDigest: firstDigest,
            targetUnit: .words,
            targetLength: 100,
            actualWordCount: 2,
            actualCharacterCount: 11,
            model: NewspaperCondensationService.modelIdentifier,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            text: "Short body."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        item.condensedPayloadData = try encoder.encode(rendition)
        item.condensationState = .ready
        item.condensationPromptVersion = NewspaperCondensationService.promptVersion
        item.condensationSourceDigest = firstDigest
        item.targetUnit = .words
        item.targetLength = 100
        item.condensedWordCount = 2
        item.cardExcerpt = "Short body."

        fixture.store.finishCapture(item, article: first)
        #expect(item.condensedText == "Short body.")
        #expect(item.cardExcerpt == "Short body.")

        let changed = ReaderArticle(
            title: "Refresh",
            byline: nil,
            blocks: [.paragraph(runs: [.plain("A genuinely changed body.")])]
        )
        fixture.store.finishCapture(item, article: changed)

        #expect(item.sourceDigest != firstDigest)
        #expect(item.condensedPayloadData == nil)
        #expect(item.condensationState == .notRequested)
        #expect(item.condensedText == nil)
        #expect(item.cardExcerpt == "A genuinely changed body.")
    }

    private func makeFixture() throws -> (
        container: ModelContainer,
        context: ModelContext,
        store: NewspaperStore
    ) {
        let schema = Schema([NewspaperArticle.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        return (container, context, NewspaperStore(modelContext: context))
    }
}

struct NewspaperURLNormalizationTests {
    @Test func sourceKeyRemovesFragmentsWithoutDiscardingTheQuery() {
        let first = URL(string: "HTTPS://Example.COM/story?edition=morning#opening")!
        let second = URL(string: "https://example.com/story?edition=morning#comments")!

        let firstKey = NewspaperStore.sourceKey(for: first)
        let secondKey = NewspaperStore.sourceKey(for: second)

        #expect(firstKey == "https://example.com/story?edition=morning")
        #expect(firstKey == secondKey)
    }
}

struct NewspaperCondensationTests {
    @Test func wordLimiterNeverExceedsTheHardLimit() {
        let result = NewspaperCondensationService.limitedToWords(
            "one two three four five",
            limit: 3
        )

        #expect(result.split(whereSeparator: \.isWhitespace).count <= 3)
        #expect(result == "one two three…")
    }

    @Test func characterLimiterIncludesEllipsisInsideTheHardLimit() {
        let result = NewspaperCondensationService.limitedToCharacters(
            "abcdefghij",
            limit: 5
        )

        #expect(result.count == 5)
        #expect(result == "abcd…")
    }

    @Test func chunkTargetsAllocateTheWholeBudgetProportionally() {
        let targets = NewspaperCondensationService.allocatedTargets(
            for: ["one", "two three", "four five six"],
            totalTarget: 12
        )

        #expect(targets == [2, 4, 6])
        #expect(targets.reduce(0, +) == 12)
    }

    @Test func allocationDistributesRemainderDeterministically() {
        let targets = NewspaperCondensationService.allocatedTargets(
            for: ["one", "two", "three"],
            totalTarget: 5
        )

        #expect(targets == [2, 2, 1])
    }
}
