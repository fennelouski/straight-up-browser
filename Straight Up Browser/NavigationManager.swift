//
//  NavigationManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import Combine

class NavigationManager: ObservableObject {
    @Published var omnibarError: String?

    func navigateToURL(_ urlString: String, activeTab: Tab?) -> URL? {
        // Clear any previous error
        omnibarError = nil

        guard let url = URL(string: urlString) else {
            // Handle invalid URLs gracefully
            let suggestions = generateURLSuggestions(for: urlString)
            var errorMessage = "Invalid URL format"

            if !suggestions.isEmpty {
                errorMessage += ". Did you mean:\n" + suggestions.map { "• \($0)" }.joined(separator: "\n")
            }

            omnibarError = errorMessage
            return nil
        }

        if let activeTab = activeTab {
            activeTab.navigateTo(url)
        }

        // Perform URL validation and security checks
        if let securityWarning = validateURLSecurity(url) {
            // Update omnibar error with security warning
            omnibarError = securityWarning
            return nil
        }

        return url
    }

    private func generateURLSuggestions(for invalidURL: String) -> [String] {
        var suggestions: [String] = []
        let trimmedURL = invalidURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Common domain typos
        let domainCorrections: [String: [String]] = [
            "google.com": ["gogle.com", "googl.com", "google.co", "googler.com"],
            "github.com": ["git hub.com", "githb.com", "github.co", "git-hub.com"],
            "stackoverflow.com": ["stack overflow.com", "stackoverflow.co", "stackoverlfow.com"],
            "youtube.com": ["youtbe.com", "youtube.co", "youtu.be"],
            "apple.com": ["appl.com", "apple.co"],
            "microsoft.com": ["microsoft.co", "microsft.com"],
            "amazon.com": ["amzn.com", "amazon.co", "amazn.com"]
        ]

        // Check for domain typos
        for (correctDomain, typos) in domainCorrections {
            for typo in typos {
                if trimmedURL.contains(typo) {
                    var correctedURL = invalidURL.replacingOccurrences(of: typo, with: correctDomain)
                    if !correctedURL.contains("://") {
                        correctedURL = "https://" + correctedURL
                    }
                    suggestions.append(correctedURL)
                    break
                }
            }
        }

        // Add https:// if missing protocol
        if !invalidURL.contains("://") && invalidURL.contains(".") {
            suggestions.append("https://" + invalidURL)
        }

        // Common protocol typos
        if invalidURL.hasPrefix("http//") {
            suggestions.append(invalidURL.replacingOccurrences(of: "http//", with: "https://"))
        }
        if invalidURL.hasPrefix("https//") {
            suggestions.append(invalidURL.replacingOccurrences(of: "https//", with: "https://"))
        }
        if invalidURL.hasPrefix("http:/") {
            suggestions.append(invalidURL.replacingOccurrences(of: "http:/", with: "https://"))
        }

        return Array(Set(suggestions)).prefix(3).map { $0 } // Return up to 3 unique suggestions
    }

    private func validateURLSecurity(_ url: URL) -> String? {
        // Check for HTTP (non-secure)
        if url.scheme == "http" && url.host != "localhost" && url.host != "127.0.0.1" {
            return "Warning: This site uses HTTP instead of HTTPS. Your connection may not be secure."
        }

        // Check for potentially dangerous URL patterns
        let urlString = url.absoluteString.lowercased()
        let dangerousPatterns = [
            "phishing",
            "malware",
            "virus",
            "trojan",
            "ransomware",
            "spyware",
            "keylogger",
            "scam",
            "fraud",
            "fake",
            "suspicious"
        ]

        for pattern in dangerousPatterns {
            if urlString.contains(pattern) {
                return "Warning: This URL contains suspicious keywords. Please verify the site is legitimate before proceeding."
            }
        }

        // Check for unusual characters in domain
        if let host = url.host {
            let suspiciousChars = CharacterSet(charactersIn: "！@#$%^&*()+=[]{}|\\:;\"'<>?")
            if host.rangeOfCharacter(from: suspiciousChars) != nil {
                return "Warning: This URL contains unusual characters. Please verify the site is legitimate."
            }

            // Check for homograph attacks (similar looking characters)
            let suspiciousHomographs = [
                "rn": "m", // rn looks like m
                "cl": "d", // cl looks like d
                "vv": "w", // vv looks like w
                "1l": "l", // 1l looks like ll
                "0o": "o", // 0o looks like oo
                "rnicrosoft": "microsoft",
                "g00gle": "google",
                "faceb00k": "facebook"
            ]

            for (suspicious, legitimate) in suspiciousHomographs {
                if host.lowercased().contains(suspicious) {
                    return "Warning: This URL may be impersonating a legitimate site (\(legitimate)). Please verify the domain."
                }
            }
        }

        // Check for IP addresses instead of domain names (often used in attacks)
        if let host = url.host, host.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
            return "Warning: This URL uses an IP address instead of a domain name. IP-based sites can be harder to verify as legitimate."
        }

        // Check for unusually long URLs (often used in phishing)
        if urlString.count > 2000 {
            return "Warning: This URL is unusually long, which is common in phishing attempts."
        }

        return nil // No security issues found
    }
}
