import Foundation
import WebKit

/// Prepared before isolated scene content is constructed. The rule is installed
/// in every configuration before any page can load, including subresources.
@MainActor enum BrowserProfileWebKit {
    private static var preparation: Task<Void, Error>?
    private static var rule: WKContentRuleList?
    private static let profileStores = BrowserTestWebKitStores()

    static func prepare() async throws {
        guard let paths = BrowserProfile.paths else { return }
        if let preparation { return try await preparation.value }
        let task = Task { @MainActor in
            guard let store = WKContentRuleListStore(url: paths.webKitRules) else {
                throw BrowserTestProfileError.unsafeDirectory
            }
            let fileRoots = [paths.root, Bundle.main.bundleURL.resolvingSymlinksInPath()].map {
                NSRegularExpression.escapedPattern(for: $0.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")
            }
            // WebKit content rules support a smaller grammar than Foundation
            // regular expressions: disjunction (|) is rejected. Use one allow
            // rule per host/root. The slash after each host prevents lookalikes.
            let allow = ["^https?://localhost(:[0-9]+)?/",
                         "^https?://127\\.0\\.0\\.1(:[0-9]+)?/",
                         "^https?://\\[::1\\](:[0-9]+)?/",
                         "^about:blank$", "^data:"] + fileRoots.map { "^" + $0 }
            let rules: [[String: Any]] = [
                ["trigger": ["url-filter": ".*"], "action": ["type": "block"]]
            ] + allow.map {
                ["trigger": ["url-filter": $0], "action": ["type": "ignore-previous-rules"]]
            }
            let data = try JSONSerialization.data(withJSONObject: rules)
            let encoded = String(decoding: data, as: UTF8.self)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.compileContentRuleList(forIdentifier: "isolated-fixtures-v1", encodedContentRuleList: encoded) { list, error in
                    if let list {
                        rule = list
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? BrowserTestProfileError.unsafeDirectory)
                    }
                }
            }
            try BrowserProfile.writeReadyManifest()
        }
        preparation = task
        try await task.value
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        guard BrowserProfile.isIsolated else { return configuration }
        guard let rule else { fatalError("Isolated WebKit was not prepared; startup refused.") }
        configuration.websiteDataStore = dataStore()
        // Local HTML/native-controls fixtures suffice for isolated acceptance.
        // Disable page scripts so fixture content cannot invoke WebAuthn or other
        // OS-backed credential APIs. Native isolated-world DOM tooling is separate.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(rule)
        return configuration
    }

    static func dataStore(container: UUID? = nil) -> WKWebsiteDataStore {
        guard BrowserProfile.isIsolated else {
            return container.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
        }
        return profileStores.store(container: container)
    }

    static func restoreContainment(on controller: WKUserContentController) {
        guard BrowserProfile.isIsolated else { return }
        guard let rule else { fatalError("Isolated WebKit containment unavailable.") }
        controller.add(rule)
    }
}

/// Testable store ownership, independent of process-global profile selection.
/// No default or identifier-backed persistent store is constructed here.
@MainActor final class BrowserTestWebKitStores {
    private var normal: WKWebsiteDataStore?
    private var containers: [UUID: WKWebsiteDataStore] = [:]

    func store(container: UUID? = nil) -> WKWebsiteDataStore {
        if let container {
            if let store = containers[container] { return store }
            let store = WKWebsiteDataStore.nonPersistent()
            containers[container] = store
            return store
        }
        if let normal { return normal }
        let store = WKWebsiteDataStore.nonPersistent()
        normal = store
        return store
    }
}
