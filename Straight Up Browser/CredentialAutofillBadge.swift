//
//  CredentialAutofillBadge.swift
//  Straight Up Browser
//
//  The browser's own password manager: saves credentials to its private
//  Keychain vault (SavedCredentialStore) when a login form is submitted, and
//  offers them back — filling both fields in one pick — the next time that
//  domain's login form is focused.
//
//  Why not just hand off to the system Passwords picker (right-click →
//  AutoFill → Passwords…, still there, still flattened to one click in
//  WebView.swift's willOpenMenu): a sandboxed third-party app has no read
//  access to Safari/iCloud Keychain's internet passwords, so that path only
//  ever works for domains the SYSTEM already has saved. A credential typed
//  into this browser and never touched in Safari would otherwise never come
//  back. Chrome, Firefox, and every other non-Safari browser solve this the
//  same way: their own vault, independent of the OS picker.
//

import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif
import WebKit
import Security

@MainActor
final class CredentialManager: ObservableObject {
    struct Presentation: Equatable {
        let tabID: UUID
        /// AppKit window coordinates, origin bottom-left.
        let fieldRect: CGRect
        let domain: String
        let usernames: [String]
    }

    struct SavePrompt: Equatable, Identifiable {
        let tabID: UUID
        let domain: String
        let username: String
        let password: String
        let isUpdate: Bool
        var id: String { "\(tabID)\(domain)\(username)" }
    }

    @Published private(set) var presentation: Presentation?
    @Published private(set) var savePrompt: SavePrompt?
    @Published private(set) var saveError: String?
    /// Set while the pointer is over the suggestion list, so the field's blur
    /// (which fires on mouseDown, before the click completes) doesn't dismiss
    /// it out from under the click. Same trick AutofillManager uses.
    @Published var pointerInsideList = false

    private weak var webViewManager: WebViewManager?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addMainActorObserver(
            forName: .browserCredentialFieldFocused,
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
            self.presentation = nil
        })
        observers.append(center.addMainActorObserver(
            forName: .browserCredentialSubmitted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.credentialSubmitted(note)
        })
        #if canImport(AppKit)
        observers.append(center.addMainActorObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.presentation = nil
        })
        #endif
    }

    func configure(webViewManager: WebViewManager) {
        self.webViewManager = webViewManager
    }

    // MARK: Offering a saved credential

    private func fieldFocused(_ note: Notification) {
        guard let tabID = note.userInfo?["tabID"] as? UUID,
              let rect = note.userInfo?["rect"] as? CGRect,
              let url = note.userInfo?["url"] as? URL,
              let domain = Self.normalizedDomain(url)
        else { return presentation = nil }
        let usernames = SavedCredentialStore.usernames(domain: domain)
        // Nothing saved for this domain: stay quiet rather than show a badge
        // that leads nowhere. Right-click → AutoFill still works for whatever
        // the system Passwords store already has.
        guard !usernames.isEmpty else { return presentation = nil }
        presentation = Presentation(tabID: tabID, fieldRect: rect, domain: domain, usernames: usernames)
    }

    /// Fills both the username and password field for one pick. Re-scans the
    /// live page rather than trusting the focus-time snapshot: the field the
    /// user is about to fill may not be the one that was focused (a username
    /// suggestion picked while the password field has focus, say).
    func pick(username: String) {
        guard let presentation,
              let webView = webViewManager?.getWebView(for: presentation.tabID)
        else { return }
        let domain = presentation.domain
        self.presentation = nil
        guard let password = SavedCredentialStore.password(domain: domain, username: username) else { return }

        Task { @MainActor in
            let raw = try? await webView.callAsyncJavaScript(
                SemanticPageJavaScript.snapshot,
                arguments: ["selectors": [] as [String]],
                in: nil,
                contentWorld: .defaultClient
            )
            guard Self.normalizedDomain(webView.url ?? URL(fileURLWithPath: "/")) == domain,
                  let raw, let scan = try? AutofillPageScan.decode(raw) else { return }
            let (usernameField, passwordField) = Self.credentialFields(in: scan)
            guard let passwordField else { return }

            var payload: [String: Any] = [
                "password": [
                    "reference": passwordField.reference(documentToken: scan.documentToken),
                    "value": password,
                ],
            ]
            if let usernameField {
                payload["username"] = [
                    "reference": usernameField.reference(documentToken: scan.documentToken),
                    "value": username,
                ]
            }
            _ = try? await webView.callAsyncJavaScript(
                SemanticPageJavaScript.credentialApply,
                arguments: ["request": payload],
                in: nil,
                contentWorld: .defaultClient
            )
            Logger.log("credential manager: filled saved login on \(domain)")
        }
    }

    /// The password field plus its best-guess paired username field, from a
    /// full-page scan. `AutofillPageScan` decodes every form control
    /// (unfiltered by type) in document order, so a password field is here
    /// even though AutofillFieldClassifier would never classify one.
    private static func credentialFields(
        in scan: AutofillPageScan
    ) -> (username: AutofillFormField?, password: AutofillFormField?) {
        let fields = scan.fields
        guard let passwordIndex = fields.firstIndex(where: {
            $0.descriptor.type == "password" && $0.descriptor.isVisible && $0.descriptor.isEditable
        }) else { return (nil, nil) }
        let password = fields[passwordIndex]

        func isUsernameish(_ field: AutofillFormField) -> Bool {
            ["text", "email", "tel", ""].contains(field.descriptor.type)
                && field.descriptor.isVisible && field.descriptor.isEditable
        }
        let byAutocomplete = fields.first { $0.descriptor.autocomplete.lowercased().contains("username") }
        let before = fields[..<passwordIndex].reversed()
        let after = fields[fields.index(after: passwordIndex)...]
        let username = byAutocomplete ?? before.first(where: isUsernameish) ?? after.first(where: isUsernameish)
        return (username, password)
    }

    // MARK: Offering to save a new one

    private func credentialSubmitted(_ note: Notification) {
        guard let tabID = note.userInfo?["tabID"] as? UUID,
              let rawDomain = note.userInfo?["domain"] as? String,
              let username = note.userInfo?["username"] as? String,
              let password = note.userInfo?["password"] as? String
        else { return }
        let domain = rawDomain.lowercased()
        // Already saved with this exact password: nothing new to offer.
        let existing = SavedCredentialStore.password(domain: domain, username: username)
        guard existing != password else {
            savePrompt = nil
            saveError = nil
            return
        }
        saveError = nil
        savePrompt = SavePrompt(tabID: tabID, domain: domain, username: username, password: password, isUpdate: existing != nil)
    }

    func acceptSavePrompt() {
        guard let savePrompt else { return }
        let status = SavedCredentialStore.save(domain: savePrompt.domain, username: savePrompt.username, password: savePrompt.password)
        guard status == errSecSuccess else {
            saveError = "Could not save password. Please try again. (\(status))"
            return
        }
        saveError = nil
        self.savePrompt = nil
    }

    func dismissSavePrompt() {
        saveError = nil
        savePrompt = nil
    }

    private static func normalizedDomain(_ url: URL) -> String? {
        url.host?.lowercased()
    }

    isolated deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

// MARK: - Suggestion list

struct CredentialSuggestionList: View {
    @ObservedObject var manager: CredentialManager

    static let rowHeight: CGFloat = 34
    static let verticalPadding: CGFloat = 6
    static let minimumWidth: CGFloat = 220

    static func height(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + verticalPadding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(manager.presentation?.usernames ?? [], id: \.self) { username in
                row(username)
                    .onTapGesture { manager.pick(username: username) }
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: 8, y: 2)
        .onHover { manager.pointerInsideList = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Saved passwords"))
    }

    private func row(_ username: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(username)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Save-password prompt

struct SavePasswordBanner: View {
    @ObservedObject var manager: CredentialManager

    var body: some View {
        if let prompt = manager.savePrompt {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                Text(manager.saveError ?? "\(prompt.isUpdate ? "Update" : "Save") password for \(prompt.username) on \(prompt.domain)?")
                    .lineLimit(1)
                Button(prompt.isUpdate ? "Update" : "Save") { manager.acceptSavePrompt() }
                    .keyboardShortcut(.defaultAction)
                Button("Not Now") { manager.dismissSavePrompt() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thinMaterial, in: Capsule())
            .shadow(radius: 6)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }
}
