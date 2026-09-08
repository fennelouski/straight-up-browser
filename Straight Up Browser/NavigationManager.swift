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

    static func searchURL(for query: String, engine: String? = UserDefaults.standard.string(forKey: "searchEngine")) -> String {
        let prefix: String
        switch engine {
        case "DuckDuckGo": prefix = "https://duckduckgo.com/?q="
        case "Bing": prefix = "https://www.bing.com/search?q="
        case "Yahoo": prefix = "https://search.yahoo.com/search?p="
        default: prefix = "https://www.google.com/search?q="
        }
        // Query values must escape separators and literal plus signs as well.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
        return prefix + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }

    // ponytail: the old keyword/homograph "security" checks were deleted -
    // they false-positived (any URL containing "rn" or "fake") and never
    // actually blocked navigation. A real interstitial can replace them if
    // safe-browsing matters later.
    func navigateToURL(_ urlString: String, activeTab: Tab?) -> URL? {
        omnibarError = nil

        guard let url = URL(string: urlString) else {
            omnibarError = String(localized: "Invalid URL")
            return nil
        }

        activeTab?.navigateTo(url)
        return url
    }
}
