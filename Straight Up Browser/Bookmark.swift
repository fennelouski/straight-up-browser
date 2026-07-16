//
//  Bookmark.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import SwiftData

@Model
final class Bookmark {
    // Defaults required for SwiftData+CloudKit compatibility.
    var id: UUID = UUID()
    var title: String = ""
    var url: URL = URL(string: "about:blank")!
    var createdAt: Date = Date()
    var lastVisited: Date?
    var favicon: Data?
    var category: String?

    init(title: String, url: URL, category: String? = nil) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.createdAt = Date()
        self.category = category
    }

    convenience init(from tab: Tab) {
        let title = tab.title.isEmpty ? Tab.extractDomain(from: tab.url) : tab.title
        self.init(title: title, url: tab.url ?? URL(string: "about:blank")!)
    }
}