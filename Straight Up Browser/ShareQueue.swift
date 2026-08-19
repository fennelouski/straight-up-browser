//
//  ShareQueue.swift
//  Straight Up Browser
//
//  The handoff between the share extension and the app (Phase 3,
//  docs/phase3-design.md §2): the extension NEVER touches the ledger — two
//  processes on one CloudKit-backed store is how sync state corrupts. It writes
//  one JSON file per shared item into the app group's ShareInbox; the app
//  drains the inbox when it becomes active. Foundation-only on purpose: this
//  file compiles into both apps, the extension, and the test target.
//

import Foundation

nonisolated enum ShareQueue {

    static let appGroupID = "group.com.nathanfennel.Straight-Up-Browser"

    /// One shared item, as the extension wrote it. `fileName` is non-nil for
    /// file/image shares and names the payload file beside this JSON.
    struct SharedItem: Codable, Equatable, Sendable {
        var id: UUID = UUID()
        var workspaceId: UUID
        var url: URL?
        var title: String
        var fileName: String?
        var sharedAt: Date = Date()
    }

    /// A workspace as the extension's picker sees it. Mirrored, never queried.
    struct MirroredWorkspace: Codable, Equatable, Sendable {
        let id: UUID
        let name: String
        let lastActiveAt: Date
    }

    // MARK: Locations

    static func containerURL(groupID: String = appGroupID) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static func inboxURL(container: URL) -> URL {
        container.appendingPathComponent("ShareInbox", isDirectory: true)
    }

    // MARK: Writing (the extension side)

    /// Writes the payload file (if any) first, the JSON last — a crashed write
    /// leaves an orphan payload, never a JSON pointing at missing bytes.
    @discardableResult
    static func enqueue(_ item: SharedItem, fileData: Data? = nil, container: URL? = containerURL()) -> Bool {
        guard let container else { return false }
        let inbox = inboxURL(container: container)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            var item = item
            if let fileData {
                let name = item.fileName ?? item.id.uuidString
                item.fileName = name
                try fileData.write(to: inbox.appendingPathComponent(name), options: .atomic)
            }
            let json = try JSONEncoder().encode(item)
            try json.write(to: inbox.appendingPathComponent(item.id.uuidString + ".share.json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Draining (the app side)

    /// Every queued item plus its payload bytes, oldest first. Pure read —
    /// `clear(_:)` removes what the caller actually ingested.
    static func pending(container: URL? = containerURL()) -> [(item: SharedItem, fileData: Data?)] {
        guard let container else { return [] }
        let inbox = inboxURL(container: container)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: inbox.path) else { return [] }
        return names.filter { $0.hasSuffix(".share.json") }
            .compactMap { name -> (SharedItem, Data?)? in
                guard let data = try? Data(contentsOf: inbox.appendingPathComponent(name)),
                      let item = try? JSONDecoder().decode(SharedItem.self, from: data)
                else { return nil }
                let fileData = item.fileName.flatMap {
                    try? Data(contentsOf: inbox.appendingPathComponent($0))
                }
                return (item, fileData)
            }
            .sorted { $0.0.sharedAt < $1.0.sharedAt }
    }

    static func clear(_ item: SharedItem, container: URL? = containerURL()) {
        guard let container else { return }
        let inbox = inboxURL(container: container)
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent(item.id.uuidString + ".share.json"))
        if let fileName = item.fileName {
            try? FileManager.default.removeItem(at: inbox.appendingPathComponent(fileName))
        }
    }

    // MARK: The workspace mirror

    private static let mirrorKey = "shareWorkspaceMirror"

    /// Refreshed whenever the app becomes active or resigns; the extension only
    /// ever reads this — it never opens the store.
    static func updateMirror(
        _ workspaces: [MirroredWorkspace],
        activeWorkspaceId: UUID?,
        groupID: String = appGroupID
    ) {
        guard let defaults = UserDefaults(suiteName: groupID) else { return }
        // The active workspace is "most recent" by definition, whatever its
        // stored timestamp says.
        let stamped = workspaces.map { workspace in
            workspace.id == activeWorkspaceId
                ? MirroredWorkspace(id: workspace.id, name: workspace.name, lastActiveAt: Date())
                : workspace
        }
        if let data = try? JSONEncoder().encode(stamped) {
            defaults.set(data, forKey: mirrorKey)
        }
    }

    /// Most-recently-active first — element zero is the picker's one-tap button.
    static func mirroredWorkspaces(groupID: String = appGroupID) -> [MirroredWorkspace] {
        guard let defaults = UserDefaults(suiteName: groupID),
              let data = defaults.data(forKey: mirrorKey),
              let workspaces = try? JSONDecoder().decode([MirroredWorkspace].self, from: data)
        else { return [] }
        return workspaces.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }
}
