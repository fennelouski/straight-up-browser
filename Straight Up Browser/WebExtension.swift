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
import CryptoKit

enum ExtensionIntegrityError: LocalizedError {
    case notDirectory
    case symbolicLink(URL)
    case unsupportedItem(URL)

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            String(localized: "The selected extension location is not a directory.")
        case .symbolicLink(let url):
            String(localized: "Extensions containing symbolic links aren’t supported: \(url.lastPathComponent)")
        case .unsupportedItem(let url):
            String(localized: "The extension contains an unsupported file type: \(url.lastPathComponent)")
        }
    }
}

enum ExtensionIntegrityFingerprint {
    static func fingerprint(of directory: URL) throws -> String {
        let root = directory.standardizedFileURL
        let rootValues = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true else {
            throw ExtensionIntegrityError.notDirectory
        }
        if rootValues.isSymbolicLink == true {
            throw ExtensionIntegrityError.symbolicLink(root)
        }

        var files: [URL] = []
        try collectFiles(in: root, into: &files)
        files.sort {
            relativePath(for: $0, root: root) < relativePath(for: $1, root: root)
        }

        var hasher = SHA256()
        for file in files {
            let relative = Data(relativePath(for: file, root: root).utf8)
            hasher.update(data: lengthPrefix(relative.count))
            hasher.update(data: relative)
            let fileSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            hasher.update(data: lengthPrefix(fileSize))
            try update(&hasher, withContentsOf: file)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func collectFiles(in directory: URL, into files: inout [URL]) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        for item in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) {
            let values = try item.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                throw ExtensionIntegrityError.symbolicLink(item)
            } else if values.isDirectory == true {
                try collectFiles(in: item, into: &files)
            } else if values.isRegularFile == true {
                files.append(item)
            } else {
                throw ExtensionIntegrityError.unsupportedItem(item)
            }
        }
    }

    private static func relativePath(for file: URL, root: URL) -> String {
        String(file.path.dropFirst(root.path.count + 1))
    }

    private static func update(_ hasher: inout SHA256, withContentsOf file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
    }

    private static func lengthPrefix(_ value: Int) -> Data {
        var bigEndian = UInt64(value).bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}

enum ExtensionPermissionPolicy {
    static func visibleTabIds(
        _ ids: [UUID],
        privateAccessAllowed: Bool,
        isPrivate: (UUID) -> Bool
    ) -> [UUID] {
        privateAccessAllowed ? ids : ids.filter { !isPrivate($0) }
    }

    static func approved<Value: Hashable>(
        _ requested: Set<Value>,
        userAllowed: Bool
    ) -> Set<Value> {
        userAllowed ? requested : []
    }
}

// The bridge exposes one normal and one private extension window so WebKit can
// enforce private-data access independently even though the app can show both
// session kinds in one native window.
@MainActor
final class WebExtensionManager: NSObject {
    static let shared = WebExtensionManager()

    // One controller for the whole app, attached to every WKWebView's config.
    // Must exist before a web view is created — a controller can't be added to
    // a web view after the fact. Inert until an extension is loaded.
    let controller = WKWebExtensionController()

    private var contexts: [WKWebExtensionContext] = []
    private var extTabs: [UUID: ExtTab] = [:]
    private lazy var normalWindow = ExtWindow(manager: self, privateMode: false)
    private lazy var privateWindow = ExtWindow(manager: self, privateMode: true)

    // Whichever window's WebViewManager most recently created a web view; the
    // bridge answers tabs.query / activeTab from this one.
    private weak var activeManager: WebViewManager?

    private let lastPathKey = "loadedExtensionPath"
    private let approvalRecordsKey = "approvedExtensionRecords"
    private let legacyApprovedScopesKey = "approvedExtensionScopes"
    private let privateAccessKey = "extensionsPrivateAccess"

    private struct ApprovalRecord: Codable {
        let scopes: [String]
        let fingerprint: String
    }

    private override init() {
        super.init()
        controller.delegate = self
    }

    var hasExtensions: Bool { !contexts.isEmpty }
    var allowsPrivateAccess: Bool {
        UserDefaults.standard.bool(forKey: privateAccessKey)
    }

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
                let extensionDirectory = directory.standardizedFileURL
                let fingerprint = try ExtensionIntegrityFingerprint.fingerprint(
                    of: extensionDirectory
                )
                let ext = try await WKWebExtension(
                    resourceBaseURL: extensionDirectory
                )
                let context = WKWebExtensionContext(for: ext)

                let scopes = requestedScopeDescriptions(for: ext)
                let alreadyApproved = previouslyApproved(
                    scopes,
                    fingerprint: fingerprint,
                    at: extensionDirectory
                )
                var approvalDetails = scopes
                if hasStoredApproval(at: extensionDirectory), !alreadyApproved {
                    approvalDetails.insert(
                        String(
                            localized: "The extension’s files or requested access changed since you last approved it."
                        ),
                        at: 0
                    )
                }
                guard alreadyApproved
                        || confirmAccess(
                            title: String(localized: "Allow \(ext.displayName ?? "this extension")?"),
                            details: approvalDetails
                        )
                else {
                    Logger.log("Extension permission denied: \(ext.displayName ?? "?")", type: "WebExtension")
                    return
                }

                // Grant exactly the manifest's required permissions and hosts.
                // Optional/runtime scopes go through the delegate prompts below.
                for permission in ext.requestedPermissions {
                    context.setPermissionStatus(.grantedExplicitly, for: permission)
                }
                for pattern in ext.requestedPermissionMatchPatterns {
                    context.setPermissionStatus(.grantedExplicitly, for: pattern)
                }
                context.hasAccessToPrivateData = allowsPrivateAccess

                try controller.load(context)
                contexts.append(context)
                rememberApproval(
                    scopes,
                    fingerprint: fingerprint,
                    at: extensionDirectory
                )
                if remember {
                    UserDefaults.standard.set(
                        extensionDirectory.path,
                        forKey: lastPathKey
                    )
                }
                Logger.log("Loaded extension: \(ext.displayName ?? "?")", type: "WebExtension")
            } catch {
                Logger.log("Extension load failed: \(error)", type: "WebExtension")
                let alert = NSAlert(error: error)
                alert.messageText = String(localized: "Couldn't load extension")
                alert.runModal()
            }
        }
    }

    private func requestedScopeDescriptions(for ext: WKWebExtension) -> [String] {
        let permissions = ext.requestedPermissions
            .map { "Permission: \(String(describing: $0))" }
        let hosts = ext.requestedPermissionMatchPatterns
            .map { "Website: \($0.string)" }
        return (permissions + hosts).sorted()
    }

    private func previouslyApproved(
        _ scopes: [String],
        fingerprint: String,
        at directory: URL
    ) -> Bool {
        guard let record = approvalRecords()[directory.path] else { return false }
        return record.scopes == scopes && record.fingerprint == fingerprint
    }

    private func hasStoredApproval(at directory: URL) -> Bool {
        let legacy = UserDefaults.standard
            .dictionary(forKey: legacyApprovedScopesKey)?[directory.path] as? [String]
        return approvalRecords()[directory.path] != nil || legacy != nil
    }

    private func rememberApproval(
        _ scopes: [String],
        fingerprint: String,
        at directory: URL
    ) {
        var records = approvalRecords()
        records[directory.path] = ApprovalRecord(
            scopes: scopes,
            fingerprint: fingerprint
        )
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: approvalRecordsKey)
        }
        // Scope-only records are intentionally not migrated: their lack of an
        // integrity hash forces one fresh approval after this upgrade.
        UserDefaults.standard.removeObject(forKey: legacyApprovedScopesKey)
    }

    private func approvalRecords() -> [String: ApprovalRecord] {
        guard let data = UserDefaults.standard.data(forKey: approvalRecordsKey),
              let records = try? JSONDecoder().decode(
                [String: ApprovalRecord].self,
                from: data
              ) else { return [:] }
        return records
    }

    private func confirmAccess(title: String, details: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = details.isEmpty
            ? String(localized: "This extension requests no additional browser or website access.")
            : details.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Deny"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func presentManagementPanel() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Extensions")
        let names = contexts.map { $0.webExtension.displayName ?? "Unnamed Extension" }
        alert.informativeText = names.isEmpty
            ? String(localized: "No extensions are loaded.")
            : names.joined(separator: "\n")

        let privateToggle = NSButton(
            checkboxWithTitle: String(localized: "Allow extensions in private tabs"),
            target: nil,
            action: nil
        )
        privateToggle.state = allowsPrivateAccess ? .on : .off
        alert.accessoryView = privateToggle
        alert.addButton(withTitle: String(localized: "Done"))
        alert.addButton(withTitle: String(localized: "Remove All"))

        let response = alert.runModal()
        let allowPrivate = privateToggle.state == .on
        UserDefaults.standard.set(allowPrivate, forKey: privateAccessKey)
        for context in contexts {
            context.hasAccessToPrivateData = allowPrivate
        }

        if response == .alertSecondButtonReturn {
            for context in contexts {
                _ = try? controller.unload(context)
            }
            contexts.removeAll()
            extTabs.removeAll()
            UserDefaults.standard.removeObject(forKey: lastPathKey)
            UserDefaults.standard.removeObject(forKey: approvalRecordsKey)
            UserDefaults.standard.removeObject(forKey: legacyApprovedScopesKey)
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
        let tab = currentActiveTab(for: context)
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

    fileprivate func currentTabs(privateMode: Bool, for context: WKWebExtensionContext) -> [ExtTab] {
        guard !privateMode || context.hasAccessToPrivateData else { return [] }
        let ids = activeManager?.liveTabIds ?? []
        let visibleIds = ExtensionPermissionPolicy.visibleTabIds(
            ids,
            privateAccessAllowed: context.hasAccessToPrivateData,
            isPrivate: isPrivateTab
        )
        return visibleIds.filter { isPrivateTab($0) == privateMode }.map(tab(for:))
    }

    fileprivate func currentActiveTab(for context: WKWebExtensionContext) -> ExtTab? {
        guard let id = activeManager?.activeTabId,
              !isPrivateTab(id) || context.hasAccessToPrivateData else { return nil }
        return tab(for: id)
    }

    fileprivate func window(privateMode: Bool) -> ExtWindow {
        privateMode ? privateWindow : normalWindow
    }

    fileprivate func window(forTab id: UUID, context: WKWebExtensionContext) -> ExtWindow? {
        let privateMode = isPrivateTab(id)
        guard !privateMode || context.hasAccessToPrivateData else { return nil }
        return window(privateMode: privateMode)
    }

    fileprivate func isPrivateTab(_ id: UUID) -> Bool {
        activeManager?.isPrivateTab(id) ?? false
    }

    fileprivate func webView(forTab id: UUID, context: WKWebExtensionContext) -> WKWebView? {
        guard !isPrivateTab(id) || context.hasAccessToPrivateData else { return nil }
        return activeManager?.existingWebView(for: id)
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
        guard hasExtensions,
              (!isPrivateTab(id) || allowsPrivateAccess),
              extTabs[id] == nil else { return }
        controller.didOpenTab(tab(for: id))
    }

    func tabClosed(_ id: UUID) {
        guard hasExtensions, let t = extTabs.removeValue(forKey: id) else { return }
        controller.didCloseTab(t, windowIsClosing: false)
    }

    func activeTabChanged(to id: UUID?, from previous: UUID?) {
        guard hasExtensions, let id,
              !isPrivateTab(id) || allowsPrivateAccess else { return }
        controller.didActivateTab(tab(for: id), previousActiveTab: previous.map(tab(for:)))
    }
}

// MARK: - Controller delegate

extension WebExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        var windows: [any WKWebExtensionWindow] = [window(privateMode: false)]
        if context.hasAccessToPrivateData {
            windows.append(window(privateMode: true))
        }
        return windows
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let id = activeManager?.activeTabId else {
            return window(privateMode: false)
        }
        return window(forTab: id, context: context)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let allowed = confirmAccess(
            title: String(localized: "Allow additional extension permissions?"),
            details: permissions.map { String(describing: $0) }.sorted()
        )
        completionHandler(
            ExtensionPermissionPolicy.approved(permissions, userAllowed: allowed),
            nil
        )
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let allowed = confirmAccess(
            title: String(localized: "Allow extension website access?"),
            details: urls.map(\.absoluteString).sorted()
        )
        completionHandler(
            ExtensionPermissionPolicy.approved(urls, userAllowed: allowed),
            nil
        )
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let allowed = confirmAccess(
            title: String(localized: "Allow extension website access?"),
            details: matchPatterns.map(\.string).sorted()
        )
        completionHandler(
            ExtensionPermissionPolicy.approved(matchPatterns, userAllowed: allowed),
            nil
        )
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
    private let privateMode: Bool

    init(manager: WebExtensionManager, privateMode: Bool) {
        self.manager = manager
        self.privateMode = privateMode
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        manager?.currentTabs(privateMode: privateMode, for: context) ?? []
    }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let tab = manager?.currentActiveTab(for: context),
              manager?.isPrivateTab(tab.tabIdentity) == privateMode else { return nil }
        return tab
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { privateMode }
}

// MARK: - Bridge: a tab, backed by its WKWebView

@MainActor
final class ExtTab: NSObject, WKWebExtensionTab {
    private let id: UUID
    private weak var manager: WebExtensionManager?
    init(id: UUID, manager: WebExtensionManager) { self.id = id; self.manager = manager }

    private func allowedWebView(for context: WKWebExtensionContext) -> WKWebView? {
        manager?.webView(forTab: id, context: context)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        manager?.window(forTab: id, context: context)
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        allowedWebView(for: context)
    }
    func url(for context: WKWebExtensionContext) -> URL? {
        allowedWebView(for: context)?.url
    }
    func title(for context: WKWebExtensionContext) -> String? {
        allowedWebView(for: context)?.title
    }
    func isSelected(for context: WKWebExtensionContext) -> Bool {
        id == manager?.currentActiveTab(for: context)?.tabIdentity
    }

    // Navigation the extension may drive (trivial via the web view).
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        allowedWebView(for: context)?.load(URLRequest(url: url)); completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin {
            allowedWebView(for: context)?.reloadFromOrigin()
        } else {
            allowedWebView(for: context)?.reload()
        }
        completionHandler(nil)
    }
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        allowedWebView(for: context)?.goBack(); completionHandler(nil)
    }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        allowedWebView(for: context)?.goForward(); completionHandler(nil)
    }

    fileprivate var tabIdentity: UUID { id }
}
