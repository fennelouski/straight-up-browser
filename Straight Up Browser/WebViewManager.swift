//
//  WebViewManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import WebKit
import Combine
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// WKWebView silently refuses file:// through load(URLRequest:) - it needs the
// read-access variant. Every URL load goes through here so local files (Finder's
// "Open With", drag-and-drop) actually render.
extension WKWebView {
    func loadURL(_ url: URL) {
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url)
        } else {
            load(URLRequest(url: url))
        }
    }
}

#if canImport(AppKit)
typealias WebViewThumbnail = NSImage
#else
typealias WebViewThumbnail = UIImage
#endif

extension NSKeyedUnarchiver {
    // Non-deprecated replacement for unarchiveTopLevelObjectWithData: decodes a
    // root object archived without secure coding (e.g. WKWebView.interactionState,
    // an opaque type). Returns nil instead of crashing on a corrupt archive.
    static func unarchiveTopLevelObject(from data: Data) -> Any? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    }
}

final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var handler: (any WKScriptMessageHandler)?
    var hasHandler: Bool { handler != nil }

    init(handler: any WKScriptMessageHandler) {
        self.handler = handler
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        handler?.userContentController(userContentController, didReceive: message)
    }
}

enum InteractionStatePersistencePolicy {
    static let maxEntries = 32
    static let maxEntryBytes = 2_000_000
    static let maxTotalBytes = 8_000_000
    static let maxFileBytes = 10_000_000

    static func bounded(_ entries: [String: Data]) -> [String: Data] {
        var result: [String: Data] = [:]
        var totalBytes = 0

        for key in entries.keys.sorted() {
            guard result.count < maxEntries else { break }
            guard let data = entries[key],
                  data.count <= maxEntryBytes,
                  data.count <= maxTotalBytes - totalBytes else { continue }
            result[key] = data
            totalBytes += data.count
        }
        return result
    }
}

class WebViewManager: NSObject, ObservableObject {
    // Claiming to be Chrome while running WebKit gets us flagged as an unsafe
    // embedded webview by Google sign-in (no Sec-CH-UA client hints to back it
    // up). Appending Safari's tokens makes WebKit build a genuine Safari UA and
    // fill in the OS/WebKit versions itself.
    static let userAgentAppName = "Version/26.4 Safari/605.1.15"

    // WebKit exposes the WebAuthn API in WKWebView but leaves it non-functional
    // without the Apple-gated com.apple.developer.web-browser.public-key-credential
    // entitlement: isUserVerifyingPlatformAuthenticatorAvailable() reports false and
    // no ceremony can complete. Advertising an API we can't honor makes sites offer
    // passkey sign-in that dead-ends (Google loops on it), so we hide it and let them
    // fall back to password. navigator.credentials stays for password autofill.
    // Scoped to the sites that actually dead-end. Deleting a global real Safari
    // 26.4 ships (which our user agent claims to be) is a bot-detection tell:
    // Cloudflare's managed challenge scores the mismatch and hard-fails with no
    // retry. Hiding it only where passkey sign-in loops keeps both working.
    // ponytail: delete this whole script if the entitlement is ever granted.
    private static let hideWebAuthnScript = """
    if (/(^|\\.)(google|youtube)\\.com$/.test(location.hostname)) {
        delete window.PublicKeyCredential;
        delete window.AuthenticatorAttestationResponse;
        delete window.AuthenticatorAssertionResponse;
    }
    """

    // A lightweight DevTools bridge. The wrappers are installed before page code,
    // but stay dormant until the user opens DevTools for that tab. This preserves
    // normal console behaviour and avoids retaining page output while the tool is
    // closed. Page code can write to its own console by definition, so this handler
    // intentionally lives in the page world.
    private static let developerToolsScript = """
    (function() {
        if (window.__subDevTools) return;
        var enabled = false;
        var inspecting = false;
        var lastInspectedElement = null;
        var inspectorOverlay = null;
        var savedCursor = null;

        function format(value) {
            if (value === undefined) return 'undefined';
            if (value === null) return 'null';
            if (typeof value === 'string') return value;
            if (typeof value === 'function') return value.toString();
            if (value instanceof Error) return value.stack || value.message;
            if (value && value.nodeType) {
                if (value.outerHTML) return value.outerHTML.slice(0, 4000);
                return String(value);
            }
            try {
                var seen = new WeakSet();
                return JSON.stringify(value, function(_, item) {
                    if (typeof item === 'bigint') return String(item) + 'n';
                    if (typeof item === 'object' && item !== null) {
                        if (seen.has(item)) return '[Circular]';
                        seen.add(item);
                    }
                    return item;
                }, 2);
            } catch (_) { return String(value); }
        }
        function post(payload) {
            if (!enabled) return;
            try { window.webkit.messageHandlers.subDevTools.postMessage(payload); } catch (_) {}
        }
        function send(level, values, source, line, column) {
            post({
                type: 'console', level: level,
                message: values.map(format).join(' '),
                source: source || location.href,
                line: line || 0, column: column || 0,
                timestamp: Date.now()
            });
        }
        function cssEscape(value) {
            if (window.CSS && CSS.escape) return CSS.escape(value);
            return String(value).replace(/[^a-zA-Z0-9_-]/g, '\\$&');
        }
        function selector(element) {
            if (element.id) return '#' + cssEscape(element.id);
            var parts = [];
            while (element && element.nodeType === 1 && element !== document.documentElement) {
                var part = element.tagName.toLowerCase();
                if (element.parentElement) {
                    var matching = Array.from(element.parentElement.children).filter(function(item) {
                        return item.tagName === element.tagName;
                    });
                    if (matching.length > 1) part += ':nth-of-type(' + (matching.indexOf(element) + 1) + ')';
                }
                parts.unshift(part);
                element = element.parentElement;
            }
            return 'html > ' + parts.join(' > ');
        }
        function description(element) {
            var id = element.id ? '#' + element.id : '';
            var classes = Array.from(element.classList || []).slice(0, 2).map(function(name) {
                return '.' + name;
            }).join('');
            return '<' + element.tagName.toLowerCase() + id + classes + '>';
        }
        function ensureHighlighter() {
            if (inspectorOverlay && inspectorOverlay.isConnected) return inspectorOverlay;
            inspectorOverlay = document.createElement('div');
            inspectorOverlay.id = '__sub-devtools-inspector-overlay';
            inspectorOverlay.setAttribute('aria-hidden', 'true');
            inspectorOverlay.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;' +
                'box-sizing:border-box;border:1px solid rgb(66,133,244);background:rgba(66,133,244,.18);display:none';
            document.documentElement.appendChild(inspectorOverlay);
            return inspectorOverlay;
        }
        function showHighlighter(element) {
            var overlay = ensureHighlighter();
            var rect = element.getBoundingClientRect();
            overlay.style.left = rect.left + 'px'; overlay.style.top = rect.top + 'px';
            overlay.style.width = rect.width + 'px'; overlay.style.height = rect.height + 'px';
            overlay.style.display = 'block';
        }
        function hideHighlighter() {
            if (inspectorOverlay) inspectorOverlay.style.display = 'none';
        }
        function sendInspection(type, element) {
            if (!element) return;
            post({
                type: type,
                selector: selector(element),
                description: description(element)
            });
        }
        function setInspecting(next) {
            next = !!next;
            if (inspecting === next) return;
            inspecting = next;
            if (next) {
                savedCursor = document.documentElement.style.cursor;
                document.documentElement.style.cursor = 'crosshair';
            } else {
                document.documentElement.style.cursor = savedCursor || '';
                savedCursor = null;
                lastInspectedElement = null;
                hideHighlighter();
            }
        }
        document.addEventListener('pointermove', function(event) {
            if (!inspecting || !event.target || event.target === inspectorOverlay) return;
            var element = event.target.nodeType === 1 ? event.target : event.target.parentElement;
            if (!element) return;
            showHighlighter(element);
            if (element !== lastInspectedElement) {
                lastInspectedElement = element;
                sendInspection('inspectHover', element);
            }
        }, true);
        document.addEventListener('click', function(event) {
            if (!inspecting || !event.target) return;
            var element = event.target.nodeType === 1 ? event.target : event.target.parentElement;
            if (!element) return;
            event.preventDefault(); event.stopImmediatePropagation(); event.stopPropagation();
            sendInspection('inspectSelect', element);
            setInspecting(false);
        }, true);
        document.addEventListener('keydown', function(event) {
            if (!inspecting || event.key !== 'Escape') return;
            event.preventDefault(); event.stopImmediatePropagation(); event.stopPropagation();
            setInspecting(false);
            post({ type: 'inspectCancel' });
        }, true);
        // Patched on first enable(), not at document start: a permanently
        // wrapped console is a bot-detection tell (console.log.toString() stops
        // reading as native code) and Cloudflare's challenge fails on it.
        var consoleWrapped = false;
        function wrapConsole() {
            if (consoleWrapped) return;
            consoleWrapped = true;
            ['log', 'debug', 'info', 'warn', 'error'].forEach(function(method) {
                var original = console[method];
                console[method] = function() {
                    send(method, Array.prototype.slice.call(arguments));
                    return original.apply(console, arguments);
                };
            });
        }
        window.addEventListener('error', function(event) {
            send('error', [event.error || event.message], event.filename, event.lineno, event.colno);
        });
        window.addEventListener('unhandledrejection', function(event) {
            send('error', ['Uncaught (in promise)', event.reason]);
        });
        window.__subDevTools = {
            enable: function() { enabled = true; wrapConsole(); },
            disable: function() { setInspecting(false); enabled = false; },
            setInspecting: setInspecting
        };
    })();
    """

    // Injected into every page: alt-click image download, long-press link
    // preview signals, and percentage-based spacebar scrolling. Native side
    // sets window.__subSpacePct per navigation in the coordinator's didCommit.
    private static let pageScript = """
    (function() {
        // Option+click on a bare image downloads it (links are handled natively)
        document.addEventListener('click', function(e) {
            if (!e.altKey || e.metaKey || e.ctrlKey) return;
            if (e.target.closest('a[href]')) return;
            var img = e.target.closest('img');
            if (img && img.currentSrc) {
                e.preventDefault(); e.stopPropagation();
                window.webkit.messageHandlers.sub.postMessage({type: 'downloadImage', url: img.currentSrc});
            }
        }, true);

        // Long-press a link -> preview. Prefetch starts on mousedown.
        var pressTimer = null, longPressed = false, startX = 0, startY = 0;
        document.addEventListener('mousedown', function(e) {
            if (e.button !== 0 || e.metaKey || e.altKey || e.ctrlKey || e.shiftKey) return;
            var a = e.target.closest('a[href]');
            if (!a || !/^https?:/.test(a.href)) return;
            longPressed = false; startX = e.clientX; startY = e.clientY;
            window.webkit.messageHandlers.sub.postMessage({type: 'linkDown', url: a.href});
            pressTimer = setTimeout(function() {
                longPressed = true;
                window.webkit.messageHandlers.sub.postMessage({type: 'linkLongPress'});
            }, 500);
        }, true);
        document.addEventListener('mousemove', function(e) {
            if (pressTimer && (Math.abs(e.clientX - startX) > 10 || Math.abs(e.clientY - startY) > 10)) {
                clearTimeout(pressTimer); pressTimer = null;
            }
        }, true);
        document.addEventListener('mouseup', function() {
            if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; }
            if (!longPressed) window.webkit.messageHandlers.sub.postMessage({type: 'linkUp'});
        }, true);
        document.addEventListener('click', function(e) {
            if (longPressed) { e.preventDefault(); e.stopPropagation(); longPressed = false; }
        }, true);

        // Spacebar scrolls a settings-defined fraction of the viewport
        document.addEventListener('keydown', function(e) {
            if (e.key !== ' ' || e.metaKey || e.ctrlKey || e.altKey) return;
            var t = e.target;
            if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
            e.preventDefault();
            var pct = (window.__subSpacePct || 90) / 100;
            window.scrollBy({top: (e.shiftKey ? -1 : 1) * window.innerHeight * pct});
        }, true);

        // First-paint ping. Two rAFs: the first is scheduled before the frame
        // that draws this document, the second lands after it — so by the time
        // this posts there really is content on screen. beginFadeIn is waiting.
        requestAnimationFrame(function() {
            requestAnimationFrame(function() {
                window.webkit.messageHandlers.sub.postMessage({type: 'painted'});
            });
        });
        window.webkit.messageHandlers.sub.postMessage({type: 'agentDOMContentLoaded'});

        // Freehand page-region selection for the attended AI panel. The page
        // receives only the temporary drawing surface; native code owns the
        // resulting screenshot and bounded text extraction.
        window.__subAgentLasso = {
            start: function() {
                var prior = document.getElementById('__sub-agent-lasso');
                if (prior) prior.remove();
                var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
                svg.id = '__sub-agent-lasso';
                svg.setAttribute('style', 'position:fixed;inset:0;width:100vw;height:100vh;z-index:2147483647;cursor:crosshair;background:rgba(20,25,35,.08);touch-action:none');
                var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
                path.setAttribute('fill', 'rgba(94,92,230,.13)');
                path.setAttribute('stroke', 'rgb(124,120,255)');
                path.setAttribute('stroke-width', '3');
                path.setAttribute('stroke-linecap', 'round');
                path.setAttribute('stroke-linejoin', 'round');
                svg.appendChild(path); document.documentElement.appendChild(svg);
                var points = [], drawing = false;
                function render() {
                    if (!points.length) return;
                    path.setAttribute('d', 'M ' + points.map(function(p) { return p.x + ' ' + p.y; }).join(' L ') + (points.length > 2 ? ' Z' : ''));
                }
                svg.addEventListener('pointerdown', function(e) {
                    drawing = true; points = [{x:e.clientX,y:e.clientY}]; svg.setPointerCapture(e.pointerId); render();
                });
                svg.addEventListener('pointermove', function(e) {
                    if (!drawing) return; points.push({x:e.clientX,y:e.clientY}); render();
                });
                svg.addEventListener('pointerup', function(e) {
                    if (!drawing || points.length < 2) { svg.remove(); return; }
                    drawing = false;
                    var xs = points.map(function(p){return p.x;}), ys = points.map(function(p){return p.y;});
                    var x = Math.max(0, Math.min.apply(null,xs)), y = Math.max(0,Math.min.apply(null,ys));
                    var right = Math.min(innerWidth,Math.max.apply(null,xs)), bottom = Math.min(innerHeight,Math.max.apply(null,ys));
                    svg.remove();
                    window.webkit.messageHandlers.sub.postMessage({type:'agentLasso',x:x,y:y,width:right-x,height:bottom-y});
                });
                function cancel(e) { if (e.key === 'Escape') { svg.remove(); document.removeEventListener('keydown',cancel,true); } }
                document.addEventListener('keydown', cancel, true);
            }
        };
    })();
    """

    // Remember the link under a native context menu before WebKit constructs
    // that menu. WKUIDelegate exposes the finished NSMenu on macOS, but not the
    // clicked element, so this tiny page-world bridge supplies the missing URL.
    // It runs in every frame so links inside embeds receive the same menu.
    private static let contextMenuScript = """
    (function() {
        document.addEventListener('contextmenu', function(event) {
            var target = event.target;
            if (target && target.nodeType !== 1) target = target.parentElement;
            var link = target && target.closest ? target.closest('a[href]') : null;
            window.webkit.messageHandlers.sub.postMessage({
                type: 'contextLink',
                url: link && link.href ? link.href : null
            });
        }, true);
    })();
    """

    // On-device page translation (PageTranslator.swift is the Swift-side driver).
    // window.__subTranslate.sampleText() feeds language detection; .extract()
    // wraps visible text nodes in spans and returns {id, text} for translation;
    // .apply(map) writes translated text back in; .toggle() flips every wrapped
    // span between translated/original. Peek: holding Option anywhere on the
    // page reveals the original text of just the element under the cursor, via
    // a body class + CSS :hover/::before (no per-mousemove JS, so it can't
    // collide with KeyboardShortcutsManager's global modifier monitor).
    private static let translateScript = """
    (function() {
        var nextId = 0, nodeMap = new Map(), showOriginal = false;

        function isVisible(el) {
            var style = window.getComputedStyle(el);
            return style && style.display !== 'none' && style.visibility !== 'hidden';
        }

        function collectTextNodes(root, limit) {
            var out = [];
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                acceptNode: function(node) {
                    if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
                    var parent = node.parentElement;
                    if (!parent || parent.isContentEditable) return NodeFilter.FILTER_REJECT;
                    if (/^(SCRIPT|STYLE|NOSCRIPT|TEXTAREA)$/.test(parent.tagName)) return NodeFilter.FILTER_REJECT;
                    if (!isVisible(parent)) return NodeFilter.FILTER_REJECT;
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            var node;
            while (out.length < limit && (node = walker.nextNode())) out.push(node);
            return out;
        }

        // ponytail: position:absolute overlay for the peek/toggle swap - good
        // enough for prose text, can misalign on tightly-laid-out inline text.
        // Upgrade to an inline-reflow-safe technique if that's reported janky.
        function injectStyle() {
            if (document.getElementById('sub-translate-style')) return;
            var style = document.createElement('style');
            style.id = 'sub-translate-style';
            style.textContent =
                '.sub-translated[data-original]{position:relative}' +
                'body.sub-peek-mode .sub-translated:hover,' +
                'body.sub-show-original .sub-translated{visibility:hidden}' +
                'body.sub-peek-mode .sub-translated:hover::before,' +
                'body.sub-show-original .sub-translated::before{' +
                'content:attr(data-original);visibility:visible;position:absolute;' +
                'left:0;top:0;width:max-content;max-width:100vw}';
            (document.head || document.documentElement).appendChild(style);
        }
        if (document.head) { injectStyle(); } else {
            document.addEventListener('DOMContentLoaded', injectStyle);
        }

        window.__subTranslate = {
            sampleText: function() {
                return document.body ? document.body.innerText.slice(0, 2000) : '';
            },
            hasTranslation: function() {
                return nodeMap.size > 0;
            },
            extract: function() {
                if (!document.body) return [];
                var results = [];
                collectTextNodes(document.body, 500).forEach(function(node) {
                    var span = document.createElement('span');
                    span.className = 'sub-translated';
                    var id = 'st' + (nextId++);
                    span.dataset.tid = id;
                    span.dataset.original = node.nodeValue;
                    node.parentNode.replaceChild(span, node);
                    span.appendChild(node);
                    nodeMap.set(id, node);
                    results.push({id: id, text: node.nodeValue});
                });
                return results;
            },
            apply: function(map) {
                Object.keys(map).forEach(function(id) {
                    var node = nodeMap.get(id);
                    if (node) node.nodeValue = map[id];
                });
            },
            toggle: function() {
                showOriginal = !showOriginal;
                if (document.body) document.body.classList.toggle('sub-show-original', showOriginal);
            }
        };

        document.addEventListener('keydown', function(e) {
            if (e.key === 'Alt' && document.body) document.body.classList.add('sub-peek-mode');
        }, true);
        document.addEventListener('keyup', function(e) {
            if (e.key === 'Alt' && document.body) document.body.classList.remove('sub-peek-mode');
        }, true);
        window.addEventListener('blur', function() {
            if (document.body) document.body.classList.remove('sub-peek-mode');
        });
    })();
    """

    // Store web views per tab ID
    private var webViews: [UUID: WKWebView] = [:]
    private var contextMenuLinks: [ObjectIdentifier: URL] = [:]
    // Includes memory-unloaded tabs. Extensions still regard those as open,
    // and this ownership map keeps their window routing stable until real close.
    private var ownedTabIds: Set<UUID> = []

    // Session isolation (see SessionKind). A tab's session is registered here so
    // getWebView can pick its WKWebsiteDataStore when the web view is first built.
    // Absent => normal (shared default store). Populated on tab creation and synced
    // from the tab list (syncSessions) so container tabs restored at launch are known.
    private var tabSessions: [UUID: (kind: SessionKind, sessionId: UUID?)] = [:]
    // Ephemeral incognito stores, held so every tab in one incognito session shares a
    // jar. Dropped (and thus wiped) when a session's last tab closes; all die on quit.
    private var incognitoStores: [UUID: WKWebsiteDataStore] = [:]

    // Saved WKWebView.interactionState for tabs unloaded under memory pressure,
    // consumed when the tab is reactivated (restores scroll + back/forward).
    private var savedInteractionStates: [UUID: Any] = [:]
    // Native WebKit media suspension is reapplied when an unloaded tab's web
    // view is recreated. A real close removes the intent with the tab.
    private var mediaSuspendedTabs: Set<UUID> = []

    // Active web view for the currently selected tab
    @Published var activeWebView: WKWebView?

    // Installed by the owning ContentView so extension requests create a real
    // app tab and can return its identity to WebKit.
    var extensionTabCreationHandler: ((URL?, Bool) -> UUID?)?

    func createExtensionTab(
        at url: URL?,
        shouldActivate: Bool
    ) -> UUID? {
        extensionTabCreationHandler?(url, shouldActivate)
    }

    // Card previews for the omnibar and the ⌘O tab grid. In-memory only: Tab has a
    // lastThumbnail column, but filling it would sync image blobs to CloudKit for a
    // purely cosmetic cache. Tabs with no capture yet fall back to their favicon.
    @Published private(set) var thumbnails: [UUID: WebViewThumbnail] = [:]

    // Stand-in cards for tabs this session has never rendered: the page's own
    // og:image — what any chat app shows when you paste the link — costs one
    // metadata fetch instead of a whole content process, so a restored session
    // has something to look at immediately. A real snapshot always wins.
    @Published private(set) var linkPreviewImages: [UUID: WebViewThumbnail] = [:]
    private var linkPreviewRequested: Set<UUID> = []

    func thumbnail(for tabId: UUID) -> WebViewThumbnail? {
        thumbnails[tabId] ?? linkPreviewImages[tabId]
    }

    /// One metadata fetch per tab per session. Callers must exclude incognito
    /// tabs: this fetch happens outside the tab's ephemeral data store.
    func warmLinkPreviews(for targets: [(id: UUID, url: URL?)]) {
        for target in targets {
            guard let url = target.url,
                  url.scheme == "http" || url.scheme == "https",
                  thumbnails[target.id] == nil,
                  linkPreviewImages[target.id] == nil,
                  linkPreviewRequested.insert(target.id).inserted else { continue }
            Task { @MainActor [weak self] in
                guard let image = await LinkPreviewCards.image(for: url),
                      let self, self.thumbnails[target.id] == nil else { return }
                self.linkPreviewImages[target.id] = image
            }
        }
    }

    #if canImport(AppKit)
    // Off-screen preview warm-up. Implementation in TabPreviewOven.swift.
    var ovenQueue: [(id: UUID, url: URL?)] = []
    var ovenBaking: UUID?
    var ovenWindow: NSWindow?
    #endif

    // Only a web view that is in a window and not hidden actually paints, so
    // this captures the tab you're leaving, the tab you're on, and whatever the
    // oven has parked off screen. A hidden background tab snapshots blank, and
    // a blank card is worse than a stale one — hence the isHidden guard.
    func captureThumbnail(for tabId: UUID?, afterScreenUpdates: Bool = true) {
        guard let tabId, let webView = webViews[tabId],
              webView.window != nil, !webView.isHidden, webView.bounds.width > 0 else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 400
        // Off screen there are no screen updates to wait for; the web content
        // process renders the frame either way.
        config.afterScreenUpdates = afterScreenUpdates
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let image else { return }
            self?.thumbnails[tabId] = image
        }
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(adBlockSettingChanged), name: .adBlockChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(javaScriptSettingChanged), name: .javaScriptChanged, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sitePermissionsChanged),
            name: .sitePermissionsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(historyDidClear), name: .browserHistoryDidClear, object: nil)
        // Restore last session's per-tab page state; getWebView consumes it the
        // first time each tab is activated. Persist again when the app quits.
        loadPersistedInteractionStates()
        #if canImport(AppKit)
        NotificationCenter.default.addObserver(
            self, selector: #selector(persistInteractionStates),
            name: NSApplication.willTerminateNotification, object: nil)
        #endif
        startMemoryPressureMonitoring()
        Logger.log("WebViewManager initialized", type: "WebViewManager")
    }

    // MARK: - Session restore (local, per-tab scroll + in-page history)

    // interactionState for open tabs, stashed between launches so a relaunch
    // resumes each page where it was. Local (Application Support) on purpose: it
    // never touches the iCloud cache-state column, so the sync privacy toggle
    // stays authoritative for what leaves the device.
    private static var interactionStateFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SessionInteractionState.plist")
    }

    static func clearPersistedInteractionStateFile() {
        guard let url = interactionStateFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    @objc private func historyDidClear() {
        savedInteractionStates.removeAll()
        Self.clearPersistedInteractionStateFile()
    }

    private func loadPersistedInteractionStates() {
        guard #available(macOS 12.0, *),
              let url = Self.interactionStateFileURL else { return }
        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > InteractionStatePersistencePolicy.maxFileBytes {
            try? FileManager.default.removeItem(at: url)
            Logger.log("Discarded oversized persisted interaction state", type: "WebViewManager")
            return
        }
        guard
              let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data]
        else { return }
        for (idString, stateData) in InteractionStatePersistencePolicy.bounded(raw) {
            guard let id = UUID(uuidString: idString),
                  let state = NSKeyedUnarchiver.unarchiveTopLevelObject(from: stateData) else { continue }
            savedInteractionStates[id] = state
        }
        Logger.log("Loaded \(savedInteractionStates.count) persisted interaction states", type: "WebViewManager")
    }

    // Archive open tabs' page state to disk. Live web views win over a stale
    // saved copy for the same tab. The bounded payload prevents a large session
    // or pathological WebKit state from growing Application Support without limit.
    // Internal (not private) so the hold-to-quit gate can trigger it early,
    // while the progress bar is still filling — see KeyboardShortcutsManager.
    @objc func persistInteractionStates() {
        guard #available(macOS 12.0, *), let url = Self.interactionStateFileURL else { return }
        var out: [String: Data] = [:]
        // Never persist incognito tabs' page state — that would write a private URL
        // (and form/scroll state) to disk, defeating the point of incognito.
        for (id, state) in savedInteractionStates where !isPrivateTab(id) {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false) {
                out[id.uuidString] = data
            }
        }
        for (id, webView) in webViews where !isPrivateTab(id) {
            if let state = webView.interactionState,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false) {
                out[id.uuidString] = data
            }
        }
        let bounded = InteractionStatePersistencePolicy.bounded(out)
        guard let plist = try? PropertyListSerialization.data(
            fromPropertyList: bounded,
            format: .binary,
            options: 0
        ) else { return }
        try? plist.write(to: url, options: .atomic)
        Logger.log("Persisted \(bounded.count) interaction states", type: "WebViewManager")
    }

    // MARK: - Memory pressure

    // The OS signals when memory is tight; we relay it so ContentView (which
    // knows each tab's policy) decides what to unload. ponytail: macOS exposes
    // only .warning/.critical, so "always" and "when needed" share the warning
    // trigger. Upgrade path: poll os_proc_available_memory() for finer tiers.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            let critical = source?.data.contains(.critical) ?? false
            Logger.log("Memory pressure relayed (critical=\(critical))", type: "WebViewManager")
            NotificationCenter.default.post(name: .memoryPressure, object: nil, userInfo: ["critical": critical])
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: - Ad blocking (WKContentRuleList)

    // ponytail: built-in list of the biggest ad/tracker networks, not EasyList.
    // Swap in a downloaded filter list if users want deeper coverage.
    private static let adHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "adservice.google.com", "2mdn.net",
        "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "criteo.com",
        "criteo.net", "taboola.com", "outbrain.com", "rubiconproject.com",
        "pubmatic.com", "openx.net", "moatads.com", "scorecardresearch.com",
        "adsafeprotected.com", "doubleverify.com", "smartadserver.com",
        "casalemedia.com", "33across.com", "quantserve.com", "yieldmo.com",
        "media.net", "teads.tv", "sharethrough.com", "spotxchange.com",
        "indexexchange.com",
    ]

    // The same list the dashboard counts page requests against, so "ads blocked"
    // and "ad requests seen" can never disagree about what an ad host is.
    static var adHostList: [String] { adHosts }

    private static var adBlockList: WKContentRuleList?

    private static func compileAdBlockList(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let list = adBlockList { completion(list); return }
        // Content-blocker regex has no alternation, so one block rule per host
        let rules = adHosts.map { host in
            let escaped = host.replacingOccurrences(of: ".", with: "\\\\.")
            return #"{"trigger":{"url-filter":"^https?://([^/]+\\.)?\#(escaped)[:/]","load-type":["third-party"]},"action":{"type":"block"}}"#
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "sub-adblock",
            encodedContentRuleList: "[\(rules.joined(separator: ","))]"
        ) { list, error in
            if let error {
                Logger.log("Ad block rule compile failed: \(error)", type: "WebViewManager")
            }
            adBlockList = list
            completion(list)
        }
    }

    private static func reportContentBlocking(_ active: Bool, for tabId: UUID) {
        Task { @MainActor in
            PageProtectionStore.shared.setContentBlocking(active, for: tabId)
        }
    }

    @objc private func adBlockSettingChanged() {
        if UserDefaults.standard.bool(forKey: "adBlockEnabled") {
            Self.compileAdBlockList { [weak self] list in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard UserDefaults.standard.bool(forKey: "adBlockEnabled"),
                          let list else {
                        for tabId in self.webViews.keys {
                            Self.reportContentBlocking(false, for: tabId)
                        }
                        return
                    }
                    for (tabId, webView) in self.webViews {
                        let controller = webView.configuration.userContentController
                        controller.remove(list) // avoid double-add
                        controller.add(list)
                        Self.reportContentBlocking(true, for: tabId)
                    }
                    self.reloadAllTabs()
                }
            }
        } else {
            for (tabId, webView) in webViews {
                if let list = Self.adBlockList {
                    webView.configuration.userContentController.remove(list)
                }
                Self.reportContentBlocking(false, for: tabId)
            }
            reloadAllTabs()
        }
    }

    @objc private func javaScriptSettingChanged() {
        reloadAllTabs()
    }

    @objc private func sitePermissionsChanged() {
        reloadAllTabs()
    }

    // Get or create a web view for a specific tab
    func getWebView(for tabId: UUID) -> WKWebView {
        Logger.log("WebViewManager getWebView called for tab \(tabId)", type: "WebViewManager")
        if let existingWebView = webViews[tabId] {
            Logger.log("WebViewManager getWebView: returning existing WebView \(Unmanaged.passUnretained(existingWebView).toOpaque()) for tab \(tabId)", type: "WebViewManager")
            return existingWebView
        }

        Logger.log("WebViewManager: Creating new WKWebView for tab \(tabId)", type: "WebViewManager")
        let webView = createWebView(for: tabId)
        webViews[tabId] = webView
        ownedTabIds.insert(tabId)
        applyMediaSuspension(mediaSuspendedTabs.contains(tabId), to: webView)
        #if canImport(AppKit)
        WebExtensionManager.shared.tabOpened(tabId, in: self)
        #endif
        // Restore scroll + back/forward if this tab was unloaded under memory pressure
        if #available(macOS 12.0, *), let state = savedInteractionStates.removeValue(forKey: tabId) {
            webView.interactionState = state
        }
        Logger.log("WebViewManager: Created new WebView \(Unmanaged.passUnretained(webView).toOpaque()) for tab \(tabId)", type: "WebViewManager")
        return webView
    }

    // Set the active tab (switches which web view is considered active)
    func setActiveTab(_ tabId: UUID?) {
        Logger.log("WebViewManager setActiveTab called with tabId: \(tabId?.uuidString ?? "nil")", type: "WebViewManager")
        guard let tabId = tabId else {
            activeWebView = nil
            return
        }

        let previousTabId = activeTabId
        captureThumbnail(for: previousTabId)   // last look at the tab you're leaving
        let webView = getWebView(for: tabId)
        Logger.log("WebViewManager setActiveTab: got WebView for tab \(tabId): \(Unmanaged.passUnretained(webView).toOpaque())", type: "WebViewManager")
        if activeWebView !== webView {
            Logger.log("WebViewManager: Switching active web view for tab \(tabId)", type: "WebViewManager")
            activeWebView = webView
            #if canImport(AppKit)
            WebExtensionManager.shared.activeTabChanged(
                to: tabId,
                from: previousTabId,
                in: self
            )
            #endif
        } else {
            Logger.log("WebViewManager setActiveTab: activeWebView already correct for tab \(tabId)", type: "WebViewManager")
        }
    }

    // Reverse lookup: which tab owns this web view (delegate callbacks arrive
    // for background webviews too, so callers can't assume "the active tab")
    func tabId(for webView: WKWebView) -> UUID? {
        webViews.first(where: { $0.value === webView })?.key
    }

    // Open-tab state read by the web extension bridge (WebExtension.swift).
    var liveTabIds: [UUID] { Array(ownedTabIds) }
    func existingWebView(for id: UUID) -> WKWebView? { webViews[id] }
    var activeTabId: UUID? { activeWebView.flatMap { tabId(for: $0) } }

    // Remove a web view. `notifyClosed` is true for a real tab close and false
    // for a memory unload (the tab lives on), so the extension bridge only sees
    // genuine closes rather than unload/reactivate churn.
    func removeWebView(for tabId: UUID, notifyClosed: Bool = true) {
        if let webView = webViews[tabId] {
            // Stop any loading and detach so the view can actually deallocate
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "sub")
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: WebKitAgentConsoleBridgeScripts.messageHandlerName
            )
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "subDevTools")
            // World-scoped handlers need the world to be removed.
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: SemanticPageJavaScript.messageHandlerName,
                contentWorld: .defaultClient
            )
            webView.removeFromSuperview()
            contextMenuLinks.removeValue(forKey: ObjectIdentifier(webView))

            // Remove from storage
            webViews.removeValue(forKey: tabId)
            Self.reportContentBlocking(false, for: tabId)

            // If this was the active web view, clear it
            if activeWebView === webView {
                activeWebView = nil
            }

            if notifyClosed {
                #if canImport(AppKit)
                WebExtensionManager.shared.tabClosed(tabId, in: self)
                #endif
            }
            Logger.log("Removed web view for tab \(tabId)", type: "WebViewManager")
        }

        savedInteractionStates.removeValue(forKey: tabId)
        // Keep the session across a memory unload (the tab reactivates and must
        // rebuild in the same store); drop it only on a genuine close. This must
        // run even when the tab never materialized a WebView.
        if notifyClosed {
            Task {
                await BrowserAgentWebKitSignalRuntime.shared.pageClosed(tabID: tabId)
            }
            ownedTabIds.remove(tabId)
            tabSessions.removeValue(forKey: tabId)
            thumbnails.removeValue(forKey: tabId)
            linkPreviewImages.removeValue(forKey: tabId)
            linkPreviewRequested.remove(tabId)
            #if canImport(AppKit)
            Task { @MainActor in TabInsights.shared.forget(tabId) }
            #endif
            #if canImport(AppKit)
            ovenQueue.removeAll { $0.id == tabId }
            #endif
            mediaSuspendedTabs.remove(tabId)
        }
    }

    // Release a tab's web view (and its content process) to reclaim RAM. Saves
    // interaction state (scroll + back/forward) so getWebView restores it when
    // the tab is reactivated. The tab stays open; only its RAM is freed.
    func unloadWebView(for tabId: UUID) {
        guard let webView = webViews[tabId] else { return }
        var state: Any?
        if #available(macOS 12.0, *) { state = webView.interactionState }
        removeWebView(for: tabId, notifyClosed: false)  // unload, not close: keep the extension's tab

        if let state { savedInteractionStates[tabId] = state }  // set AFTER teardown clears it
    }

    // Register an externally created web view (a window.open popup, which must
    // be built from the configuration WebKit hands us) under a tab's ID.
    func adoptWebView(
        _ webView: WKWebView,
        for tabId: UUID,
        navigationDelegate: WKNavigationDelegate,
        uiDelegate: WKUIDelegate
    ) {
        // A popup can immediately receive a download response (Google Docs
        // exports do), before SwiftUI has a chance to attach it to a container.
        // Its delegates must be ready before returning it to WebKit.
        webView.navigationDelegate = navigationDelegate
        webView.uiDelegate = uiDelegate
        applyStandardSetup(to: webView)
        webViews[tabId] = webView
        ownedTabIds.insert(tabId)
        let blockingActive = UserDefaults.standard.bool(forKey: "adBlockEnabled")
            && Self.adBlockList != nil
        if blockingActive, let list = Self.adBlockList {
            let controller = webView.configuration.userContentController
            controller.remove(list)
            controller.add(list)
        }
        Self.reportContentBlocking(blockingActive, for: tabId)
        #if canImport(AppKit)
        WebExtensionManager.shared.tabOpened(tabId, in: self)
        #endif
        Logger.log("WebViewManager: adopted external WebView for tab \(tabId)", type: "WebViewManager")
    }

    // MARK: - Session isolation

    // Record a tab's session so getWebView can pick its data store at creation.
    func registerSession(for tabId: UUID, kind: SessionKind, sessionId: UUID?) {
        if kind == .normal { tabSessions.removeValue(forKey: tabId) }
        else { tabSessions[tabId] = (kind, sessionId) }
    }

    // Rebuild the map from the current tab list. Covers container tabs restored from
    // SwiftData at launch, which must be known before their web views are built.
    func syncSessions(from tabs: [Tab]) {
        for tab in tabs where tab.sessionKind != .normal {
            tabSessions[tab.id] = (tab.sessionKind, tab.sessionId)
        }
    }

    // The WKWebsiteDataStore (cookie/cache/storage jar) a tab browses in. See SessionKind.
    private func dataStore(for tabId: UUID) -> WKWebsiteDataStore {
        guard let session = tabSessions[tabId] else { return .default() }
        switch session.kind {
        case .normal:
            return .default()
        case .container:
            guard let id = session.sessionId else { return .default() }
            return WKWebsiteDataStore(forIdentifier: id)
        case .incognito:
            let id = session.sessionId ?? tabId
            if let store = incognitoStores[id] { return store }
            let store = WKWebsiteDataStore.nonPersistent()
            incognitoStores[id] = store
            return store
        }
    }

    // The store a live tab is using, for scoped cache clearing. Reads the web view's
    // own config when built; otherwise resolves from the registry.
    func dataStore(forTab tabId: UUID) -> WKWebsiteDataStore {
        webViews[tabId]?.configuration.websiteDataStore ?? dataStore(for: tabId)
    }

    // Drop (and thus wipe) an incognito session's jar once its last tab is gone.
    func discardIncognitoStore(_ sessionId: UUID) {
        incognitoStores.removeValue(forKey: sessionId)
    }

    // Build the ephemeral jar for a tab-to-incognito conversion, before any tab
    // joins the session. Cookies are copied from the source tab's store so
    // cookie-based logins survive the switch; localStorage/IndexedDB have no
    // copy API and are left behind, so sites keeping auth tokens there sign out.
    // Completion fires on main once the jar is ready to browse in.
    func prepareIncognitoStore(sessionId: UUID, copyingCookiesFromTab tabId: UUID, completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.nonPersistent()
        incognitoStores[sessionId] = store
        dataStore(forTab: tabId).httpCookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.httpCookieStore.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { completion() }
        }
    }

    // Whether a tab is incognito (its page state must never be persisted to disk).
    func isPrivateTab(_ tabId: UUID) -> Bool {
        tabSessions[tabId]?.kind == .incognito
    }

    // A tab's session, for inheriting it onto a new tab (Cmd+T, window.open popups).
    func session(for tabId: UUID) -> (kind: SessionKind, sessionId: UUID?) {
        tabSessions[tabId] ?? (.normal, nil)
    }

    // Create a new WKWebView with proper configuration
    private func createWebView(for tabId: UUID) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The tab's session decides its cookie/cache/storage jar. Normal tabs get the
        // shared default store (unchanged); containers/incognito get isolated stores.
        // Popups adopted via adoptWebView inherit the opener's store from its config.
        configuration.websiteDataStore = dataStore(for: tabId)
        // Popups adopted via adoptWebView inherit this from the opener's config
        configuration.applicationNameForUserAgent = Self.userAgentAppName

        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // JS on/off is decided per navigation in the policy delegate - the
        // settings toggle read here wouldn't reliably stick
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .video

        // WKUserContentController retains handlers. The weak proxy prevents the
        // manager -> web view -> content controller -> manager retain cycle.
        configuration.userContentController.add(
            WeakScriptMessageHandler(handler: self),
            name: "sub"
        )
        configuration.userContentController.add(
            WeakScriptMessageHandler(handler: self),
            name: WebKitAgentConsoleBridgeScripts.messageHandlerName
        )
        configuration.userContentController.add(
            WeakScriptMessageHandler(handler: self),
            name: "subDevTools"
        )
        // Scoped to the isolated world, where the semantic runtime lives. The
        // "sub" handler above is page-world only (that's what `add(_:name:)`
        // means), so the runtime can't reach it — and giving this its own name
        // is the trust boundary: a page cannot forge messages into a handler it
        // has no reference to.
        configuration.userContentController.add(
            WeakScriptMessageHandler(handler: self),
            contentWorld: .defaultClient,
            name: SemanticPageJavaScript.messageHandlerName
        )
        if UserDefaults.standard.bool(forKey: "adBlockEnabled") {
            Self.reportContentBlocking(false, for: tabId)
            Self.compileAdBlockList { [weak self] list in
                DispatchQueue.main.async {
                    guard let self,
                          UserDefaults.standard.bool(forKey: "adBlockEnabled"),
                          let webView = self.webViews[tabId],
                          let list else {
                        Self.reportContentBlocking(false, for: tabId)
                        return
                    }
                    let controller = webView.configuration.userContentController
                    controller.remove(list)
                    controller.add(list)
                    Self.reportContentBlocking(true, for: tabId)
                }
            }
        } else {
            Self.reportContentBlocking(false, for: tabId)
        }
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.contextMenuScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.developerToolsScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: SemanticPageJavaScript.bootstrap,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .defaultClient
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.translateScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        // Must run before any page code so feature detection sees the truth, and
        // in subframes because sign-in flows are often framed.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.hideWebAuthnScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        // Attach the app-wide web extension controller so any loaded extension's
        // content scripts run in this tab. Inert when no extension is loaded, but
        // must be set before the web view exists — it can't be added later.
        // ponytail: web extensions are macOS-only in v1; the controller wiring is
        // compiled out on iPad. Port WebExtension.swift when iPad needs extensions.
        #if canImport(AppKit)
        configuration.webExtensionController = WebExtensionManager.shared.controller
        WebExtensionManager.shared.register(self)
        #endif

        let webView = BrowserWKWebView(frame: .zero, configuration: configuration)
        applyStandardSetup(to: webView)
        return webView
    }

    private func applyStandardSetup(to webView: WKWebView) {
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        if #available(macOS 13.3, *) {
            // Right-click > Inspect Element via Safari Web Inspector
            webView.isInspectable = true
        }
        // What WebKit paints where the page hasn't yet — the source of the white
        // flash. Matching the window means even an unpainted web view is invisible.
        #if os(macOS)
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .windowBackgroundColor }
        #endif
    }

    func contextMenuLink(for webView: WKWebView) -> URL? {
        contextMenuLinks[ObjectIdentifier(webView)]
    }

    // MARK: - Fade in on first paint

    // Between didCommit (old document gone) and the page's first paint there is
    // nothing to show, and WebKit flashes its background. So: hide at commit,
    // fade in when the page's double-rAF ping says pixels exist. Backstops —
    // didFinish, didFail, and a hard timer — cover content that never runs our
    // script (PDFs, downloads, plugin content) so a tab can't be left blank.
    private var fadePending: Set<ObjectIdentifier> = []

    func beginFadeIn(_ webView: WKWebView) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "fadeInPages") == nil || defaults.bool(forKey: "fadeInPages") else { return }
        fadePending.insert(ObjectIdentifier(webView))
        setAlpha(webView, 0, duration: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak webView] in
            guard let webView else { return }
            self?.revealPage(webView)
        }
    }

    func revealPage(_ webView: WKWebView) {
        guard fadePending.remove(ObjectIdentifier(webView)) != nil else { return }
        let ms = UserDefaults.standard.object(forKey: "fadeInDuration") as? Double ?? 250
        setAlpha(webView, 1, duration: min(max(ms, 100), 1000) / 1000)
    }

    private func setAlpha(_ webView: WKWebView, _ alpha: CGFloat, duration: TimeInterval) {
        #if os(macOS)
        guard duration > 0 else { webView.alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup {
            $0.duration = duration
            webView.animator().alphaValue = alpha
        }
        #else
        UIView.animate(withDuration: duration) { webView.alpha = alpha }
        #endif
    }

    // Navigation methods that delegate to the active web view
    func goBack() {
        activeWebView?.goBack()
    }

    func goForward() {
        activeWebView?.goForward()
    }

    func reload() {
        activeWebView?.reload()
    }

    func reloadAllTabs() {
        for (_, webView) in webViews {
            webView.reload()
        }
    }

    func stopLoading() {
        activeWebView?.stopLoading()
    }

    func load(_ request: URLRequest) {
        activeWebView?.load(request)
    }

    // Computed properties that delegate to the active web view
    var canGoBack: Bool {
        activeWebView?.canGoBack ?? false
    }

    var canGoForward: Bool {
        activeWebView?.canGoForward ?? false
    }

    var isLoading: Bool {
        activeWebView?.isLoading ?? false
    }

    var url: URL? {
        activeWebView?.url
    }

    var title: String? {
        activeWebView?.title
    }

    var estimatedProgress: Double {
        activeWebView?.estimatedProgress ?? 0.0
    }

    // Evaluate JavaScript on the active web view
    func evaluateJavaScript(_ javaScriptString: String, completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil) {
        activeWebView?.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
    }

    func activateAgentConsoleBridge(on webView: WKWebView, token: String) async throws {
        let scripts = WebKitAgentConsoleBridgeScripts(configuration: .init(token: token))
        _ = try await webView.callAsyncJavaScript(
            scripts.installation + "\nreturn true;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    func setMuted(_ muted: Bool, for tabId: UUID) {
        let wasSuspended = mediaSuspendedTabs.contains(tabId)
        if muted {
            mediaSuspendedTabs.insert(tabId)
        } else {
            mediaSuspendedTabs.remove(tabId)
        }
        guard wasSuspended != muted else { return }
        guard let webView = webViews[tabId] else { return }
        applyMediaSuspension(muted, to: webView)
    }

    func isMediaSuspended(for tabId: UUID) -> Bool {
        mediaSuspendedTabs.contains(tabId)
    }

    private func applyMediaSuspension(_ suspended: Bool, to webView: WKWebView) {
        // Native suspension covers frames, WebAudio, current media, and media
        // created later. Page script cannot resume it until the app revokes it.
        webView.setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
    }

    // Clean up all web views
    func cleanup() {
        for (_, webView) in webViews {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "sub")
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: WebKitAgentConsoleBridgeScripts.messageHandlerName
            )
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "subDevTools")
            // World-scoped handlers need the world to be removed.
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: SemanticPageJavaScript.messageHandlerName,
                contentWorld: .defaultClient
            )
            webView.removeFromSuperview()
        }
        webViews.removeAll()
        mediaSuspendedTabs.removeAll()
        activeWebView = nil
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        cleanup()
        Logger.log("WebViewManager deallocated", type: "WebViewManager")
    }
}

extension WebViewManager: WKScriptMessageHandler {
    private func publishAgentSignal(_ draft: WebKitAgentSignalDraft, from webView: WKWebView) {
        guard let tabID = tabId(for: webView) else { return }
        Task {
            await BrowserAgentWebKitSignalRuntime.shared.publish(draft, tabID: tabID)
        }
    }

    private func agentFrameSource(for message: WKScriptMessage) -> WebKitAgentFrameSource {
        guard !message.frameInfo.isMainFrame else { return .mainFrame }
        let frameURL = message.frameInfo.request.url
        let mainURL = message.webView?.url
        let origin = frameURL.flatMap(Self.agentOrigin)
        let isSameOrigin = frameURL?.scheme?.lowercased() == mainURL?.scheme?.lowercased()
            && frameURL?.host()?.lowercased() == mainURL?.host()?.lowercased()
            && frameURL?.port == mainURL?.port
        return isSameOrigin
            ? .sameOriginSubframe(origin: origin)
            : .crossOriginBoundary(origin: origin)
    }

    private static func agentOrigin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else {
            return nil
        }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// Autofill focus signals from the isolated world.
    ///
    /// The rect is converted here rather than in JavaScript because this is
    /// where the web view — and therefore its bounds, zoom, and split-pane
    /// position — is in hand.
    private func handleSemanticRuntimeMessage(_ body: [String: Any], from message: WKScriptMessage) {
        guard let type = body["type"] as? String else { return }
        // The runtime is main-frame-only, but assert it: an iframe must never be
        // able to summon a suggestion list.
        guard message.frameInfo.isMainFrame else { return }

        switch type {
        case "autofillFieldFocused":
            guard let webView = message.webView,
                  let tabID = tabId(for: webView),
                  let signal = try? AutofillFocusSignal.decode(body) else { return }
            // Page zoom and pinch magnification multiply. `magnification` is
            // AppKit-only; iPad has no autofill UI listening for this anyway.
            #if os(macOS)
            let scale = max(webView.pageZoom * webView.magnification, 0.01)
            #else
            let scale = max(webView.pageZoom, 0.01)
            #endif
            let viewRect = AutofillGeometry.viewRect(
                css: signal.rect,
                in: webView.bounds,
                scale: scale
            )
            NotificationCenter.default.post(
                name: .browserAutofillFieldFocused,
                object: nil,
                userInfo: [
                    "signal": signal,
                    "tabID": tabID,
                    "rect": webView.convert(viewRect, to: nil),
                    "url": webView.url as Any,
                ]
            )
        case "autofillFieldDismissed":
            NotificationCenter.default.post(name: .browserAutofillDismissed, object: nil)
        default:
            break
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if message.name == "subDevTools" {
            guard let webView = message.webView,
                  let tabID = tabId(for: webView),
                  let type = body["type"] as? String else { return }
            switch type {
            case "console":
                guard let level = body["level"] as? String,
                      let text = body["message"] as? String else { return }
                NotificationCenter.default.post(
                    name: .browserDeveloperConsoleMessage,
                    object: nil,
                    userInfo: [
                        "tabID": tabID,
                        "level": level,
                        "message": String(text.prefix(16_384)),
                        "source": String((body["source"] as? String ?? "").prefix(2_048)),
                        "line": (body["line"] as? NSNumber)?.intValue ?? 0,
                        "column": (body["column"] as? NSNumber)?.intValue ?? 0,
                        "timestamp": (body["timestamp"] as? NSNumber)?.doubleValue ?? 0,
                    ]
                )
            case "inspectHover", "inspectSelect", "inspectCancel":
                guard message.frameInfo.isMainFrame else { return }
                NotificationCenter.default.post(
                    name: .browserDeveloperElementInspected,
                    object: nil,
                    userInfo: [
                        "tabID": tabID,
                        "type": type,
                        "selector": String((body["selector"] as? String ?? "").prefix(8_192)),
                        "description": String((body["description"] as? String ?? "").prefix(1_024)),
                    ]
                )
            default:
                break
            }
            return
        }
        if message.name == WebKitAgentConsoleBridgeScripts.messageHandlerName {
            guard let webView = message.webView,
                  let tabID = tabId(for: webView),
                  let token = body["token"] as? String,
                  let rawLevel = body["level"] as? String,
                  let level = WebKitAgentConsoleLevel(rawValue: rawLevel),
                  let text = body["message"] as? String else { return }
            let bridgeMessage = WebKitAgentConsoleBridgeMessage(
                token: token,
                level: level,
                message: text,
                sourceOrigin: body["sourceOrigin"] as? String,
                line: (body["line"] as? NSNumber)?.uintValue,
                column: (body["column"] as? NSNumber)?.uintValue,
                frame: agentFrameSource(for: message)
            )
            Task {
                await BrowserAgentWebKitSignalRuntime.shared.publishConsole(
                    bridgeMessage,
                    tabID: tabID
                )
            }
            return
        }
        if message.name == SemanticPageJavaScript.messageHandlerName {
            handleSemanticRuntimeMessage(body, from: message)
            return
        }
        guard let type = body["type"] as? String else { return }

        switch type {
        case "contextLink":
            guard let webView = message.webView else { return }
            let key = ObjectIdentifier(webView)
            if let urlString = body["url"] as? String,
               let url = URL(string: urlString),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                contextMenuLinks[key] = url
            } else {
                contextMenuLinks.removeValue(forKey: key)
            }
        case "downloadImage":
            if let urlString = body["url"] as? String,
               let url = URL(string: urlString),
               SettingsManager.shared.optionClickShouldDownload(url, isImage: true),
               let webView = message.webView {
                webView.startDownload(using: URLRequest(url: url)) { download in
                    // The coordinator owns destinations, progress, pause/restart,
                    // and the originating-tab association for every download.
                    #if os(macOS)
                    if let coordinator = webView.navigationDelegate as? WebView.Coordinator {
                        coordinator.track(download, from: webView)
                    } else {
                        download.delegate = webView.navigationDelegate as? WKDownloadDelegate
                    }
                    #else
                    download.delegate = webView.navigationDelegate as? WKDownloadDelegate
                    #endif
                }
            }
        case "painted":
            if let webView = message.webView {
                revealPage(webView)
                if let tabID = tabId(for: webView) {
                    NotificationCenter.default.post(
                        name: .browserDeveloperPageDidLoad,
                        object: nil,
                        userInfo: ["tabID": tabID]
                    )
                }
            }
        case "agentDOMContentLoaded":
            if let webView = message.webView {
                publishAgentSignal(
                    .pageLifecycle(.init(phase: .domContentLoaded, url: webView.url)),
                    from: webView
                )
            }
        case "agentLasso":
            guard let webView = message.webView,
                  let tabID = tabId(for: webView),
                  let x = (body["x"] as? NSNumber)?.doubleValue,
                  let y = (body["y"] as? NSNumber)?.doubleValue,
                  let width = (body["width"] as? NSNumber)?.doubleValue,
                  let height = (body["height"] as? NSNumber)?.doubleValue,
                  width >= 4, height >= 4 else { return }
            NotificationCenter.default.post(
                name: .browserAgentLassoSelected,
                object: nil,
                userInfo: ["tabID": tabID, "rect": CGRect(x: x, y: y, width: width, height: height)]
            )
        case "linkDown":
            if let urlString = body["url"] as? String, let url = URL(string: urlString) {
                NotificationCenter.default.post(name: .browserLinkPreviewDown, object: nil, userInfo: ["url": url])
            }
        case "linkLongPress":
            NotificationCenter.default.post(name: .browserLinkPreviewLongPress, object: nil)
        case "linkUp":
            NotificationCenter.default.post(name: .browserLinkPreviewUp, object: nil)
        default:
            break
        }
    }
}

/// WKWebView subclass whose only job is the iOS text-selection edit menu:
/// "Anchor" beside Copy is the one truly low-friction selection gesture iOS
/// allows (Phase 2, design §6.1). A plain WKWebView everywhere else.
final class BrowserWKWebView: WKWebView {
    #if os(iOS)
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        let anchor = UIAction(
            title: String(localized: "Anchor"),
            image: UIImage(systemName: "link.badge.plus")
        ) { _ in
            NotificationCenter.default.post(name: .browserAnchorSelection, object: nil)
        }
        builder.insertSibling(UIMenu(options: .displayInline, children: [anchor]),
                              afterMenu: .standardEdit)
    }
    #endif
}
