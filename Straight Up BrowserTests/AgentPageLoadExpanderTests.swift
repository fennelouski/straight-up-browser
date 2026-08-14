import Foundation
import Testing
import WebKit
@testable import Browser

@MainActor
struct AgentPageLoadExpanderTests {
    @Test func settingDefaultsOnAndCanBeDisabled() throws {
        let suiteName = "AgentPageLoadExpanderTests.Settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        #expect(AgentPageExpansionSettings.isEnabled(in: defaults))
        defaults.set(false, forKey: AgentPageExpansionSettings.Key.enabled)
        #expect(!AgentPageExpansionSettings.isEnabled(in: defaults))
    }

    @Test func repeatedScrollingLoadsLazyArticlesAndRestoresTheViewport() async throws {
        let webView = makeWebView()
        let probe = AgentPageExpansionNavigationProbe()
        try await probe.load(
            """
            <!doctype html>
            <meta name="viewport" content="width=device-width">
            <style>body{margin:0}.story{height:900px;border-bottom:1px solid #ccc}</style>
            <main id="stories"><article class="story">Story 1</article></main>
            <script>
            let count = 1;
            function appendStory() {
              if (count >= 5) return;
              count += 1;
              const article = document.createElement('article');
              article.className = 'story';
              article.textContent = 'Story ' + count;
              document.querySelector('#stories').appendChild(article);
            }
            addEventListener('scroll', () => {
              if (scrollY + innerHeight >= document.documentElement.scrollHeight - 80) {
                setTimeout(appendStory, 5);
              }
            });
            </script>
            """,
            in: webView
        )
        _ = try await webView.evaluateJavaScript("scrollTo(0, 120)")
        let originalY = try #require(try await webView.evaluateJavaScript("scrollY") as? Double)

        let report = try await AgentPageLoadExpander.expand(
            webView,
            policy: .test
        )
        let articleCount = try #require(
            try await webView.evaluateJavaScript("document.querySelectorAll('article').length") as? Int
        )
        let finalY = try #require(try await webView.evaluateJavaScript("scrollY") as? Double)

        #expect(articleCount == 5)
        #expect(report.steps > 0)
        #expect(report.didLoadMore)
        #expect(abs(finalY - originalY) < 1)

        let cachedReport = try await AgentPageLoadExpander.expand(webView, policy: .test)
        #expect(cachedReport.cached)
        #expect(cachedReport.steps == 0)
    }

    @Test func nestedScrollableFeedsAreExpandedAndRestored() async throws {
        let webView = makeWebView()
        let probe = AgentPageExpansionNavigationProbe()
        try await probe.load(
            """
            <!doctype html>
            <style>
              #feed{height:240px;overflow-y:auto}
              .story{height:220px;border-bottom:1px solid #ccc}
            </style>
            <div id="feed"><article class="story">Story 1</article><article class="story">Story 2</article></div>
            <script>
            const feed = document.querySelector('#feed');
            let count = 2;
            feed.addEventListener('scroll', () => {
              if (feed.scrollTop + feed.clientHeight < feed.scrollHeight - 40 || count >= 5) return;
              setTimeout(() => {
                count += 1;
                const article = document.createElement('article');
                article.className = 'story';
                article.textContent = 'Story ' + count;
                feed.appendChild(article);
              }, 5);
            });
            </script>
            """,
            in: webView
        )
        _ = try await webView.evaluateJavaScript("document.querySelector('#feed').scrollTop = 40")

        let report = try await AgentPageLoadExpander.expand(webView, policy: .test)
        let articleCount = try #require(
            try await webView.evaluateJavaScript("document.querySelectorAll('article').length") as? Int
        )
        let finalY = try #require(
            try await webView.evaluateJavaScript("document.querySelector('#feed').scrollTop") as? Double
        )

        #expect(articleCount == 5)
        #expect(report.scrollRootCount >= 2)
        #expect(abs(finalY - 40) < 1)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(
            frame: CGRect(x: 0, y: 0, width: 900, height: 600),
            configuration: configuration
        )
    }
}

@MainActor
private final class AgentPageExpansionNavigationProbe: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: URL(string: "https://lazy.test/"))
        }
        webView.navigationDelegate = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
