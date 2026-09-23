//
//  ResearchHandoff.swift
//  Straight Up Browser
//
//  The outbound half of deep research. Phase 7 already brings a Claude/Gemini
//  report IN (⌃⌘I, ResearchReportImport.swift); what an external agent could
//  never see was the workspace it was researching FOR — the question, the
//  sources already kept, the ones already rejected. These three MCP tools are
//  that window, plus the return trip through the importer that already exists.
//
//  Reading is the only new code here. import_report is ResearchReportImporter
//  called with no sheet in front of it, so the ledger writes, the anchors, and
//  the pre-populated edges stay in exactly one place.
//

import Foundation
import SwiftData

@MainActor
enum ResearchHandoff {

    nonisolated static let toolNames: Set<String> = [
        "list_workspaces", "get_workspace_brief", "import_report",
    ]

    // Bounds on the brief: a workspace with four hundred sources must still
    // produce a prompt an agent can actually read.
    // ponytail: fixed caps, no pagination. Add a cursor if someone hits one.
    private static let maximumSources = 100
    private static let maximumQuoteCharacters = 240
    private static let maximumDocumentCharacters = 1_200

    static func call(
        _ tool: String,
        arguments: [String: Any],
        modelContext: ModelContext
    ) async -> [String: Any] {
        // The stores are wired once at launch (ContentView) and shared with
        // ResearchRecall — never a second LedgerStore over the same context.
        guard let ledger = ResearchRecall.shared.ledgerStore,
              let documents = ResearchRecall.shared.documentStore else {
            return ["error": "The research ledger is not ready yet."]
        }

        switch tool {
        case "list_workspaces":
            return listWorkspaces(ledger: ledger, documents: documents, modelContext: modelContext)

        case "get_workspace_brief":
            switch resolveWorkspace(arguments, ledger: ledger, modelContext: modelContext) {
            case .failed(let error):
                return error
            case .found(let workspace):
                return [
                    "ok": true,
                    "workspaceId": workspace.id.uuidString,
                    "name": workspace.name,
                    "brief": brief(for: workspace, ledger: ledger, documents: documents),
                ]
            }

        case "import_report":
            let markdown = (arguments["markdown"] as? String ?? arguments["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdown.isEmpty else {
                return ["error": "import_report requires markdown"]
            }
            switch resolveWorkspace(arguments, ledger: ledger, modelContext: modelContext) {
            case .failed(let error):
                return error
            case .found(let workspace):
                let title = (arguments["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let summary = await ResearchReportImporter.importReport(
                    text: markdown,
                    titleOverride: (title?.isEmpty ?? true) ? nil : title,
                    workspace: workspace,
                    ledgerStore: ledger,
                    documentStore: documents
                ) else {
                    return ["error": "The report could not be imported — is iCloud Drive available?"]
                }
                return [
                    "ok": true,
                    "workspaceId": workspace.id.uuidString,
                    "documentId": summary.documentId.uuidString,
                    "documentName": summary.documentName,
                    "citedSources": summary.citedSources,
                    "linkedEdges": summary.linkedEdges,
                ]
            }

        default:
            return ["error": "unsupported research tool: \(tool)"]
        }
    }

    // MARK: - list_workspaces

    private static func listWorkspaces(
        ledger: LedgerStore,
        documents: DocumentStore,
        modelContext: ModelContext
    ) -> [String: Any] {
        let active = TabManager.restoredActiveWorkspaceId()
        let rows = allWorkspaces(modelContext).map { workspace -> [String: Any] in
            let refs = ledger.references(workspaceId: workspace.id)
            return [
                "id": workspace.id.uuidString,
                "name": workspace.name,
                "isActive": workspace.id == active,
                "isArchived": workspace.isArchived,
                "openSources": refs.filter { $0.disposition != .dismissed }.count,
                "dismissedSources": refs.filter { $0.disposition == .dismissed }.count,
                "documents": documents.documents(workspaceId: workspace.id).count,
                "lastActiveAt": ISO8601DateFormatter().string(from: workspace.lastActiveAt),
            ]
        }
        var result: [String: Any] = ["ok": true, "workspaces": rows]
        if let active { result["activeWorkspaceId"] = active.uuidString }
        return result
    }

    // MARK: - get_workspace_brief

    private static func brief(
        for workspace: Workspace,
        ledger: LedgerStore,
        documents: DocumentStore
    ) -> String {
        var lines = ["# Workspace: \(workspace.name)"]

        let refs = ledger.references(workspaceId: workspace.id)
        // `kept` is what an archived workspace's survivors become — still a
        // source the user wanted, so it belongs with the open ones.
        let keeping = refs.filter { $0.disposition != .dismissed }
            .sorted { $0.addedAt < $1.addedAt }
        let dismissed = refs.filter { $0.disposition == .dismissed }

        let notes = documents.documents(workspaceId: workspace.id)
        if !notes.isEmpty {
            lines.append("\n## The user's own notes")
            lines.append("What they are actually asking. Everything below serves this.")
            for row in notes {
                lines.append("\n### \(row.displayName)")
                guard let url = documents.url(for: row),
                      let text = try? String(contentsOf: url, encoding: .utf8) else {
                    lines.append("_(not synced to this device yet)_")
                    continue
                }
                // Clipped, not collapsed: a note's paragraphs are the shape
                // of the question.
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(body.count > maximumDocumentCharacters
                    ? String(body.prefix(maximumDocumentCharacters)) + "…"
                    : body)
            }
        }

        lines.append("\n## Sources already captured (\(keeping.count))")
        if keeping.isEmpty {
            lines.append("_None yet._")
        } else {
            if keeping.count > maximumSources {
                lines.append("_Showing the first \(maximumSources) of \(keeping.count), oldest first._")
            }
            for ref in keeping.prefix(maximumSources) {
                guard let article = ledger.source(sourceKey: ref.sourceKey) else { continue }
                lines.append("- [\(article.title)](\(article.url.absoluteString))")
                let excerpt = article.cardExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !excerpt.isEmpty {
                    lines.append("  \(truncated(excerpt, to: maximumQuoteCharacters))")
                }
                for anchor in ledger.anchors(sourceKey: ref.sourceKey)
                where !anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("  - anchored: “\(truncated(anchor.quote, to: maximumQuoteCharacters))”")
                }
            }
        }

        if !dismissed.isEmpty {
            lines.append("\n## Already rejected (\(dismissed.count)) — do not revisit")
            lines.append("The user opened each of these and closed it. Closing IS the rejection.")
            for ref in dismissed.prefix(maximumSources) {
                guard let article = ledger.source(sourceKey: ref.sourceKey) else { continue }
                lines.append("- \(article.title) — \(article.url.absoluteString)")
            }
        }

        lines.append("""

        ## Handing work back
        Write the report as Markdown with inline [link text](url) citations —
        every claim carries the URL it stands on — then call `import_report`
        with `workspaceId` \(workspace.id.uuidString). Each citation becomes a
        source, an anchor, and a claim-citation edge in this workspace.
        """)
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared

    /// Result needs an Error; a lookup failure here is already a tool response.
    private enum WorkspaceLookup {
        case found(Workspace)
        case failed([String: Any])
    }

    private static func allWorkspaces(_ modelContext: ModelContext) -> [Workspace] {
        let descriptor = FetchDescriptor<Workspace>(
            sortBy: [SortDescriptor(\.orderIndex), SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// An explicit `workspaceId`, else whichever workspace the user is in. The
    /// failure names the real workspaces so an agent's second try succeeds.
    private static func resolveWorkspace(
        _ arguments: [String: Any],
        ledger: LedgerStore,
        modelContext: ModelContext
    ) -> WorkspaceLookup {
        if let raw = arguments["workspaceId"] as? String, !raw.isEmpty {
            guard let id = UUID(uuidString: raw), let workspace = ledger.workspace(id: id) else {
                return .failed(["error": "No workspace with id \(raw). Call list_workspaces."])
            }
            return .found(workspace)
        }
        if let active = TabManager.restoredActiveWorkspaceId(),
           let workspace = ledger.workspace(id: active) {
            return .found(workspace)
        }
        let names = allWorkspaces(modelContext).map(\.name)
        return .failed([
            "error": names.isEmpty
                ? "There are no research workspaces yet."
                : "No workspace is active — pass workspaceId. Available: \(names.joined(separator: ", "))",
        ])
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
