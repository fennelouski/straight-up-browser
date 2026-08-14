#if os(macOS)
import AppKit
import Foundation
import WebKit

enum AgentPageExpansionSettings {
    enum Key {
        static let enabled = "browserAgentLoadsMorePageContent"
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.enabled) as? Bool ?? true
    }
}

struct AgentPageExpansionPolicy: Equatable, Sendable {
    let maximumSteps: Int
    let maximumScrollRoots: Int
    let maximumDurationMilliseconds: Int
    let settleMilliseconds: Int
    let stablePassesRequired: Int
    let cacheLifetimeMilliseconds: Int

    static let standard = AgentPageExpansionPolicy(
        maximumSteps: 24,
        maximumScrollRoots: 6,
        maximumDurationMilliseconds: 6_000,
        settleMilliseconds: 180,
        stablePassesRequired: 2,
        cacheLifetimeMilliseconds: 120_000
    )

    static let test = AgentPageExpansionPolicy(
        maximumSteps: 24,
        maximumScrollRoots: 6,
        maximumDurationMilliseconds: 2_000,
        settleMilliseconds: 20,
        stablePassesRequired: 2,
        cacheLifetimeMilliseconds: 120_000
    )
}

struct AgentPageExpansionReport: Codable, Equatable, Sendable {
    let steps: Int
    let scrollRootCount: Int
    let initialHeight: Int
    let finalHeight: Int
    let didLoadMore: Bool
    let cached: Bool
}

enum AgentPageLoadExpanderError: Error {
    case invalidResult
}

/// Coaxes bounded lazy/infinite feeds to populate their existing Page DOM.
/// The Page stays authoritative: no duplicate navigation, cookie jar, or SPA
/// state is created. A frozen snapshot covers the live view while JavaScript
/// scrolls the document and nested feeds, then every original offset is restored.
@MainActor
enum AgentPageLoadExpander {
    static func expand(
        _ webView: WKWebView,
        policy: AgentPageExpansionPolicy = .standard
    ) async throws -> AgentPageExpansionReport {
        let overlay = await snapshotOverlay(for: webView)
        defer { overlay?.removeFromSuperview() }

        let raw = try await webView.callAsyncJavaScript(
            "return await " + script(for: policy),
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let report = try? JSONDecoder().decode(
                AgentPageExpansionReport.self,
                from: data
              ) else {
            throw AgentPageLoadExpanderError.invalidResult
        }
        Logger.log(
            "Page expansion finished: steps=\(report.steps), roots=\(report.scrollRootCount), heightDelta=\(report.finalHeight - report.initialHeight), cached=\(report.cached)",
            type: "BrowserAgent"
        )
        return report
    }

    static func script(for policy: AgentPageExpansionPolicy) -> String {
        """
        (async function() {
            const policy = {
                maximumSteps: \(max(1, policy.maximumSteps)),
                maximumScrollRoots: \(max(1, policy.maximumScrollRoots)),
                maximumDurationMilliseconds: \(max(100, policy.maximumDurationMilliseconds)),
                settleMilliseconds: \(max(0, policy.settleMilliseconds)),
                stablePassesRequired: \(max(1, policy.stablePassesRequired)),
                cacheLifetimeMilliseconds: \(max(0, policy.cacheLifetimeMilliseconds))
            };
            const scrollingElement = document.scrollingElement || document.documentElement;
            if (!scrollingElement) {
                return JSON.stringify({
                    steps: 0, scrollRootCount: 0, initialHeight: 0,
                    finalHeight: 0, didLoadMore: false, cached: false
                });
            }
            const textLength = () => String(document.body?.innerText || '').length;
            const cached = window.__subAgentPageExpansion;
            if (policy.cacheLifetimeMilliseconds > 0 && cached
                && Date.now() - cached.finishedAt < policy.cacheLifetimeMilliseconds
                && scrollingElement.scrollHeight <= cached.height
                && textLength() <= cached.textLength) {
                return JSON.stringify({
                    steps: 0,
                    scrollRootCount: cached.scrollRootCount,
                    initialHeight: scrollingElement.scrollHeight,
                    finalHeight: scrollingElement.scrollHeight,
                    didLoadMore: false,
                    cached: true
                });
            }

            const nestedRoots = [];
            let inspectedElements = 0;
            for (const element of document.querySelectorAll('body *')) {
                if (inspectedElements >= 5000
                    || nestedRoots.length >= policy.maximumScrollRoots - 1) break;
                inspectedElements += 1;
                if (!(element instanceof HTMLElement)) continue;
                const style = getComputedStyle(element);
                const overflow = style.overflowY;
                if ((overflow === 'auto' || overflow === 'scroll')
                    && element.clientHeight >= 80
                    && element.scrollHeight > element.clientHeight + 120) {
                    nestedRoots.push(element);
                }
            }
            const roots = [scrollingElement, ...nestedRoots]
                .filter((root, index, values) => values.indexOf(root) === index)
                .slice(0, policy.maximumScrollRoots);
            const offsets = roots.map(root => ({
                top: root.scrollTop,
                left: root.scrollLeft
            }));
            const initialHeight = scrollingElement.scrollHeight;
            const initialTextLength = textLength();
            const startedAt = performance.now();
            const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
            let steps = 0;

            try {
                for (const root of roots) {
                    let stablePasses = 0;
                    while (steps < policy.maximumSteps
                        && performance.now() - startedAt < policy.maximumDurationMilliseconds
                        && stablePasses < policy.stablePassesRequired) {
                        const beforeHeight = root.scrollHeight;
                        const maximumOffset = Math.max(0, beforeHeight - root.clientHeight);
                        root.scrollTop = maximumOffset;
                        steps += 1;
                        await wait(policy.settleMilliseconds);
                        const afterHeight = root.scrollHeight;
                        stablePasses = afterHeight > beforeHeight + 1
                            ? 0
                            : stablePasses + 1;
                    }
                }
            } finally {
                roots.forEach((root, index) => {
                    root.scrollLeft = offsets[index].left;
                    root.scrollTop = offsets[index].top;
                });
                await wait(0);
            }

            const finalHeight = scrollingElement.scrollHeight;
            const finalTextLength = textLength();
            window.__subAgentPageExpansion = {
                finishedAt: Date.now(),
                height: finalHeight,
                textLength: finalTextLength,
                scrollRootCount: roots.length
            };
            return JSON.stringify({
                steps,
                scrollRootCount: roots.length,
                initialHeight,
                finalHeight,
                didLoadMore: finalHeight > initialHeight || finalTextLength > initialTextLength,
                cached: false
            });
        })();
        """
    }

    private static func snapshotOverlay(for webView: WKWebView) async -> NSImageView? {
        guard webView.window != nil,
              webView.bounds.width > 0,
              webView.bounds.height > 0 else { return nil }
        let image: NSImage? = await withCheckedContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image else { return nil }
        let overlay = AgentPageExpansionSnapshotView(frame: webView.bounds)
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        overlay.autoresizingMask = [.width, .height]
        overlay.setAccessibilityElement(false)
        webView.addSubview(overlay, positioned: .above, relativeTo: nil)
        return overlay
    }
}

private final class AgentPageExpansionSnapshotView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
