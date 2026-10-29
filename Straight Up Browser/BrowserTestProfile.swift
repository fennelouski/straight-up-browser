import Foundation
import CryptoKit
import Darwin

/// Explicit opt-in only. XCTest environment variables keep their existing behavior.
nonisolated enum BrowserTestProfileSelection: Equatable, Sendable {
    case production
    case isolated(String)

    static let flag = "-isolatedTestProfile"

    static func parse(_ arguments: [String]) throws -> Self {
        let matches = arguments.indices.filter { arguments[$0].hasPrefix(flag) }
        guard !matches.isEmpty else { return .production }
        guard matches.count == 1, let index = matches.first,
              arguments[index] == flag, arguments.indices.contains(index + 1) else {
            throw BrowserTestProfileError.invalidArguments
        }
        let identifier = arguments[index + 1]
        guard (1...64).contains(identifier.utf8.count),
              identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              identifier.first != "-" else { throw BrowserTestProfileError.invalidArguments }
        return .isolated(identifier)
    }
}

nonisolated enum BrowserTestProfileError: Error {
    case invalidArguments, unsafeDirectory, unavailableDefaults, profileInUse
}

nonisolated struct BrowserTestProfilePaths: Codable, Equatable, Sendable {
    let identifier: String
    let root: URL
    let defaultsSuite: String
    var support: URL { root.appendingPathComponent("Application Support", isDirectory: true) }
    var caches: URL { root.appendingPathComponent("Caches", isDirectory: true) }
    var documents: URL { root.appendingPathComponent("Documents", isDirectory: true) }
    var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    var webKitRules: URL { root.appendingPathComponent("WebKit Rules", isDirectory: true) }
    var manifest: URL { root.appendingPathComponent("isolation-manifest.json") }

    var manifestStorage: [String: String] {
        ["root": root.path, "defaultsSuite": defaultsSuite, "applicationSupport": support.path,
         "caches": caches.path, "documents": documents.path, "downloads": downloads.path,
         "webKitRules": webKitRules.path, "manifest": manifest.path,
         "history": support.appendingPathComponent("Straight Up Browser/browsing-history.json").path,
         "downloadHistory": support.appendingPathComponent("Straight Up Browser/file-history.json").path,
         "theme": support.appendingPathComponent("Theme Authority").path,
         "cliNamespace": support.appendingPathComponent("Straight Up Browser").path,
         "cliPipe": support.appendingPathComponent("Straight Up Browser/cli.pipe").path,
         "cliResponses": support.appendingPathComponent("Straight Up Browser/responses").path]
    }

    func contains(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == root.path || resolved.hasPrefix(root.path + "/")
    }

    func allowsNavigation(_ url: URL, bundleRoot: URL) -> Bool {
        if url.absoluteString == "about:blank" || url.scheme == "data" { return true }
        if url.isFileURL {
            let resolved = url.resolvingSymlinksInPath().path
            return contains(url) || resolved.hasPrefix(bundleRoot.resolvingSymlinksInPath().path + "/")
        }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil
    }

    init(identifier: String, temporaryDirectory: URL) throws {
        guard try BrowserTestProfileSelection.parse(["Browser", BrowserTestProfileSelection.flag, identifier]) == .isolated(identifier) else {
            throw BrowserTestProfileError.invalidArguments
        }
        self.identifier = identifier
        root = temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Browser Isolated Test Profiles", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        defaultsSuite = "com.nathanfennel.Browser.IsolatedTest." + identifier
    }
}

/// UserDefaults is thread-safe. The immutable context owns one private suite and
/// an exclusive profile lock; a failed private resource never selects production.
nonisolated final class BrowserTestProfileContext: @unchecked Sendable {
    let paths: BrowserTestProfilePaths
    let defaults: UserDefaults
    private let lockDescriptor: Int32

    init(paths: BrowserTestProfilePaths,
         defaultsFactory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }) throws {
        self.paths = paths
        let manager = FileManager.default
        // Each acceptance run gets a new identifier. Never resume an old on-disk
        // graph which might contain symlinks or stale paths supplied by fixtures.
        guard !manager.fileExists(atPath: paths.root.path) else { throw BrowserTestProfileError.profileInUse }
        for directory in [paths.root.deletingLastPathComponent(), paths.root, paths.support,
                          paths.caches, paths.documents, paths.downloads, paths.webKitRules] {
            if !manager.fileExists(atPath: directory.path) {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            }
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
                  info.st_mode & 0o077 == 0 else { throw BrowserTestProfileError.unsafeDirectory }
        }
        let lock = paths.root.appendingPathComponent("profile.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw BrowserTestProfileError.unsafeDirectory }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(descriptor); throw BrowserTestProfileError.unsafeDirectory
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw BrowserTestProfileError.profileInUse
        }
        guard let defaults = defaultsFactory(paths.defaultsSuite) else {
            close(descriptor); throw BrowserTestProfileError.unavailableDefaults
        }
        guard (defaults.persistentDomain(forName: paths.defaultsSuite) ?? [:]).isEmpty else {
            close(descriptor); throw BrowserTestProfileError.profileInUse
        }
        self.defaults = defaults
        lockDescriptor = descriptor
    }

    deinit { close(lockDescriptor) }

    func writeManifest(ready: Bool) throws {
        struct Manifest: Encodable {
            let schema = 1
            let mode = "isolated-native-test"
            let ready: Bool
            let identifier: String
            let pid: Int32
            let bundleIdentifier: String?
            let version: String?
            let build: String?
            let executableSHA256: String?
            let storage: [String: String]
            let nativeNetwork = "disabled, including loopback URLSession; page fixtures use WebKit"
            let webKit = "nonpersistent; loopback/bundled/profile fixtures only"
            let externalIntegrations = "disabled"
            let keychain = "disabled; no reads/writes/key creation"
            let cloud = "disabled; local documents only"
            let ipc = "disabled; private namespace reserved"
            let swiftData = "in-memory; CloudKit none"
            let pageJavaScript = "disabled; native isolated-world scripts only"
            let appClipboardActions = "private named pasteboard; OS text-editing services excluded from acceptance"
            let externalFiles = "choosers/import/export/external app handoffs disabled"
        }
        let executableHash = try Bundle.main.executableURL.map {
            SHA256.hash(data: try Data(contentsOf: $0)).map { String(format: "%02x", $0) }.joined()
        }
        let manifest = Manifest(ready: ready, identifier: paths.identifier, pid: getpid(),
            bundleIdentifier: Bundle.main.bundleIdentifier,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            executableSHA256: executableHash, storage: paths.manifestStorage)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: paths.manifest, options: .atomic)
    }
}

/// Every app-owned default/store origin resolves here before touching production.
/// Pure selection/path/context types above let tests inject fixtures without
/// changing this process-global selection or UserDefaults.standard.
nonisolated enum BrowserProfile {
    private static let context: BrowserTestProfileContext? = {
        do {
            switch try BrowserTestProfileSelection.parse(ProcessInfo.processInfo.arguments) {
            case .production: return nil
            case .isolated(let identifier):
                let paths = try BrowserTestProfilePaths(identifier: identifier,
                    temporaryDirectory: FileManager.default.temporaryDirectory)
                let context = try BrowserTestProfileContext(paths: paths)
                context.defaults.register(defaults: ["acceptedEULAVersion": 1,
                    "globalOmnibarHotkey": "off", "tabSyncEnabled": false,
                    "defaultBrowserPromptEnabled": false, "downloadsFolder": paths.downloads.path])
                try context.writeManifest(ready: false)
                return context
            }
        } catch {
            // No modal, defaults access, retry or production fallback on failure.
            FileHandle.standardError.write(Data("Isolated test profile unavailable; startup refused.\n".utf8))
            exit(78)
        }
    }()

    static var isIsolated: Bool { context != nil }
    static var paths: BrowserTestProfilePaths? { context?.paths }
    static var allowsExternalIntegrations: Bool { !isIsolated }
    static var defaults: UserDefaults { context?.defaults ?? UserDefaults.standard }
    static func defaults(_ requested: @autoclosure () -> UserDefaults) -> UserDefaults {
        context?.defaults ?? requested()
    }
    static var applicationSupportURLs: [URL] {
        if let paths { return [paths.support] }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    }
    static var cacheURLs: [URL] {
        if let paths { return [paths.caches] }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
    }
    static var documentURLs: [URL] {
        if let paths { return [paths.documents] }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    }
    static var downloadURLs: [URL] {
        if let paths { return [paths.downloads] }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
    }
    static func writeReadyManifest() throws { try context?.writeManifest(ready: true) }
    static func invalidateManifest() { try? context?.writeManifest(ready: false) }
    static func allowsFileAccess(_ url: URL) -> Bool { paths?.contains(url) ?? true }
    static func windowTitle(_ base: String) -> String {
        guard let paths else { return base }
        return base + " — ISOLATED [" + paths.identifier + "]"
    }

    static func allowsNavigation(_ url: URL) -> Bool {
        guard let paths else { return true }
        return paths.allowsNavigation(url, bundleRoot: Bundle.main.bundleURL)
    }
}
