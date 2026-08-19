//
//  DocumentPane.swift
//  Straight Up Browser
//
//  The Mac document pane (Phase 2, design §2): a TextKit NSTextView doing
//  hybrid live Markdown rendering, hosted in an AppKit view so it can sit in
//  WebViewContainer's pane layout beside web views (ADR 0008).
//
//  DEVIATION from design §2.1, recorded in docs/phase2-design.md: the Mac pane
//  is AppKit end to end rather than a SwiftUI wrapper — WebViewContainer lays
//  out NSViews, and an NSHostingView indirection would add focus and first-
//  responder seams for no benefit.
//

#if os(macOS)

import AppKit
import Combine

// MARK: - Pane manager

/// Per-window registry of live document pane views, the document-side sibling
/// of WebViewManager: WebViewContainer asks it for the view behind a pane id.
@MainActor
final class DocumentPaneManager: ObservableObject {
    private var panes: [UUID: DocumentPaneView] = [:]
    weak var documentStore: DocumentStore?

    /// Nil when the id is not a document — which is how WebViewContainer tells
    /// tab panes from document panes.
    func paneView(for id: UUID) -> DocumentPaneView? {
        if let existing = panes[id] { return existing }
        guard let store = documentStore, let row = store.document(id: id) else { return nil }
        let session = store.session(for: row, workspaceId: row.workspaceId)
        let pane = DocumentPaneView(session: session, store: store)
        panes[id] = pane
        return pane
    }

    func isDocument(_ id: UUID) -> Bool {
        panes[id] != nil || documentStore?.document(id: id) != nil
    }

    func discard(_ id: UUID) {
        panes.removeValue(forKey: id)?.removeFromSuperview()
        documentStore?.closeSession(for: id)
    }

    func discardAll() {
        for id in Array(panes.keys) { discard(id) }
    }
}

// MARK: - Pane view

/// One open document: the editor plus its transient state line. Owned by
/// DocumentPaneManager; framed by WebViewContainer.layoutPanes.
@MainActor
final class DocumentPaneView: NSView, NSTextViewDelegate {
    let session: DocumentEditSession
    private weak var store: DocumentStore?
    private let textView = MarkdownTextView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var cancellables: Set<AnyCancellable> = []
    private var peekPopover: NSPopover?

    init(session: DocumentEditSession, store: DocumentStore) {
        self.session = session
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.autoresizingMask = [.width]
        statusLabel.isHidden = true
        addSubview(statusLabel)

        textView.delegate = self
        textView.autoresizingMask = [.width]

        session.$externalRevision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.adoptSessionText() }
            .store(in: &cancellables)
        session.$resolvedLinks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restyle() }
            .store(in: &cancellables)
        store.$missingDocumentIds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] missing in self?.updateStatus(missing: missing) }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            self, selector: #selector(focusFind), name: .browserDocumentFind, object: nil)

        if session.isLoaded {
            adoptSessionText()
        } else {
            Task { [weak self] in
                await self?.session.open()
                self?.adoptSessionText()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        statusLabel.frame = NSRect(x: 0, y: bounds.height - 28, width: bounds.width, height: 20)
        textView.textContainerInset = NSSize(width: max(16, (bounds.width - 720) / 2), height: 20)
    }

    func focusEditor() {
        window?.makeFirstResponder(textView)
    }

    /// The editor's current selection — the bibliography panel's query prefill.
    func selectedText() -> String? {
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    @objc private func focusFind() {
        guard window?.firstResponder === textView
            || window?.firstResponder === self
            || textView.window != nil && isDisplayedFocused() else { return }
        textView.performFindPanelAction(NSMenuItem()) // shows the find bar
    }

    private func isDisplayedFocused() -> Bool {
        // The notification is only posted while a document owns focus; a stray
        // hidden pane must not also open its find bar.
        window != nil && superview != nil && !isHidden
    }

    private func adoptSessionText() {
        guard textView.string != session.text else { restyle(); return }
        let selection = textView.selectedRange()
        textView.setTextPreservingUndo(session.text)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        restyle()
        updateStatus(missing: store?.missingDocumentIds ?? [])
    }

    private func restyle() {
        textView.restyle(resolved: session.resolvedLinks)
    }

    private func updateStatus(missing: Set<UUID>) {
        if missing.contains(session.documentId) {
            statusLabel.stringValue = String(localized: "File missing — it may have been moved or deleted outside Browser.")
            statusLabel.isHidden = false
        } else if case .unavailable = store?.containerState {
            statusLabel.stringValue = String(localized: "iCloud Drive is unavailable — sign in to edit documents.")
            statusLabel.isHidden = false
        } else if session.isLoaded && session.text.isEmpty && !textView.string.isEmpty {
            statusLabel.isHidden = true
        } else {
            statusLabel.isHidden = true
        }
    }

    // MARK: NSTextViewDelegate

    nonisolated func textDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            session.editorDidChangeText(textView.string)
            restyle()
        }
    }

    nonisolated func textViewDidChangeSelection(_ notification: Notification) {
        // Caret moved: the old and new caret lines change mark opacity.
        MainActor.assumeIsolated { restyle() }
    }

    nonisolated func textDidEndEditing(_ notification: Notification) {
        MainActor.assumeIsolated {
            let session = session
            Task { await session.saveNow() }
        }
    }

    nonisolated func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Pull the Sendable URL out before hopping isolation.
        let url: URL? = link as? URL ?? (link as? String).flatMap(URL.init(string:))
        return MainActor.assumeIsolated {
            guard let url else { return false }
            let attributes = textView.textStorage?.attributes(at: charIndex, effectiveRange: nil)
            if let anchorId = attributes?[MarkdownStyling.anchorIdAttribute] as? UUID {
                handleAnchorClick(anchorId: anchorId, url: url, charIndex: charIndex)
            } else {
                // An ordinary link opens like one (design §6.2).
                NotificationCenter.default.post(name: .browserOpenURL, object: url)
            }
            return true
        }
    }

    // MARK: Anchor pills (design §6.4)

    private func handleAnchorClick(anchorId: UUID, url: URL, charIndex: Int) {
        let behavior = UserDefaults.standard.string(forKey: "anchorLinkOpenBehavior") ?? "peek"
        if behavior == "peek" {
            showPeek(anchorId: anchorId, url: url, charIndex: charIndex)
        } else {
            postOpen(anchorId: anchorId, url: url)
        }
    }

    private func postOpen(anchorId: UUID, url: URL) {
        NotificationCenter.default.post(
            name: .browserOpenAnchor, object: nil,
            userInfo: ["anchorId": anchorId, "url": url]
        )
    }

    private func showPeek(anchorId: UUID, url: URL, charIndex: Int) {
        peekPopover?.close()
        guard let resolved = session.resolvedLinks.first(where: { $0.anchorId == anchorId }) else {
            postOpen(anchorId: anchorId, url: url)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        let view = AnchorPeekView(
            quote: resolved.match.parsed.text,
            sourceTitle: url.host ?? url.absoluteString,
            disposition: resolved.disposition
        ) { [weak self] in
            self?.peekPopover?.close()
            self?.postOpen(anchorId: anchorId, url: url)
        }
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = view
        popover.contentSize = view.fittingSize
        let glyphRect = textView.firstRect(forCharacterRange: NSRange(location: charIndex, length: 1), actualRange: nil)
        let windowRect = window?.convertFromScreen(glyphRect) ?? .zero
        let localRect = convert(windowRect, from: nil)
        peekPopover = popover
        popover.show(relativeTo: localRect, of: self, preferredEdge: .maxY)
    }
}

// MARK: - Peek popover content

private final class AnchorPeekView: NSView {
    private let onOpen: () -> Void

    init(quote: String, sourceTitle: String, disposition: SourceDisposition?, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        super.init(frame: .zero)

        let quoteLabel = NSTextField(wrappingLabelWithString: "“\(quote)”")
        quoteLabel.font = .systemFont(ofSize: 13)
        quoteLabel.maximumNumberOfLines = 6
        quoteLabel.preferredMaxLayoutWidth = 320

        let sourceLabel = NSTextField(labelWithString: sourceTitle)
        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .secondaryLabelColor

        let dispositionText: String? = switch disposition {
        case .open: String(localized: "In the working set")
        case .kept: String(localized: "Kept")
        case .dismissed: String(localized: "Dismissed")
        case nil: nil
        }

        let openButton = NSButton(title: String(localized: "Open Source"), target: self, action: #selector(openTapped))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [quoteLabel, sourceLabel])
        if let dispositionText {
            let dispositionLabel = NSTextField(labelWithString: dispositionText)
            dispositionLabel.font = .systemFont(ofSize: 11)
            dispositionLabel.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(dispositionLabel)
        }
        stack.addArrangedSubview(openButton)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openTapped() { onOpen() }
}

// MARK: - The text view

/// NSTextView with hybrid live Markdown rendering: rendered form everywhere,
/// syntax marks faded to near-invisible off the caret line (MarkdownStyling
/// computes spans; this maps them to attributes). Attribute-only writes — the
/// string is never mutated by styling, so disk bytes always equal screen bytes.
@MainActor
final class MarkdownTextView: NSTextView {

    static let bodyFont = NSFont.systemFont(ofSize: 14)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    init() {
        super.init(frame: .zero)
        isRichText = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        // Markdown is source text: smart substitutions would corrupt it.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        font = Self.bodyFont
        typingAttributes = [.font: Self.bodyFont, .foregroundColor: NSColor.labelColor]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Replace the whole text (external reload, title repair, append) without
    /// polluting the undo stack with a single giant replacement.
    func setTextPreservingUndo(_ newText: String) {
        undoManager?.removeAllActions(withTarget: self)
        string = newText
    }

    /// Recompute every attribute from the current string + resolution state.
    /// ponytail: whole-document restyle on each edit and caret move; documents
    /// are notes, not novels. Make it incremental if a trace ever shows it.
    func restyle(resolved: [AnchorResolver.ResolvedLink]) {
        guard let storage = textStorage else { return }
        let text = string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let caretLine = (text as NSString).lineRange(
            for: NSRange(location: min(selectedRange().location, fullRange.length), length: 0))

        storage.beginEditing()
        storage.setAttributes([.font: Self.bodyFont, .foregroundColor: NSColor.labelColor], range: fullRange)

        for span in MarkdownStyling.spans(for: text) {
            apply(span, caretLine: caretLine, to: storage)
        }
        // Enriched anchor pills on top (design §6.2).
        for link in resolved where link.isEnriched {
            applyPill(link, to: storage, fullRange: fullRange)
        }
        // Plain and enriched links are clickable alike.
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
                value: NSFont.boldSystemFont(ofSize: Self.bodyFont.pointSize * scale), range: range)
        case .bold:
            storage.addAttribute(.font,
                value: NSFontManager.shared.convert(Self.bodyFont, toHaveTrait: .boldFontMask), range: range)
        case .italic:
            storage.addAttribute(.font,
                value: NSFontManager.shared.convert(Self.bodyFont, toHaveTrait: .italicFontMask), range: range)
        case .inlineCode:
            storage.addAttribute(.font, value: Self.codeFont, range: range)
            storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: range)
        case .codeBlock:
            storage.addAttribute(.font, value: Self.codeFont, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .listMarker:
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
        case .blockquoteText:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .syntaxMark:
            let onCaretLine = NSIntersectionRange(range, caretLine).length > 0
            let alpha = onCaretLine ? 0.8 : MarkdownStyling.fadedMarkOpacity
            storage.addAttribute(.foregroundColor,
                value: NSColor.secondaryLabelColor.withAlphaComponent(alpha), range: range)
        case .linkText:
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        }
    }

    private func applyPill(_ link: AnchorResolver.ResolvedLink, to storage: NSTextStorage, fullRange: NSRange) {
        let textRange = clamp(link.match.textRange, to: fullRange)
        guard textRange.length > 0, let anchorId = link.anchorId else { return }
        let tint: NSColor = switch link.disposition {
        case .kept: .systemGreen
        case .dismissed: .systemGray
        case .open, nil: .controlAccentColor
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
}

#endif
