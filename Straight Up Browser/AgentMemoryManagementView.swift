//
//  AgentMemoryManagementView.swift
//  Straight Up Browser
//
//  Review, edit, disable, export, and forget the separate scoped Agent memory
//  store. Browsing history, conversations, and run records are not affected.
//

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentMemoryManagementView: View {
    @ObservedObject var controller: AgentMemoryController

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var editingEntry: AgentMemoryEntry?
    @State private var confirmingDeleteAll = false
    @State private var exportMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stored Agent Memory")
                        .font(.title2.weight(.semibold))
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export Redacted…", action: exportRedacted)
                    .disabled(controller.entries.isEmpty)
                Button("Forget All…", role: .destructive) {
                    confirmingDeleteAll = true
                }
                .disabled(controller.entries.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            } else if let exportMessage {
                Label(exportMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            if controller.entries.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Stored Memory" : "No Matching Memory",
                    systemImage: "brain.head.profile",
                    description: Text(
                        searchText.isEmpty
                            ? "Approved memories will appear here with their scope and provenance."
                            : "Try a different search."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.entries) { entry in
                    memoryRow(entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .searchable(text: $searchText, prompt: "Search stored memory")
        .task(id: searchText) {
            if !searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            await controller.refresh(searchText: searchText)
        }
        .sheet(item: $editingEntry) { entry in
            AgentMemoryEditView(entry: entry) { text in
                Task { await controller.edit(id: entry.id, text: text) }
            }
        }
        .confirmationDialog(
            "Forget every stored Agent memory?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Forget All Memory", role: .destructive) {
                Task { await controller.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the separate memory store. Browsing history, conversations, runs, bookmarks, and provider data are unchanged.")
        }
    }

    private var summaryText: String {
        guard let summary = controller.storageSummary else {
            return "Scoped memory stored separately from browser history"
        }
        return "\(summary.enabledEntryCount) active of \(summary.entryCount) · \(ByteCountFormatter.string(fromByteCount: Int64(summary.approximateBytes), countStyle: .file))"
    }

    private func memoryRow(_ entry: AgentMemoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.text)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(scopeLabel(entry.scope))
                    Text(entry.sensitivity.rawValue.capitalized)
                    Text(entry.provenance.kind.rawValue)
                    if let expiresAt = entry.expiresAt {
                        Text("Expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(entry.whyItExists)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { entry.isEnabled },
                    set: { enabled in
                        Task {
                            await controller.setEnabled(id: entry.id, enabled: enabled)
                        }
                    }
                )
            )
            .labelsHidden()
            .help(entry.isEnabled ? "Disable this memory" : "Enable this memory")

            Button {
                editingEntry = entry
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit memory")

            Button(role: .destructive) {
                Task { await controller.delete(id: entry.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget memory")
        }
        .padding(.vertical, 5)
    }

    private func scopeLabel(_ scope: AgentMemoryScope) -> String {
        switch scope {
        case .global:
            "Global"
        case .origin(let origin):
            origin.description
        case .task:
            "Task"
        case .conversation:
            "Conversation"
        }
    }

    private func exportRedacted() {
        Task {
            do {
                let data = try await controller.exportData()
                let panel = NSSavePanel()
                panel.title = "Export Redacted Agent Memory"
                panel.nameFieldStringValue = "browser-agent-memory-redacted.json"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try data.write(to: destination, options: [.atomic])
                exportMessage = "Exported a redacted memory document."
            } catch {
                exportMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

private struct AgentMemoryEditView: View {
    let entry: AgentMemoryEntry
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(entry: AgentMemoryEntry, save: @escaping (String) -> Void) {
        self.entry = entry
        self.save = save
        _draft = State(initialValue: entry.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Stored Memory")
                .font(.headline)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 180)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15))
                }
            Text("Editing changes only this memory entry. Its scope, sensitivity, provenance, and backlinks are preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}
#endif
