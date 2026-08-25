//
//  TranslationHistoryStore.swift
//  Straight Up Browser
//
//  Every page whose language auto-translate noticed, and whether it actually
//  translated it — so Settings can show what the feature has been doing
//  instead of it working (or silently not working) invisibly in the
//  background. One row per host, same shape as SiteHistory.
//

import Foundation

struct TranslationHistoryRecord: Codable, Identifiable {
    var id: String { host }
    var host: String
    var title: String
    var sourceLanguage: String
    var targetLanguage: String
    var detectedAt: Date
    var translatedAt: Date?
    var detectCount: Int
    var translateCount: Int
}

final class TranslationHistoryStore {
    static let shared = TranslationHistoryStore()

    private static let storeKey = "translationHistory"
    private static let maxEntries = 300
    private let defaults: UserDefaults
    private(set) var records: [String: TranslationHistoryRecord] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([String: TranslationHistoryRecord].self, from: data) {
            records = decoded
        }
    }

    func recordDetection(host: String, title: String, source: String, target: String, now: Date = Date()) {
        upsert(host: host, title: title, source: source, target: target, now: now) {
            $0.detectedAt = now
            $0.detectCount += 1
        }
    }

    func recordTranslation(host: String, title: String, source: String, target: String, now: Date = Date()) {
        upsert(host: host, title: title, source: source, target: target, now: now) {
            $0.translatedAt = now
            $0.translateCount += 1
        }
    }

    var recent: [TranslationHistoryRecord] {
        records.values.sorted { ($0.translatedAt ?? $0.detectedAt) > ($1.translatedAt ?? $1.detectedAt) }
    }

    func clear() {
        records = [:]
        defaults.removeObject(forKey: Self.storeKey)
    }

    private func upsert(
        host: String, title: String, source: String, target: String, now: Date,
        apply: (inout TranslationHistoryRecord) -> Void
    ) {
        var entry = records[host] ?? TranslationHistoryRecord(
            host: host, title: title, sourceLanguage: source, targetLanguage: target,
            detectedAt: now, translatedAt: nil, detectCount: 0, translateCount: 0)
        entry.title = title
        entry.sourceLanguage = source
        entry.targetLanguage = target
        apply(&entry)
        records[host] = entry
        save()
    }

    private func save() {
        if records.count > Self.maxEntries {
            let keep = records.values.sorted { ($0.translatedAt ?? $0.detectedAt) > ($1.translatedAt ?? $1.detectedAt) }
                .prefix(Self.maxEntries)
            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.host, $0) })
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.storeKey)
        }
    }
}
