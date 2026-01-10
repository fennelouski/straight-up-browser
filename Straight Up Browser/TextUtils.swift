//
//  TextUtils.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI

struct TextUtils {
    /// Measures the width of text with the given font
    static func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributedString = NSAttributedString(string: text, attributes: [.font: font])
        return attributedString.size().width
    }

    /// Calculates the maximum number of tabs that can fit in the given width
    static func calculateMaxTabs(for width: CGFloat, tabWidth: CGFloat) -> Int {
        return max(1, Int(width / tabWidth))
    }

    /// Truncates text to fit within the specified width using progressive strategies
    static func truncateText(_ text: String, maxWidth: CGFloat, font: NSFont) -> String {
        guard !text.isEmpty else { return text }

        // Quick check if text already fits
        if measureTextWidth(text, font: font) <= maxWidth {
            return text
        }

        // Strategy 1: Try removing protocol (http://, https://)
        var truncated = text
        if truncated.hasPrefix("https://") {
            truncated = String(truncated.dropFirst(8))
        } else if truncated.hasPrefix("http://") {
            truncated = String(truncated.dropFirst(7))
        }

        if measureTextWidth(truncated, font: font) <= maxWidth {
            return truncated
        }

        // Strategy 2: Try truncating with ellipsis
        let ellipsis = "..."
        let ellipsisWidth = measureTextWidth(ellipsis, font: font)
        let availableWidth = maxWidth - ellipsisWidth

        if availableWidth > 0 {
            var result = ""
            for char in truncated {
                let testString = result + String(char)
                if measureTextWidth(testString, font: font) <= availableWidth {
                    result = testString
                } else {
                    break
                }
            }
            if !result.isEmpty {
                return result + ellipsis
            }
        }

        // Strategy 3: Try keeping only the domain part (before first dot or slash)
        let components = truncated.split(separator: ".", maxSplits: 1)
        if components.count > 1, let firstComponent = components.first {
            let domainOnly = String(firstComponent)
            if measureTextWidth(domainOnly, font: font) <= maxWidth {
                return domainOnly
            }
        }

        // Strategy 4: Try keeping first few characters
        let maxChars = Int(maxWidth / font.pointSize) // Rough estimate
        if maxChars > 0 && truncated.count > maxChars {
            let shortened = String(truncated.prefix(maxChars))
            if measureTextWidth(shortened, font: font) <= maxWidth {
                return shortened + ellipsis
            }
        }

        // Strategy 5: Use initials/acronym
        let words = truncated.split(separator: " ")
        if words.count > 1 {
            // Take first letter of each word
            let initials = words.compactMap { $0.first }.map { String($0) }.joined()
            if measureTextWidth(initials, font: font) <= maxWidth {
                return initials
            }
        }

        // Last resort: Single character
        if let firstChar = truncated.first {
            return String(firstChar)
        }

        return text
    }

    /// Gets the optimal tab title for a given available width and display settings
    static func getOptimalTabTitle(for tab: Tab, availableWidth: CGFloat, tabBarWidth: CGFloat) -> String {
        // Determine what title to show based on tab bar width and settings
        let shouldShowWebpageTitle = tabBarWidth >= 100 && SettingsManager.shared.showWebpageTitlesInTabs
        let titleToShow = shouldShowWebpageTitle ? tab.title : Tab.extractDomain(from: tab.url)

        // Account for icon width (12px) and padding (4px spacing + 6px horizontal padding on each side)
        let iconWidth: CGFloat = 12
        let spacing: CGFloat = 4
        let padding: CGFloat = 12 // 6px on each side
        let textWidth = availableWidth - iconWidth - spacing - padding

        guard textWidth > 0 else { return "" }

        let font = NSFont.systemFont(ofSize: 11)
        return truncateText(titleToShow, maxWidth: textWidth, font: font)
    }
}