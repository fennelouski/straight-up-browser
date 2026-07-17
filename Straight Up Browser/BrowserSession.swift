//
//  BrowserSession.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 7/17/26.
//

import Foundation
import SwiftUI
import SwiftData

// A persistent, isolated browsing container. Its tabs use their own
// WKWebsiteDataStore(forIdentifier: id) — a separate cookie/cache/storage jar — so
// you can stay logged into the same site under different accounts side by side.
// Incognito is NOT modeled here: incognito sessions are ephemeral and live only in
// memory (WebViewManager.incognitoStores), so a private URL never persists or syncs.
@Model
final class BrowserSession {
    // Defaults required for SwiftData+CloudKit compatibility (see Tab.swift). The
    // definition (name + color) may sync harmlessly; the data store itself is local.
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#5E5CE6"
    var createdAt: Date = Date()

    init(name: String, color: Color) {
        self.id = UUID()
        self.name = name
        self.colorHex = color.toHex() ?? "#5E5CE6"
        self.createdAt = Date()
    }

    // Reuses Color(hex:) / toHex() defined in TabGroup.swift.
    var color: Color { Color(hex: colorHex) ?? .purple }

    func updateColor(_ color: Color) {
        self.colorHex = color.toHex() ?? "#5E5CE6"
    }

    // A stable, distinct tint for an incognito session, which has no persisted record.
    // Different incognito sessions get different blue–violet hues so two isolated
    // private sessions still read as different. Stable within a run (incognito never
    // outlives the process, so per-run stability is all that's needed).
    static func incognitoColor(for sessionId: UUID) -> Color {
        let h = Double(abs(sessionId.hashValue) % 1000) / 1000.0
        return Color(hue: 0.62 + h * 0.16, saturation: 0.55, brightness: 0.82)
    }
}
