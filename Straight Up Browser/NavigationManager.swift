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
