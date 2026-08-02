//
//  FaviconCache.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import WebKit

enum FaviconCacheScope: Equatable {
    case normal
    case container(UUID)
    case privateBrowsing

    static func forTab(_ tab: Tab) -> FaviconCacheScope {
        switch tab.sessionKind {
        case .normal:
            .normal
        case .container:
            tab.sessionId.map(FaviconCacheScope.container) ?? .privateBrowsing
        case .incognito:
            .privateBrowsing
        }
    }

    fileprivate var identifier: String? {
        switch self {
        case .normal:
            "normal"
        case .container(let id):
            "container:\(id.uuidString)"
        case .privateBrowsing:
            nil
        }
    }
}

enum FaviconLoadingPolicy {
    static let maximumByteCount = 512 * 1_024

    static func allows(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            url.host != nil
        case "data":
            url.absoluteString.lowercased().hasPrefix("data:image/")
                && url.absoluteString.utf8.count
                    <= ((maximumByteCount + 2) / 3) * 4 + 256
        default:
            false
        }
    }

    static func decodedPayload(_ base64: String) -> Data? {
        let maximumEncodedLength = ((maximumByteCount + 2) / 3) * 4
        guard base64.utf8.count <= maximumEncodedLength,
              let data = Data(base64Encoded: base64),
              !data.isEmpty,
              data.count <= maximumByteCount else { return nil }
        return data
    }

    /// Fetch inside the page's WebKit content world. This keeps cookies, cache,
    /// proxying, and container/private data-store boundaries identical to the
    /// document instead of creating a second global URLSession identity.
    static func load(from url: URL, in webView: WKWebView) async -> Data? {
        guard allows(url) else { return nil }
        let script = """
            const response = await fetch(iconURL, {
              credentials: 'include',
              cache: 'force-cache'
            });
            if (!response.ok || !response.body) return null;

            const declaredLength = Number(response.headers.get('content-length') || '0');
            if (declaredLength > maximumByteCount) {
              await response.body.cancel();
              return null;
            }

            const reader = response.body.getReader();
            const chunks = [];
            let byteCount = 0;
            while (true) {
              const result = await reader.read();
              if (result.done) break;
              byteCount += result.value.byteLength;
              if (byteCount > maximumByteCount) {
                await reader.cancel();
                return null;
              }
              chunks.push(result.value);
            }
            if (!byteCount) return null;

            let binary = '';
            for (const chunk of chunks) {
              for (let offset = 0; offset < chunk.length; offset += 32768) {
                binary += String.fromCharCode.apply(
                  null,
                  chunk.subarray(offset, offset + 32768)
                );
              }
            }
            return btoa(binary);
            """

        guard let result = try? await webView.callAsyncJavaScript(
            script,
            arguments: [
                "iconURL": url.absoluteString,
                "maximumByteCount": maximumByteCount,
            ],
            in: nil,
            contentWorld: .page
        ), let base64 = result as? String else { return nil }
        return decodedPayload(base64)
    }
}

// NSCache is thread-safe and evicts by countLimit on its own; no extra
// queue or LRU bookkeeping needed.
class FaviconCache {
    static let shared = FaviconCache()

    private let cache = NSCache<NSString, NSData>()

    init(countLimit: Int = 314) {
        cache.countLimit = countLimit
    }

    /// Get cached favicon data for a URL
    func getFavicon(for url: URL, scope: FaviconCacheScope) -> Data? {
        guard let key = cacheKey(for: url, scope: scope) else { return nil }
        return cache.object(forKey: key as NSString) as Data?
    }

    /// Store favicon data for a URL
    @discardableResult
    func setFavicon(
        _ data: Data,
        for url: URL,
        scope: FaviconCacheScope
    ) -> Bool {
        guard !data.isEmpty,
              data.count <= FaviconLoadingPolicy.maximumByteCount,
              let key = cacheKey(for: url, scope: scope) else { return false }
        cache.setObject(data as NSData, forKey: key as NSString)
        return true
    }

    /// Generate a consistent cache key from URL
    private func cacheKey(
        for url: URL,
        scope: FaviconCacheScope
    ) -> String? {
        guard let scopeIdentifier = scope.identifier else { return nil }
        // Check if this is an alternative image cache key
        if url.absoluteString.hasPrefix("alt_") {
            // For alternative images, use the full URL as the key to distinguish different images
            return "\(scopeIdentifier)|\(url.absoluteString)"
        }

        // Use the domain/host as the key to avoid caching different favicons for the same site
        // but with different paths (e.g., /page1 vs /page2)
        guard let host = url.host else {
            return "\(scopeIdentifier)|\(url.absoluteString)"
        }

        // Remove www. prefix for consistency
        var domain = host.lowercased()
        if domain.hasPrefix("www.") {
            domain = String(domain.dropFirst(4))
        }

        let scheme = url.scheme?.lowercased() ?? "https"
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scopeIdentifier)|\(scheme)://\(domain)\(port)"
    }
}
