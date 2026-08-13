//
//  Autofill.swift
//  Straight Up Browser
//
//  The suggestion list: what appears when you focus a name, email, phone, or
//  address field, and what happens when you pick something.
//
//  Picking fills every recognized EMPTY field on the page, not just the focused
//  one, so one keystroke finishes a signup form. Anything already typed is left
//  alone.
//
//  Why a root-level SwiftUI overlay rather than a .popover or an NSPanel:
//    * .popover anchors to a view in the SwiftUI tree, and the field is pixels
//      inside a WKWebView — there's nothing to anchor to.
//    * An NSPanel that can become key would blur the page's input, which fires
//      DOM blur, closes the site's own dropdown, and makes the fill's focus()
//      generate a second focus round. Its only real advantage is drawing past
//      the window edge, and the field is inside the window anyway.
//  So: the same trick screenshotFlashOverlay uses — an AppKit window-coordinate
//  rect, drawn by SwiftUI at the root, with one y-flip.
//

import SwiftUI
import SwiftData
import WebKit
import Combine
#if canImport(AppKit)
import AppKit
#endif

struct AutofillSuggestion: Identifiable, Equatable {
    let person: AutofillPersonReference
    let profileName: String
    let value: String

    var id: String { person.storageValue }
}

@MainActor
final class AutofillManager: ObservableObject {
    struct Presentation: Equatable {
        let tabID: UUID
        let signal: AutofillFocusSignal
        let field: AutofillField
        /// AppKit window coordinates, origin bottom-left.
        let fieldRect: CGRect
        let url: URL?
    }

    @Published private(set) var presentation: Presentation?
    @Published private(set) var suggestions: [AutofillSuggestion] = []
    @Published var selectedIndex = 0
    /// Set while the pointer is over the list. Clicking it resigns the web
    /// view's first responder, which fires DOM blur and would otherwise dismiss
    /// the list out from under the click.
    @Published var pointerInsideList = false

    private weak var webViewManager: WebViewManager?
    private var modelContext: ModelContext?
    private var preferences: AutofillPreferences { .shared }
    private var observers: [NSObjectProtocol] = []
    private var focusToken = UUID()
    #if canImport(AppKit)
    private var keyMonitor: Any?
    #endif

    var isShowing: Bool { presentation != nil && !suggestions.isEmpty }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addMainActorObserver(
            forName: .browserAutofillFieldFocused,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.fieldFocused(note)
        })
        observers.append(center.addMainActorObserver(
            forName: .browserAutofillDismissed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.pointerInsideList else { return }
            self.dismiss()
        })
        #if canImport(AppKit)
        observers.append(center.addMainActorObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dismiss()
        })
        #endif
    }

    func configure(webViewManager: WebViewManager, modelContext: ModelContext) {
        self.webViewManager = webViewManager
        self.modelContext = modelContext
    }

    // MARK: Presenting

    private func fieldFocused(_ note: Notification) {
        guard let signal = note.userInfo?["signal"] as? AutofillFocusSignal,
              let tabID = note.userInfo?["tabID"] as? UUID,
              let rect = note.userInfo?["rect"] as? CGRect else { return }
        let url = note.userInfo?["url"] as? URL

        let incognito = webViewManager?.isPrivateTab(tabID) ?? false
        guard preferences.shouldOffer(url: url, incognito: incognito),
              let field = AutofillFieldClassifier.classify(signal.hints),
              preferences.allows(field.category)
        else { return dismiss() }

        dismiss()
        let token = UUID()
        focusToken = token
        let candidate = Presentation(
            tabID: tabID,
            signal: signal,
            field: field,
            fieldRect: rect,
            url: url
        )
        let manualProfiles = manualProfiles()
        let contactPeople = preferences.contactPeople
        let activePerson = preferences.activePerson

        Task { @MainActor [weak self] in
            #if os(macOS)
            let contacts = await AutofillContactStore.resolve(contactPeople)
            #else
            let contacts: [AutofillResolvedPerson] = []
            #endif
            guard let self,
                  self.focusToken == token,
                  self.stillAllows(candidate)
            else { return }
            let currentContacts = self.preferences.contactPeople
            let selectedContacts = contacts.filter {
                currentContacts.contains($0.reference) || currentContacts.contains($0.resolvedReference)
            }
            self.reconcileContactReferences(selectedContacts)
            let rows = self.buildSuggestions(
                for: field,
                manualProfiles: manualProfiles,
                contacts: selectedContacts,
                activePerson: activePerson
            )
            guard !rows.isEmpty else { return }
            self.presentation = candidate
            self.suggestions = rows
            self.selectedIndex = 0
            self.installKeyMonitor()
        }
    }

    private func buildSuggestions(
        for field: AutofillField,
        manualProfiles: [AutofillResolvedPerson],
        contacts: [AutofillResolvedPerson],
        activePerson: AutofillPersonReference?
    ) -> [AutofillSuggestion] {
        var seen = Set<String>()
        let people = orderedPeople(
            manualProfiles: manualProfiles,
            contacts: contacts,
            activePerson: activePerson
        )
        return people.compactMap { person in
            let value = person.values[field] ?? ""
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return AutofillSuggestion(
                person: person.resolvedReference,
                profileName: person.name,
                value: String(value.prefix(AutofillFieldClassifier.maximumValueLength))
            )
        }
    }

    /// Fetched on demand rather than mirrored: focus is rare enough that a
    /// fetch is cheaper than keeping a copy in step. Contacts are resolved on a
    /// background task above and never enter SwiftData.
    private func manualProfiles() -> [AutofillResolvedPerson] {
        guard let modelContext else { return [] }
        let descriptor = FetchDescriptor<AutofillProfile>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let profiles = (try? modelContext.fetch(descriptor)) ?? []
        return profiles.map { profile in
            AutofillResolvedPerson(
                reference: .manual(profile.id),
                resolvedReference: .manual(profile.id),
                contactIdentifier: nil,
                name: profile.displayName,
                values: Dictionary(
                    uniqueKeysWithValues: AutofillField.allCases.map { ($0, profile.value(for: $0)) }
                )
            )
        }
    }

    private func orderedPeople(
        manualProfiles: [AutofillResolvedPerson],
        contacts: [AutofillResolvedPerson],
        activePerson: AutofillPersonReference?
    ) -> [AutofillResolvedPerson] {
        var people = contacts + manualProfiles
        guard let activePerson,
              let index = people.firstIndex(where: { $0.reference == activePerson }) else {
            return people
        }
        people.insert(people.remove(at: index), at: 0)
        return people
    }

    private func stillAllows(_ candidate: Presentation) -> Bool {
        guard preferences.shouldOffer(url: candidate.url, incognito: webViewManager?
            .isPrivateTab(candidate.tabID) ?? false), preferences.allows(candidate.field.category) else {
            return false
        }
        return webViewManager?.activeTabId == candidate.tabID
    }

    private func reconcileContactReferences(_ contacts: [AutofillResolvedPerson]) {
        for person in contacts {
            if case .contact(let old) = person.reference,
               case .contact(let resolved) = person.resolvedReference {
                preferences.replaceContact(identifier: old, with: resolved)
            }
        }
    }

    private func remainsSelected(_ person: AutofillPersonReference) -> Bool {
        switch person {
        case .manual:
            true
        case .me, .contact:
            preferences.contactPeople.contains(person)
        }
    }

    func dismiss() {
        focusToken = UUID()
        guard presentation != nil else { return }
        presentation = nil
        suggestions = []
        selectedIndex = 0
        pointerInsideList = false
        removeKeyMonitor()
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        #if canImport(AppKit)
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShowing, NSApp.keyWindow != nil else { return event }
            switch AutofillKeyAction.forKeyCode(event.keyCode) {
            case .move(let delta):
                self.move(by: delta)
                return nil
            case .commit:
                self.commit()
                return nil
            case .dismiss(let swallow):
                self.dismiss()
                return swallow ? nil : event
            }
        }
        #endif
    }

    private func removeKeyMonitor() {
        #if canImport(AppKit)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        #endif
    }

    func move(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let count = suggestions.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    // MARK: Filling

    func commit(person: AutofillPersonReference? = nil) {
        guard let presentation,
              !suggestions.isEmpty,
              let chosen = person ?? suggestions[safe: selectedIndex]?.person,
              let webView = webViewManager?.getWebView(for: presentation.tabID)
        else { return dismiss() }
        dismiss()

        Task { @MainActor in
            guard self.stillAllows(presentation),
                  self.remainsSelected(chosen),
                  self.webViewManager?.getWebView(for: presentation.tabID) === webView
            else { return }
            let values = await values(for: chosen)
            guard let values,
                  self.stillAllows(presentation),
                  self.remainsSelected(chosen),
                  self.webViewManager?.getWebView(for: presentation.tabID) === webView
            else { return }
            let allowed = Dictionary(
                uniqueKeysWithValues: AutofillCategory.allCases.map { ($0, self.preferences.allows($0)) }
            )
            await fill(webView: webView, values: values, allowed: allowed, expecting: presentation)
        }
    }

    private func values(for person: AutofillPersonReference) async -> [AutofillField: String]? {
        switch person {
        case .manual(let id):
            return manualProfiles().first(where: { $0.reference == .manual(id) })?.values
        case .me, .contact:
            #if os(macOS)
            return await AutofillContactStore.resolve(person)?.values
            #else
            return nil
            #endif
        }
    }

    private func fill(
        webView: WKWebView,
        values: [AutofillField: String],
        allowed: [AutofillCategory: Bool],
        expecting presentation: Presentation
    ) async {
        let raw = try? await webView.callAsyncJavaScript(
            SemanticPageJavaScript.snapshot,
            arguments: ["selectors": [] as [String]],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let raw, let scan = try? AutofillPageScan.decode(raw) else { return }
        // The page navigated between focus and pick; the elements we were about
        // to fill no longer exist.
        guard scan.documentToken == presentation.signal.documentToken else { return }

        let assignments = AutofillFieldClassifier.plan(
            candidates: scan.candidates,
            value: { values[$0] ?? "" },
            allows: { allowed[$0] ?? true }
        )
        guard !assignments.isEmpty else { return }

        let byLocalID = Dictionary(
            uniqueKeysWithValues: scan.fields.map { ($0.localID, $0) }
        )
        // Values travel as callAsyncJavaScript ARGUMENTS, never interpolated
        // into a script string.
        let payload: [[String: Any]] = assignments.compactMap { assignment in
            guard let field = byLocalID[assignment.localID] else { return nil }
            return [
                "reference": field.reference(documentToken: scan.documentToken),
                "value": assignment.value,
            ]
        }
        _ = try? await webView.callAsyncJavaScript(
            SemanticPageJavaScript.autofillApply,
            arguments: ["request": ["assignments": payload]],
            in: nil,
            contentWorld: .defaultClient
        )
        // Field names and the host only — never a value.
        Logger.log("autofill: filled \(assignments.count) field(s) [\(assignments.map { "\($0.field)" }.joined(separator: ", "))] on \(presentation.url?.host ?? "unknown")")
    }

    isolated deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        #if canImport(AppKit)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        #endif
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - The list

struct AutofillSuggestionList: View {
    @ObservedObject var autofill: AutofillManager

    static let rowHeight: CGFloat = 34
    static let verticalPadding: CGFloat = 6
    static let minimumWidth: CGFloat = 240

    static func height(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + verticalPadding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(autofill.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                row(suggestion, selected: index == autofill.selectedIndex)
                    .onTapGesture { autofill.commit(person: suggestion.person) }
                    .onHover { hovering in
                        if hovering { autofill.selectedIndex = index }
                    }
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: 8, y: 2)
        .onHover { autofill.pointerInsideList = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Autofill suggestions"))
    }

    private func row(_ suggestion: AutofillSuggestion, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.append")
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: 14)
            Text(suggestion.value)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(suggestion.profileName)
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                .lineLimit(1)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }
}
