import SwiftUI

nonisolated struct NewspaperShoppingSignal: Codable, Identifiable, Equatable {
    var id: String { url.absoluteString }
    let url: URL
    let title: String
    let capturedAt: Date
}

/// Product-page metadata only, after a regular-tab dwell and separate consent.
/// No purchase history, account data, guessed prices, affiliate links or ad API.
enum NewspaperShoppingStore {
    static func signals(defaults: UserDefaults = .standard, now: Date = .now) -> [NewspaperShoppingSignal] {
        guard defaults.bool(forKey: NewspaperEditionPreferences.captureShopping),
              let data = defaults.data(forKey: NewspaperEditionPreferences.shoppingSignals), data.count <= 32_768,
              let entries = try? JSONDecoder().decode([NewspaperShoppingSignal].self, from: data) else { return [] }
        let options = NewspaperDiscoveryOptions(defaults: defaults)
        return Array(entries.filter { now.timeIntervalSince($0.capturedAt) <= 30 * 86400 && options.permits($0.url) }.prefix(12))
    }
    static func record(url: URL, title: String, defaults: UserDefaults = .standard, now: Date = .now) {
        guard defaults.bool(forKey: NewspaperEditionPreferences.captureShopping), NewspaperDiscoveryOptions(defaults: defaults).permits(url) else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanTitle.count >= 3, cleanTitle.count <= 200 else { return }
        var entries = signals(defaults: defaults, now: now).filter { $0.url != url }
        entries.insert(.init(url: url, title: cleanTitle, capturedAt: now), at: 0)
        guard let data = try? JSONEncoder().encode(Array(entries.prefix(12))), data.count <= 32_768 else { return }
        defaults.set(data, forKey: NewspaperEditionPreferences.shoppingSignals)
    }
    static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: NewspaperEditionPreferences.shoppingSignals) }
    static func matchingArticle(title: String, articles: [NewspaperArticle]) -> NewspaperArticle? {
        let words = Set(title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 4 }.map(String.init))
        guard !words.isEmpty else { return nil }
        return articles.first { article in
            let candidate = Set(article.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return words.intersection(candidate).count >= min(2, words.count)
        }
    }
}

struct NewspaperShoppingCards: View {
    let signals: [NewspaperShoppingSignal]
    let articles: [NewspaperArticle]
    let onOpen: (URL) -> Void
    @Environment(\.newspaperEdition) private var style
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your shopping notebook", systemImage: "tag").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Personal clippings from product pages you chose to collect. No paid placements.").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                ForEach(signals) { signal in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("PERSONAL CLIPPING").font(.caption2.bold()).tracking(1.5).foregroundStyle(style.accent)
                        Text(signal.title).font(.system(.title3, design: style.sansSerif ? .default : .serif).bold()).fixedSize(horizontal: false, vertical: true)
                        Text(signal.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                        Button("Revisit product") { onOpen(signal.url) }.buttonStyle(BrowserPressStyle())
                        if let review = NewspaperShoppingStore.matchingArticle(title: signal.title, articles: articles) {
                            NavigationLink(value: review.id) { Label("Related reading: \(review.title)", systemImage: "text.book.closed") }
                                .font(.caption).buttonStyle(BrowserPressStyle())
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(style.accent.opacity(0.06))
                    .overlay { Rectangle().strokeBorder(style.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: style.isMagazine ? [] : [3, 2])) }
                    .transition(BrowserMotion.panel)
                }
            }
        }.accessibilityIdentifier("newspaper-shopping-notebook")
    }
}

struct NewspaperShoppingSettings: View {
    @AppStorage(NewspaperEditionPreferences.captureShopping) private var enabled = false
    @AppStorage(NewspaperEditionPreferences.showShopping) private var visible = true
    var body: some View {
        CollapsibleSection(searchID: "newspaper.shopping") {
            Toggle("Collect product interests from regular pages I visit", isOn: $enabled)
                .accessibilityIdentifier("newspaper-shopping-consent")
            Toggle("Show personal shopping clippings in my edition", isOn: $visible).disabled(!enabled)
            Button("Clear shopping clippings", role: .destructive) { NewspaperShoppingStore.clear() }
            Text("Off by default. Only explicit product metadata is collected after a dwell; password and payment forms, private sessions and excluded sites are skipped. Up to 12 titles and source links stay on this device for 30 days. Turning collection off clears them. No prices or endorsements are generated, and nothing is sent to advertisers or an AI provider.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Label("Shopping Notebook", systemImage: "tag") }
        .onChange(of: enabled) { _, value in if !value { NewspaperShoppingStore.clear() } }
    }
}
