import Foundation
import Testing
import WebKit
@testable import Browser

@MainActor
private final class CredentialFixtureMessages: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var messages: [WKScriptMessage] = []
    var finished = false
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        messages.append(message)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}

@MainActor
struct CredentialPageRuntimeTests {
    private func fixture(_ html: String) async throws -> (WKWebView, CredentialFixtureMessages) {
        let handler = CredentialFixtureMessages()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(handler, contentWorld: .defaultClient, name: "straightUpSemantic")
        config.userContentController.addUserScript(WKUserScript(source: CredentialPageRuntime.bootstrap,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.navigationDelegate = handler
        view.loadHTMLString(html, baseURL: URL(string: "https://login.example/"))
        for _ in 0..<100 {
            if handler.finished { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(handler.finished)
        return (view, handler)
    }

    @Test func usernameOnlyThenPasswordOnlyFillWithoutSubmittingAndRememberTheUsername() async throws {
        let (view, handler) = try await fixture("<form onsubmit='event.preventDefault()'><input id='account_name_text_field'><button>Continue</button></form>")
        let result = try await view.callAsyncJavaScript(CredentialPageRuntime.apply,
            arguments: ["request": ["origin": "https://login.example", "username": "synthetic-user", "password": "synthetic-password", "submit": false]],
            in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(result?["usernameFilled"] as? Bool == true)
        #expect(result?["passwordFilled"] as? Bool == false)
        #expect(handler.messages.isEmpty)
        _ = try await view.evaluateJavaScript("document.querySelector('form').requestSubmit(); document.body.innerHTML=\"<form onsubmit='event.preventDefault()'><input type='password'><button>Sign In</button></form>\";")
        _ = try await view.callAsyncJavaScript(CredentialPageRuntime.apply,
            arguments: ["request": ["origin": "https://login.example", "username": "synthetic-user", "password": "synthetic-password", "submit": false]],
            in: nil, contentWorld: .defaultClient)
        _ = try await view.evaluateJavaScript("document.querySelector('form').requestSubmit()")
        try await Task.sleep(for: .milliseconds(100))
        let submissions = handler.messages.compactMap { $0.body as? [String: Any] }.filter { $0["type"] as? String == "loginSubmitted" }
        #expect(submissions.last?["username"] as? String == "synthetic-user")
        #expect(submissions.last?["password"] as? String == "synthetic-password")
    }

    @Test func embeddedFrameOwnsTheTargetAndRejectsStaleDocumentOrWrongOrigin() async throws {
        let (view, handler) = try await fixture("<iframe srcdoc=\"<input autocomplete='username'><input type='password'>\"></iframe>")
        _ = try await view.evaluateJavaScript("document.querySelector('iframe').contentDocument.querySelector('input').focus()")
        for _ in 0..<40 {
            if handler.messages.contains(where: { ($0.body as? [String: Any])?["type"] as? String == "loginFieldFocused" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let focus = try #require(handler.messages.first { ($0.body as? [String: Any])?["type"] as? String == "loginFieldFocused" })
        #expect(!focus.frameInfo.isMainFrame)
        let body = try #require(focus.body as? [String: Any])
        #expect(body["password"] == nil)
        #expect(body["username"] == nil)
        let origin = try #require(body["origin"] as? String)
        let token = try #require(body["documentToken"] as? String)
        func apply(origin: String, token: String) async throws -> Bool {
            let result = try await view.callAsyncJavaScript(CredentialPageRuntime.apply,
                arguments: ["request": ["origin": origin, "documentToken": token, "username": "synthetic-user", "password": "synthetic-password", "submit": false]],
                in: focus.frameInfo, contentWorld: .defaultClient) as? [String: Any]
            return result?["filled"] as? Bool ?? false
        }
        #expect(try await !apply(origin: "https://attacker.example", token: token))
        #expect(try await !apply(origin: origin, token: "stale"))
        #expect(try await apply(origin: origin, token: token))
        let values = try await view.evaluateJavaScript("Array.from(document.querySelector('iframe').contentDocument.querySelectorAll('input')).map(el=>el.value)") as? [String]
        #expect(values == ["synthetic-user", "synthetic-password"])
    }

    @Test func signupAndUnrelatedSearchFieldsDoNotReceiveSavedPasswords() async throws {
        let (view, _) = try await fixture("<input type='text' name='search'><input type='password' autocomplete='new-password'>")
        let result = try await view.callAsyncJavaScript(CredentialPageRuntime.apply,
            arguments: ["request": ["origin": "https://login.example", "username": "synthetic-user", "password": "synthetic-password", "submit": false]],
            in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(result?["filled"] as? Bool == false)
    }
}
