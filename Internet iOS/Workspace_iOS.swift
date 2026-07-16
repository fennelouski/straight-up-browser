//
//  Workspace_iOS.swift
//  Internet (iPadOS)
//
//  Saved-workspace value types (a named snapshot of the current tabs + groups),
//  mirroring the Mac ContentView's SavedWorkspace/SavedTabGroup/SavedWorkspaceTab.
//  Persistence lives here as static helpers using the same UserDefaults key as
//  the Mac app.
//

import Foundation
import SwiftUI

struct SavedWorkspace: Codable, Identifiable {
    let id: UUID
    let name: String
    let createdAt: Date
    let groups: [SavedTabGroup]
    let tabs: [SavedWorkspaceTab]

    init(name: String, groups: [TabGroup], tabs: [Tab]) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.groups = groups.map(SavedTabGroup.init(from:))
        self.tabs = tabs.map(SavedWorkspaceTab.init(from:))
    }

    private static let storageKey = "saved_workspaces"

    static func loadAll() -> [SavedWorkspace] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let workspaces = try? JSONDecoder().decode([SavedWorkspace].self, from: data) else { return [] }
        return workspaces
    }

    static func saveAll(_ workspaces: [SavedWorkspace]) {
        if let data = try? JSONEncoder().encode(workspaces) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

struct SavedTabGroup: Codable {
    let id: UUID
    let name: String
    let colorHex: String
    let orderIndex: Int

    init(from group: TabGroup) {
        self.id = group.id
        self.name = group.name
        self.colorHex = group.colorHex
        self.orderIndex = group.orderIndex
    }
}

struct SavedWorkspaceTab: Codable {
    let id: UUID
    let title: String
    let urlString: String?
    let groupId: UUID?
    let isPinned: Bool
    let isMuted: Bool
    let zoomLevel: Double
    let orderIndex: Int

    init(from tab: Tab) {
        self.id = tab.id
        self.title = tab.title
        self.urlString = tab.url?.absoluteString
        self.groupId = tab.groupId
        self.isPinned = tab.isPinned
        self.isMuted = tab.isMuted
        self.zoomLevel = tab.zoomLevel
        self.orderIndex = tab.orderIndex
    }
}
