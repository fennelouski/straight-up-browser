import Foundation

enum NewspaperRecentReading {
    static func candidates(_ visits: [HistoryVisit], options: NewspaperDiscoveryOptions, now: Date = .now) -> [URL] {
        var seen: Set<String> = []
        return Array(visits.sorted { $0.visitedAt > $1.visitedAt }.compactMap { visit in
            let age = now.timeIntervalSince(visit.visitedAt)
            guard let url = NewspaperDiscoveryOptions.publicURL(visit.url) else { return nil }
            let path = visit.url.path.lowercased()
            guard age >= 0, age <= 30 * 86400, options.permits(url),
                  (path.isEmpty || path == "/" ? options.related : path.count > 12),
                  seen.insert(NewspaperStore.sourceKey(for: url)).inserted else { return nil }
            let host = visit.url.host?.lowercased() ?? ""
            if host == "reddit.com" || host.hasSuffix(".reddit.com") {
                guard path.contains("/comments/") || (options.related && path.hasPrefix("/r/")) else { return nil }
            }
            return url
        }.prefix(96))
    }

    static func isLikelyStoryURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        guard path.count > 12, !["/tag/", "/category/", "/topics/", "/account/", "/login/", "/checkout/"].contains(where: path.contains),
              !["jpg", "jpeg", "png", "gif", "webp", "svg", "pdf", "mp4", "css", "js"].contains(url.pathExtension.lowercased()) else { return false }
        let host = url.host?.lowercased() ?? ""
        if host == "reddit.com" || host.hasSuffix(".reddit.com") { return path.contains("/comments/") }
        let slug = url.lastPathComponent
        return slug.count > 20 && (slug.contains("-") || slug.hasSuffix(".html"))
    }

    static func section(for article: ReaderArticle, url: URL) -> String {
        if let section = article.section?.trimmingCharacters(in: .whitespacesAndNewlines), !section.isEmpty { return section }
        let host = url.host?.lowercased() ?? ""
        if host == "petapixel.com" || host.hasSuffix(".petapixel.com") { return "Photography" }
        if host == "gizmodo.com" || host.hasSuffix(".gizmodo.com") || host == "engadget.com" || host.hasSuffix(".engadget.com") { return "Technology" }
        if host == "reddit.com" || host.hasSuffix(".reddit.com") { return "Community" }
        let words = Set((article.title + " " + url.path).lowercased().split { !$0.isLetter }.map(String.init))
        for (section, terms) in [("Photography", ["photography", "camera", "photographer"]),
            ("Science", ["science", "space", "astronomy", "research"]),
            ("Technology", ["technology", "software", "iphone", "computer", "gadget"]),
            ("Business", ["business", "market", "finance", "economy"]),
            ("Culture", ["music", "film", "art", "culture"]),
            ("Sport", ["sports", "football", "basketball", "tennis"])] {
            if !words.isDisjoint(with: terms) { return section }
        }
        return "Features"
    }
}
