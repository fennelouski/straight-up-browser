import Foundation
import CoreGraphics
import Testing
import SwiftUI
@testable import Browser

struct PaneLayoutModelTests {
    private func leaves(_ count: Int) -> [LayoutPane] { (0..<count).map { _ in LayoutPane(content: .tab(UUID())) } }

    @Test func fivePaneTopologyHasDistinctStablePaneAndContentIdentities() throws {
        let leaves = leaves(5), tree = try #require(PaneLayoutTree.largeLeading(leaves))
        _ = try tree.validated()
        #expect(tree.panes.count == 5)
        #expect(Set(tree.panes.map(\.id)).count == 5)
        #expect(Set(tree.contentIDs) == Set(leaves.map { $0.content.id }))
        #expect(zip(tree.panes.map(\.id), tree.contentIDs).allSatisfy { $0 != $1 })
        let decoded = try JSONDecoder().decode(PaneLayoutTree.self, from: JSONEncoder().encode(tree))
        #expect(decoded == tree)
    }

    @Test func swapChangesOnlyOccupantsAndKeepsExactDividerGeometry() throws {
        let panes = leaves(5), original = try #require(PaneLayoutTree.largeLeading(panes))
        let swapped = try original.placing(panes[0].content, at: panes[4].id, edge: .center)
        #expect(swapped.panes.map(\.id) == original.panes.map(\.id))
        #expect(swapped.panes.first?.content == panes[4].content)
        #expect(swapped.panes.last?.content == panes[0].content)
        let bounds = CGRect(x: 0, y: 0, width: 1400, height: 900)
        #expect(swapped.geometry(in: bounds).dividers == original.geometry(in: bounds).dividers)
        #expect(try swapped.placing(panes[0].content, at: panes[0].id, edge: .center) == original)
    }

    @Test func edgeMovePrunesBeforeInsertingAndOwnEdgesAreNoOps() throws {
        let panes = leaves(3), tree = try #require(PaneLayoutTree.columns(panes))
        for edge in PanePlacement.allCases { #expect(try tree.placing(panes[0].content, at: panes[0].id, edge: edge) == tree) }
        let moved = try tree.placing(panes[0].content, at: panes[2].id, edge: .below)
        #expect(moved.panes.count == 3)
        #expect(Set(moved.panes.map(\.id)) == Set(tree.panes.map(\.id)))
        #expect(moved.panes.last?.id == panes[0].id)
        _ = try moved.validated()
    }

    @Test func hiddenCenterPlacementRetainsPanePositionWithoutDuplicatingContent() throws {
        let panes = leaves(2), tree = try #require(PaneLayoutTree.columns(panes)), hidden = PaneContentReference.tab(UUID())
        let placed = try tree.placing(hidden, at: panes[1].id, edge: .center)
        #expect(placed.panes.count == 2)
        #expect(placed.panes[1].id == panes[1].id)
        #expect(placed.panes[1].content == hidden)
        #expect(!placed.contentIDs.contains(panes[1].content.id))
    }

    @Test func documentsKeepTypedProviderReferencesThroughMoves() throws {
        let doc = LayoutPane(content: .document(UUID())), tab = LayoutPane(content: .tab(UUID()))
        let tree = try #require(PaneLayoutTree.columns([doc, tab]))
        let swapped = try tree.placing(doc.content, at: tab.id, edge: .center)
        #expect(swapped.panes[1].content == doc.content)
        #expect(swapped.panes[0].content == tab.content)
    }

    @Test func legacyMembershipRemovalPrunesWithoutResettingFivePaneTopologyAndAdditionSplitsFocusedLeaf() throws {
        let panes = leaves(5), tree = try #require(PaneLayoutTree.largeLeading(panes))
        let remaining = Array(panes.dropLast()).map(\.content)
        let pruned = try #require(try tree.reconciling(remaining, anchorContentID: panes[0].content.id))
        #expect(pruned == tree.removing(panes[4].id))
        let added = PaneContentReference.tab(UUID())
        let expanded = try #require(try pruned.reconciling(remaining + [added], anchorContentID: panes[0].content.id))
        #expect(expanded.contentIDs.contains(added.id))
        #expect(Set(pruned.panes.map(\.id)).isSubset(of: Set(expanded.panes.map(\.id))))
        if case .split(let id, let axis, let ratio, _, _) = tree,
           case .split(let nextID, let nextAxis, let nextRatio, _, _) = expanded {
            #expect(id == nextID); #expect(axis == nextAxis); #expect(ratio == nextRatio)
        }
    }

    @Test func minimumClampsAppliedRatiosWithoutRewritingPreferredRatios() throws {
        let tree = try #require(PaneLayoutTree.largeLeading(leaves(5)))
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        let geometry = tree.geometry(in: bounds)
        #expect(geometry.panes.values.allSatisfy { $0.width >= 240 && $0.height >= 160 })
        #expect(geometry.panes.values.reduce(0) { $0 + $1.width * $1.height } == bounds.width * bounds.height)
        if case .split(_, _, let preferred, _, _) = tree { #expect(preferred == 0.55) }
        #expect(geometry.dividers.first?.ratio == 0.4)
        let large = tree.geometry(in: CGRect(x: 0, y: 0, width: 1600, height: 900))
        #expect(large.dividers.first?.ratio == 0.55)
    }

    @Test func compactProjectionKeepsProtectedAndPreferredTreeUnchanged() throws {
        let panes = leaves(5), tree = try #require(PaneLayoutTree.largeLeading(panes))
        let saved = tree
        let compact = tree.compactProjection(in: CGSize(width: 500, height: 400), protecting: [panes[0].content.id], focused: panes[3].content.id)
        #expect(compact.contentIDs.contains(panes[0].content.id))
        #expect(compact.contentIDs.contains(panes[3].content.id))
        #expect(compact.panes.count == 2)
        #expect(tree == saved)
        #expect(tree.compactProjection(in: CGSize(width: 1600, height: 900), protecting: [], focused: nil) == tree)
    }

    @Test func spatialNeighborsNeverWrapAndResolveAsymmetricTiesByReadingOrder() throws {
        let panes = leaves(5), tree = try #require(PaneLayoutTree.largeLeading(panes))
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        #expect(tree.neighbor(of: panes[0].id, toward: .left, in: bounds) == nil)
        #expect(tree.neighbor(of: panes[0].id, toward: .right, in: bounds) == panes[1].id)
        #expect(tree.neighbor(of: panes[1].id, toward: .right, in: bounds) == panes[2].id)
        #expect(tree.neighbor(of: panes[1].id, toward: .below, in: bounds) == panes[3].id)
        #expect(tree.neighbor(of: panes[3].id, toward: .above, in: bounds) == panes[1].id)
        #expect(tree.neighbor(of: panes[4].id, toward: .below, in: bounds) == nil)
        #expect(tree.neighbor(of: panes[4].id, toward: .left, in: bounds) == panes[3].id)
    }

    @Test func malformedDuplicatesRatiosAndOversizedTreesAreRejected() throws {
        let pane = leaves(1)[0]
        let duplicate = PaneLayoutTree.split(id: UUID(), axis: .x, ratio: 0.5, first: .pane(pane), second: .pane(pane))
        #expect(throws: PaneLayoutError.invalidTree) { try duplicate.validated() }
        for ratio in [0.0, 1.0, Double.nan, Double.infinity] {
            let tree = PaneLayoutTree.split(id: UUID(), axis: .x, ratio: ratio, first: .pane(pane), second: .pane(leaves(1)[0]))
            #expect(throws: PaneLayoutError.invalidTree) { try tree.validated() }
        }
        let large = try #require(PaneLayoutTree.columns(leaves(33)))
        #expect(throws: PaneLayoutError.invalidTree) { try large.validated() }
        #expect(try #require(PaneLayoutTree.columns(leaves(32))).validated().panes.count == 32)
    }

    @Test func meetingClassificationDoesNotDependOnUserMemoryPinPreferences() {
        for address in ["https://meet.google.com/abc-defg-hij", "https://zoom.us/j/123", "https://us02web.zoom.us/j/123", "https://teams.microsoft.com/l/meetup-join/123"] {
            let url = URL(string: address)!
            #expect(LayoutStarterURLPolicy.isMeeting(url))
            #expect(LayoutStarterURLPolicy.safeStarter(url) == nil)
        }
        #expect(!LayoutStarterURLPolicy.isMeeting(URL(string: "https://zoom.us.evil.example/j/123")))
        #expect(!LayoutStarterURLPolicy.isMeeting(URL(string: "https://notzoom.us/j/123")))
    }

    @Test func secretAndAuthenticationURLsAreOmittedInsteadOfRewritten() {
        for address in ["https://example.com/doc?token=secret", "https://example.com/doc#private", "https://person:secret@example.com/doc", "https://example.com/oauth/callback", "file:///tmp/private", "https://example.com/download/signed"] {
            #expect(LayoutStarterURLPolicy.safeStarter(URL(string: address)) == nil)
        }
        #expect(LayoutStarterURLPolicy.safeStarter(URL(string: "https://example.com/document/ordinary")) != nil)
    }

    @Test func recipeStoreRetainsVersionsAndRejectsStaleUpdatesAndDoesNotWriteURLsForManualSlots() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalLayoutRecipeStore(url: folder.appendingPathComponent("recipes.json"))
        let pane = leaves(1)[0]
        var recipe = LocalLayoutRecipe(name: "Review", tree: .pane(pane), slots: [LayoutRecipeSlot(id: pane.content.id, restore: .chooseCurrentMeeting)])
        let first = try store.save(recipe, expectedRevision: nil)
        recipe.name = "Review updated"
        let second = try store.save(recipe, expectedRevision: first.revision)
        #expect(second.revision == 2)
        #expect(throws: PaneLayoutError.stalePreview) { try store.save(recipe, expectedRevision: 1) }
        #expect(try store.previousVersions(of: recipe.id).last == first)
        #expect(try store.recipes() == [second])
        #expect(FileManager.default.fileExists(atPath: store.url.appendingPathExtension("previous").path))
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!text.contains("https"))
        try store.delete(recipe.id, expectedRevision: second.revision)
        #expect(try store.recipes().isEmpty)
    }

    @Test func updateDiffIgnoresSplitBookkeepingAndTimestamps() throws {
        let panes = leaves(2)
        let tree = try #require(PaneLayoutTree.columns(panes))
        let before = LocalLayoutRecipe(name: "Review", tree: tree,
                                       slots: panes.map { LayoutRecipeSlot(id: $0.content.id, restore: .empty) })
        var proposed = before
        proposed.tree = try #require(PaneLayoutTree.columns(panes))
        proposed.updatedAt = before.updatedAt.addingTimeInterval(600)
        let diff = try LocalLayoutRecipeUpdateDiff(before: before, proposed: proposed)
        #expect(diff.isEmpty)
        #expect(diff.beforeRevision == 1)
        #expect(diff.proposedRevision == 2)
    }

    @Test func updateDiffShowsTopologyAndPreferredRatiosBeforeAndAfter() throws {
        let panes = leaves(2), tree = try #require(PaneLayoutTree.columns(panes))
        let before = LocalLayoutRecipe(name: "Review", tree: tree,
                                       slots: panes.map { LayoutRecipeSlot(id: $0.content.id, restore: .empty) })
        var proposed = before
        proposed.tree = .split(id: UUID(), axis: .y, ratio: 0.65, first: .pane(panes[0]), second: .pane(panes[1]))
        let diff = try LocalLayoutRecipeUpdateDiff(before: before, proposed: proposed)
        let topology = try #require(diff.changes.first { $0.kind == .topology })
        #expect(topology.before.contains("Left / right"))
        #expect(topology.after.contains("Top / bottom"))
        let ratio = try #require(diff.changes.first { $0.kind == .dividerRatios })
        #expect(ratio.before.contains("50%"))
        #expect(ratio.after.contains("65%"))
        #expect(diff.changes.filter { $0.kind == .position }.count == 2)
        #expect(!diff.changes.contains { $0.kind == .addedContent || $0.kind == .removedContent })
        proposed.tree = tree.settingRatio(nodeID: tree.geometry(in: CGRect(x: 0, y: 0, width: 800, height: 400)).dividers[0].id, ratio: 0.5000000000001)
        let tiny = try LocalLayoutRecipeUpdateDiff(before: before, proposed: proposed)
        let tinyRatio = try #require(tiny.changes.first { $0.kind == .dividerRatios })
        #expect(tinyRatio.before != tinyRatio.after)
    }

    @Test func updateDiffTreatsSameURLContentSwapAsPositionsNotDeletionOrRestoreChanges() throws {
        let panes = leaves(2), tree = try #require(PaneLayoutTree.columns(panes))
        let sameURL = URL(string: "https://example.com/document")!
        let before = LocalLayoutRecipe(name: "Review", tree: tree,
                                       slots: panes.map { LayoutRecipeSlot(id: $0.content.id, restore: .safeStarter(sameURL)) })
        var proposed = before
        proposed.tree = try tree.placing(panes[0].content, at: panes[1].id, edge: .center)
        let diff = try LocalLayoutRecipeUpdateDiff(before: before, proposed: proposed)
        #expect(diff.changes.count == 2)
        #expect(diff.changes.allSatisfy { $0.kind == .position })
        #expect(Set(diff.changes.map(\.id)).count == diff.changes.count)
    }

    @Test func updateDiffShowsExactStarterProfileAndFocusChanges() throws {
        let panes = leaves(2), tree = try #require(PaneLayoutTree.columns(panes))
        let oldURL = URL(string: "https://example.com/old")!, newURL = URL(string: "https://example.com/new")!
        let before = LocalLayoutRecipe(name: "Review", tree: tree,
                                       slots: panes.map { LayoutRecipeSlot(id: $0.content.id, restore: .safeStarter(oldURL)) },
                                       focusedContentID: panes[0].content.id)
        var proposed = before
        let profileID = UUID()
        proposed.slots[0].restore = .safeStarter(newURL)
        proposed.slots[0].profileID = profileID
        proposed.focusedContentID = panes[1].content.id
        let diff = try LocalLayoutRecipeUpdateDiff(before: before, proposed: proposed)
        #expect(Set(diff.changes.map(\.kind)) == [.restoreReference, .profile, .focus])
        let reference = try #require(diff.changes.first { $0.kind == .restoreReference })
        #expect(reference.before.contains(oldURL.absoluteString))
        #expect(reference.after.contains(newURL.absoluteString))
        let profile = try #require(diff.changes.first { $0.kind == .profile })
        #expect(profile.before == "Normal profile")
        #expect(profile.after.contains(profileID.uuidString))
    }

    @Test func updateDiffDistinguishesAddedRemovedAndChangedDocumentReferences() throws {
        let panes = [LayoutPane(content: .document(UUID())), LayoutPane(content: .tab(UUID())), LayoutPane(content: .tab(UUID()))]
        let tree = try #require(PaneLayoutTree.columns(panes))
        let oldDocumentID = UUID(), newDocumentID = UUID()
        let before = LocalLayoutRecipe(name: "Review", tree: tree, slots: [
            LayoutRecipeSlot(id: panes[0].content.id, restore: .document(oldDocumentID)),
            LayoutRecipeSlot(id: panes[1].content.id, restore: .chooseCurrentMeeting),
            LayoutRecipeSlot(id: panes[2].content.id, restore: .empty)
        ])
        var proposed = before
        let pruned = try #require(tree.removing(panes[1].id))
        let newSlotID = UUID()
        proposed.tree = try pruned.placing(.tab(newSlotID), at: panes[0].id, edge: .below)
        proposed.slots.remove(at: 1)
        proposed.slots[0].restore = .document(newDocumentID)
        proposed.slots.append(LayoutRecipeSlot(id: newSlotID, restore: .empty))
        let diff = try LocalLayoutRecipeUpdateDiff(before: before, proposed: proposed)
        #expect(diff.changes.filter { $0.kind == .removedContent }.count == 1)
        #expect(diff.changes.filter { $0.kind == .addedContent }.count == 1)
        let reference = try #require(diff.changes.first { $0.kind == .restoreReference })
        #expect(reference.before.contains(oldDocumentID.uuidString))
        #expect(reference.after.contains(newDocumentID.uuidString))
        let removed = try #require(diff.changes.first { $0.kind == .removedContent })
        #expect(removed.before.contains("Manual meeting slot"))
        #expect(removed.after.contains("live content stays open"))
    }

    @Test func updateDiffRejectsUnsafeOrStaleSnapshotsBeforeRenderingReferences() throws {
        let pane = leaves(1)[0]
        let before = LocalLayoutRecipe(name: "Review", tree: .pane(pane), slots: [LayoutRecipeSlot(id: pane.content.id, restore: .empty)])
        var proposed = before
        proposed.slots[0].restore = .safeStarter(URL(string: "https://example.com/doc?token=secret")!)
        #expect(throws: PaneLayoutError.invalidTree) { try LocalLayoutRecipeUpdateDiff(before: before, proposed: proposed) }
        proposed = before
        proposed.revision += 1
        #expect(throws: PaneLayoutError.stalePreview) { try LocalLayoutRecipeUpdateDiff(before: before, proposed: proposed) }
        proposed = before
        proposed.id = UUID()
        #expect(throws: PaneLayoutError.invalidTree) { try LocalLayoutRecipeUpdateDiff(before: before, proposed: proposed) }
    }

    @Test func rolloutDefaultsOffAndNeverSelectsRecursiveRendererOrExpandedAdmissionBeforeEnable() {
        #expect(!PaneLayoutRolloutPolicy.isEnabled(storedValue: nil))
        #expect(!PaneLayoutRolloutPolicy.isEnabled(storedValue: false))
        #expect(PaneLayoutRolloutPolicy.isEnabled(storedValue: true))
        #expect(PaneLayoutRolloutPolicy.newMembershipLimit(enabled: false) == 4)
        #expect(PaneLayoutRolloutPolicy.newMembershipLimit(enabled: true) == 8)
        #expect(PaneLayoutRolloutPolicy.renderingMode(enabled: false, hasTree: true, memberCount: 4) == .legacyGrid)
        #expect(PaneLayoutRolloutPolicy.renderingMode(enabled: false, hasTree: true, memberCount: 8) == .legacyColumns)
        #expect(PaneLayoutRolloutPolicy.renderingMode(enabled: true, hasTree: true, memberCount: 8) == .recursive)
        #expect(PaneLayoutRolloutPolicy.renderingMode(enabled: false, hasTree: true, memberCount: 1) == .single)
    }

    @Test func retainedTreeRequiresUnchangedTypedMembershipOrderWorkspaceAndEnable() {
        let members = [PaneContentReference.tab(UUID()), .document(UUID())], workspace = UUID()
        #expect(PaneLayoutRolloutPolicy.canRestoreRetainedTree(enabled: true, retainedMembers: members, currentMembers: members, retainedWorkspaceID: workspace, currentWorkspaceID: workspace))
        #expect(!PaneLayoutRolloutPolicy.canRestoreRetainedTree(enabled: false, retainedMembers: members, currentMembers: members, retainedWorkspaceID: workspace, currentWorkspaceID: workspace))
        #expect(!PaneLayoutRolloutPolicy.canRestoreRetainedTree(enabled: true, retainedMembers: members, currentMembers: Array(members.reversed()), retainedWorkspaceID: workspace, currentWorkspaceID: workspace))
        #expect(!PaneLayoutRolloutPolicy.canRestoreRetainedTree(enabled: true, retainedMembers: members, currentMembers: [.tab(members[0].id), .tab(members[1].id)], retainedWorkspaceID: workspace, currentWorkspaceID: workspace))
        #expect(!PaneLayoutRolloutPolicy.canRestoreRetainedTree(enabled: true, retainedMembers: members, currentMembers: members, retainedWorkspaceID: workspace, currentWorkspaceID: UUID()))
    }

    @Test func storeRejectsPromotingStaleReviewedDraftToNewerExpectedRevisionAndRejectsOverflow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalLayoutRecipeStore(url: folder.appendingPathComponent("recipes.json"))
        let pane = leaves(1)[0]
        var original = LocalLayoutRecipe(name: "Review", tree: .pane(pane), slots: [LayoutRecipeSlot(id: pane.content.id, restore: .empty)])
        original = try store.save(original, expectedRevision: nil)
        var intervening = original
        intervening.name = "Intervening restore"
        intervening = try store.save(intervening, expectedRevision: original.revision)
        var staleDraft = original
        staleDraft.name = "Old reviewed change"
        #expect(throws: PaneLayoutError.stalePreview) { try store.save(staleDraft, expectedRevision: intervening.revision) }
        #expect(try store.recipes() == [intervening])
        var exhausted = original
        exhausted.id = UUID(); exhausted.revision = Int.max
        exhausted = try store.save(exhausted, expectedRevision: nil)
        #expect(throws: PaneLayoutError.invalidTree) { try store.save(exhausted, expectedRevision: Int.max) }
        #expect(try store.recipes().contains(exhausted))
    }
}

@MainActor
struct PaneLayoutTransactionTests {
    private func enabledManager(windowID: UUID = UUID()) -> TabManager {
        let defaults = UserDefaults(suiteName: "pane-layout-enabled-tests-" + UUID().uuidString)!
        defaults.set(true, forKey: PaneLayoutRolloutPolicy.defaultsKey)
        return TabManager(windowID: windowID, paneLayoutDefaults: defaults)
    }

    #if os(macOS)
    @Test func nilNativeLoadClearsCoordinatorDedupAndFadeBeforeOrdinaryManualRecovery() {
        let views = WebViewManager(), manager = enabledManager()
        manager.setWebViewManager(views)
        let page = URL(string: "https://example.com/page")!, tab = manager.createNewTab()
        let parent = WebView(url: .constant(page), canGoBack: .constant(false), canGoForward: .constant(false),
                             title: .constant(""), isLoading: .constant(false), progressValue: .constant(0), hasRenderedContent: .constant(false),
                             webViewManager: views, tabManager: manager, tabs: [tab], activeTabId: tab.id, onURLChange: nil)
        let coordinator = parent.makeCoordinator(), engine = views.getWebView(for: tab.id)
        views.setActiveTab(tab.id)
        coordinator.beginLoad(page, in: engine)
        coordinator.lastRequestedURL = page
        views.preparePageFade(engine, targetURL: page)
        coordinator.coldStarterLoadDidNotStart(in: engine, requestedURL: page)
        #expect(coordinator.loadInFlight(for: engine) == nil)
        #expect(coordinator.lastRequestedURL == nil)
        #expect(engine.alphaValue == 1)
        #expect(WebViewLoadDecision.shouldLoad(target: page, showing: nil, requested: coordinator.lastRequestedURL,
                                             inFlight: coordinator.loadInFlight(for: engine), isLoading: false))
    }
    #endif

    @Test func rolloutOffPreservesLegacyFourPaneLimitAndBlocksAllNewMutationPaths() throws {
        let defaults = UserDefaults(suiteName: "pane-layout-off-tests-" + UUID().uuidString)!
        defaults.set(true, forKey: "paneArrangementsEnabled") // Old editor toggle grants no rollout.
        let manager = TabManager(windowID: UUID(), paneLayoutDefaults: defaults)
        let tabs = (0..<6).map { _ in manager.createNewTab() }
        manager.selectedTabId = tabs[0].id
        for tab in tabs.dropFirst() { manager.toggleSplitMembership(tab, tabs: tabs) }
        #expect(!manager.paneLayoutsEnabled)
        #expect(manager.splitTabIds.count == 4)
        #expect(manager.paneLayout == nil)
        let before = try #require(manager.currentPaneLayout())
        let candidate = try #require(PaneLayoutTree.columns(before.panes, axis: .y))
        let preview = try manager.previewPaneTree(candidate, summary: "Read-only preview", tabs: tabs)
        #expect(throws: PaneLayoutError.rolloutDisabled) { try manager.applyPaneLayout(preview, tabs: tabs) }
        #expect(throws: PaneLayoutError.rolloutDisabled) { try manager.undoPaneLayout(tabs: tabs) }
        #expect(throws: PaneLayoutError.rolloutDisabled) { try manager.togglePaneMaximize(tabs[0].id, tabs: tabs) }
        #expect(manager.currentPaneLayout() == before)
        #expect(manager.closedTabs.isEmpty)
    }

    @Test func rolloutRevocationRetainsEveryLiveTabAndRestoresTreeOnlyWithUnchangedMembership() throws {
        let defaults = UserDefaults(suiteName: "pane-layout-revocation-tests-" + UUID().uuidString)!
        defaults.set(true, forKey: PaneLayoutRolloutPolicy.defaultsKey)
        let views = WebViewManager(), windowID = UUID()
        let manager = TabManager(windowID: windowID, webViewManager: views, paneLayoutDefaults: defaults)
        let tabs = (0..<6).map { _ in manager.createNewTab() }
        tabs[0].url = URL(string: "https://meet.google.com/a-b-c")
        manager.selectedTabId = tabs[0].id
        for tab in tabs[1...4] { manager.toggleSplitMembership(tab, tabs: tabs) }
        let initial = try #require(manager.currentPaneLayout())
        let recursive = try #require(PaneLayoutTree.largeLeading(initial.panes))
        _ = try manager.applyPaneLayout(manager.previewPaneTree(recursive, summary: "Five panes", tabs: tabs), tabs: tabs)
        let cachedViews = tabs.prefix(5).map { views.getWebView(for: $0.id) }
        let lateDrag = try manager.previewPaneTree(recursive.settingRatio(nodeID: recursive.geometry(in: CGRect(x: 0, y: 0, width: 1600, height: 900)).dividers[0].id, ratio: 0.6), summary: "Pending resize", tabs: tabs, action: .resize)
        let membership = manager.splitTabIds, focused = manager.selectedTabId
        let key = "paneLayoutRecovery.v1." + windowID.uuidString
        let recovery = UserDefaults.standard.data(forKey: key)
        manager.setPaneLayoutsEnabled(false)
        #expect(manager.splitTabIds == membership)
        #expect(manager.selectedTabId == focused)
        #expect(manager.paneLayout == recursive)
        #expect(!manager.canUndoPaneLayout)
        #expect(throws: PaneLayoutError.rolloutDisabled) { try manager.applyPaneLayout(lateDrag, tabs: tabs) }
        manager.toggleSplitMembership(tabs[5], tabs: tabs)
        #expect(manager.splitTabIds == membership)
        #expect(UserDefaults.standard.data(forKey: key) == recovery)
        for (tab, cached) in zip(tabs.prefix(5), cachedViews) { #expect(views.existingWebView(for: tab.id) === cached) }
        manager.setPaneLayoutsEnabled(true)
        #expect(manager.currentPaneLayout() == recursive)
        manager.setPaneLayoutsEnabled(false)
        manager.toggleSplitMembership(tabs[4], tabs: tabs)
        #expect(manager.splitTabIds.count == 4)
        #expect(UserDefaults.standard.data(forKey: key) == recovery)
        manager.setPaneLayoutsEnabled(true)
        #expect(!manager.splitTabIds.contains(tabs[4].id))
        #expect(manager.currentPaneLayout()?.panes.count == 4)
        #expect(manager.closedTabs.isEmpty)
        for (tab, cached) in zip(tabs.prefix(5), cachedViews) { #expect(views.existingWebView(for: tab.id) === cached) }
    }

    @Test func rolloutOffRecoveryDoesNotMigrateOrRewriteAndEnableRestoresRetainedRecord() throws {
        let windowID = UUID(), enabled = enabledManager(windowID: windowID)
        let tabs = (0..<5).map { _ in enabled.createNewTab() }
        enabled.selectedTabId = tabs[0].id
        for tab in tabs.dropFirst() { enabled.toggleSplitMembership(tab, tabs: tabs) }
        let initial = try #require(enabled.currentPaneLayout())
        let tree = try #require(PaneLayoutTree.largeLeading(initial.panes))
        _ = try enabled.applyPaneLayout(enabled.previewPaneTree(tree, summary: "Saved recovery", tabs: tabs), tabs: tabs)
        let key = "paneLayoutRecovery.v1." + windowID.uuidString
        let data = UserDefaults.standard.data(forKey: key)
        let defaults = UserDefaults(suiteName: "pane-layout-disabled-recovery-" + UUID().uuidString)!
        let off = TabManager(windowID: windowID, paneLayoutDefaults: defaults)
        off.restoreSplit(from: tabs)
        #expect(off.splitTabIds == tree.contentIDs)
        #expect(off.paneLayout == nil)
        #expect(UserDefaults.standard.data(forKey: key) == data)
        off.setPaneLayoutsEnabled(true)
        #expect(off.currentPaneLayout() == tree)
    }

    @Test func rolloutEnableRetainsUnknownOrCorruptRecoveryThroughLaterMutations() throws {
        for retainingLiveTree in [false, true] {
        for bytes in [Data("invalid recovery".utf8), Data("{\"schemaVersion\":2,\"futureData\":\"retain\"}".utf8)] {
            let windowID = UUID(), defaults = UserDefaults(suiteName: "pane-rejected-recovery-" + UUID().uuidString)!
            let manager = TabManager(windowID: windowID, paneLayoutDefaults: defaults)
            let a = manager.createNewTab(), b = manager.createNewTab(), c = manager.createNewTab()
            manager.selectedTabId = a.id
            manager.toggleSplitMembership(b, tabs: [a, b, c])
            if retainingLiveTree { manager.setPaneLayoutsEnabled(true); manager.setPaneLayoutsEnabled(false) }
            let key = "paneLayoutRecovery.v1." + windowID.uuidString
            UserDefaults.standard.set(bytes, forKey: key)
            manager.setPaneLayoutsEnabled(true)
            #expect(manager.currentPaneLayout()?.contentIDs == [a.id, b.id])
            manager.selectedTabId = b.id
            manager.toggleSplitMembership(c, tabs: [a, b, c])
            #expect(UserDefaults.standard.data(forKey: key) == bytes)
            UserDefaults.standard.removeObject(forKey: key)
        }
        }
    }

    @Test func actualEngineDisposalReleasesOnlyItsPermitAndSuccessfulStarterRestoresNormally() throws {
        let defaults = UserDefaults(suiteName: "pane-disposal-test-" + UUID().uuidString)!
        defaults.set(true, forKey: PaneLayoutRolloutPolicy.defaultsKey)
        let views = WebViewManager(), manager = TabManager(windowID: UUID(), webViewManager: views, paneLayoutDefaults: defaults)
        let tabs = (0..<3).map { _ in manager.createNewTab(url: URL(string: "https://example.com/page")) }
        let scheduler = manager.coldLayoutStarters
        scheduler.register(starters: tabs.map { .init(tabID: $0.id, startingURL: $0.url) }, workspaceID: nil, layoutRevision: 0, gateEnabled: true)
        let first = try #require(scheduler.reserveNext(visibleTabIDs: Set(tabs.map(\.id)), focusedTabID: tabs[0].id, workspaceID: nil, layoutRevision: 0, gateEnabled: true))
        let second = try #require(scheduler.reserveNext(visibleTabIDs: Set(tabs.map(\.id)), focusedTabID: tabs[1].id, workspaceID: nil, layoutRevision: 0, gateEnabled: true))
        _ = views.getWebView(for: tabs[0].id); _ = views.getWebView(for: tabs[1].id)
        try manager.loadDeferredLayoutStarter(tabs[2].id, tabs: tabs)
        #expect(manager.shouldDeferColdLayoutStarter(tabs[2].id))
        #expect(scheduler.pendingTabIDs == [tabs[2].id])
        #expect(scheduler.inFlightCount == 2)
        scheduler.cancelPending(reason: .undo)
        try manager.loadDeferredLayoutStarter(tabs[2].id, tabs: tabs)
        #expect(manager.shouldDeferColdLayoutStarter(tabs[2].id))
        #expect(scheduler.inFlightCount == 2)
        #expect(scheduler.reserveNext(visibleTabIDs: Set(tabs.map(\.id)), focusedTabID: tabs[2].id, workspaceID: nil, layoutRevision: manager.paneLayoutRevision, gateEnabled: true) == nil)
        views.removeWebView(for: tabs[0].id, notifyClosed: false)
        #expect(scheduler.inFlightCount == 1)
        #expect(scheduler.activePermit(for: tabs[1].id)?.token == second.token)
        #expect(scheduler.isDeferred(tabs[0].id))
        #expect(!scheduler.terminal(first.token))
        #expect(scheduler.terminal(second.token, outcome: .finished))
        views.removeWebView(for: tabs[1].id, notifyClosed: false)
        #expect(!manager.shouldDeferColdLayoutStarter(tabs[1].id))
        views.removeWebView(for: tabs[0].id, notifyClosed: true)
        #expect(!manager.shouldDeferColdLayoutStarter(tabs[0].id))
        #expect(scheduler.isDeferred(tabs[2].id))
        try manager.loadDeferredLayoutStarter(tabs[2].id, tabs: tabs)
        #expect(manager.shouldDeferColdLayoutStarter(tabs[2].id))
        #expect(scheduler.pendingTabIDs == [tabs[2].id])
        #expect(manager.selectedTabId == tabs[2].id)
    }
    @Test func maximizeRestoreKeepsPreferredTreeAndFocusAndCannotHideProtectedCall() throws {
        let manager = enabledManager()
        let a = manager.createNewTab(), b = manager.createNewTab()
        manager.selectedTabId = a.id
        manager.toggleSplitMembership(b, tabs: [a, b])
        let before = try #require(manager.currentPaneLayout())
        manager.selectedTabId = a.id
        try manager.togglePaneMaximize(b.id, tabs: [a, b])
        #expect(manager.maximizedPaneContentID == b.id)
        #expect(manager.selectedTabId == b.id)
        #expect(manager.currentPaneLayout() == before)
        try manager.togglePaneMaximize(b.id, tabs: [a, b])
        #expect(manager.maximizedPaneContentID == nil)
        #expect(manager.selectedTabId == a.id)
        #expect(manager.currentPaneLayout() == before)
        a.url = URL(string: "https://meet.google.com/a-b-c")
        #expect(throws: PaneLayoutError.protectedPane) { try manager.togglePaneMaximize(b.id, tabs: [a, b]) }
    }

    @Test func recipesSerializeConfigurationSlotsAndColdPreviewNeverMatchesByURL() throws {
        let manager = enabledManager()
        let ordinary = manager.createNewTab(url: URL(string: "https://example.com/document"))
        let meeting = manager.createNewTab(url: URL(string: "https://us02web.zoom.us/j/123"))
        ordinary.title = "Sensitive website title"
        manager.selectedTabId = ordinary.id
        manager.toggleSplitMembership(meeting, tabs: [ordinary, meeting])
        let recipe = try manager.makeLayoutRecipe(named: "Review", tabs: [ordinary, meeting])
        let encoded = try String(decoding: JSONEncoder().encode(recipe), as: UTF8.self)
        #expect(!encoded.contains(ordinary.id.uuidString))
        #expect(!encoded.contains(meeting.id.uuidString))
        #expect(!encoded.contains("Sensitive website title"))
        #expect(!encoded.contains("zoom.us"))
        #expect(recipe.slots.contains { if case .chooseCurrentMeeting = $0.restore { true } else { false } })
        let cold = enabledManager()
        let sameURL = cold.createNewTab(url: ordinary.url)
        let preview = try cold.previewLayoutRecipe(recipe, tabs: [sameURL])
        #expect(preview.newTabs.count == 2)
        #expect(preview.newTabs.filter { $0.startingURL != nil }.count == 1)
        #expect(!preview.tree.contentIDs.contains(sameURL.id))
        #expect(cold.currentPaneLayout()?.contentIDs == [sameURL.id])
    }

    @Test func versionedRecoveryRestoresExactTreeAndRatios() throws {
        let windowID = UUID(), manager = enabledManager(windowID: windowID)
        defer {
            for key in ["splitTabIds", "paneLayoutRecovery.v1", "selectedTabId"] {
                UserDefaults.standard.removeObject(forKey: key + "." + windowID.uuidString)
            }
        }
        let tabs = (0..<5).map { _ in manager.createNewTab() }
        manager.selectedTabId = tabs[0].id
        for tab in tabs.dropFirst() { manager.toggleSplitMembership(tab, tabs: tabs) }
        let initialTree = try #require(manager.currentPaneLayout())
        let tree = try #require(PaneLayoutTree.largeLeading(initialTree.panes))
        _ = try manager.applyPaneLayout(manager.previewPaneTree(tree, summary: "Five panes", tabs: tabs), tabs: tabs)
        manager.toggleSplitMembership(tabs[4], tabs: tabs)
        let pruned = try #require(manager.currentPaneLayout())
        let removedPane = try #require(tree.panes.first { $0.content.id == tabs[4].id })
        #expect(pruned == tree.removing(removedPane.id))
        let restored = enabledManager(windowID: windowID)
        restored.restoreSplit(from: tabs)
        #expect(restored.currentPaneLayout() == pruned)
        #expect(restored.splitTabIds == pruned.contentIDs)
        let corrupt = Data("invalid recovery".utf8)
        UserDefaults.standard.set(corrupt, forKey: "paneLayoutRecovery.v1." + windowID.uuidString)
        let fallback = enabledManager(windowID: windowID)
        fallback.restoreSplit(from: tabs)
        #expect(fallback.currentPaneLayout()?.panes.count == 4)
        #expect(UserDefaults.standard.data(forKey: "paneLayoutRecovery.v1." + windowID.uuidString) == corrupt)
    }

    @Test func newBlankSplitCreatesNothingDuringPreviewAndUndoKeepsItsTabOpen() throws {
        let manager = enabledManager()
        let existing = manager.createIncognitoTab()
        let before = try #require(manager.currentPaneLayout())
        let preview = try manager.previewNewBlankPane(targetPaneID: before.panes[0].id, edge: .right, tabs: [existing])
        #expect(manager.incognitoTabs.count == 1)
        #expect(manager.currentPaneLayout() == before)
        #expect(preview.newTabs.count == 1)
        #expect(preview.newTabs.first?.isPrivate == true)
        #expect(try manager.applyPaneLayout(preview, tabs: [existing]))
        #expect(manager.incognitoTabs.count == 2)
        let created = manager.incognitoTabs[1]
        #expect(created.sessionId == existing.sessionId)
        #expect(created.url == nil)
        try manager.undoPaneLayout(tabs: manager.incognitoTabs)
        #expect(manager.currentPaneLayout() == before)
        #expect(manager.incognitoTabs.count == 2)
        #expect(manager.incognitoTabs[1] === created)
        #expect(manager.closedTabs.isEmpty)
    }

    @Test func previewCancelStaleApplyAndUndoPreserveExactExistingObjects() throws {
        let manager = enabledManager()
        let a = manager.createIncognitoTab(), b = manager.createIncognitoTab(sessionId: nil)
        // Use one private session; placement never moves between stores.
        b.sessionId = a.sessionId
        manager.selectedTabId = a.id
        manager.toggleSplitMembership(b, tabs: [a, b])
        let before = try #require(manager.currentPaneLayout())
        let preview = try manager.previewPanePlacement(source: .tab(a.id), targetPaneID: before.panes[1].id, edge: .center, tabs: [a, b])
        #expect(manager.currentPaneLayout() == before)
        #expect(manager.closedTabs.isEmpty)
        #expect(try manager.applyPaneLayout(preview, tabs: [a, b]))
        #expect(manager.splitTabIds == [b.id, a.id])
        #expect(throws: PaneLayoutError.stalePreview) { try manager.applyPaneLayout(preview, tabs: [a, b]) }
        try manager.undoPaneLayout(tabs: [a, b])
        #expect(manager.currentPaneLayout() == before)
        #expect(manager.incognitoTabs[0] === a)
        #expect(manager.incognitoTabs[1] === b)
        #expect(manager.closedTabs.isEmpty)
        #expect(throws: PaneLayoutError.privateLayout) { try manager.makeLayoutRecipe(named: "Private", tabs: [a, b]) }
    }

    @Test func protectedHiddenReplacementIsRejectedAndOrdinaryOutsideSelectionStillDissolvesSplit() throws {
        let manager = enabledManager()
        let a = manager.createNewTab(url: URL(string: "https://meet.google.com/a-b-c")), b = manager.createNewTab(), c = manager.createNewTab()
        manager.selectedTabId = a.id; manager.toggleSplitMembership(b, tabs: [a, b, c])
        let tree = try #require(manager.currentPaneLayout())
        #expect(throws: PaneLayoutError.protectedPane) { try manager.previewPanePlacement(source: .tab(c.id), targetPaneID: tree.panes[0].id, edge: .center, tabs: [a, b, c]) }
        manager.selectedTabId = c.id
        #expect(manager.splitTabIds.isEmpty)
    }
}
