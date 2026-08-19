//
//  DocumentSidebarRows_iOS.swift
//  Browser (iOS/iPadOS)
//
//  Workspace document rows in the sidebar list (Phase 2). Documents live in
//  their own block above the tab rows; selecting one shows it full screen.
//

import SwiftUI
import SwiftData

struct DocumentSidebarRows_iOS: View {
    let workspaceId: UUID
    @ObservedObject var documentStore: DocumentStore
    let focusedDocumentId: UUID?
    let onSelect: (UUID) -> Void
    let onNewDocument: () -> Void
    // iPad only (ADR 0008): non-nil enables the Open in Split context action.
    let splitMembership: ((UUID) -> Bool)?
    let onToggleSplit: ((UUID) -> Void)?

    @Query private var documents: [WorkspaceDocument]
    @State private var renamingDocument: WorkspaceDocument?
    @State private var renameText = ""

    init(
        workspaceId: UUID,
        documentStore: DocumentStore,
        focusedDocumentId: UUID?,
        onSelect: @escaping (UUID) -> Void,
        onNewDocument: @escaping () -> Void,
        splitMembership: ((UUID) -> Bool)? = nil,
        onToggleSplit: ((UUID) -> Void)? = nil
    ) {
        self.workspaceId = workspaceId
        self.documentStore = documentStore
        self.focusedDocumentId = focusedDocumentId
        self.onSelect = onSelect
        self.onNewDocument = onNewDocument
        self.splitMembership = splitMembership
        self.onToggleSplit = onToggleSplit
        _documents = Query(
            filter: #Predicate<WorkspaceDocument> { $0.workspaceId == workspaceId },
            sort: [SortDescriptor(\.orderIndex), SortDescriptor(\.createdAt)]
        )
    }

    var body: some View {
        Section {
            ForEach(documents) { document in
                row(for: document)
            }
            Button(action: onNewDocument) {
                Label(String(localized: "New Document"), systemImage: "plus.rectangle.portrait")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Documents")
        }
        .alert(String(localized: "Rename Document"), isPresented: Binding(
            get: { renamingDocument != nil },
            set: { if !$0 { renamingDocument = nil } }
        )) {
            TextField(String(localized: "Name"), text: $renameText)
            Button(String(localized: "Rename")) {
                if let document = renamingDocument {
                    _ = documentStore.renameDocument(document, to: renameText)
                }
                renamingDocument = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { renamingDocument = nil }
        }
    }

    private func row(for document: WorkspaceDocument) -> some View {
        let isMissing = documentStore.missingDocumentIds.contains(document.id)
        return Button {
            onSelect(document.id)
        } label: {
            HStack {
                Label(document.displayName, systemImage: isMissing ? "doc.badge.ellipsis" : "doc.text")
                    .foregroundStyle(isMissing ? Color.secondary : Color.primary)
                Spacer()
                if focusedDocumentId == document.id {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .contextMenu {
            if let onToggleSplit {
                Button {
                    onToggleSplit(document.id)
                } label: {
                    Label(splitMembership?(document.id) == true
                          ? String(localized: "Remove from Split")
                          : String(localized: "Open in Split"),
                          systemImage: "rectangle.split.2x1")
                }
            }
            Button {
                renameText = document.displayName
                renamingDocument = document
            } label: {
                Label(String(localized: "Rename…"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                documentStore.deleteDocument(document)
            } label: {
                Label(String(localized: "Delete Document"), systemImage: "trash")
            }
        }
        .accessibilityLabel(document.displayName)
        .accessibilityHint(String(localized: "Workspace document"))
    }
}
