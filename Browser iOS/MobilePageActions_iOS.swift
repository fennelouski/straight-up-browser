//
//  MobilePageActions_iOS.swift
//  Browser (iOS)
//
//  Native mobile presentations for desktop page actions: printing, PDF export,
//  visible/full-page snapshots, the system activity sheet, and Reader Mode.
//

import SwiftUI
import UIKit
import WebKit

struct ActivitySheet_iOS: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

enum MobilePageActions_iOS {
    enum ImageFormat {
        case png
        case jpeg

        var fileExtension: String { self == .png ? "png" : "jpg" }
    }

    static func printPage(_ webView: WKWebView) {
        let controller = UIPrintInteractionController.shared
        controller.printFormatter = webView.viewPrintFormatter()
        controller.present(animated: true)
    }

    static func exportPDF(
        _ webView: WKWebView,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: webView.scrollView.contentSize)
        webView.createPDF(configuration: configuration) { result in
            completion(result.flatMap { data in
                Result {
                    let title = sanitizedFilename(webView.title ?? "Page")
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(title)-\(UUID().uuidString).pdf")
                    try data.write(to: url, options: .atomic)
                    return url
                }
            })
        }
    }

    static func snapshot(
        _ webView: WKWebView,
        fullPage: Bool,
        completion: @escaping (Result<UIImage, Error>) -> Void
    ) {
        let configuration: WKSnapshotConfiguration? = if fullPage {
            {
                let value = WKSnapshotConfiguration()
                value.rect = CGRect(origin: .zero, size: webView.scrollView.contentSize)
                value.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
                value.afterScreenUpdates = true
                return value
            }()
        } else {
            nil
        }

        webView.takeSnapshot(with: configuration) { image, error in
            if let image {
                completion(.success(image))
            } else {
                completion(.failure(error ?? MobilePageActionError.snapshotFailed))
            }
        }
    }

    static func exportSnapshot(
        _ webView: WKWebView,
        fullPage: Bool,
        format: ImageFormat,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        snapshot(webView, fullPage: fullPage) { result in
            completion(result.flatMap { image in
                Result {
                    let data: Data?
                    switch format {
                    case .png:
                        data = image.pngData()
                    case .jpeg:
                        let renderer = UIGraphicsImageRenderer(size: image.size)
                        let flattened = renderer.image { context in
                            UIColor.white.setFill()
                            context.cgContext.fill(CGRect(origin: .zero, size: image.size))
                            image.draw(at: .zero)
                        }
                        data = flattened.jpegData(compressionQuality: 0.9)
                    }
                    guard let data else { throw MobilePageActionError.imageEncodingFailed }
                    let suffix = fullPage ? "full-page" : "screenshot"
                    return try writeTemporaryFile(
                        data,
                        title: webView.title ?? "Page",
                        suffix: suffix,
                        extension: format.fileExtension
                    )
                }
            })
        }
    }

    static func extractPageText(
        _ webView: WKWebView,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let script = """
        (() => {
          const root = document.querySelector('article, main, [role="main"]') || document.body;
          const text = (root && root.innerText ? root.innerText : '')
            .replace(/\\u00a0/g, ' ')
            .replace(/[ \\t]+\\n/g, '\\n')
            .replace(/\\n{3,}/g, '\\n\\n')
            .trim();
          return { title: document.title || '', text };
        })()
        """
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let result = value as? [String: Any],
                  let body = result["text"] as? String,
                  !body.isEmpty else {
                completion(.failure(MobilePageActionError.noPageText))
                return
            }
            let title = (result["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            completion(.success(title.isEmpty ? body : "\(title)\n\n\(body)"))
        }
    }

    static func exportPrimaryPageImage(
        _ webView: WKWebView,
        completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void
    ) {
        webView.evaluateJavaScript(primaryImageScript) { value, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let descriptor = value as? [String: Any],
                  let rawURL = descriptor["url"] as? String,
                  let imageURL = URL(string: rawURL) else {
                completion(.failure(MobilePageActionError.noPageImage))
                return
            }
            if imageURL.scheme == "data" {
                do {
                    completion(.success(try exportDataImageURL(imageURL, title: descriptor["name"] as? String ?? "Image")))
                } catch {
                    completion(.failure(error))
                }
                return
            }
            downloadRawImage(
                imageURL,
                pageURL: webView.url,
                title: descriptor["name"] as? String ?? webView.title ?? "Image",
                cookieStore: webView.configuration.websiteDataStore.httpCookieStore,
                completion: completion
            )
        }
    }

    private static let primaryImageScript = """
    (() => {
      const absolute = value => {
        try { return new URL(value, document.baseURI).href; } catch (_) { return null; }
      };
      const metadata = [
        document.querySelector('meta[property="og:image"]')?.content,
        document.querySelector('meta[name="twitter:image"]')?.content,
        document.querySelector('link[rel="image_src"]')?.href
      ].map(absolute).filter(Boolean);
      const centerX = innerWidth / 2, centerY = innerHeight / 2;
      const candidates = Array.from(document.images).map(image => {
        const rect = image.getBoundingClientRect();
        const width = image.naturalWidth || rect.width;
        const height = image.naturalHeight || rect.height;
        if (!image.currentSrc && !image.src) return null;
        if (width < 80 || height < 80 || rect.width < 24 || rect.height < 24) return null;
        const style = getComputedStyle(image);
        if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return null;
        const visibleWidth = Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0));
        const visibleHeight = Math.max(0, Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0));
        const visibleArea = visibleWidth * visibleHeight;
        const area = Math.min(width * height, 12000000);
        const label = `${image.alt || ''} ${image.className || ''} ${image.id || ''}`.toLowerCase();
        const semanticBonus = image.closest('article, main, figure, [role="main"]') ? 2500000 : 0;
        const metadataBonus = metadata.includes(absolute(image.currentSrc || image.src)) ? 1800000 : 0;
        const chromePenalty = /(logo|icon|avatar|emoji|badge|sprite|tracking|pixel)/.test(label) ? 3000000 : 0;
        const dx = Math.abs(rect.left + rect.width / 2 - centerX);
        const dy = Math.abs(rect.top + rect.height / 2 - centerY);
        const centerBonus = Math.max(0, 800000 - (dx + dy) * 900);
        return {
          url: absolute(image.currentSrc || image.src),
          name: image.alt || document.title || 'Image',
          score: area + visibleArea * 4 + semanticBonus + metadataBonus + centerBonus - chromePenalty
        };
      }).filter(Boolean).sort((a, b) => b.score - a.score);
      if (candidates.length) return candidates[0];
      if (metadata.length) return { url: metadata[0], name: document.title || 'Image' };
      return null;
    })()
    """

    private static func downloadRawImage(
        _ imageURL: URL,
        pageURL: URL?,
        title: String,
        cookieStore: WKHTTPCookieStore,
        completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void
    ) {
        cookieStore.getAllCookies { cookies in
            var request = URLRequest(url: imageURL)
            if let pageURL {
                request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
            }
            let applicableCookies = cookies.filter { cookie in
                cookieApplies(cookie, to: imageURL)
            }
            for (field, value) in HTTPCookie.requestHeaderFields(with: applicableCookies) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    guard let data, !data.isEmpty,
                          let response = response as? HTTPURLResponse,
                          (200...299).contains(response.statusCode) else {
                        completion(.failure(MobilePageActionError.imageDownloadFailed))
                        return
                    }
                    do {
                        let ext = imageExtension(mimeType: response.mimeType, url: imageURL)
                        let knownImageExtension = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "svg"]
                            .contains(ext)
                        guard response.mimeType?.hasPrefix("image/") == true
                                || knownImageExtension
                                || UIImage(data: data) != nil else {
                            throw MobilePageActionError.imageDownloadFailed
                        }
                        let suggested = response.suggestedFilename
                            .map { ($0 as NSString).deletingPathExtension }
                        let output = try writeTemporaryFile(
                            data,
                            title: suggested ?? title,
                            suffix: "image",
                            extension: ext
                        )
                        completion(.success(output))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }.resume()
        }
    }

    private static func cookieApplies(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domainMatches = host == domain || host.hasSuffix(".\(domain)")
        let pathMatches = url.path.isEmpty || url.path.hasPrefix(cookie.path)
        let securityMatches = !cookie.isSecure || url.scheme?.lowercased() == "https"
        return domainMatches && pathMatches && securityMatches
    }

    private static func imageExtension(mimeType: String?, url: URL) -> String {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/heic", "image/heif": "heic"
        case "image/svg+xml": "svg"
        default:
            url.pathExtension.isEmpty ? "img" : String(url.pathExtension.prefix(8)).lowercased()
        }
    }

    private static func exportDataImageURL(_ url: URL, title: String) throws -> URL {
        let raw = url.absoluteString
        guard let comma = raw.firstIndex(of: ",") else {
            throw MobilePageActionError.imageDownloadFailed
        }
        let header = String(raw[..<comma])
        let payload = String(raw[raw.index(after: comma)...])
        let data: Data?
        if header.localizedCaseInsensitiveContains(";base64") {
            data = Data(base64Encoded: payload)
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data, !data.isEmpty else {
            throw MobilePageActionError.imageDownloadFailed
        }
        let mime = header.dropFirst("data:".count).split(separator: ";").first.map(String.init)
        return try writeTemporaryFile(
            data,
            title: title,
            suffix: "image",
            extension: imageExtension(mimeType: mime, url: url)
        )
    }

    private static func writeTemporaryFile(
        _ data: Data,
        title: String,
        suffix: String,
        extension fileExtension: String
    ) throws -> URL {
        let title = sanitizedFilename(title)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(title)-\(suffix)-\(UUID().uuidString).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func sanitizedFilename(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Page" : String(cleaned.prefix(80))
    }
}

private enum MobilePageActionError: LocalizedError {
    case snapshotFailed
    case imageEncodingFailed
    case noPageImage
    case imageDownloadFailed
    case noPageText

    var errorDescription: String? {
        switch self {
        case .snapshotFailed: "The page could not be captured."
        case .imageEncodingFailed: "The captured page could not be encoded."
        case .noPageImage: "No shareable image was found on this page."
        case .imageDownloadFailed: "The page’s primary image could not be downloaded."
        case .noPageText: "No readable text was found on this page."
        }
    }
}

struct ReaderPresentation_iOS: Identifiable {
    let id = UUID()
    let article: ReaderArticle
}

struct ReaderMode_iOS: View {
    @Environment(\.dismiss) private var dismiss
    let article: ReaderArticle
    let onOpen: (URL) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(article.title).font(.largeTitle.bold())
                        if let byline = article.byline {
                            Text(byline).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 10)

                    ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                        ReaderBlockRow_iOS(block: block)
                    }
                }
                .font(.system(size: 18, design: .serif))
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Reader Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            onOpen(url)
            dismiss()
            return .handled
        })
    }
}

private struct ReaderBlockRow_iOS: View {
    let block: ReaderBlock

    @ViewBuilder
    var body: some View {
        switch block {
        case .heading(let level, let runs):
            Text(attributedText(for: runs))
                .font(headingFont(level))
                .fontWeight(.semibold)
                .accessibilityHeading(headingLevel(level))
                .padding(.top, level <= 2 ? 14 : 8)
        case .paragraph(let runs):
            Text(attributedText(for: runs))
        case .listItem(let ordered, let ordinal, let depth, let runs):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ordered ? "\(ordinal ?? 1)." : "•")
                    .fontWeight(.semibold)
                    .frame(width: 30, alignment: .trailing)
                    .accessibilityHidden(true)
                Text(attributedText(for: runs))
            }
            .padding(.leading, CGFloat(depth) * 24)
            .accessibilityElement(children: .combine)
        case .quote(let runs):
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 4)
                    .accessibilityHidden(true)
                Text(attributedText(for: runs)).italic().foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 15, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .caption(let runs):
            Text(attributedText(for: runs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func attributedText(for runs: [ReaderInline]) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var fragment = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.isStrong { intent.insert(.stronglyEmphasized) }
            if run.isEmphasized { intent.insert(.emphasized) }
            if run.isCode { intent.insert(.code) }
            if !intent.isEmpty { fragment.inlinePresentationIntent = intent }
            fragment.link = run.link
            result.append(fragment)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        case 4: .headline
        case 5: .subheadline
        default: .caption
        }
    }

    private func headingLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}
