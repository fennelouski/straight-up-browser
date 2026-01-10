//
//  FaviconCache.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation

class FaviconCache {
    static let shared = FaviconCache()

    private let cache = NSCache<NSString, NSData>()
    private let maxEntries = 314
    private var accessOrder = [String]() // Track access order for LRU eviction
    private let accessQueue = DispatchQueue(label: "com.straightupbrowser.faviconcache", attributes: .concurrent)

    private init() {
        cache.countLimit = maxEntries
    }

    /// Get cached favicon data for a URL
    func getFavicon(for url: URL) -> Data? {
        let key = cacheKey(for: url)
        return accessQueue.sync {
            // Update access order (move to front)
            if let index = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: index)
            }
            accessOrder.insert(key, at: 0)

            return cache.object(forKey: key as NSString) as Data?
        }
    }

    /// Store favicon data for a URL
    func setFavicon(_ data: Data, for url: URL) {
        let key = cacheKey(for: url)
        accessQueue.async(flags: .barrier) {
            // Check if we're at capacity and need to evict
            if self.accessOrder.count >= self.maxEntries {
                if let oldestKey = self.accessOrder.last {
                    self.cache.removeObject(forKey: oldestKey as NSString)
                    self.accessOrder.removeLast()
                }
            }

            // Add new entry
            if let index = self.accessOrder.firstIndex(of: key) {
                self.accessOrder.remove(at: index)
            }
            self.accessOrder.insert(key, at: 0)
            self.cache.setObject(data as NSData, forKey: key as NSString)
        }
    }

    /// Check if favicon exists in cache
    func hasFavicon(for url: URL) -> Bool {
        let key = cacheKey(for: url)
        return accessQueue.sync {
            return cache.object(forKey: key as NSString) != nil
        }
    }

    /// Clear all cached favicons
    func clearCache() {
        accessQueue.async(flags: .barrier) {
            self.cache.removeAllObjects()
            self.accessOrder.removeAll()
        }
    }

    /// Get cache statistics
    func getCacheStats() -> (count: Int, maxEntries: Int) {
        return accessQueue.sync {
            return (accessOrder.count, maxEntries)
        }
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