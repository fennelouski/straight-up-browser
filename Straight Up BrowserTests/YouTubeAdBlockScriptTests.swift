//
//  YouTubeAdBlockScriptTests.swift
//  Straight Up BrowserTests
//
//  YouTube serves video ads first-party, so the content rule list can't see
//  them. This checks the injected script strips them out of the player response
//  and clicks through whatever still reaches the player.
//

import Testing
import WebKit
@testable import Browser

struct YouTubeAdBlockScriptTests {

    @Test @MainActor func stripsAdsFromPlayerResponseAndSkipsPlayingAd() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebViewManager.youTubeAdBlockScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let loader = YouTubeAdBlockLoader()
        webView.navigationDelegate = loader
        try await loader.load(
            """
            <!doctype html><html><body>
              <script>
                var ytInitialPlayerResponse = { streamingData: {}, adPlacements: [1], adSlots: [2] };
              </script>
              <div id="movie_player" class="ad-showing">
                <button class="ytp-ad-skip-button" onclick="window.__skipped = true"></button>
              </div>
            </body></html>
            """,
            in: webView
        )

        func js(_ source: String) async throws -> Any? {
            try await webView.evaluateJavaScript("(function(){ return \(source); })()")
        }

        // Inline object literal never passes through JSON.parse — the setter catches it.
        #expect(try await js("'adPlacements' in window.ytInitialPlayerResponse") as? Bool == false)
        #expect(try await js("'adSlots' in window.ytInitialPlayerResponse") as? Bool == false)
        #expect(try await js("typeof window.ytInitialPlayerResponse.streamingData") as? String == "object")

        // Player fetches go through JSON.parse.
        let parsed = "JSON.parse('{\"streamingData\":{},\"playerAds\":[1],\"adBreakHeartbeatParams\":\"x\"}')"
        #expect(try await js("'playerAds' in \(parsed)") as? Bool == false)
        #expect(try await js("'adBreakHeartbeatParams' in \(parsed)") as? Bool == false)
        // Everything that isn't an ad field survives the round trip.
        #expect(try await js("JSON.parse('{\"videoId\":\"abc\"}').videoId") as? String == "abc")

        // The poll clicks the skip button on an ad that got through.
        try await Task.sleep(for: .milliseconds(800))
        #expect(try await js("window.__skipped === true") as? Bool == true)
    }
}

private final class YouTubeAdBlockLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com/watch?v=x"))
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
