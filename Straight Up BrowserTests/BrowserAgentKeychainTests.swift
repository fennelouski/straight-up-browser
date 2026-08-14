import Testing
@testable import Browser

struct BrowserAgentKeychainTests {
    @Test func uiTestingNeverTouchesTheUsersKeychain() {
        #expect(!BrowserAgentKeychain.permitsAccess(arguments: ["Browser", "-uiTesting"]))
        #expect(BrowserAgentKeychain.permitsAccess(arguments: ["Browser"]))
    }
}
