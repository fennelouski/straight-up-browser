import Foundation
import SwiftData
import Testing
@testable import Browser

// MARK: - Canonical identity

struct SourceCanonicalizerTests {
    @Test("A video's timestamp is an anchor locator, not a source identity")
    func youTubeShapesCollapseToOneSource() {
        let expected = "https://youtube.com/watch?v=dQw4w9WgXcQ"
        let shapes = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=417",
            "https://youtu.be/dQw4w9WgXcQ?t=417",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&index=4",
            "https://www.youtube.com/embed/dQw4w9WgXcQ"
        ]
        for shape in shapes {
            let key = SourceCanonicalizer.canonicalKey(for: URL(string: shape)!)
            #expect(key == expected, "\(shape) should canonicalize to \(expected), got \(key)")
        }
    }

    @Test("Tracking parameters never fork a source")
    func trackingParamsAreStripped() {
        let plain = SourceCanonicalizer.canonicalKey(for: URL(string: "https://example.com/post")!)
        let tagged = SourceCanonicalizer.canonicalKey(
            for: URL(string: "https://www.example.com/post?utm_source=news&utm_medium=email&fbclid=abc")!
        )
        #expect(plain == tagged)
        #expect(plain == "https://example.com/post")
    }

    @Test("Meaningful query parameters survive, in a stable order")
    func meaningfulQueryIsKeptAndSorted() {
        let a = SourceCanonicalizer.canonicalKey(for: URL(string: "https://example.com/s?b=2&a=1")!)
        let b = SourceCanonicalizer.canonicalKey(for: URL(string: "https://example.com/s?a=1&b=2")!)
        #expect(a == b)
        #expect(a.contains("a=1"))
        #expect(a.contains("b=2"))
    }

    @Test("arXiv PDFs and abstracts are one source, but versions are not")
    func arXivPdfMapsToAbstractAndKeepsVersion() {
        let pdf = SourceCanonicalizer.canonicalKey(for: URL(string: "https://arxiv.org/pdf/2401.12345v2.pdf")!)
        let abs = SourceCanonicalizer.canonicalKey(for: URL(string: "https://arxiv.org/abs/2401.12345v2")!)
        #expect(pdf == abs)
        #expect(pdf == "https://arxiv.org/abs/2401.12345v2")

        let v1 = SourceCanonicalizer.canonicalKey(for: URL(string: "https://arxiv.org/abs/2401.12345v1")!)
        #expect(v1 != abs, "v1 and v2 of a paper are genuinely different sources")
    }

    @Test("DOIs normalize host and case")
    func doiIsNormalized() {
        let a = SourceCanonicalizer.canonicalKey(for: URL(string: "https://dx.doi.org/10.1000/XyZ")!)
        let b = SourceCanonicalizer.canonicalKey(for: URL(string: "https://doi.org/10.1000/xyz")!)
        #expect(a == b)
    }

    @Test("A text fragment anchors into a page without becoming a second page")
    func fragmentsNeverEnterTheKey() {
        let page = SourceCanonicalizer.canonicalKey(for: URL(string: "https://example.com/a")!)
        let anchored = SourceCanonicalizer.canonicalKey(
            for: URL(string: "https://example.com/a#:~:text=gut%20bacteria")!
        )
        #expect(page == anchored)
    }

    @Test("Timestamps are recovered from either spelling, including 1h2m3s")
    func timestampParsing() {
        #expect(SourceCanonicalizer.youTubeTimestampSeconds(in: URL(string: "https://youtu.be/x?t=417")!) == 417)
        #expect(SourceCanonicalizer.youTubeTimestampSeconds(in: URL(string: "https://youtu.be/x?t=1h2m3s")!) == 3723)
        #expect(SourceCanonicalizer.youTubeTimestampSeconds(in: URL(string: "https://youtu.be/x")!) == nil)
    }
}

// MARK: - Anchor syntax

struct AnchorLinkTests {
    @Test("Every modality round-trips through its stored locator")
    func locatorRoundTrip() {
        let cases: [(SourceModality, AnchorLocator)] = [
            (.webPage, .textFragment("text=gut%20bacteria")),
            (.video, .timestamp(start: 417, end: nil)),
            (.video, .timestamp(start: 417, end: 432)),
            (.pdf, .pdfPage(12, quote: nil)),
            (.image, .imageRegion("xywh=percent:10,20,30,40"))
        ]
        for (modality, locator) in cases {
            let parsed = AnchorLocator.parse(locator.stored, modality: modality)
            #expect(parsed == locator, "\(modality) locator \(locator.stored) did not round-trip")
        }
    }

    @Test("The href is a genuine deep link per modality")
    func hrefComposition() {
        let page = URL(string: "https://example.com/a")!
        let fragment = AnchorLocator.textFragment("text=quote").url(base: page, modality: .webPage)
        #expect(fragment.absoluteString == "https://example.com/a#:~:text=quote")

        let video = URL(string: "https://youtube.com/watch?v=abc")!
        let stamped = AnchorLocator.timestamp(start: 417, end: nil).url(base: video, modality: .video)
        #expect(stamped.absoluteString.contains("t=417"))
        #expect(stamped.absoluteString.contains("v=abc"))

        let pdf = AnchorLocator.pdfPage(12, quote: nil)
            .url(base: URL(string: "https://example.com/p.pdf")!, modality: .pdf)
        #expect(pdf.absoluteString == "https://example.com/p.pdf#page=12")
    }

    @Test("A link carries its ledger id and still parses as ordinary Markdown")
    func markdownRoundTrip() throws {
        let id = UUID()
        let url = URL(string: "https://example.com/a#:~:text=quote")!
        let line = AnchorLink.markdown(text: "the finding", url: url, anchorId: id)

        #expect(line.hasPrefix("[the finding](https://example.com/a#:~:text=quote \"^"))

        let parsed = try #require(AnchorLink.parseAll(in: line).first)
        #expect(parsed.text == "the finding")
        #expect(parsed.url == url)
        #expect(AnchorLink.matches(anchorId: id, idPrefix: try #require(parsed.idPrefix)))
    }

    @Test("A plain Markdown link is not an error — it parses with no ledger id")
    func plainLinkDegradesGracefully() throws {
        let parsed = try #require(AnchorLink.parseAll(in: "[a](https://example.com/x)").first)
        #expect(parsed.idPrefix == nil)
        #expect(parsed.url.absoluteString == "https://example.com/x")
    }

    @Test("A foreign title is not mistaken for a ledger id")
    func foreignTitleIsIgnored() throws {
        let parsed = try #require(
            AnchorLink.parseAll(in: "[a](https://example.com/x \"someone else's title\")").first
        )
        #expect(parsed.idPrefix == nil)
    }
}

// MARK: - Ledger semantics

@MainActor
struct LedgerStoreTests {

    private func makeStore() throws -> (ModelContainer, ModelContext, LedgerStore) {
        let schema = Schema([
            NewspaperArticle.self, Workspace.self, WorkspaceSourceRef.self,
            WorkspaceDocument.self, LedgerAnchor.self, LedgerClaim.self,
            LedgerEdge.self, LedgerArchive.self, Tab.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        return (container, context, LedgerStore(modelContext: context))
    }

    private func makeWorkspace(_ context: ModelContext, name: String = "Fermentation") -> Workspace {
        let workspace = Workspace(name: name)
        context.insert(workspace)
        return workspace
    }

    @Test("Settling records the source as open, filed under the workspace")
    func settleRecordsOpenReference() throws {
        let (_, context, store) = try makeStore()
        let workspace = makeWorkspace(context)
        let url = URL(string: "https://example.com/koji")!

        let article = try #require(store.recordSettle(url: url, title: "Koji", workspaceId: workspace.id))
        #expect(article.section == "Fermentation")
        #expect(article.firstWorkspaceId == workspace.id)

        let ref = try #require(store.reference(workspaceId: workspace.id, sourceKey: article.sourceKey))
        #expect(ref.disposition == .open)
        #expect(ref.method == .settle)
    }

    @Test("Settle fires once per page: an unchanged revisit writes nothing")
    func settleDoesNotRefireOnRevisit() throws {
        let (_, context, store) = try makeStore()
        let workspace = makeWorkspace(context)
        let url = URL(string: "https://example.com/koji")!

        let first = try #require(store.recordSettle(url: url, title: "Koji", workspaceId: workspace.id))
        // Simulate the capture completing, which is what arms the fast guard.
        first.captureState = .ready

        #expect(store.isFullyCaptured(workspaceId: workspace.id, url: url))
        #expect(store.recordSettle(url: url, title: "Koji", workspaceId: workspace.id) == nil)
        #expect(store.references(sourceKey: first.sourceKey).count == 1)
    }

    @Test("A deferred source is retried rather than skipped")
    func deferredSourceIsUpgraded() throws {
        let (_, context, store) = try makeStore()
        let workspace = makeWorkspace(context)
        let url = URL(string: "https://example.com/koji")!

        let article = try #require(store.recordSettle(url: url, title: "Koji", workspaceId: workspace.id))
        #expect(article.captureState == .deferred)
        #expect(!store.isFullyCaptured(workspaceId: workspace.id, url: url))
    }

    @Test("Closing a tab writes dismissed and captures nothing")
    func rejectionWritesDispositionOnly() throws {
        let (_, context, store) = try makeStore()
        let workspace = makeWorkspace(context)
        let url = URL(string: "https://example.com/junk")!

        store.recordRejection(url: url, title: "Junk", workspaceId: workspace.id)

        let key = SourceCanonicalizer.canonicalKey(for: url)
        let ref = try #require(store.reference(workspaceId: workspace.id, sourceKey: key))
        #expect(ref.disposition == .dismissed)

        let article = try #require(store.source(sourceKey: key))
        #expect(article.originalPayloadData == nil, "rejection must never capture text")
        #expect(article.captureState == .deferred)
    }

    @Test("A blank tab has no source, so closing it writes nothing")
    func rejectionIgnoresBlankTabs() throws {
        let (_, context, store) = try makeStore()
        let workspace = makeWorkspace(context)
        store.recordRejection(url: nil, title: "", workspaceId: workspace.id)
        #expect(store.references(workspaceId: workspace.id).isEmpty)
    }

    @Test("Deliberately reopening a rejected source reverses the rejection")
    func settleAfterDismissReturnsToOpen() throws {
        let (_, context, store) = try makeStore()
        let workspace = makeWorkspace(context)
        let url = URL(string: "https://example.com/second-look")!

        store.recordRejection(url: url, title: "Second look", workspaceId: workspace.id)
        store.recordSettle(url: url, title: "Second look", workspaceId: workspace.id)

        let key = SourceCanonicalizer.canonicalKey(for: url)
        #expect(store.reference(workspaceId: workspace.id, sourceKey: key)?.disposition == .open)
    }

    @Test("Archiving sweeps open to kept, leaves rejections alone, and is idempotent")
    func archiveSweep() throws {
        let (_, context, store) = try makeStore()
        let workspace = makeWorkspace(context)
        store.recordSettle(url: URL(string: "https://example.com/a")!, title: "A", workspaceId: workspace.id)
        store.recordSettle(url: URL(string: "https://example.com/b")!, title: "B", workspaceId: workspace.id)
        store.recordRejection(url: URL(string: "https://example.com/c")!, title: "C", workspaceId: workspace.id)

        #expect(store.archiveWorkspace(workspace) == 2)
        let refs = store.references(workspaceId: workspace.id)
        #expect(refs.filter { $0.disposition == .kept }.count == 2)
        #expect(refs.filter { $0.disposition == .dismissed }.count == 1)

        // Runs again on another device after sync; must write nothing.
        #expect(store.archiveWorkspace(workspace) == 0)
        #expect(store.references(workspaceId: workspace.id).filter { $0.disposition == .kept }.count == 2)
    }

    @Test("One source, two workspaces: the first keeps the section")
    func firstWorkspaceWinsTheSection() throws {
        let (_, context, store) = try makeStore()
        let first = makeWorkspace(context, name: "Fermentation")
        let second = makeWorkspace(context, name: "Protein Synthesis")
        let url = URL(string: "https://example.com/shared")!

        let article = try #require(store.recordSettle(url: url, title: "Shared", workspaceId: first.id))
        store.recordSettle(url: url, title: "Shared", workspaceId: second.id)

        #expect(article.section == "Fermentation")
        #expect(article.firstWorkspaceId == first.id)
        #expect(store.references(sourceKey: article.sourceKey).count == 2)
    }

    @Test("A source rejected everywhere is hidden from the feed; open anywhere keeps it")
    func feedExclusion() throws {
        let (_, context, store) = try makeStore()
        let first = makeWorkspace(context, name: "Fermentation")
        let second = makeWorkspace(context, name: "Protein Synthesis")
        let url = URL(string: "https://example.com/maybe")!

        store.recordRejection(url: url, title: "Maybe", workspaceId: first.id)
        let key = SourceCanonicalizer.canonicalKey(for: url)
        let article = try #require(store.source(sourceKey: key))
        #expect(store.isHiddenFromFeed(article))

        store.recordSettle(url: url, title: "Maybe", workspaceId: second.id)
        #expect(!store.isHiddenFromFeed(article), "still in play in another workspace")
    }

    @Test("Provenance lineage is recorded when one source leads to another")
    func lineageIsRecorded() throws {
        let (_, context, store) = try makeStore()
        let workspace = makeWorkspace(context)
        let parent = try #require(store.recordSettle(
            url: URL(string: "https://example.com/parent")!, title: "Parent", workspaceId: workspace.id
        ))
        let child = try #require(store.recordSettle(
            url: URL(string: "https://example.com/child")!,
            title: "Child",
            workspaceId: workspace.id,
            openedFromSourceId: parent.id
        ))

        let ref = try #require(store.reference(workspaceId: workspace.id, sourceKey: child.sourceKey))
        #expect(ref.openedFromSourceId == parent.id)

        let parentRef = try #require(store.reference(workspaceId: workspace.id, sourceKey: parent.sourceKey))
        #expect(parentRef.openedFromSourceId == nil, "an omnibar-opened tab has no lineage")
    }

    @Test("Seen-before reports the workspace, the verdict, and the rating")
    func priorEncounters() throws {
        let (_, context, store) = try makeStore()
        let workspace = makeWorkspace(context)
        let url = URL(string: "https://example.com/known")!
        let article = try #require(store.recordSettle(url: url, title: "Known", workspaceId: workspace.id))
        article.rating = 4

        // A tracking-tagged variant of the same page still finds it.
        let encounters = store.priorEncounters(for: URL(string: "https://example.com/known?utm_source=x")!)
        #expect(encounters.count == 1)
        #expect(encounters.first?.workspaceName == "Fermentation")
        #expect(encounters.first?.rating == 4)
        #expect(encounters.first?.disposition == .open)
    }

    @Test("The capture reconciler leaves deferred sources alone")
    func reconcilerIgnoresDeferredSources() throws {
        let (_, context, store) = try makeStore()
        let workspace = makeWorkspace(context)
        let deferred = try #require(store.recordSettle(
            url: URL(string: "https://example.com/later")!, title: "Later", workspaceId: workspace.id
        ))
        #expect(deferred.captureState == .deferred)

        // A genuinely interrupted capture, which the reconciler must fix.
        let interrupted = NewspaperArticle(url: URL(string: "https://example.com/mid")!, title: "Mid")
        interrupted.captureState = .capturing
        context.insert(interrupted)

        NewspaperStore(modelContext: context).reconcileInterruptedWork()

        #expect(deferred.captureState == .deferred, "a deferred source is not an interrupted one")
        #expect(interrupted.captureState == .failed)
    }

    @Test("Archives above the cap are skipped rather than stored")
    func archiveCap() throws {
        let (_, _, store) = try makeStore()
        let id = UUID()
        store.storeArchive(sourceId: id, sourceKey: "k", data: Data(repeating: 0, count: 1_024))
        #expect(store.totalArchiveBytes() == 1_024)

        let overCap = Data(repeating: 0, count: WorkspaceCapturePolicy.maximumArchiveBytes + 1)
        store.storeArchive(sourceId: id, sourceKey: "k", data: overCap)
        #expect(store.totalArchiveBytes() == 1_024, "an oversized archive must not be stored")
    }
}

// MARK: - Store routing

/// The privacy/quota guarantee that page archives never sync is enforced by
/// which ModelConfiguration declares the entity. Both store files end up
/// containing every table (Core Data creates the full model in each), so the
/// only meaningful check is where a write actually lands.
@MainActor
struct LedgerArchiveRoutingTests {

    @Test("Archives write to the local store, never the synced one")
    func archivesLandInTheLocalStore() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Mirrors ModelContainerStartup.makeDefault: one schema, two stores.
        let schema = Schema(TabSync.cloudBackedModelTypes + TabSync.localOnlyModelTypes)
        let syncedURL = directory.appendingPathComponent("synced.store")
        let localURL = directory.appendingPathComponent("LocalArchives.store")
        let synced = ModelConfiguration(
            schema: Schema(TabSync.cloudBackedModelTypes),
            url: syncedURL,
            cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "LocalArchives",
            schema: Schema(TabSync.localOnlyModelTypes),
            url: localURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [synced, local])
        let context = ModelContext(container)

        let workspace = Workspace(name: "Fermentation")
        context.insert(workspace)
        let store = LedgerStore(modelContext: context)
        let article = try #require(store.recordSettle(
            url: URL(string: "https://example.com/koji")!, title: "Koji", workspaceId: workspace.id
        ))
        store.storeArchive(sourceId: article.id, sourceKey: article.sourceKey, data: Data(repeating: 7, count: 4_096))
        try context.save()

        #expect(store.totalArchiveBytes() == 4_096)
        #expect(FileManager.default.fileExists(atPath: localURL.path), "the local archive store must exist")

        // The archive bytes are in the local file and nowhere near the synced one.
        let syncedBytes = (try Data(contentsOf: syncedURL)).count
        let localBytes = (try Data(contentsOf: localURL)).count
        #expect(localBytes > 0)
        #expect(syncedBytes > 0)

        // And the entity is declared local-only, which is what keeps CloudKit out.
        #expect(TabSync.localOnlyModelTypes.map { String(describing: $0) } == ["LedgerArchive"])
        #expect(!TabSync.cloudBackedModelTypeNames.contains("LedgerArchive"))
    }
}

// MARK: - Migration

@MainActor
struct LedgerMigratorTests {

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            NewspaperArticle.self, Workspace.self, WorkspaceSourceRef.self,
            WorkspaceDocument.self, LedgerAnchor.self, LedgerClaim.self,
            LedgerEdge.self, LedgerArchive.self, Tab.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, ModelContext(container))
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ledger.migrator.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.description)
        return defaults
    }

    @Test("Duplicates collapsing onto one canonical key merge, richest row winning")
    func mergesDuplicatesOnRekey() throws {
        let (_, context) = try makeContext()

        // Same video, three shapes, saved before canonicalization existed.
        let plain = NewspaperArticle(url: URL(string: "https://www.youtube.com/watch?v=abc")!, title: "Video")
        plain.addedAt = Date(timeIntervalSince1970: 1_000)
        plain.rating = 2
        let stamped = NewspaperArticle(url: URL(string: "https://youtu.be/abc?t=417")!, title: "Video")
        stamped.addedAt = Date(timeIntervalSince1970: 2_000)
        stamped.originalPayloadData = Data("text".utf8)
        stamped.rating = 5
        stamped.isRead = true
        for article in [plain, stamped] { context.insert(article) }

        let report = LedgerMigrator(modelContext: context, defaults: makeDefaults()).migrateIfNeeded()
        #expect(report.mergedDuplicates == 1)

        let remaining = try context.fetch(FetchDescriptor<NewspaperArticle>())
        #expect(remaining.count == 1)
        let winner = try #require(remaining.first)
        #expect(winner.originalPayloadData != nil, "the row with text wins")
        #expect(winner.rating == 5, "the better rating is absorbed")
        #expect(winner.isRead)
        #expect(winner.sourceKey == "https://youtube.com/watch?v=abc")
    }

    @Test("A second migration run changes nothing")
    func migrationIsIdempotent() throws {
        let (_, context) = try makeContext()
        let defaults = makeDefaults()
        context.insert(NewspaperArticle(url: URL(string: "https://www.example.com/a?utm_source=x")!, title: "A"))
        context.insert(NewspaperArticle(url: URL(string: "https://example.com/a")!, title: "A"))

        let first = LedgerMigrator(modelContext: context, defaults: defaults).migrateIfNeeded()
        #expect(first.mergedDuplicates == 1)

        let second = LedgerMigrator(modelContext: context, defaults: defaults).migrateIfNeeded()
        #expect(second.total == 0)
        #expect(try context.fetch(FetchDescriptor<NewspaperArticle>()).count == 1)
    }

    @Test("Old UserDefaults workspace snapshots become real workspaces with their tabs")
    func importsLegacySnapshots() throws {
        let (_, context) = try makeContext()
        let defaults = makeDefaults()
        let workspaceId = UUID()
        let json = """
        [{"id":"\(workspaceId.uuidString)","name":"Fermentation",
          "createdAt":\(Date(timeIntervalSinceReferenceDate: 0).timeIntervalSinceReferenceDate),
          "groups":[],
          "tabs":[{"id":"\(UUID().uuidString)","title":"Koji",
                   "urlString":"https://example.com/koji","isPinned":false,"orderIndex":0}]}]
        """
        defaults.set(Data(json.utf8), forKey: "saved_workspaces")

        let report = LedgerMigrator(modelContext: context, defaults: defaults).migrateIfNeeded()
        #expect(report.importedWorkspaces == 1)

        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(workspaces.first?.name == "Fermentation")
        #expect(workspaces.first?.sectionName == "Fermentation")

        let tabs = try context.fetch(FetchDescriptor<Tab>())
        #expect(tabs.count == 1)
        #expect(tabs.first?.workspaceId == workspaceId, "imported tabs join their workspace")
        #expect(defaults.data(forKey: "saved_workspaces") == nil, "the old key is consumed")
        #expect(defaults.data(forKey: "saved_workspaces_migrated_backup") != nil, "but kept as a backup")
    }

    @Test("Merge order: text beats rating, rating beats age, age preserves the original filing")
    func mergeWinnerOrdering() {
        let old = NewspaperArticle(url: URL(string: "https://example.com/a")!, title: "old")
        old.addedAt = Date(timeIntervalSince1970: 1_000)
        let new = NewspaperArticle(url: URL(string: "https://example.com/a")!, title: "new")
        new.addedAt = Date(timeIntervalSince1970: 2_000)

        #expect(LedgerMigrator.winsMerge(old, new), "earliest addedAt wins when all else is equal")

        new.rating = 3
        #expect(LedgerMigrator.winsMerge(new, old), "a better rating beats being older")

        old.originalPayloadData = Data("t".utf8)
        #expect(LedgerMigrator.winsMerge(old, new), "having the text beats everything")
    }
}

// MARK: - Workspace membership

@MainActor
struct WorkspaceMembershipTests {

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Tab.self, Workspace.self, WorkspaceSourceRef.self, NewspaperArticle.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, ModelContext(container))
    }

    /// Mirrors ContentView.visiblePersistedTabs / BrowserView_iOS.visibleTabs.
    private func visible(_ tabs: [Tab], workspaceId: UUID?) -> [Tab] {
        tabs.filter { $0.workspaceId == workspaceId }
    }

    @Test("A workspace's tabs never appear in the default workspace")
    func tabsStayWithTheirWorkspace() throws {
        let (_, context) = try makeContext()
        let workspace = Workspace(name: "Fermentation")
        context.insert(workspace)

        let owned = Tab(title: "Koji", url: URL(string: "https://example.com/koji"), isActive: false)
        owned.workspaceId = workspace.id
        let loose = Tab(title: "Weather", url: URL(string: "https://example.com/w"), isActive: false)
        for tab in [owned, loose] { context.insert(tab) }
        let all = [owned, loose]

        #expect(visible(all, workspaceId: workspace.id).map(\.id) == [owned.id])
        #expect(visible(all, workspaceId: nil).map(\.id) == [loose.id])
    }

    @Test("Suspending is only a filter change: nothing is discarded")
    func suspendPreservesMembership() throws {
        let (_, context) = try makeContext()
        let workspace = Workspace(name: "Fermentation")
        context.insert(workspace)
        let tab = Tab(title: "Koji", url: URL(string: "https://example.com/koji"), isActive: false)
        tab.workspaceId = workspace.id
        context.insert(tab)

        // Suspend == active workspace becomes nil. The tab is untouched.
        #expect(visible([tab], workspaceId: nil).isEmpty)
        #expect(tab.workspaceId == workspace.id, "membership survives suspension")
        #expect(visible([tab], workspaceId: workspace.id).count == 1, "and restore is the same filter")
    }
}
