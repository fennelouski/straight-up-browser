//
//  BrowserEngine.swift
//  Straight Up Browser
//
//  Engine identity is shared browser data; engine availability is a property of
//  the current build. A Chromium-preferred tab may therefore sync to iPhone or
//  iPad and open there with WebKit without losing what its Mac should use.
//

import Foundation

#if (os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)) && CHROMIUM_ENABLED
#error("CHROMIUM_ENABLED is a macOS-only capability")
#endif

enum BrowserEngine: String, Codable, CaseIterable, Sendable {
    case webKit = "webkit"
    case chromium = "chromium"
}

/// The engines that this particular binary can instantiate.
///
/// `CHROMIUM_ENABLED` is deliberately necessary but not sufficient: the OS
/// check makes it impossible for a mobile target to advertise Chromium even if
/// a build setting is copied accidentally. The normal Mac and every mobile
/// build therefore remain WebKit-only until a dedicated Mac artifact opts in.
enum BrowserEngineAvailability {
    nonisolated static var supportedEngines: [BrowserEngine] {
        #if os(macOS) && CHROMIUM_ENABLED
        [.webKit, .chromium]
        #else
        [.webKit]
        #endif
    }

    nonisolated static var isChromiumAvailable: Bool {
        supportedEngines.contains(.chromium)
    }

    nonisolated static func effectiveEngine(for preferredEngine: BrowserEngine) -> BrowserEngine {
        supportedEngines.contains(preferredEngine) ? preferredEngine : .webKit
    }
}

/// Everything a newly-created tab should inherit from its opener. Keeping
/// engine and storage identity together prevents popups, duplicates, and new
/// tabs from silently crossing either boundary when another engine is added.
struct BrowsingContext: Equatable, Sendable {
    let sessionKind: SessionKind
    let sessionId: UUID?
    let preferredEngine: BrowserEngine

    static let normalWebKit = BrowsingContext(
        sessionKind: .normal,
        sessionId: nil,
        preferredEngine: .webKit
    )
}
