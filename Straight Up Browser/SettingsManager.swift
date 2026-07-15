//
//  SettingsManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import SwiftUI

class SettingsManager {
    static let shared = SettingsManager()

    private let userDefaults = UserDefaults.standard

    // Keys for UserDefaults
    private enum Keys {
        static let maxHistorySize = "maxHistorySize"
        static let theme = "theme"
        static let showWebpageTitlesInTabs = "showWebpageTitlesInTabs"
    }

    // Default values
    private enum Defaults {
        static let maxHistorySize = 100
        static let theme = "System"
        static let showWebpageTitlesInTabs = false
    }

    private init() {
        // Initialize defaults if not set
        if userDefaults.object(forKey: Keys.maxHistorySize) == nil {
            userDefaults.set(Defaults.maxHistorySize, forKey: Keys.maxHistorySize)
        }
        if userDefaults.object(forKey: Keys.theme) == nil {
            userDefaults.set(Defaults.theme, forKey: Keys.theme)
        }
        if userDefaults.object(forKey: Keys.showWebpageTitlesInTabs) == nil {
            userDefaults.set(Defaults.showWebpageTitlesInTabs, forKey: Keys.showWebpageTitlesInTabs)
        }
    }

    // MARK: - History Settings

    /// Maximum number of history entries per tab
    var maxHistorySize: Int {
        get {
            return userDefaults.integer(forKey: Keys.maxHistorySize)
        }
        set {
            userDefaults.set(max(10, newValue), forKey: Keys.maxHistorySize) // Minimum of 10
            userDefaults.synchronize()
        }
    }

    // MARK: - Appearance Settings

    /// Current theme preference
    var theme: String {
        get {
            return userDefaults.string(forKey: Keys.theme) ?? Defaults.theme
        }
        set {
            userDefaults.set(newValue, forKey: Keys.theme)
            userDefaults.synchronize()
        }
    }

    /// Computed color scheme based on theme preference
    var colorScheme: ColorScheme? {
        switch theme {
        case "Light":
            return .light
        case "Dark":
            return .dark
        case "System":
            return nil // Use system preference
        default:
            return nil
        }
    }

    // MARK: - Tab Display Settings

    /// Whether to show webpage titles instead of domain names in tab bar
    var showWebpageTitlesInTabs: Bool {
        get {
            return userDefaults.bool(forKey: Keys.showWebpageTitlesInTabs)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.showWebpageTitlesInTabs)
            userDefaults.synchronize()
        }
    }

    // MARK: - Option-Click Download

    /// Should an option-click on this URL trigger a download?
    /// Rules: master toggle -> never-domains -> per-kind toggle -> always-domains -> file types.
    func optionClickShouldDownload(_ url: URL, isImage: Bool) -> Bool {
        // Bool settings default to on when unset
        func boolOn(_ key: String) -> Bool {
            userDefaults.object(forKey: key) == nil || userDefaults.bool(forKey: key)
        }
        func list(_ key: String) -> [String] {
            (userDefaults.string(forKey: key) ?? "")
                .lowercased()
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map(String.init)
        }

        guard boolOn("optionClickDownloadEnabled") else { return false }

        let host = (url.host ?? "").lowercased()
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if list("optionClickNeverDomains").contains(where: matches) { return false }
        guard boolOn(isImage ? "optionClickDownloadImages" : "optionClickDownloadLinks") else { return false }
        if list("optionClickAlwaysDomains").contains(where: matches) { return true }

        let types = list("optionClickFileTypes")
        guard !types.isEmpty else { return true } // empty = all file types
        return types.contains(url.pathExtension.lowercased())
    }

}