//
//  CredentialAutofillBadge.swift
//  Straight Up Browser
//
//  A small key badge over focused username/password fields, so filling a
//  saved credential is one click instead of right-click → AutoFill →
//  Passwords…. The browser never reads passwords itself — sandboxed apps
//  can't reach Safari/iCloud Keychain internet passwords, and shouldn't be
//  able to — so this hands off to WebKit's own native contextual menu, the
//  same one a real right-click builds, just summoned at the field and jumped
//  straight to the "AutoFill" submenu.
//

import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif
import WebKit

@MainActor
final class CredentialAutofillBadge: ObservableObject {
    struct Presentation: Equatable {
        let tabID: UUID
        /// AppKit window coordinates, origin bottom-left — same convention as
        /// AutofillManager.Presentation.fieldRect.
        let fieldRect: CGRect
    }

    @Published private(set) var presentation: Presentation?
    /// Set while the pointer is over the badge, so the field's blur (which
    /// fires on mouseDown, before the click completes) doesn't dismiss it out
    /// from under the click. Same trick AutofillManager uses for its list.
    @Published var pointerInsideBadge = false

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
            guard let self, !self.pointerInsideBadge else { return }
            self.presentation = nil
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

    private func fieldFocused(_ note: Notification) {
        guard let tabID = note.userInfo?["tabID"] as? UUID,
              let rect = note.userInfo?["rect"] as? CGRect else { return }
        presentation = Presentation(tabID: tabID, fieldRect: rect)
    }

    /// Builds the exact contextual menu a right-click at the field would
    /// build, then opens straight to its "AutoFill" item — WebKit still
    /// decides what's in it (nothing if the domain has no saved credential),
    /// and the user still clicks the real "Passwords…" item themselves.
    func activate() {
        #if canImport(AppKit)
        guard let presentation,
              let webView = webViewManager?.getWebView(for: presentation.tabID),
              let window = webView.window else { return }
        let windowPoint = CGPoint(x: presentation.fieldRect.midX, y: presentation.fieldRect.midY)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let nativeMenu = webView.menu(for: event) else { return }

        let target = Self.autofillSubmenu(in: nativeMenu) ?? nativeMenu
        let viewPoint = webView.convert(windowPoint, from: nil)
        target.popUp(positioning: nil, at: viewPoint, in: webView)
        #endif
    }

    #if canImport(AppKit)
    private static func autofillSubmenu(in menu: NSMenu) -> NSMenu? {
        menu.items.first { $0.title.localizedCaseInsensitiveContains("autofill") }?.submenu
    }
    #endif

    isolated deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

// MARK: - The badge

struct CredentialAutofillBadgeView: View {
    @ObservedObject var badge: CredentialAutofillBadge

    static let size: CGFloat = 20

    var body: some View {
        Button(action: badge.activate) {
            Image(systemName: "key.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.size, height: Self.size)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .shadow(radius: 3, y: 1)
        .onHover { badge.pointerInsideBadge = $0 }
        .accessibilityLabel(Text("AutoFill Password"))
    }
}
