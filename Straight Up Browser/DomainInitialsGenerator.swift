//
//  DomainInitialsGenerator.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
#if os(macOS)
import AppKit
#endif

class DomainInitialsGenerator {
    static let shared = DomainInitialsGenerator()

    private let cache = NSCache<NSString, NSData>()
    private let maxCacheSize = 200 // Cache up to 200 generated images

    private init() {
        cache.countLimit = maxCacheSize
    }

    /// Generate a stylized initial image for a domain
    func generateInitialImage(for domain: String, size: NSSize = NSSize(width: 32, height: 32)) -> Data? {
        let cacheKey = "\(domain)_\(Int(size.width))x\(Int(size.height))"
        let nsCacheKey = cacheKey as NSString

        // Check cache first
        if let cachedData = cache.object(forKey: nsCacheKey) as Data? {
            return cachedData
        }

        // Generate the image
        guard let imageData = createInitialImage(for: domain, size: size) else {
            return nil
        }

        // Cache the result
        cache.setObject(imageData as NSData, forKey: nsCacheKey)

        return imageData
    }

    private func createInitialImage(for domain: String, size: NSSize) -> Data? {
        // Extract the first letter from the domain
        let firstLetter = extractFirstLetter(from: domain)

        // Generate consistent colors based on domain
        let colors = generateColors(for: domain)

        // Create the image
        let image = NSImage(size: size)
        image.lockFocus()

        // Draw background circle
        let backgroundRect = NSRect(origin: .zero, size: size)
        let backgroundPath = NSBezierPath(ovalIn: backgroundRect)
        colors.background.setFill()
        backgroundPath.fill()

        // Draw the letter
        let fontSize = size.width * 0.6 // Letter takes up 60% of the image width
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colors.text,
            .paragraphStyle: paragraphStyle
        ]

        let letterString = NSAttributedString(string: firstLetter, attributes: attributes)
        let letterSize = letterString.size()

        // Center the letter
        let letterRect = NSRect(
            x: (size.width - letterSize.width) / 2,
            y: (size.height - letterSize.height) / 2 + size.height * 0.05 - 1.5, // Slight upward adjustment for visual centering, then moved down 1.5 points
            width: letterSize.width,
            height: letterSize.height
        )

        letterString.draw(in: letterRect)

        image.unlockFocus()

        // Convert to PNG data
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmapRep.representation(using: .png, properties: [:])
    }

    private func extractFirstLetter(from domain: String) -> String {
        // Clean the domain (remove www., subdomains, etc.)
        var cleanDomain = domain.lowercased()

        // Remove common prefixes
        if cleanDomain.hasPrefix("www.") {
            cleanDomain = String(cleanDomain.dropFirst(4))
        }

        // Remove subdomains (keep only the main domain)
        let components = cleanDomain.split(separator: ".")
        if components.count >= 2 {
            // For domains like sub.example.com, use "e" from "example"
            // For domains like example.com, use "e" from "example"
            let mainDomain = components[components.count - 2]
            if let firstChar = mainDomain.first {
                return String(firstChar).uppercased()
            }
        }

        // Fallback: use first character of the input
        return cleanDomain.first?.uppercased() ?? "?"
    }

    private func generateColors(for domain: String) -> (background: NSColor, text: NSColor) {
        // Generate a consistent hash from the domain
        let hash = domain.hashValue

        // Use the hash to generate HSL colors for consistency
        // Hue: 0-360 degrees based on hash
        let hue = Double(abs(hash) % 360) / 360.0

        // Saturation: 65-85% for vibrant but not overwhelming colors
        let saturation = 0.65 + (Double(abs(hash) % 20) / 100.0)

        // Lightness: 45-65% for good contrast
        let lightness = 0.45 + (Double(abs(hash) % 20) / 100.0)

        // Convert HSL to RGB
        let backgroundColor = hslToRgb(h: hue, s: saturation, l: lightness)

        // Choose text color based on background brightness
        // Use relative luminance formula: 0.299*R + 0.587*G + 0.114*B
        let luminance = 0.299 * backgroundColor.redComponent +
                       0.587 * backgroundColor.greenComponent +
                       0.114 * backgroundColor.blueComponent

        let textColor = luminance > 0.5 ? NSColor.black : NSColor.white

        return (backgroundColor, textColor)
    }

    private func hslToRgb(h: Double, s: Double, l: Double) -> NSColor {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2

        var r = 0.0, g = 0.0, b = 0.0

        let hueSegment = h * 6
        switch hueSegment {
        case 0..<1:
            r = c; g = x; b = 0
        case 1..<2:
            r = x; g = c; b = 0
        case 2..<3:
            r = 0; g = c; b = x
        case 3..<4:
            r = 0; g = x; b = c
        case 4..<5:
            r = x; g = 0; b = c
        default:
            r = c; g = 0; b = x
        }

        return NSColor(red: r + m, green: g + m, blue: b + m, alpha: 1.0)
    }

    /// Clear all cached generated images
    func clearCache() {
        cache.removeAllObjects()
    }

    /// Get cache statistics
    func getCacheStats() -> (count: Int, maxSize: Int) {
        return (cache.totalCostLimit - cache.totalCostLimit + cache.countLimit, maxCacheSize)
    }

    /// Pre-generate common domain initials for faster loading
    func pregenerateCommonDomains() {
        let commonDomains = [
            "google.com", "youtube.com", "facebook.com", "amazon.com",
            "twitter.com", "instagram.com", "linkedin.com", "github.com",
            "stackoverflow.com", "reddit.com", "wikipedia.org", "apple.com",
            "microsoft.com", "netflix.com", "spotify.com", "twitch.tv"
        ]

        for domain in commonDomains {
            _ = generateInitialImage(for: domain)
        }
    }

    /// Test function to verify the generator works
    func testGenerator() {
        let testDomains = ["google.com", "github.com", "stackoverflow.com", "example.co.uk"]
        print("Testing Domain Initials Generator:")

        for domain in testDomains {
            if let data = generateInitialImage(for: domain) {
                print("✓ Generated initial for \(domain): \(data.count) bytes")
            } else {
                print("✗ Failed to generate initial for \(domain)")
            }
        }
    }
}