import Foundation
import Testing
@testable import Browser

struct BrowserTestProfileTests {
    @Test func noFlagAndOrdinaryUnitEnvironmentKeepProductionSelection() throws {
        #expect(try BrowserTestProfileSelection.parse(["Browser", "-uiTesting"]) == .production)
        #expect(!BrowserProfile.isIsolated)
        #expect(BrowserProfile.defaults === UserDefaults.standard)
        #expect(BrowserProfileNetwork.session === URLSession.shared)
        let configuration = URLSessionConfiguration.ephemeral
        #expect(BrowserProfileNetwork.configuration(configuration) === configuration)
    }

    @Test(arguments: ["a", "acceptance-20261018_01", String(repeating: "x", count: 64)])
    func validIdentifiers(_ identifier: String) throws {
        #expect(try BrowserTestProfileSelection.parse(["Browser", "-isolatedTestProfile", identifier]) == .isolated(identifier))
    }

    @Test(arguments: ["", "..", "a/b", "a\\b", "a b", "-flag", "é", String(repeating: "x", count: 65)])
    func unsafeIdentifiersFailClosed(_ identifier: String) {
        #expect(throws: BrowserTestProfileError.self) {
            try BrowserTestProfileSelection.parse(["Browser", "-isolatedTestProfile", identifier])
        }
    }

    @Test(arguments: [["Browser", "-isolatedTestProfile"],
                      ["Browser", "-isolatedTestProfile=one"],
                      ["Browser", "-isolatedTestProfile", "a", "-isolatedTestProfile", "b"]])
    func ambiguousFlagsFailClosed(_ arguments: [String]) {
        #expect(throws: BrowserTestProfileError.self) { try BrowserTestProfileSelection.parse(arguments) }
    }

    @Test func privatePathsCannotEscapeOrAliasProductionFixture() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let paths = try BrowserTestProfilePaths(identifier: "one-" + UUID().uuidString, temporaryDirectory: fixture.root)
        #expect(paths.contains(paths.downloads.appendingPathComponent("file.txt")))
        #expect(!paths.contains(paths.root.appendingPathComponent("../outside.txt")))
        #expect(!paths.contains(URL(string: "https://localhost/a")!))
        let context = try BrowserTestProfileContext(paths: paths)
        defer { context.defaults.removePersistentDomain(forName: paths.defaultsSuite) }
        let production = fixture.root.appendingPathComponent("production-sentinel")
        try Data("unchanged".utf8).write(to: production)
        let alias = paths.documents.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: production)
        #expect(!paths.contains(alias))
        context.defaults.set("private", forKey: "sentinel")
        #expect(try String(contentsOf: production, encoding: .utf8) == "unchanged")
    }

    @Test func privateContextLeavesOtherDefaultsSuiteUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let productionName = "BrowserProfileTests.ProductionFixture." + UUID().uuidString
        let production = try #require(UserDefaults(suiteName: productionName))
        defer { production.removePersistentDomain(forName: productionName) }
        production.set("unchanged", forKey: "sentinel")
        let paths = try BrowserTestProfilePaths(identifier: "private-" + UUID().uuidString, temporaryDirectory: fixture.root)
        defer { UserDefaults().removePersistentDomain(forName: paths.defaultsSuite) }
        let context = try BrowserTestProfileContext(paths: paths)
        context.defaults.set("changed privately", forKey: "sentinel")
        #expect(production.string(forKey: "sentinel") == "unchanged")
        #expect(context.defaults !== production)
        #expect(paths.defaultsSuite != productionName)
    }

    @Test func unavailablePrivateDefaultsNeverFallsBack() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let paths = try BrowserTestProfilePaths(identifier: "unavailable-" + UUID().uuidString, temporaryDirectory: fixture.root)
        #expect(throws: BrowserTestProfileError.self) {
            try BrowserTestProfileContext(paths: paths, defaultsFactory: { _ in nil })
        }
        #expect(!FileManager.default.fileExists(atPath: paths.manifest.path))
    }

    @Test func concurrentProfileOwnerIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let paths = try BrowserTestProfilePaths(identifier: "locked-" + UUID().uuidString, temporaryDirectory: fixture.root)
        let context = try BrowserTestProfileContext(paths: paths)
        _ = withExtendedLifetime(context) {
            #expect(throws: BrowserTestProfileError.self) { try BrowserTestProfileContext(paths: paths) }
        }
    }

    @Test func symlinkRootIsRejectedBeforeDefaultsFactory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let paths = try BrowserTestProfilePaths(identifier: "linked-" + UUID().uuidString, temporaryDirectory: fixture.root)
        try FileManager.default.createDirectory(at: paths.root.deletingLastPathComponent(), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: paths.root, withDestinationURL: fixture.root)
        var called = false
        #expect(throws: BrowserTestProfileError.self) {
            try BrowserTestProfileContext(paths: paths, defaultsFactory: { _ in called = true; return nil })
        }
        #expect(!called)
    }

    @Test func manifestBindsExecutableAndAllOwnedRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let paths = try BrowserTestProfilePaths(identifier: "manifest-" + UUID().uuidString, temporaryDirectory: fixture.root)
        let context = try BrowserTestProfileContext(paths: paths)
        try context.writeManifest(ready: false)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: paths.manifest)) as? [String: Any])
        #expect(json["ready"] as? Bool == false)
        #expect(json["mode"] as? String == "isolated-native-test")
        #expect((json["executableSHA256"] as? String)?.count == 64)
        let storage = try #require(json["storage"] as? [String: String])
        #expect(storage == paths.manifestStorage)
        for (key, path) in storage where key != "defaultsSuite" {
            #expect(paths.contains(URL(fileURLWithPath: path)))
        }
        #expect(json["keychain"] as? String == "disabled; no reads/writes/key creation")
    }

    @Test func isolatedNativeSessionHasNoPersistentCredentialCookieOrCacheStore() {
        let configuration = BrowserProfileNetwork.isolatedConfiguration()
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.protocolClasses?.count == 1)
    }

    @Test func navigationPolicyAllowsOnlyOwnedOrLoopbackFixtures() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let paths = try BrowserTestProfilePaths(identifier: UUID().uuidString, temporaryDirectory: fixture.root)
        let bundle = fixture.root.appendingPathComponent("Fixture.app")
        for value in ["http://127.0.0.1:8123/", "https://localhost/page", "http://[::1]/", "about:blank", "data:text/html,hello"] {
            #expect(paths.allowsNavigation(URL(string: value)!, bundleRoot: bundle))
        }
        for value in ["https://example.invalid/", "https://localhost.evil.invalid/", "http://user:pass@localhost/", "mailto:fixture@example.invalid", "zoommtg://fixture"] {
            #expect(!paths.allowsNavigation(URL(string: value)!, bundleRoot: bundle))
        }
        #expect(paths.allowsNavigation(paths.documents.appendingPathComponent("fixture.html"), bundleRoot: bundle))
        #expect(!paths.allowsNavigation(fixture.root.appendingPathComponent("production.html"), bundleRoot: bundle))
    }

    @Test func isolatedNativeSessionRejectsRequestsWithoutServerOrCredentials() async {
        let session = URLSession(configuration: BrowserProfileNetwork.isolatedConfiguration())
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "http://127.0.0.1:1/never-contact")!)
            Issue.record("Private native request unexpectedly succeeded")
        } catch { #expect((error as? URLError)?.code == .noPermissionsToReadFile) }
    }

    private struct Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserProfileTests-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
