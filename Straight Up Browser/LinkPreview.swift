//
//  LinkPreview.swift
//  Straight Up Browser
//
//  Long-press a link to preview it. The page script posts linkDown on
//  mousedown (prefetch starts immediately), linkLongPress after 500ms of
//  holding, and linkUp on a short click (cancels the prefetch). The preview
//  panel appears only once the page has actually loaded.
//

import SwiftUI
import WebKit
import Combine

final class LinkPreviewManager: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isShowing = false

    let webView: WKWebView
    private var wantPreview = false
    private var contentReady = false
    private var escMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    override init() {
        // Plain configuration: no page script, so previews can't nest previews
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.customUserAgent = WebViewManager.userAgent
        webView.navigationDelegate = self

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .browserLinkPreviewDown, object: nil, queue: .main) { [weak self] note in
            if let url = note.userInfo?["url"] as? URL {
                self?.linkDown(url)
            }
        })
        observers.append(center.addObserver(forName: .browserLinkPreviewLongPress, object: nil, queue: .main) { [weak self] _ in
            self?.wantPreview = true
            self?.maybeShow()
        })
        observers.append(center.addObserver(forName: .browserLinkPreviewUp, object: nil, queue: .main) { [weak self] _ in
            // Short click: the real navigation is happening; drop the prefetch
            guard let self = self, !self.isShowing else { return }
            self.webView.stopLoading()
            self.wantPreview = false
        })
    }

    private func linkDown(_ url: URL) {
        guard !isShowing else { return }
        wantPreview = false
        contentReady = false
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        contentReady = true
        maybeShow()
    }

    private func maybeShow() {
        guard wantPreview, contentReady, !isShowing else { return }
        isShowing = true
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dismiss()
                return nil
            }
            return event
        }
    }

    func dismiss() {
        isShowing = false
        wantPreview = false
        webView.stopLoading()
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// Hosts an externally owned WKWebView (the preview)
struct StaticWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
