//
//  TranslationLanguageUsage.swift
//  Straight Up Browser
//
//  The Translation framework exposes no install date or last-used date for a
//  downloaded language model, so this is our own proxy: seeded the moment
//  `prepareTranslation()` first succeeds for a language, updated whenever that
//  language actually translates a page. Settings uses it to suggest offloading
//  packs that have sat installed and unused for a while.
//

import Foundation

struct LanguagePackUsage: Codable {
    var code: String
    var installedAt: Date
    var lastUsedAt: Date?
}

final class TranslationLanguageUsage {
    static let shared = TranslationLanguageUsage()

    private static let storeKey = "translationLanguageUsage"
    private let defaults: UserDefaults
    private(set) var packs: [String: LanguagePackUsage] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([String: LanguagePackUsage].self, from: data) {
            packs = decoded
        }
    }

    func markInstalled(_ code: String, now: Date = Date()) {
        guard packs[code] == nil else { return }
        packs[code] = LanguagePackUsage(code: code, installedAt: now, lastUsedAt: nil)
        save()
    }

    func markUsed(_ code: String, now: Date = Date()) {
        if packs[code] == nil { packs[code] = LanguagePackUsage(code: code, installedAt: now, lastUsedAt: nil) }
        packs[code]?.lastUsedAt = now
        save()
    }

    // Installed long enough ago and idle long enough that freeing the disk
    // space is probably worth more than keeping it warm.
    func staleCandidates(
        now: Date = Date(),
        installedFor: TimeInterval = 60 * 86400,
        unusedFor: TimeInterval = 60 * 86400
    ) -> [LanguagePackUsage] {
        packs.values.filter { pack in
            now.timeIntervalSince(pack.installedAt) >= installedFor
                && now.timeIntervalSince(pack.lastUsedAt ?? pack.installedAt) >= unusedFor
        }.sorted { $0.installedAt < $1.installedAt }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(packs) {
            defaults.set(data, forKey: Self.storeKey)
        }
    }
}
