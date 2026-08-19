//
//  UndoCloseTests.swift
//  Straight Up BrowserTests
//
//  Undo of an accidental tab close must un-write the `dismissed` disposition,
//  not merely restore the tab (SPEC's undo-close debt, closed 2026-08-20), and
//  a multi-pane ⌘W must undo as one unit. Also pins the two split-pane fixes
//  from the same sweep: a document pane takes focus when its tab neighbor
//  closes, and restoreSplit resolves document ids (ADR 0008).
//

import Testing
import SwiftData
import Foundation
@testable import Browser

@MainActor
struct UndoCloseTests {

    private func makeFixture() throws -> (ModelContainer, ModelContext, LedgerStore, TabManager) {
        let schema = Schema([
            NewspaperArticle.self, Workspace.self, WorkspaceSourceRef.self,
            WorkspaceDocument.self, LedgerAnchor.self, LedgerClaim.self,
            LedgerEdge.self, LedgerArchive.self, Tab.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let manager = TabManager(modelContext: context, terminateApplication: {})
        let store = LedgerStore(modelContext: context)
        manager.ledgerStore = store
        return (container, context, store, manager)
    }

    private func makeWorkspaceTab(_ manager: TabManager, workspace: Workspace, url: String) -> Tab {
        let tab = manager.createNewTab(url: URL(string: url))
        tab.workspaceId = workspace.id
        return tab
    }

    @Test("Reopen restores the ref's prior disposition and the tab's workspace")
    func reopenRestoresPriorDisposition() throws {
        let (_, context, store, manager) = try makeFixture()
        let workspace = Workspace(name: "Fermentation")
        context.insert(workspace)
        let url = URL(string: "https://example.com/settled")!
        let tab = makeWorkspaceTab(manager, workspace: workspace, url: url.absoluteString)
        store.recordSettle(url: url, title: "Settled", workspaceId: workspace.id)

        manager.closeTab(tab, tabs: [tab], reason: .userRejected)
        let key = SourceCanonicalizer.canonicalKey(for: url)
        #expect(store.reference(workspaceId: workspace.id, sourceKey: key)?.disposition == .dismissed)

        let reopened = try #require(manager.reopenLastClosedTab())
        #expect(reopened.workspaceId == workspace.id, "membership is permanent; reopen restores it")
        #expect(store.reference(workspaceId: workspace.id, sourceKey: key)?.disposition == .open,
                "undo must un-write the rejection, returning the prior verdict")
    }

    @Test("Reopen deletes the ref the close itself created")
    func reopenDeletesCloseCreatedRef() throws {
        let (_, context, store, manager) = try makeFixture()
        let workspace = Workspace(name: "Fermentation")
        context.insert(workspace)
        let url = URL(string: "https://example.com/never-settled")!
        let tab = makeWorkspaceTab(manager, workspace: workspace, url: url.absoluteString)

        manager.closeTab(tab, tabs: [tab], reason: .userRejected)
        let key = SourceCanonicalizer.canonicalKey(for: url)
        #expect(store.reference(workspaceId: workspace.id, sourceKey: key)?.disposition == .dismissed)

        _ = try #require(manager.reopenLastClosedTab())
        #expect(store.reference(workspaceId: workspace.id, sourceKey: key) == nil,
                "the close created this ref; undoing the close removes the record")
    }

    @Test("Undo never clobbers a verdict that moved on after the close")
    func undoLeavesNewerVerdictsAlone() throws {
        let (_, context, store, manager) = try makeFixture()
        let workspace = Workspace(name: "Fermentation")
        context.insert(workspace)
        let url = URL(string: "https://example.com/second-look")!
        let tab = makeWorkspaceTab(manager, workspace: workspace, url: url.absoluteString)

        manager.closeTab(tab, tabs: [tab], reason: .userRejected)
        // Deliberately reopening the source elsewhere already reversed the verdict.
        store.recordSettle(url: url, title: "Second look", workspaceId: workspace.id)

        _ = try #require(manager.reopenLastClosedTab())
        let key = SourceCanonicalizer.canonicalKey(for: url)
        #expect(store.reference(workspaceId: workspace.id, sourceKey: key)?.disposition == .open,
                "a ref no longer dismissed is not the close's to undo")
    }

    @Test("Housekeeping closes wrote nothing, so reopen un-writes nothing")
    func reopenAfterHousekeepingCloseWritesNothing() throws {
        let (_, context, store, manager) = try makeFixture()
        let workspace = Workspace(name: "Fermentation")
        context.insert(workspace)
        let url = URL(string: "https://example.com/settled")!
        let tab = makeWorkspaceTab(manager, workspace: workspace, url: url.absoluteString)
        store.recordSettle(url: url, title: "Settled", workspaceId: workspace.id)

        manager.closeTab(tab, tabs: [tab], reason: .housekeeping)
        _ = try #require(manager.reopenLastClosedTab())
        let key = SourceCanonicalizer.canonicalKey(for: url)
        #expect(store.reference(workspaceId: workspace.id, sourceKey: key)?.disposition == .open)
    }

    @Test("A multi-pane close reopens as one unit, un-writing every disposition")
    func multiCloseUndoesAsOneUnit() throws {
        let (_, context, store, manager) = try makeFixture()
        let workspace = Workspace(name: "Fermentation")
        context.insert(workspace)
        let urlA = URL(string: "https://example.com/a")!
        let urlB = URL(string: "https://example.com/b")!
        let tabA = makeWorkspaceTab(manager, workspace: workspace, url: urlA.absoluteString)
        let tabB = makeWorkspaceTab(manager, workspace: workspace, url: urlB.absoluteString)
        store.recordSettle(url: urlA, title: "A", workspaceId: workspace.id)
        store.recordSettle(url: urlB, title: "B", workspaceId: workspace.id)

        let saved = UserDefaults.standard.stringArray(forKey: "splitTabIds")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "splitTabIds") }
            else { UserDefaults.standard.removeObject(forKey: "splitTabIds") }
        }
        manager.splitTabIds = [tabA.id, tabB.id]
        manager.selectedTabId = tabA.id
        let stackBefore = manager.closedTabs.count
        manager.closeTabSet(tabs: [tabA, tabB])
        #expect(manager.closedTabs.count == stackBefore + 2)

        _ = try #require(manager.reopenLastClosedTab())
        #expect(manager.closedTabs.count == stackBefore, "one ⇧⌘T undoes the whole set")
        let keyA = SourceCanonicalizer.canonicalKey(for: urlA)
        let keyB = SourceCanonicalizer.canonicalKey(for: urlB)
        #expect(store.reference(workspaceId: workspace.id, sourceKey: keyA)?.disposition == .open)
        #expect(store.reference(workspaceId: workspace.id, sourceKey: keyB)?.disposition == .open)
    }

    @Test("Closing the tab pane beside a document pane focuses the document")
    func closingTabBesideDocumentFocusesDocument() throws {
        let (_, _, _, manager) = try makeFixture()
        let documentId = UUID()
        manager.isDocumentPaneId = { $0 == documentId }
        let tabA = manager.createNewTab(url: URL(string: "https://example.com/a"))
        let tabB = manager.createNewTab(url: URL(string: "https://example.com/b"))

        let saved = UserDefaults.standard.stringArray(forKey: "splitTabIds")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "splitTabIds") }
            else { UserDefaults.standard.removeObject(forKey: "splitTabIds") }
        }
        manager.splitTabIds = [tabA.id, documentId]
        manager.selectedTabId = tabA.id

        manager.closeTab(tabA, tabs: [tabA, tabB], reason: .userRejected)
        #expect(manager.splitTabIds.isEmpty)
        #expect(manager.focusedDocumentId == documentId,
                "the surviving document pane inherits focus, not a sidebar neighbor")
        #expect(manager.selectedTabId == tabB.id)
    }

    @Test("restoreSplit resolves document ids beside tab ids")
    func restoreSplitResolvesDocuments() throws {
        let (_, _, _, manager) = try makeFixture()
        let documentId = UUID()
        manager.isDocumentPaneId = { $0 == documentId }
        let tabA = manager.createNewTab(url: URL(string: "https://example.com/a"))
        let tabB = manager.createNewTab(url: URL(string: "https://example.com/b"))

        let saved = UserDefaults.standard.stringArray(forKey: "splitTabIds")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "splitTabIds") }
            else { UserDefaults.standard.removeObject(forKey: "splitTabIds") }
        }
        UserDefaults.standard.set([tabA.id.uuidString, documentId.uuidString], forKey: "splitTabIds")

        manager.selectedTabId = tabB.id
        manager.restoreSplit(from: [tabA, tabB])
        #expect(manager.splitTabIds == [tabA.id, documentId],
                "a Split containing a document pane survives relaunch (ADR 0008)")
        #expect(manager.selectedTabId == tabA.id, "selection lands on the split's tab member")
    }
}
