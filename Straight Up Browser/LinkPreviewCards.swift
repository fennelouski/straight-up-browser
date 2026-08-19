//
//  LinkPreviewCards.swift
//  Straight Up Browser
//
//  Visual tabs need a picture, and a tab you haven't opened has nothing to
//  photograph. The page's own link-preview image — the og:image every chat app
//  shows when you paste a URL — is a decent stand-in, and LinkPresentation
//  fetches it with one HTTP request instead of a whole web content process.
//

import Foundation
import LinkPresentation
import UniformTypeIdentifiers

@MainActor
enum LinkPreviewCards {
    // Per-session only. These are cosmetic placeholders that a real snapshot
    // replaces the moment the tab renders; nothing here is worth a disk cache.
    private static var cache: [String: WebViewThumbnail] = [:]
    private static var missing: Set<String> = []

    static func image(for url: URL) async -> WebViewThumbnail? {
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        guard !missing.contains(key) else { return nil }

        let provider = LPMetadataProvider()
        provider.timeout = 10
        // Only the image matters here; skipping the subresource fetches keeps
        // this to roughly one request per tab.
        provider.shouldFetchSubresources = true

        guard let metadata = try? await provider.startFetchingMetadata(for: url),
              let itemProvider = metadata.imageProvider ?? metadata.iconProvider,
              let image = await load(itemProvider) else {
            missing.insert(key)
            return nil
        }
        cache[key] = image
        return image
    }

    private static func load(_ provider: NSItemProvider) async -> WebViewThumbnail? {
        let identifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        }
        guard let identifier else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        return data.flatMap(WebViewThumbnail.init(data:))
    }
}
