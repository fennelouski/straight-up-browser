import SwiftUI
import WebKit

/// One tiny, in-memory viewport snapshot supplies independent edge colors.
/// No page text, images or colors are saved.
/// Scroll observations debounce work; they never reposition browser controls.
@MainActor final class MobilePageChrome: ObservableObject {
    @Published private(set) var top: UIColor?
    @Published private(set) var bottom: UIColor?
    @Published private(set) var fixedEdges: [Double] = []
    private weak var webView: WKWebView?
    private var offsetObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var sampling = false
    private var pendingSample = false
    private var paused = false

    #if DEBUG
    var acceptanceSummary: String? {
        guard BrowserProfile.isIsolated, MobileTestConfiguration.isUITesting,
              ProcessInfo.processInfo.arguments.contains("-mobileTestChromeMetrics") else { return nil }
        return "top=\(String(describing: top)); bottom=\(String(describing: bottom)); bounds=\(String(describing: webView?.bounds)); insets=\(String(describing: webView?.scrollView.adjustedContentInset)); edges=\(fixedEdges); scheme=\(webView?.url?.scheme ?? "none")"
    }
    #endif

    func attach(_ view: WKWebView) {
        if webView !== view {
            detach()
            webView = view
        }
        paused = false
        if offsetObservation == nil {
            offsetObservation = view.scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self, weak view] _, change in
                guard change.oldValue != change.newValue else { return }
                Task { @MainActor in if let view { self?.schedule(view) } }
            }
        }
        if boundsObservation == nil {
            boundsObservation = view.observe(\.bounds, options: [.old, .new]) { [weak self, weak view] _, change in
                guard change.oldValue?.size != change.newValue?.size else { return }
                Task { @MainActor in if let view { self?.schedule(view) } }
            }
        }
        schedule(view)
    }

    func pause() {
        paused = true
        work?.cancel()
        pendingSample = false
        offsetObservation = nil
        boundsObservation = nil
        generation = UUID()
        // Keep the last visible colors while the OS snapshots/suspends the page.
    }

    func detach() {
        work?.cancel()
        pendingSample = false
        offsetObservation = nil
        boundsObservation = nil
        webView = nil
        generation = UUID()
        top = nil; bottom = nil; fixedEdges = []
    }

    private func schedule(_ view: WKWebView) {
        guard !paused, webView === view else { return }
        if sampling {
            generation = UUID()
            pendingSample = true
            return
        }
        work?.cancel()
        let token = UUID()
        generation = token
        work = Task { [weak self, weak view] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, let view, !view.isLoading, view.bounds.width > 0, view.bounds.height > 4 else { return }
            self.sampling = true
            defer {
                self.sampling = false
                if self.pendingSample {
                    self.pendingSample = false
                    if let current = self.webView { self.schedule(current) }
                }
            }
            let fallback = view.underPageBackgroundColor
            let colors = await Self.edgeColors(view)
            guard !Task.isCancelled, self.generation == token else { return }
            self.top = colors.0 ?? fallback; self.bottom = colors.1 ?? fallback
            // Fixed-position horizontal borders only. Sticky/scrolling elements
            // are intentionally excluded. Compare two samples to reject animation.
            guard BrowserProfile.isIsolated
                    || BrowserProfile.defaults.object(forKey: "javaScriptEnabled") as? Bool != false else {
                self.fixedEdges = []; return
            }
            let first = await Self.edges(view)
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let second = await Self.edges(view)
            guard !Task.isCancelled, self.generation == token else { return }
            self.fixedEdges = first.filter { edge in second.contains { abs($0 - edge) < 1 } }
        }
    }

    private static func edgeColors(_ view: WKWebView) async -> (UIColor?, UIColor?) {
        let ratio = 64 / max(view.bounds.width, view.bounds.height)
        let size = CGSize(width: max(1, view.bounds.width * ratio), height: max(1, view.bounds.height * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        var complete = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.scaleBy(x: ratio, y: ratio)
            complete = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        var image = complete ? rendered.cgImage : nil
        // WebKit's own snapshot can omit fixed compositor layers. Prefer the
        // actual on-screen hierarchy; retain its API as an offscreen fallback.
        if image == nil {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = view.bounds
            configuration.snapshotWidth = NSNumber(value: Double(size.width))
            configuration.afterScreenUpdates = true
            image = (try? await view.takeSnapshot(configuration: configuration))?.cgImage
        }
        guard let image else { return (nil, nil) }
        let inset = view.scrollView.adjustedContentInset
        let scale = CGFloat(image.height) / max(1, view.bounds.height)
        let topRow = min(image.height - 1, max(0, Int(max(0, inset.top) * scale)))
        let bottomRow = min(image.height - 1, max(topRow, Int((view.bounds.height - max(0, inset.bottom)) * scale) - 1))
        return (rowColor(image, y: topRow), rowColor(image, y: bottomRow))
    }

    private static func rowColor(_ image: CGImage, y: Int) -> UIColor? {
        guard let row = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: 1)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        return pixel.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(row, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard bytes[3] > 240 else { return nil }
            return UIColor(red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255,
                           blue: CGFloat(bytes[2]) / 255, alpha: 1)
        }
    }

    private static func edges(_ view: WKWebView) async -> [Double] {
        guard abs(view.scrollView.zoomScale - 1) < 0.01, abs(view.pageZoom - 1) < 0.01 else { return [] }
        let script = Self.fixedEdgeScript
        let result = try? await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
        guard let row = result as? [String: Any], let height = row["height"] as? Double, height > 0,
              let edges = row["edges"] as? [Double] else { return [] }
        return edges.map { edge in view.convert(CGPoint(x: 0, y: edge * view.bounds.height / height), to: nil).y }
    }

    static let fixedEdgeScript = """
        (() => { const out=[],walker=document.createTreeWalker(document.body,NodeFilter.SHOW_ELEMENT);
        for(let i=0;i<400&&out.length<24;i++) {
          const e=walker.nextNode();if(!e)break;
          const s=getComputedStyle(e),r=e.getBoundingClientRect();
          if(s.position!=='fixed'||s.visibility!=='visible'||Number(s.opacity)<0.9||r.width<innerWidth*0.3||r.height<1)continue;
          if(r.bottom<0||r.top>innerHeight)continue;
          let p=e.parentElement,depth=0,anchored=true;
          while(p&&p!==document.documentElement&&depth++<12) {
            const a=getComputedStyle(p);
            if(a.transform!=='none'||a.perspective!=='none'||a.filter!=='none'||/(paint|layout|strict|content)/.test(a.contain)||/(transform|filter|perspective)/.test(a.willChange)) {anchored=false;break;}
            p=p.parentElement;
          }
          if(!anchored||depth>12)continue;
          if(parseFloat(s.borderTopWidth)>0)out.push(r.top);
          if(parseFloat(s.borderBottomWidth)>0)out.push(r.bottom);
        } const v=window.visualViewport, offset=v ? v.offsetTop : 0, height=v ? v.height : innerHeight;
        return {height,edges:out.slice(0,24).map(y=>y-offset).filter(y=>y>=0&&y<=height)}; })()
        """
}

struct MobileVisualTabs: View {
    let tabs: [Tab]
    let selectedID: UUID?
    let preview: UIImage?
    let select: (Tab) -> Void
    let close: (Tab) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 16) {
                    ForEach(tabs) { tab in
                        VStack(spacing: 0) {
                            Button { select(tab); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack {
                                        Rectangle().fill(Color.secondary.opacity(0.08))
                                        if tab.id == selectedID, let preview {
                                            Image(uiImage: preview).resizable().scaledToFill()
                                        } else {
                                            Image(systemName: tab.sessionKind == .incognito ? "eye.slash" : "globe")
                                                .font(.largeTitle).foregroundStyle(.secondary)
                                        }
                                    }.frame(height: 140).clipped().accessibilityHidden(true)
                                    Text(tab.title.isEmpty ? "New Tab" : tab.title).font(.headline).lineLimit(2)
                                    Text(tab.url?.host ?? "No address").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.padding(10)
                            }.buttonStyle(.plain)
                            Button("Close Tab", systemImage: "xmark") { close(tab) }.font(.caption).padding(10)
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tab.id == selectedID ? Color.accentColor : .clear, lineWidth: 2))
                    }
                }.padding()
            }
            .navigationTitle("Visual Tabs")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
