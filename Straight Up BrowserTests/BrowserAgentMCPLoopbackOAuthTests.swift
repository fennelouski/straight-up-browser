import Foundation
import Testing
@testable import Browser

struct BrowserAgentMCPLoopbackOAuthTests {
    @Test func listenerUsesEphemeralIPv4LoopbackAndAcceptsOnlyExactStateAndPath() async throws {
        let listener = try BrowserAgentMCPLoopbackAuthorizationListener()
        let redirectURI = try await listener.start()
        #expect(redirectURI.scheme == "http")
        #expect(redirectURI.host == "127.0.0.1")
        #expect(redirectURI.port != nil)
        #expect(redirectURI.port != 53_682)
        #expect(redirectURI.path == "/oauth/callback")

        let callbackTask = Task {
            try await listener.waitForCallback(expectedState: "expected-state", timeout: .seconds(5))
        }

        let port = try #require(redirectURI.port)
        let wrongPath = try #require(URL(
            string: "http://127.0.0.1:\(port)/wrong?code=ignored&state=expected-state"
        ))
        let (_, wrongPathResponse) = try await URLSession.shared.data(from: wrongPath)
        #expect((wrongPathResponse as? HTTPURLResponse)?.statusCode == 400)

        var wrongState = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)
        wrongState?.queryItems = [
            URLQueryItem(name: "code", value: "ignored"),
            URLQueryItem(name: "state", value: "wrong-state"),
        ]
        let (_, wrongStateResponse) = try await URLSession.shared.data(
            from: try #require(wrongState?.url)
        )
        #expect((wrongStateResponse as? HTTPURLResponse)?.statusCode == 400)

        var duplicateState = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)
        duplicateState?.queryItems = [
            URLQueryItem(name: "code", value: "ignored"),
            URLQueryItem(name: "state", value: "expected-state"),
            URLQueryItem(name: "state", value: "expected-state"),
        ]
        let (_, duplicateStateResponse) = try await URLSession.shared.data(
            from: try #require(duplicateState?.url)
        )
        #expect((duplicateStateResponse as? HTTPURLResponse)?.statusCode == 400)

        var accepted = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)
        accepted?.queryItems = [
            URLQueryItem(name: "code", value: "authorization-code"),
            URLQueryItem(name: "state", value: "expected-state"),
        ]
        let acceptedURL = try #require(accepted?.url)
        let (_, acceptedResponse) = try await URLSession.shared.data(from: acceptedURL)
        #expect((acceptedResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await callbackTask.value == acceptedURL)
    }

    @Test func listenerTimesOutAndClosesWithoutAValidCallback() async throws {
        let listener = try BrowserAgentMCPLoopbackAuthorizationListener()
        _ = try await listener.start()
        await #expect(throws: MCPConnectionError.timeout(milliseconds: 30)) {
            try await listener.waitForCallback(
                expectedState: "never-arrives",
                timeout: .milliseconds(30)
            )
        }
    }
}
