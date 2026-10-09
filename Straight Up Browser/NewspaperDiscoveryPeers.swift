import Foundation

/// A small private-iCloud mailbox, not a remotely executed agent. Each device
/// publishes only its own row. Stale worker advertisements expire after three
/// minutes; candidate links expire after one day. KVS is eventually consistent,
/// so election reduces duplicate loads without claiming exactly-once execution.
@MainActor
enum NewspaperDiscoveryPeers {
    private static let prefix = "newspaperDiscoveryPeer."
    private static let advertisedKey = "newspaperDiscoveryHasAdvertisement"
    private static var key: String { prefix + NewspaperWorkIdentity.current }
    struct Advertisement: Codable {
        var updatedAt: Date
        var idle: Bool
        var links: [String]
        var linksUpdatedAt: Date
    }
    static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: NewspaperPreferences.Key.shareDiscovery)
            && defaults.bool(forKey: NewspaperPreferences.Key.discoverRelated)
            && defaults.bool(forKey: TabSync.Key.enabled)
    }
    static func heartbeat(idle: Bool, defaults: UserDefaults = .standard) {
        guard enabled(defaults: defaults) else { removeLocal(defaults: defaults); return }
        let store = NSUbiquitousKeyValueStore.default
        var row = decode(store.data(forKey: key)) ?? Advertisement(updatedAt: .now, idle: false, links: [], linksUpdatedAt: .now)
        row.updatedAt = .now
        row.idle = idle
        if let data = try? JSONEncoder().encode(row) {
            store.set(data, forKey: key)
            defaults.set(true, forKey: advertisedKey)
            store.synchronize()
        }
    }
    static func publishCandidates(_ links: [URL], defaults: UserDefaults = .standard) {
        guard enabled(defaults: defaults) else { return }
        let store = NSUbiquitousKeyValueStore.default
        var row = decode(store.data(forKey: key)) ?? Advertisement(updatedAt: .now, idle: false, links: [], linksUpdatedAt: .now)
        row.links = Array(links.map(\.absoluteString).filter { $0.count < 512 }.prefix(10))
        row.linksUpdatedAt = .now
        if let data = try? JSONEncoder().encode(row) {
            store.set(data, forKey: key)
            defaults.set(true, forKey: advertisedKey)
            store.synchronize()
        }
    }
    static func isElectedIdleWorker(defaults: UserDefaults = .standard, now: Date = .now) -> Bool {
        guard enabled(defaults: defaults) else { return true }
        return electedWorker(advertisements: advertisements(), now: now) == key
    }
    static func electedWorker(advertisements: [String: Advertisement], now: Date) -> String? {
        advertisements.filter { $0.value.idle && now.timeIntervalSince($0.value.updatedAt) >= 0 && now.timeIntervalSince($0.value.updatedAt) < 180 }.keys.sorted().first
    }
    static func candidates(defaults: UserDefaults = .standard) -> [URL] {
        guard enabled(defaults: defaults) else { return [] }
        let options = NewspaperDiscoveryOptions(defaults: defaults)
        return Array(Set(advertisements().filter { $0.key != key && Date().timeIntervalSince($0.value.linksUpdatedAt) < 86400 }
            .values.flatMap(\.links).compactMap(URL.init(string:)).filter(options.permits)).prefix(20))
    }
    static func removeLocal(defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: advertisedKey) else { return }
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
        defaults.set(false, forKey: advertisedKey)
    }
    private static func advertisements() -> [String: Advertisement] {
        NSUbiquitousKeyValueStore.default.dictionaryRepresentation.reduce(into: [:]) { result, item in
            guard item.key.hasPrefix(prefix), let data = item.value as? Data, let row = decode(data) else { return }
            result[item.key] = row
        }
    }
    private static func decode(_ data: Data?) -> Advertisement? {
        guard let data, data.count < 8192 else { return nil }
        return try? JSONDecoder().decode(Advertisement.self, from: data)
    }
}
