//
//  ScreenshotManager.swift
//  Straight Up Browser
//
//  The four capture shortcuts (⌘S / ⇧⌘S / ⌥⌘S / ⇧⌥⌘S) and the settings behind
//  them. Each kind picks its own destinations — clipboard, the shared folder,
//  its own folder — and each destination picks its own format.
//
//  macOS only: every capture path is AppKit/WKWebView specific.
//

import AppKit
import PDFKit
import ScreenCaptureKit
import WebKit
import SwiftUI

// MARK: - Model

enum ScreenshotKind: String, CaseIterable, Codable, Identifiable {
    case visible, fullPage, element, window

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .visible: return "Visible Area"
        case .fullPage: return "Full Page"
        case .element: return "Element Under Cursor"
        case .window: return "Window and Tab Bar"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .visible: return "What the page is showing right now."
        case .fullPage: return "The whole document, top to bottom, however far it scrolls."
        case .element: return "Whatever the mouse is over — an image, a field, or a block of text."
        case .window: return "The entire window, tab bar and all."
        }
    }

    var command: ShortcutCommand {
        switch self {
        case .visible: return .screenshotVisible
        case .fullPage: return .screenshotFullPage
        case .element: return .screenshotElement
        case .window: return .screenshotWindow
        }
    }
}

enum ScreenshotFormat: String, CaseIterable, Codable, Identifiable {
    case png, jpg, pdf

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var label: String {
        switch self {
        case .png: return "PNG"
        case .jpg: return "JPEG"
        case .pdf: return "PDF"
        }
    }
}

// How ⇧⌥⌘S gets the window. Only the window server can see the SwiftUI tab
// list, and reaching it means Screen Recording permission — so we ask once,
// up front, rather than letting macOS spring the prompt on someone.
enum WindowCaptureMode: String, CaseIterable, Identifiable {
    case ask, full, limited

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .ask: return "Ask the first time"
        case .full: return "Full window (needs permission)"
        case .limited: return "Limited (no permission)"
        }
    }
}

struct ScreenshotDestination: Codable, Equatable {
    var enabled: Bool
    var format: ScreenshotFormat
}

struct ScreenshotConfig: Codable, Equatable {
    var clipboard = ScreenshotDestination(enabled: true, format: .png)
    var shared = ScreenshotDestination(enabled: false, format: .png)
    var own = ScreenshotDestination(enabled: false, format: .png)
    // Empty means unset — same convention as `downloadsFolder`.
    var ownFolder = ""
}

// MARK: - Settings store

// Same shape as ShortcutStore: one JSON blob in UserDefaults, @Observable so the
// settings pane re-renders. Only the two folder/scope scalars live as plain
// keys, because @AppStorage reads them directly in the pane.
@Observable
final class ScreenshotSettings {
    static let shared = ScreenshotSettings()

    enum Key {
        static let configs = "screenshotSettings"
        static let sharedFolder = "screenshotSharedFolder"
        static let visibleWholeContentArea = "screenshotVisibleWholeContentArea"
        static let windowCaptureMode = "screenshotWindowCaptureMode"
    }

    private(set) var configs: [String: ScreenshotConfig] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Key.configs),
           let decoded = try? JSONDecoder().decode([String: ScreenshotConfig].self, from: data) {
            configs = decoded
        }
    }

    func config(for kind: ScreenshotKind) -> ScreenshotConfig {
        configs[kind.rawValue] ?? ScreenshotConfig()
    }

    func update(_ kind: ScreenshotKind, _ mutate: (inout ScreenshotConfig) -> Void) {
        var config = self.config(for: kind)
        mutate(&config)
        configs[kind.rawValue] = config
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: Key.configs)
        }
    }

    // One call per control in the settings pane — the thing that keeps a
    // 4-kinds × 7-controls grid from becoming 28 hand-written bindings.
    func binding<V>(_ kind: ScreenshotKind, _ path: WritableKeyPath<ScreenshotConfig, V>) -> Binding<V> {
        Binding(
            get: { self.config(for: kind)[keyPath: path] },
            set: { value in self.update(kind) { $0[keyPath: path] = value } }
        )
    }

    /// Where "save to the shared folder" writes. Empty setting = ~/Pictures/Browser Screenshots.
    var sharedFolder: URL {
        let custom = UserDefaults.standard.string(forKey: Key.sharedFolder) ?? ""
        guard custom.isEmpty else { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Browser Screenshots", isDirectory: true)
    }

    /// ⌘S over a split: focused pane only (default), or every pane composited.
    var visibleCapturesWholeContentArea: Bool {
        UserDefaults.standard.bool(forKey: Key.visibleWholeContentArea)
    }

    /// Unset means we haven't explained the permission trade-off yet.
    var windowCaptureMode: WindowCaptureMode {
        get {
            (UserDefaults.standard.string(forKey: Key.windowCaptureMode)).flatMap(WindowCaptureMode.init) ?? .ask
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.windowCaptureMode) }
    }
}

// MARK: - Capture

// A finished capture: the pixels (nil when a PDF came straight from WebKit),
// a pre-encoded PDF when we have one, and where on screen it came from so the
// flash can cover exactly that.
private struct Shot {
    var image: NSImage?
    var vectorPDF: Data?
    var rectInWindow: CGRect
    var source: URL?
    var pageTitle: String?
}

enum ScreenshotManager {

    // MARK: Entry points

    static func capture(_ kind: ScreenshotKind, in webViewManager: WebViewManager) {
        guard let webView = webViewManager.activeWebView else { return }
        switch kind {
        case .visible:
            if ScreenshotSettings.shared.visibleCapturesWholeContentArea,
               let container = contentContainer(of: webView) {
                composite(container) { deliver($0, kind: kind, webView: webView) }
            } else {
                snapshot(webView, rect: nil) { deliver($0, kind: kind, webView: webView) }
            }
        case .fullPage:
            captureFullPage(webView, kind: kind)
        case .element:
            captureElement(webView, kind: kind)
        case .window:
            guard let window = webView.window else { return }
            switch ScreenshotSettings.shared.windowCaptureMode {
            case .ask:
                explainWindowCapture(on: window) { choice in
                    guard let choice else { return }  // cancelled: capture nothing
                    ScreenshotSettings.shared.windowCaptureMode = choice
                    captureWindow(window, mode: choice) { deliver($0, kind: kind, webView: webView) }
                }
            case let mode:
                captureWindow(window, mode: mode) { deliver($0, kind: kind, webView: webView) }
            }
        }
    }

    // MARK: Window

    /// Has the user granted Screen Recording? Preflight never prompts, so this
    /// is safe to call from the settings pane just to render a hint.
    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // Shown once, before macOS would spring its own Screen Recording prompt.
    // Someone on a managed machine can't grant that permission at all, so the
    // limited path has to be a real answer here, not a consolation prize —
    // hence two equal-weight cards rather than an alert with a default button.
    private static func explainWindowCapture(on window: NSWindow, completion: @escaping (WindowCaptureMode?) -> Void) {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Answered exactly once: whichever path fires first wins, and any later
        // call is a no-op rather than a second endSheet on a closed sheet.
        var answered = false
        let finish: (WindowCaptureMode?) -> Void = { [weak window, weak sheet] choice in
            guard !answered, let sheet else { return }
            answered = true
            window?.endSheet(sheet)
            completion(choice)
        }

        sheet.contentViewController = NSHostingController(
            rootView: WindowCapturePanel(onChoose: { finish($0) }, onCancel: { finish(nil) })
        )
        sheet.titlebarAppearsTransparent = true
        window.beginSheet(sheet)
    }

    private static func captureWindow(_ window: NSWindow, mode: WindowCaptureMode, completion: @escaping (NSImage?) -> Void) {
        guard let contentView = window.contentView else {
            completion(nil)
            return
        }
        guard mode == .full else {
            composite(contentView, completion: completion)
            return
        }
        captureWindowViaScreenCapture(window) { image in
            if let image {
                completion(image)
            } else {
                // Asked for permission and didn't get it (or not yet) — still
                // hand back a screenshot rather than nothing.
                composite(contentView, completion: completion)
            }
        }
    }

    // The tab bar is SwiftUI, and neither cacheDisplay nor CALayer.render picks
    // its list up — both leave a flat column where the tabs should be. Only the
    // window server has the real pixels, so this is ScreenCaptureKit's job even
    // though the window is our own — and that means Screen Recording permission.
    private static func captureWindowViaScreenCapture(_ window: NSWindow, completion: @escaping (NSImage?) -> Void) {
        Task {
            let image: NSImage? = await {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                        return nil
                    }
                    let config = SCStreamConfiguration()
                    let scale = window.backingScaleFactor
                    config.width = Int(target.frame.width * scale)
                    config.height = Int(target.frame.height * scale)
                    config.showsCursor = false
                    let cgImage = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: target),
                        configuration: config
                    )
                    return NSImage(cgImage: cgImage, size: target.frame.size)
                } catch {
                    Logger.log("Window capture unavailable, compositing instead: \(error.localizedDescription)",
                               type: "ScreenshotManager")
                    return nil
                }
            }()
            await MainActor.run { completion(image) }
        }
    }

    // MARK: Visible / element

    private static func snapshot(_ webView: WKWebView, rect: CGRect?, completion: @escaping (NSImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        if let rect { config.rect = rect }
        webView.takeSnapshot(with: config) { image, _ in completion(image) }
    }

    private static func captureElement(_ webView: WKWebView, kind: ScreenshotKind) {
        guard let window = webView.window else { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        // With a split open the mouse may be over a pane that isn't the focused
        // one — "under the cursor" means that pane, not the focused tab.
        let target = paneUnderMouse(from: webView, pointInWindow: inWindow) ?? webView
        let inView = target.convert(inWindow, from: nil)
        guard target.bounds.contains(inView) else { return }

        // AppKit's y grows upward, CSS's grows downward, and page zoom scales
        // between CSS pixels and view points.
        let zoom = max(target.magnification, 0.01)
        let cssX = inView.x / zoom
        let cssY = (target.bounds.height - inView.y) / zoom

        target.evaluateJavaScript(elementRectJS(x: cssX, y: cssY)) { result, _ in
            guard let r = result as? [String: Double],
                  let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"], w > 1, h > 1 else { return }
            // Back to view points, then flip y again for the snapshot rect.
            let viewRect = CGRect(
                x: x * zoom,
                y: target.bounds.height - (y + h) * zoom,
                width: w * zoom,
                height: h * zoom
            ).intersection(target.bounds)
            guard !viewRect.isNull, viewRect.width > 1, viewRect.height > 1 else { return }
            snapshot(target, rect: viewRect) {
                deliver($0, kind: kind, webView: target, rectInView: viewRect)
            }
        }
    }

    // Pick the element under (x, y), then climb to something worth framing.
    // ponytail: "climb until it gets big" heuristic — swap in a readability-style
    // block scorer if it grabs the wrong container on real pages.
    private static func elementRectJS(x: Double, y: Double) -> String {
        """
        (function() {
          var el = document.elementFromPoint(\(x), \(y));
          if (!el) return null;
          var atomic = ['IMG','VIDEO','CANVAS','SVG','INPUT','TEXTAREA','SELECT','BUTTON','PICTURE'];
          if (atomic.indexOf(el.tagName) === -1) {
            var viewport = window.innerWidth * window.innerHeight;
            var node = el;
            while (node.parentElement && node.parentElement.tagName !== 'BODY') {
              var pr = node.parentElement.getBoundingClientRect();
              if (pr.width * pr.height > viewport * 0.6) break;
              node = node.parentElement;
            }
            el = node;
          }
          var r = el.getBoundingClientRect();
          return { x: r.left, y: r.top, w: r.width, h: r.height };
        })()
        """
    }

    // MARK: Full page

    private static func captureFullPage(_ webView: WKWebView, kind: ScreenshotKind) {
        // Every destination wanting PDF? WebKit already renders the whole
        // document as vector — no resize dance, and the text stays selectable.
        let config = ScreenshotSettings.shared.config(for: kind)
        let destinations = [config.clipboard, config.shared, config.own].filter(\.enabled)
        if !destinations.isEmpty, destinations.allSatisfy({ $0.format == .pdf }) {
            webView.createPDF { result in
                guard case .success(let data) = result else { return }
                deliver(Shot(image: nil, vectorPDF: data,
                             rectInWindow: rectInWindow(webView, rect: nil),
                             source: webView.url, pageTitle: webView.title), kind: kind)
            }
            return
        }

        webView.evaluateJavaScript("[document.documentElement.scrollWidth, document.documentElement.scrollHeight]") { result, _ in
            guard let size = result as? [Double], size.count == 2 else {
                snapshot(webView, rect: nil) { deliver($0, kind: kind, webView: webView) }
                return
            }
            let zoom = max(webView.magnification, 0.01)
            // ponytail: hard cap so a runaway infinite-scroll page can't try to
            // allocate a gigapixel bitmap. Add scroll-and-stitch if the cap bites.
            let full = CGSize(width: min(size[0] * zoom, 20000), height: min(size[1] * zoom, 20000))
            let original = webView.frame
            webView.frame = CGRect(origin: original.origin, size: full)
            // One runloop hop so WebKit lays out at the new size before we ask.
            DispatchQueue.main.async {
                snapshot(webView, rect: nil) { image in
                    webView.frame = original
                    deliver(image, kind: kind, webView: webView)
                }
            }
        }
    }

    // MARK: Compositing

    // WKWebView renders out of process, so the chrome capture leaves a hole where
    // the page should be — draw each pane's snapshot back in on top.
    // ponytail: composite rather than CGWindowListCreateImage, which would make
    // the app ask for Screen Recording permission to photograph its own window.
    private static func composite(_ view: NSView, completion: @escaping (NSImage?) -> Void) {
        // Draw everything into one image: the chrome first, the pane snapshots
        // on top. cacheDisplay is the obvious way to get the chrome and the
        // wrong one — it drives drawRect, and SwiftUI's tab bar draws through
        // Core Animation, so the tab list came out solid black. Rendering the
        // layer tree picks up everything the window actually shows.
        func compose(_ overlays: [(NSImage, CGRect)]) -> NSImage {
            let result = NSImage(size: view.bounds.size)
            result.lockFocus()
            if let context = NSGraphicsContext.current?.cgContext, let layer = view.layer {
                context.saveGState()
                // CALayer.render draws top-left-down; lockFocus gives us a
                // bottom-left-up context.
                context.translateBy(x: 0, y: view.bounds.height)
                context.scaleBy(x: 1, y: -1)
                layer.render(in: context)
                context.restoreGState()
            }
            for (image, frame) in overlays {
                image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            }
            result.unlockFocus()
            return result
        }

        let panes = webViews(in: view).filter { !$0.isHidden }
        guard !panes.isEmpty else {
            completion(compose([]))
            return
        }

        var remaining = panes.count
        var overlays: [(NSImage, CGRect)] = []
        for pane in panes {
            var frame = pane.convert(pane.bounds, to: view)
            // The window's content view is an NSHostingView, which is flipped;
            // the image context the overlays draw into never is.
            if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
            pane.takeSnapshot(with: nil) { image, _ in
                if let image { overlays.append((image, frame)) }
                remaining -= 1
                guard remaining == 0 else { return }
                completion(compose(overlays))
            }
        }
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        view.subviews.flatMap { subview -> [WKWebView] in
            (subview as? WKWebView).map { [$0] } ?? webViews(in: subview)
        }
    }

    private static func contentContainer(of webView: WKWebView) -> NSView? {
        var view: NSView? = webView.superview
        while let candidate = view {
            if candidate is WebViewContainer { return candidate }
            view = candidate.superview
        }
        return nil
    }

    private static func paneUnderMouse(from webView: WKWebView, pointInWindow: CGPoint) -> WKWebView? {
        guard let container = contentContainer(of: webView) else { return nil }
        return webViews(in: container).first {
            !$0.isHidden && $0.convert($0.bounds, to: nil).contains(pointInWindow)
        }
    }

    // MARK: Delivery

    private static func rectInWindow(_ view: NSView, rect: CGRect?) -> CGRect {
        view.convert(rect ?? view.bounds, to: nil)
    }

    private static func deliver(_ image: NSImage?, kind: ScreenshotKind, webView: WKWebView, rectInView: CGRect? = nil) {
        guard let image else { return }
        deliver(Shot(image: image, vectorPDF: nil,
                     rectInWindow: rectInWindow(webView, rect: rectInView),
                     source: webView.url, pageTitle: webView.title), kind: kind)
    }

    private static func deliver(_ shot: Shot, kind: ScreenshotKind) {
        let config = ScreenshotSettings.shared.config(for: kind)
        var wrote = false

        if config.clipboard.enabled, let data = encode(shot, as: config.clipboard.format) {
            let type = pasteboardType(for: config.clipboard.format)
            let pasteboard = NSPasteboard.general
            // declareTypes, not a bare clearContents: setData for a type the
            // pasteboard was never told about is dropped.
            pasteboard.declareTypes([type], owner: nil)
            pasteboard.setData(data, forType: type)
            wrote = true
        }

        if config.shared.enabled,
           write(shot, format: config.shared.format, to: ScreenshotSettings.shared.sharedFolder) {
            wrote = true
        }

        if config.own.enabled, !config.ownFolder.isEmpty,
           write(shot, format: config.own.format, to: URL(fileURLWithPath: config.ownFolder)) {
            wrote = true
        }

        guard wrote else { return }
        NotificationCenter.default.post(name: .browserScreenshotFlash, object: nil,
                                        userInfo: ["rect": shot.rectInWindow])
    }

    @discardableResult
    private static func write(_ shot: Shot, format: ScreenshotFormat, to folder: URL) -> Bool {
        guard let data = encode(shot, as: format) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, name: fileName(for: shot), ext: format.fileExtension)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.log("Screenshot write failed: \(error.localizedDescription)", type: "ScreenshotManager")
            return false
        }
        DownloadManager.shared.record(url, kind: .download, source: shot.source)
        return true
    }

    private static func encode(_ shot: Shot, as format: ScreenshotFormat) -> Data? {
        // A vector PDF only ever exists when every destination asked for PDF,
        // so there is no "rasterize the PDF back" case to handle.
        if format == .pdf, let vector = shot.vectorPDF { return vector }
        guard let image = shot.image else { return nil }
        switch format {
        case .png, .jpg:
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: format == .png ? .png : .jpeg,
                                      properties: format == .png ? [:] : [.compressionFactor: 0.9])
        case .pdf:
            let document = PDFDocument()
            guard let page = PDFPage(image: image) else { return nil }
            document.insert(page, at: 0)
            return document.dataRepresentation()
        }
    }

    private static func pasteboardType(for format: ScreenshotFormat) -> NSPasteboard.PasteboardType {
        switch format {
        case .png: return .png
        case .jpg: return NSPasteboard.PasteboardType("public.jpeg")
        case .pdf: return .pdf
        }
    }

    private static func fileName(for shot: Shot) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let site = shot.source?.host ?? shot.pageTitle ?? "Page"
        // Slashes and colons would fork the path or confuse Finder.
        let safe = site.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
        return "Browser Screenshot \(safe) \(formatter.string(from: Date()))"
    }

    private static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent("\(name).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name)-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }
}

#if DEBUG
// ponytail: one runnable check that persistence round-trips and every format
// actually encodes; called from AppDelegate alongside ShortcutStore.selfCheck().
extension ScreenshotSettings {
    static func selfCheck() {
        for kind in ScreenshotKind.allCases {
            assert(ShortcutCommand.all.contains(kind.command), "no shortcut for \(kind.rawValue)")
        }

        var config = ScreenshotConfig()
        config.own = ScreenshotDestination(enabled: true, format: .pdf)
        config.ownFolder = "/tmp/shots"
        let data = try! JSONEncoder().encode(["visible": config])
        let back = try! JSONDecoder().decode([String: ScreenshotConfig].self, from: data)
        assert(back["visible"] == config, "config did not round-trip")

        let image = NSImage(size: CGSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.drawSwatch(in: CGRect(x: 0, y: 0, width: 2, height: 2)); image.unlockFocus()
        for format in ScreenshotFormat.allCases {
            assert(ScreenshotManager.encodeForTesting(image, as: format)?.isEmpty == false,
                   "\(format.rawValue) encode produced nothing")
        }
    }
}

extension ScreenshotManager {
    static func encodeForTesting(_ image: NSImage, as format: ScreenshotFormat) -> Data? {
        encode(Shot(image: image, vectorPDF: nil, rectInWindow: .zero, source: nil, pageTitle: nil), as: format)
    }
}
#endif
