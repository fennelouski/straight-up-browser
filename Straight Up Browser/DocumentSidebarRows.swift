//
//  DocumentSidebarRows.swift
//  Straight Up Browser
//
//  Workspace document rows in the Mac sidebar (Phase 2, design §1.2). Documents
//  are full peers: click displays one solo, shift-click toggles Split
//  membership, exactly like tabs. They live in their own block above the tab
//  list — a deliberate deviation from full orderIndex interleaving, recorded in
//  docs/phase2-design.md: "sidebar order = pane order" holds within each kind.
//

#if os(macOS)

import SwiftUI
import SwiftData

struct WorkspaceDocumentSidebarRows: View {
    let workspaceId: UUID
    @ObservedObject var documentStore: DocumentStore
    @ObservedObject var tabManager: TabManager
    let iconOnly: Bool

    @Query private var documents: [WorkspaceDocument]
    @State private var renamingId: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    init(workspaceId: UUID, documentStore: DocumentStore, tabManager: TabManager, iconOnly: Bool) {
        self.workspaceId = workspaceId
        self.documentStore = documentStore
        self.tabManager = tabManager
        self.iconOnly = iconOnly
        _documents = Query(
            filter: #Predicate<WorkspaceDocument> { $0.workspaceId == workspaceId },
            sort: [SortDescriptor(\.orderIndex), SortDescriptor(\.createdAt)]
        )
    }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(documents) { document in
                row(for: document)
            }
            newDocumentRow
        }
        .padding(.bottom, 4)
    }

    private func row(for document: WorkspaceDocument) -> some View {
        let isFocused = tabManager.focusedDocumentId == document.id
        let isInSplit = tabManager.splitTabIds.contains(document.id)
        let isMissing = documentStore.missingDocumentIds.contains(document.id)
        return HStack(spacing: 6) {
            Image(systemName: isMissing ? "doc.badge.ellipsis" : "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                .frame(width: 18)
            if !iconOnly {
                if renamingId == document.id {
                    TextField("", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($renameFocused)
                        .onSubmit { commitRename(document) }
                        .onExitCommand { renamingId = nil }
                } else {
                    Text(document.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(isMissing ? Color.secondary : Color.primary)
                }
                Spacer(minLength: 0)
                if isInSplit {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isFocused ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                tabManager.toggleDocumentSplitMembership(document.id)
            } else {
                tabManager.selectDocument(document.id)
            }
        }
        .contextMenu {
            Button(tabManager.splitTabIds.contains(document.id)
                   ? String(localized: "Remove from Split")
                   : String(localized: "Open in Split")) {
                tabManager.toggleDocumentSplitMembership(document.id)
            }
            Button(String(localized: "Rename…")) {
                renameText = document.displayName
                renamingId = document.id
                renameFocused = true
            }
            Divider()
            Button(String(localized: "Delete Document"), role: .destructive) {
                if tabManager.focusedDocumentId == document.id || tabManager.splitTabIds.contains(document.id) {
                    tabManager.closeDocumentPane(document.id)
                }
                documentStore.deleteDocument(document)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(document.displayName)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .accessibilityHint(String(localized: "Workspace document"))
    }

    private var newDocumentRow: some View {
        Button {
            NotificationCenter.default.post(name: .browserNewWorkspaceDocument, object: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.rectangle.portrait")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                if !iconOnly {
                    Text("New Document")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "New Document"))
    }

    private func commitRename(_ document: WorkspaceDocument) {
        defer { renamingId = nil }
        _ = documentStore.renameDocument(document, to: renameText)
    }
}

#endif
