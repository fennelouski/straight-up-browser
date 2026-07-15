//
//  WebExtension.swift
//  Straight Up Browser
//
//  Adopts WKWebExtension (macOS 15.4+) so a user can load a browser extension
//  — e.g. a password manager like Bitwarden — and have its content scripts run
//  in every tab, plus open its toolbar popup (the vault/unlock UI).
//
//  Direct iCloud Keychain / Apple Passwords autofill is Safari-private and not
//  available to third-party WKWebView browsers; this is the supported route to
//  password autofill: the user brings their own extension.
//

import WebKit
import AppKit

// ponytail: v1 models the whole app as ONE extension "window" that owns every
// live tab and reports the frontmost one as active. Per-NSWindow tab sets are
// the upgrade path if an extension ever needs true multi-window fidelity.
@MainActor
final class WebExtensionManager: NSObject {
    static let shared = WebExtensionManager()

    // One controller for the whole app, attached to every WKWebView's config.
    // Must exist before a web view is created — a controller can't be added to
    // a web view after the fact. Inert until an extension is loaded.
    let controller = WKWebExtensionController()

    private var contexts: [WKWebExtensionContext] = []
    private var extTabs: [UUID: ExtTab] = [:]
    private lazy var extWindow = ExtWindow(manager: self)

    // Whichever window's WebViewManager most recently created a web view; the
    // bridge answers tabs.query / activeTab from this one.
    private weak var activeManager: WebViewManager?

    private let lastPathKey = "loadedExtensionPath"

    private override init() {
        super.init()
        controller.delegate = self
    }

    var hasExtensions: Bool { !contexts.isEmpty }

    /// Called by WebViewManager as it creates web views. Gives the bridge a
    /// live manager to read tabs from, and reloads the last-used extension once
    /// there's somewhere to host it.
    func register(_ manager: WebViewManager) {
        activeManager = manager
        if contexts.isEmpty, let path = UserDefaults.standard.string(forKey: lastPathKey) {
            loadExtension(at: URL(fileURLWithPath: path), remember: false)
        }
    }

    // MARK: - Loading

    /// Pick an unpacked extension folder (the directory containing manifest.json).
    // ponytail: unpacked-from-folder, not a bundled app-extension target — no
    // extra Xcode target, and it's how you'd dev-load Bitwarden/uBlock. Package
    // a Safari Web Extension target if you later want to ship one built in.
    func presentLoadPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an unpacked extension folder (the one containing manifest.json)."
        panel.prompt = "Load"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadExtension(at: url)
    }

    func loadExtension(at directory: URL, remember: Bool = true) {
        Task {
            do {
                let ext = try await WKWebExtension(resourceBaseURL: directory)
                let context = WKWebExtensionContext(for: ext)

                // Grant every API permission it asks for plus access to all
                // hosts, so a password manager can read login forms everywhere.
                // That is the whole point; v1 trusts the extension the user
                // deliberately chose rather than gating each grant behind a prompt.
                for permission in ext.requestedPermissions {
                    context.setPermissionStatus(.grantedExplicitly, for: permission)
                }
                context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())

                try controller.load(context)
                contexts.append(context)
                if remember { UserDefaults.standard.set(directory.path, forKey: lastPathKey) }
                Logger.log("Loaded extension: \(ext.displayName ?? "?")", type: "WebExtension")
            } catch {
                Logger.log("Extension load failed: \(error)", type: "WebExtension")
                let alert = NSAlert(error: error)
                alert.messageText = String(localized: "Couldn't load extension")
                alert.runModal()
            }
        }
    }

    // MARK: - Popup

    /// Open the first loaded extension's toolbar popup (its unlock/vault UI).
    /// macOS hands us a ready-made NSPopover via the action.
    func showPopup() {
        guard let context = contexts.first else {
            Logger.log("No extension loaded", type: "WebExtension")
            return
        }
        let tab = currentActiveTab()
        if let popover = context.action(for: tab)?.popupPopover {
            present(popover)
        } else {
            // No popup (e.g. an action that just toggles) — run its default.
            context.performAction(for: tab)
        }
    }

    private func present(_ popover: NSPopover) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let anchor = window.contentView else { return }
        // Anchor to the top-trailing corner, where a toolbar button would sit.
        let rect = NSRect(x: anchor.bounds.maxX - 24, y: anchor.bounds.maxY - 8, width: 8, height: 8)
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }

    // MARK: - Tab bridge (reads live state from the active WebViewManager)

    fileprivate func currentTabs() -> [ExtTab] {
        (activeManager?.liveTabIds ?? []).map(tab(for:))
    }

    fileprivate func currentActiveTab() -> ExtTab? {
        activeManager?.activeTabId.map(tab(for:))
    }

    fileprivate func window() -> ExtWindow { extWindow }

    fileprivate func webView(forTab id: UUID) -> WKWebView? {
        activeManager?.existingWebView(for: id)
    }

    private func tab(for id: UUID) -> ExtTab {
        if let existing = extTabs[id] { return existing }
        let t = ExtTab(id: id, manager: self)
        extTabs[id] = t
        return t
    }

    // MARK: - Lifecycle notifications (called by WebViewManager)

    // Idempotent: a tab reactivated after a memory unload re-creates its web
    // view but is not a new tab, so only announce genuinely-new ids.
    func tabOpened(_ id: UUID) {
        guard hasExtensions, extTabs[id] == nil else { return }
        controller.didOpenTab(tab(for: id))
    }

    func tabClosed(_ id: UUID) {
        guard hasExtensions, let t = extTabs.removeValue(forKey: id) else { return }
        controller.didCloseTab(t, windowIsClosing: false)
    }

    func activeTabChanged(to id: UUID?, from previous: UUID?) {
        guard hasExtensions, let id else { return }
        controller.didActivateTab(tab(for: id), previousActiveTab: previous.map(tab(for:)))
    }
}

// MARK: - Controller delegate

extension WebExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window()]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window()
    }

    // Auto-grant optional permissions the extension asks for at runtime — same
    // trust stance as load time.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let popover = action.popupPopover { present(popover) }
        completionHandler(nil)
    }

    // Route the extension's "open a tab" through the app's existing new-tab path.
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        if let url = configuration.url {
            NotificationCenter.default.post(name: .browserOpenURL, object: nil,
                                            userInfo: ["url": url.absoluteString, "newTab": true])
        } else {
            NotificationCenter.default.post(name: .browserNewTab, object: nil)
        }
        // ponytail: don't hand back a tab object yet — the extension just won't
        // track this specific tab. Wire a real handoff if that matters.
        completionHandler(nil, nil)
    }
}

// MARK: - Bridge: one window that owns every live tab

@MainActor
final class ExtWindow: NSObject, WKWebExtensionWindow {
    private weak var manager: WebExtensionManager?
    init(manager: WebExtensionManager) { self.manager = manager }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        manager?.currentTabs() ?? []
    }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        manager?.currentActiveTab()
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
}

// MARK: - Bridge: a tab, backed by its WKWebView

@MainActor
final class ExtTab: NSObject, WKWebExtensionTab {
    private let id: UUID
    private weak var manager: WebExtensionManager?
    init(id: UUID, manager: WebExtensionManager) { self.id = id; self.manager = manager }

    private var webView: WKWebView? { manager?.webView(forTab: id) }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { manager?.window() }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func url(for context: WKWebExtensionContext) -> URL? { webView?.url }
    func title(for context: WKWebExtensionContext) -> String? { webView?.title }
    func isSelected(for context: WKWebExtensionContext) -> Bool { id == manager?.currentActiveTab()?.tabIdentity }

    // Navigation the extension may drive (trivial via the web view).
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.load(URLRequest(url: url)); completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
        completionHandler(nil)
    }
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goBack(); completionHandler(nil)
    }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goForward(); completionHandler(nil)
    }

    fileprivate var tabIdentity: UUID { id }
}
