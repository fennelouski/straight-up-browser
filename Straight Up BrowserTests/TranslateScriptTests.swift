//
//  TranslateScriptTests.swift
//  Straight Up BrowserTests
//
//  Drives WebViewManager's __subTranslate bridge in a real WKWebView: what it
//  offers, what it skips once offered, same-origin frames, in-place apply, and
//  selection splitting for word-level translation.
//

import Testing
import WebKit
@testable import Browser

struct TranslateScriptTests {

    @Test @MainActor func extractApplyAndSelectionRoundTrip() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebViewManager.translateScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let loader = TranslateScriptLoader()
        webView.navigationDelegate = loader
        try await loader.load(
            """
            <!doctype html><html><body>
              <nav>Inbox</nav>
              <p id="mail">Hallo Nathan, de vergadering is morgen.</p>
              <div style="display:none"><span>hidden</span></div>
              <iframe id="same" srcdoc='<p>Groeten uit Amsterdam</p>'></iframe>
            </body></html>
            """,
            in: webView
        )
        // srcdoc frames finish after the parent's didFinish.
        try await Task.sleep(for: .milliseconds(300))

        func js(_ source: String) async throws -> Any? {
            try await webView.evaluateJavaScript("(function(){ return \(source); })()")
        }
        func texts(_ value: Any?) -> [String] {
            ((value as? [[String: String]]) ?? []).compactMap { $0["text"] }
        }

        let first = try await js("window.__subTranslate.extract(false)")
        #expect(texts(first) == ["Inbox", "Hallo Nathan, de vergadering is morgen.", "Groeten uit Amsterdam"])
        let mailId = try #require((first as? [[String: String]])?[1]["id"])

        // Offered nodes are not offered again unless everything is asked for.
        #expect(texts(try await js("window.__subTranslate.extract(false)")).isEmpty)
        #expect(texts(try await js("window.__subTranslate.extract(true)")).count == 3)

        _ = try await js("window.__subTranslate.apply({\"\(mailId)\": \"Hello Nathan, the meeting is tomorrow.\"})")
        #expect(try await js("document.getElementById('mail').textContent") as? String == "Hello Nathan, the meeting is tomorrow.")
        #expect(try await js("document.querySelector('#mail .sub-translated').dataset.original") as? String
                == "Hallo Nathan, de vergadering is morgen.")
        #expect(try await js("window.__subTranslate.hasTranslation()") as? Bool == true)

        // A re-offer of a translated node carries its original text.
        let again = texts(try await js("window.__subTranslate.extract(true)"))
        #expect(again.contains("Hallo Nathan, de vergadering is morgen."))

        // Select one word out of the untouched nav text and translate just it.
        _ = try await js("""
            (function(){ var node = document.querySelector('nav').firstChild;
              var range = document.createRange(); range.setStart(node, 0); range.setEnd(node, 2);
              var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range); return true; })()
            """)
        let selected = try await js("window.__subTranslate.extractSelection()")
        #expect(texts(selected) == ["In"])
        let selectedId = try #require((selected as? [[String: String]])?.first?["id"])
        _ = try await js("window.__subTranslate.apply({\"\(selectedId)\": \"Postvak\"})")
        #expect(try await js("document.querySelector('nav').textContent") as? String == "Postvakbox")

        _ = try await js("window.__subTranslate.toggle()")
        #expect(try await js("window.__subTranslate.isShowingOriginal()") as? Bool == true)
        #expect(try await js("document.body.classList.contains('sub-show-original')") as? Bool == true)
    }
}

@MainActor
private final class TranslateScriptLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://translate.example/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
