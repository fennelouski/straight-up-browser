//
//  FaviconCache.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation

// NSCache is thread-safe and evicts by countLimit on its own; no extra
// queue or LRU bookkeeping needed.
class FaviconCache {
    static let shared = FaviconCache()

    private let cache = NSCache<NSString, NSData>()

    private init() {
        cache.countLimit = 314
    }

    /// Get cached favicon data for a URL
    func getFavicon(for url: URL) -> Data? {
        return cache.object(forKey: cacheKey(for: url) as NSString) as Data?
    }

    /// Store favicon data for a URL
    func setFavicon(_ data: Data, for url: URL) {
        cache.setObject(data as NSData, forKey: cacheKey(for: url) as NSString)
    }

    /// Generate a consistent cache key from URL
    private func cacheKey(for url: URL) -> String {
        // Check if this is an alternative image cache key
        if url.absoluteString.hasPrefix("alt_") {
            // For alternative images, use the full URL as the key to distinguish different images
            return url.absoluteString
        }

        // Use the domain/host as the key to avoid caching different favicons for the same site
        // but with different paths (e.g., /page1 vs /page2)
        guard let host = url.host else {
            return url.absoluteString
        }

        // Remove www. prefix for consistency
        var domain = host
        if domain.hasPrefix("www.") {
            domain = String(domain.dropFirst(4))
        }

        return domain
    }
}
