//
//  TabGroup.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import SwiftUI
import SwiftData

@Model
final class TabGroup {
    // Defaults required for SwiftData+CloudKit compatibility.
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#007AFF"
    var createdAt: Date = Date()
    var orderIndex: Int = 0

    init(name: String, color: Color, orderIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.colorHex = color.toHex() ?? "#007AFF"
        self.createdAt = Date()
        self.orderIndex = orderIndex
    }

    var color: Color {
        Color(hex: colorHex) ?? Color.blue
    }

    func updateColor(_ color: Color) {
        self.colorHex = color.toHex() ?? "#007AFF"
    }
}

// Extension to convert Color to hex and vice versa
extension Color {
    func toHex() -> String? {
        #if canImport(AppKit)
        let platformColor = NSColor(self)
        #else
        let platformColor = UIColor(self)
        #endif
        guard let components = platformColor.cgColor.components, components.count >= 3 else {
            return nil
        }
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
    }
}

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}