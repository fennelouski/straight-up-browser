//
//  DocumentPane_iOS.swift
//  Browser (iOS/iPadOS)
//
//  The document editor on iOS (Phase 2, design §1.4): a document displays full
//  screen where a page would render — "another thing the window can display."
//  Same hybrid live rendering as the Mac, via the shared MarkdownStyling core
//  and DocumentEditSession.
//

import SwiftUI
import UIKit

/// Full-screen document host: header strip + editor.
struct DocumentPaneHost_iOS: View {
    let documentId: UUID
    @ObservedObject var documentStore: DocumentStore
    @ObservedObject var tabManager: TabManager

    var body: some View {
        if let row = documentStore.document(id: documentId) {
            DocumentPane_iOS(
                row: row,
                session: documentStore.session(for: row, workspaceId: row.workspaceId),
                documentStore: documentStore,
                onClose: { tabManager.closeDocumentPane(documentId) }
            )
        }
    }
}

private struct DocumentPane_iOS: View {
    let row: WorkspaceDocument
    @ObservedObject var session: DocumentEditSession
    @ObservedObject var documentStore: DocumentStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(row.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .browserToggleAuditView, object: nil)
                } label: {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(String(localized: "Graph & Audit"))
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(String(localized: "Close document"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            if documentStore.missingDocumentIds.contains(row.id) {
                statusLine(String(localized: "File missing — it may have been moved or deleted outside Browser."))
            } else if case .unavailable = documentStore.containerState {
                statusLine(String(localized: "iCloud Drive is unavailable — sign in to edit documents."))
            } else if !session.isLoaded {
                statusLine(String(localized: "Waiting for iCloud…"))
            }

            MarkdownEditorRepresentable_iOS(session: session)
        }
        .background(Color(.systemBackground))
        .task { if !session.isLoaded { await session.open() } }
        .onDisappear { Task { await session.saveNow() } }
    }

    private func statusLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
    }
}

// MARK: - The text view

private struct MarkdownEditorRepresentable_iOS: UIViewRepresentable {
    @ObservedObject var session: DocumentEditSession

    func makeUIView(context: Context) -> MarkdownTextView_iOS {
        let view = MarkdownTextView_iOS()
        view.delegate = context.coordinator
        context.coordinator.textView = view
        view.text = session.text
        view.restyle(resolved: session.resolvedLinks)
        return view
    }

    func updateUIView(_ uiView: MarkdownTextView_iOS, context: Context) {
        context.coordinator.session = session
        // Adopt session text only on external revisions, never on echoes of the
        // user's own typing.
        if context.coordinator.adoptedRevision != session.externalRevision {
            context.coordinator.adoptedRevision = session.externalRevision
            if uiView.text != session.text {
                let selection = uiView.selectedRange
                uiView.text = session.text
                let length = (uiView.text as NSString).length
                uiView.selectedRange = NSRange(location: min(selection.location, length), length: 0)
            }
        }
        uiView.restyle(resolved: session.resolvedLinks)
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var session: DocumentEditSession
        weak var textView: MarkdownTextView_iOS?
        var adoptedRevision = 0

        init(session: DocumentEditSession) {
            self.session = session
            adoptedRevision = session.externalRevision
        }

        func textViewDidChange(_ textView: UITextView) {
            session.editorDidChangeText(textView.text)
            (textView as? MarkdownTextView_iOS)?.restyle(resolved: session.resolvedLinks)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? MarkdownTextView_iOS)?.restyle(resolved: session.resolvedLinks)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            let session = session
            Task { await session.saveNow() }
        }

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            let attributes = textView.attributedText.attributes(at: textItem.range.location, effectiveRange: nil)
            let anchorId = attributes[MarkdownStyling.anchorIdAttribute] as? UUID
            return UIAction(title: String(localized: "Open")) { _ in
                if let anchorId {
                    NotificationCenter.default.post(
                        name: .browserOpenAnchor, object: nil,
                        userInfo: ["anchorId": anchorId, "url": url]
                    )
                } else {
                    NotificationCenter.default.post(name: .browserOpenURL, object: url)
                }
            }
        }
    }
}

/// UITextView with the shared hybrid Markdown rendering. Attribute-only writes;
/// the string is never mutated by styling.
final class MarkdownTextView_iOS: UITextView {

    static let bodyFont = UIFont.systemFont(ofSize: 16)
    static let codeFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    init() {
        super.init(frame: .zero, textContainer: nil)
        // Markdown is source text: smart substitutions would corrupt it.
        autocorrectionType = .default
        smartQuotesType = .no
        smartDashesType = .no
        autocapitalizationType = .sentences
        font = Self.bodyFont
        textColor = .label
        backgroundColor = .systemBackground
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 240, right: 12)
        isFindInteractionEnabled = true
        linkTextAttributes = [:] // pill styling owns link colors
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Same span mapping as the Mac editor. ponytail: whole-document restyle on
    /// each edit and caret move; make it incremental if profiling demands.
    func restyle(resolved: [AnchorResolver.ResolvedLink]) {
        let storage = textStorage
        let text = text ?? ""
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        guard fullRange.length > 0 else { return }
        let caretLine = (text as NSString).lineRange(
            for: NSRange(location: min(selectedRange.location, fullRange.length), length: 0))

        storage.beginEditing()
        storage.setAttributes([.font: Self.bodyFont, .foregroundColor: UIColor.label], range: fullRange)

        for span in MarkdownStyling.spans(for: text) {
            apply(span, caretLine: caretLine, to: storage)
        }
        for link in resolved where link.isEnriched {
            applyPill(link, to: storage, fullRange: fullRange)
        }
        for link in resolved {
            storage.addAttribute(.link, value: link.match.parsed.url, range: clamp(link.match.textRange, to: fullRange))
        }
        storage.endEditing()
    }

    private func apply(_ span: MarkdownStyling.Span, caretLine: NSRange, to storage: NSTextStorage) {
        let range = clamp(span.range, to: NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return }
        switch span.kind {
        case .heading(let level):
            let scale = MarkdownStyling.headingScales[min(level, 6) - 1]
            storage.addAttribute(.font,
                value: UIFont.boldSystemFont(ofSize: Self.bodyFont.pointSize * scale), range: range)
        case .bold:
            storage.addAttribute(.font, value: withTraits(.traitBold), range: range)
        case .italic:
            storage.addAttribute(.font, value: withTraits(.traitItalic), range: range)
        case .inlineCode:
            storage.addAttribute(.font, value: Self.codeFont, range: range)
            storage.addAttribute(.backgroundColor, value: UIColor.quaternarySystemFill, range: range)
        case .codeBlock:
            storage.addAttribute(.font, value: Self.codeFont, range: range)
            storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
        case .listMarker:
            storage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: range)
        case .blockquoteText:
            storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
        case .syntaxMark:
            let onCaretLine = NSIntersectionRange(range, caretLine).length > 0
            let alpha = onCaretLine ? 0.8 : MarkdownStyling.fadedMarkOpacity
            storage.addAttribute(.foregroundColor,
                value: UIColor.secondaryLabel.withAlphaComponent(alpha), range: range)
        case .linkText:
            storage.addAttribute(.foregroundColor, value: UIColor.link, range: range)
        }
    }

    private func applyPill(_ link: AnchorResolver.ResolvedLink, to storage: NSTextStorage, fullRange: NSRange) {
        let textRange = clamp(link.match.textRange, to: fullRange)
        guard textRange.length > 0, let anchorId = link.anchorId else { return }
        let tint: UIColor = switch link.disposition {
        case .kept: .systemGreen
        case .dismissed: .systemGray
        case .open, nil: .tintColor
        }
        storage.addAttribute(.backgroundColor, value: tint.withAlphaComponent(0.16), range: textRange)
        storage.addAttribute(.foregroundColor, value: tint, range: textRange)
        storage.addAttribute(MarkdownStyling.anchorIdAttribute, value: anchorId, range: textRange)
        if let sourceKey = link.sourceKey {
            storage.addAttribute(MarkdownStyling.anchorSourceKeyAttribute, value: sourceKey, range: textRange)
        }
    }

    private func clamp(_ range: NSRange, to bounds: NSRange) -> NSRange {
        let location = min(range.location, bounds.length)
        return NSRange(location: location, length: min(range.length, bounds.length - location))
    }

    private func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let descriptor = Self.bodyFont.fontDescriptor.withSymbolicTraits(traits)
        return descriptor.map { UIFont(descriptor: $0, size: Self.bodyFont.pointSize) } ?? Self.bodyFont
    }
}
