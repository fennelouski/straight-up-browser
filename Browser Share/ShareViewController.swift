//
//  ShareViewController.swift
//  Browser Share
//
//  The share extension (Phase 3, docs/phase3-design.md): a compact one-tap
//  workspace picker. It NEVER opens the app's store — it reads the mirrored
//  workspace list, writes one queue item into the app group's ShareInbox, and
//  completes. The app ingests on its next activation.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    private var payload = SharePayload()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let workspaces = ShareQueue.mirroredWorkspaces()
        let host = UIHostingController(rootView: ShareSheetView(
            workspaces: workspaces,
            onPick: { [weak self] workspaceId in self?.finish(workspaceId: workspaceId) },
            onCancel: { [weak self] in self?.cancel() }
        ))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        extractPayload()
    }

    // MARK: Payload extraction

    private struct SharePayload {
        var url: URL?
        var title: String = ""
        var fileData: Data?
        var fileName: String?
    }

    private func extractPayload() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }
        for item in items {
            if payload.title.isEmpty, let text = item.attributedContentText?.string, !text.isEmpty {
                payload.title = text
            }
            for provider in item.attachments ?? [] {
                load(provider)
            }
        }
    }

    private func load(_ provider: NSItemProvider) {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
                guard let url = value as? URL else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if url.isFileURL {
                        self.adoptFile(at: url)
                    } else if self.payload.url == nil {
                        self.payload.url = url
                    }
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] value, _ in
                guard let text = value as? String else { return }
                Task { @MainActor in
                    guard let self else { return }
                    // Text that parses as a URL is a URL share; other text
                    // becomes the title.
                    if self.payload.url == nil, let url = URL(string: text),
                       url.scheme == "http" || url.scheme == "https" {
                        self.payload.url = url
                    } else if self.payload.title.isEmpty {
                        self.payload.title = text
                    }
                }
            }
        } else if let type = [UTType.image, .movie, .pdf, .data].first(where: {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) {
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, _ in
                guard let url else { return }
                // The provider deletes its temp file after this returns: read now.
                let data = try? Data(contentsOf: url)
                let name = url.lastPathComponent
                Task { @MainActor in
                    guard let self, let data, self.payload.fileData == nil else { return }
                    self.payload.fileData = data
                    self.payload.fileName = name
                }
            }
        }
    }

    private func adoptFile(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard payload.fileData == nil, let data = try? Data(contentsOf: url) else { return }
        payload.fileData = data
        payload.fileName = url.lastPathComponent
    }

    // MARK: Completion

    private func finish(workspaceId: UUID) {
        // Extraction is async; by tap time it has virtually always landed, but
        // give a slow provider one breath rather than dropping the share.
        Task { @MainActor in
            if payload.url == nil && payload.fileData == nil {
                try? await Task.sleep(for: .milliseconds(400))
            }
            let item = ShareQueue.SharedItem(
                workspaceId: workspaceId,
                url: payload.url,
                title: payload.title,
                fileName: payload.fileData != nil ? payload.fileName : nil
            )
            if payload.url != nil || payload.fileData != nil {
                ShareQueue.enqueue(item, fileData: payload.fileData)
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

// MARK: - The picker

private struct ShareSheetView: View {
    let workspaces: [ShareQueue.MirroredWorkspace]
    let onPick: (UUID) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if workspaces.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No workspaces yet")
                            .font(.headline)
                        Text("Open Browser and turn your tabs into a workspace first.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        // Most recently active first: element zero is the one tap.
                        if let primary = workspaces.first {
                            Section {
                                Button {
                                    onPick(primary.id)
                                } label: {
                                    Label(String(localized: "Add to \(primary.name)"),
                                          systemImage: "plus.rectangle.on.folder")
                                        .font(.headline)
                                }
                            }
                        }
                        if workspaces.count > 1 {
                            Section("Other Workspaces") {
                                ForEach(workspaces.dropFirst(), id: \.id) { workspace in
                                    Button(workspace.name) { onPick(workspace.id) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text("Add to Workspace"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), action: onCancel)
                }
            }
        }
    }
}
