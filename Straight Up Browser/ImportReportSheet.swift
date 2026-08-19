//
//  ImportReportSheet.swift
//  Straight Up Browser
//
//  The deep-research import sheet (Phase 7, design §1): paste first, file
//  second — reports live in chat UIs, and copy-paste is the real gesture.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportReportSheet: View {
    let workspace: Workspace
    let ledgerStore: LedgerStore
    let documentStore: DocumentStore
    /// Called with the finished summary so the host can select the document
    /// and show the transient note.
    let onImported: (ResearchReportImporter.Summary) -> Void
    var onClose: (() -> Void)? = nil

    @State private var text = ""
    @State private var title = ""
    @State private var showFilePicker = false
    @State private var importing = false
    @State private var errorNote: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste a Gemini, Claude, or ChatGPT research report here…")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 10)
            Divider()
            footer
        }
        #if os(macOS)
        .frame(width: 560)
        .frame(maxHeight: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        #endif
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let contents = try? String(contentsOf: url, encoding: .utf8) {
                    text = contents
                    if title.isEmpty {
                        title = url.deletingPathExtension().lastPathComponent
                    }
                } else {
                    errorNote = String(localized: "Couldn't read that file as text.")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square")
                .foregroundStyle(.secondary)
            Text("Import Research Report")
                .font(.headline)
            Spacer()
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(String(localized: "Close import"))
        }
        .padding(10)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField(String(localized: "Title (optional — the report's heading is used)"), text: $title)
                    .textFieldStyle(.roundedBorder)
                Button {
                    showFilePicker = true
                } label: {
                    Label(String(localized: "File…"), systemImage: "doc")
                }
            }
            HStack {
                if let errorNote {
                    Text(errorNote).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button {
                    runImport()
                } label: {
                    if importing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Import into \(workspace.name)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(importing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }

    private func runImport() {
        importing = true
        errorNote = nil
        Task { @MainActor in
            defer { importing = false }
            let summary = await ResearchReportImporter.importReport(
                text: text,
                titleOverride: title.isEmpty ? nil : title,
                workspace: workspace,
                ledgerStore: ledgerStore,
                documentStore: documentStore
            )
            if let summary {
                onImported(summary)
            } else {
                errorNote = String(localized: "Nothing to import — is iCloud Drive available?")
            }
        }
    }
}
