import Foundation
#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
#endif

struct ImportedLibraryBookmark: Equatable {
    let title: String
    let url: URL
    let category: String?
}

enum BrowserLibrary {
    static func historyURLs(from tabs: [Tab]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []

        for tab in tabs.reversed() {
            for url in tab.history.reversed()
            where url.scheme == "http" || url.scheme == "https" {
                if seen.insert(url.absoluteString).inserted {
                    result.append(url)
                }
            }
        }
        return result
    }

    static func sortedTabs(_ tabs: [Tab]) -> [Tab] {
        tabs.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return $0.orderIndex < $1.orderIndex
        }
    }

    static func removeHistory(url: URL, from tabs: [Tab]) {
        for tab in tabs {
            tab.historyStrings.removeAll { $0 == url.absoluteString }
            tab.currentHistoryIndex = min(
                tab.currentHistoryIndex,
                tab.historyStrings.count - 1
            )
        }
    }

    static func bookmarkHTML(_ bookmarks: [Bookmark]) -> String {
        let grouped = Dictionary(grouping: bookmarks) {
            let category = $0.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return category.isEmpty ? String(localized: "Bookmarks") : category
        }

        let folders = grouped.keys.sorted().map { folder in
            let links = (grouped[folder] ?? [])
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map { bookmark in
                    "        <DT><A HREF=\"\(escape(bookmark.url.absoluteString))\">\(escape(bookmark.title))</A>"
                }
                .joined(separator: "\n")
            return """
                <DT><H3>\(escape(folder))</H3>
                <DL><p>
            \(links)
                </DL><p>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Browser Bookmarks</TITLE>
        <H1>Browser Bookmarks</H1>
        <DL><p>
        \(folders)
        </DL><p>
        """
    }

    static func bookmarks(fromHTML html: String) -> [ImportedLibraryBookmark] {
        let pattern = #"<H3\b[^>]*>(.*?)</H3>|<A\b[^>]*HREF\s*=\s*["']([^"']+)["'][^>]*>(.*?)</A>"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        var currentFolder: String?
        var result: [ImportedLibraryBookmark] = []
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in expression.matches(in: html, range: range) {
            if let folderRange = Range(match.range(at: 1), in: html) {
                currentFolder = decodedHTML(String(html[folderRange])).trimmedNonEmpty
                continue
            }
            guard let urlRange = Range(match.range(at: 2), in: html),
                  let titleRange = Range(match.range(at: 3), in: html) else { continue }
            let urlString = decodedHTML(String(html[urlRange]))
            guard let url = URL(string: urlString),
                  url.scheme == "http" || url.scheme == "https" else { continue }
            let title = decodedHTML(String(html[titleRange])).trimmedNonEmpty
                ?? url.host
                ?? url.absoluteString
            result.append(
                ImportedLibraryBookmark(
                    title: title,
                    url: url,
                    category: currentFolder
                )
            )
        }
        return result
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func decodedHTML(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"<[^>]+>"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated struct ReaderInline: Codable, Equatable {
    let text: String
    let link: URL?
    let isStrong: Bool
    let isEmphasized: Bool
    let isCode: Bool

    init(
        text: String,
        link: URL? = nil,
        isStrong: Bool = false,
        isEmphasized: Bool = false,
        isCode: Bool = false
    ) {
        self.text = text
        self.link = link
        self.isStrong = isStrong
        self.isEmphasized = isEmphasized
        self.isCode = isCode
    }

    static func plain(_ text: String) -> ReaderInline {
        ReaderInline(text: text)
    }
}

nonisolated enum ReaderBlock: Codable, Equatable {
    case heading(level: Int, runs: [ReaderInline])
    case paragraph(runs: [ReaderInline])
    case listItem(
        ordered: Bool,
        ordinal: Int?,
        depth: Int,
        runs: [ReaderInline]
    )
    case quote(runs: [ReaderInline])
    case code(String)
    case caption(runs: [ReaderInline])

    var plainText: String {
        switch self {
        case .heading(_, let runs),
             .paragraph(let runs),
             .listItem(_, _, _, let runs),
             .quote(let runs),
             .caption(let runs):
            runs.map(\.text).joined()
        case .code(let text):
            text
        }
    }
}

nonisolated struct ReaderImage: Codable, Equatable {
    let url: URL
    let altText: String?
}

nonisolated struct ReaderArticle: Codable, Equatable {
    let title: String
    let byline: String?
    let blocks: [ReaderBlock]
    let publication: String?
    let section: String?
    let publishedAt: Date?
    let images: [ReaderImage]

    init(
        title: String,
        byline: String?,
        blocks: [ReaderBlock],
        publication: String? = nil,
        section: String? = nil,
        publishedAt: Date? = nil,
        images: [ReaderImage] = []
    ) {
        self.title = title
        self.byline = byline
        self.blocks = blocks
        self.publication = publication
        self.section = section
        self.publishedAt = publishedAt
        self.images = images
    }

    var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n\n")
    }
}

enum ReaderMode {
    static let extractionScript = """
        (() => {
          const source = document.querySelector('article') || document.querySelector('main') || document.body;
          if (!source) return null;
          const copy = source.cloneNode(true);
          copy.querySelectorAll(`
            script, style, nav, form, button, aside, footer, noscript, iframe,
            [aria-label*="advert" i], [class~="advertisement"], [class~="ad"],
            [data-ad], [id^="ad-"], [class^="ad-"]
          `).forEach(node => node.remove());

          const runsFor = node => {
            const runs = [];
            const visit = (current, style) => {
              if (current.nodeType === Node.TEXT_NODE) {
                const text = (current.nodeValue || '').replace(/\\s+/g, ' ');
                if (text) runs.push({ text, ...style });
                return;
              }
              if (current.nodeType !== Node.ELEMENT_NODE) return;
              const tag = current.tagName;
              if (tag === 'UL' || tag === 'OL') return;
              if (tag === 'BR') {
                runs.push({ text: '\\n', ...style });
                return;
              }
              const next = {
                href: tag === 'A' ? current.href : style.href,
                strong: style.strong || tag === 'STRONG' || tag === 'B',
                emphasized: style.emphasized || tag === 'EM' || tag === 'I',
                code: style.code || tag === 'CODE'
              };
              Array.from(current.childNodes).forEach(child => visit(child, next));
            };
            visit(node, {
              href: '',
              strong: false,
              emphasized: false,
              code: false
            });

            const merged = [];
            runs.forEach(run => {
              const previous = merged[merged.length - 1];
              if (previous &&
                  previous.href === run.href &&
                  previous.strong === run.strong &&
                  previous.emphasized === run.emphasized &&
                  previous.code === run.code) {
                previous.text += run.text;
              } else {
                merged.push(run);
              }
            });
            if (merged.length) {
              merged[0].text = merged[0].text.trimStart();
              merged[merged.length - 1].text = merged[merged.length - 1].text.trimEnd();
            }
            return merged.filter(run => run.text.length > 0);
          };

          const blocks = [];
          const addRuns = (kind, node, extra = {}) => {
            const runs = runsFor(node);
            if (runs.some(run => run.text.trim().length > 0)) {
              blocks.push({ kind, runs, ...extra });
            }
          };

          const walkList = (list, depth) => {
            const ordered = list.tagName === 'OL';
            let ordinal = Number.parseInt(list.getAttribute('start') || '1', 10);
            Array.from(list.children).forEach(item => {
              if (item.tagName !== 'LI') return;
              const content = item.cloneNode(true);
              content.querySelectorAll('ul, ol').forEach(nested => nested.remove());
              addRuns('listItem', content, {
                ordered,
                ordinal: ordered ? ordinal : null,
                depth
              });
              Array.from(item.children)
                .filter(child => child.tagName === 'UL' || child.tagName === 'OL')
                .forEach(nested => walkList(nested, depth + 1));
              ordinal += 1;
            });
          };

          const walk = container => {
            Array.from(container.children).forEach(node => {
              const tag = node.tagName;
              if (/^H[1-6]$/.test(tag)) {
                addRuns('heading', node, { level: Number(tag.slice(1)) });
              } else if (tag === 'P') {
                addRuns('paragraph', node);
              } else if (tag === 'UL' || tag === 'OL') {
                walkList(node, 0);
              } else if (tag === 'BLOCKQUOTE') {
                addRuns('quote', node);
              } else if (tag === 'PRE') {
                const text = (node.textContent || '').trim();
                if (text) blocks.push({ kind: 'code', text });
              } else if (tag === 'FIGCAPTION') {
                addRuns('caption', node);
              } else if (tag === 'ARTICLE' || tag === 'MAIN' || tag === 'SECTION' ||
                         tag === 'DIV' || tag === 'FIGURE') {
                walk(node);
              } else {
                addRuns('paragraph', node);
              }
            });
          };

          walk(copy);
          if (!blocks.length) addRuns('paragraph', copy);
          if (!blocks.length) return null;
          const extractedCharacters = blocks.reduce((total, block) => {
            if (block.text) return total + block.text.length;
            return total + (block.runs || []).reduce((sum, run) => sum + run.text.length, 0);
          }, 0);
          if (blocks.length > 10000 || extractedCharacters > 2000000) {
            return { error: 'tooLarge' };
          }
          const author = document.querySelector('[rel="author"], .byline, [class*="author"]');
          const textOf = selector => {
            const node = document.querySelector(selector);
            const value = node && (node.content || node.getAttribute('datetime') || node.textContent || '');
            return typeof value === 'string' ? value.trim() : '';
          };
          const seenImages = new Set();
          const images = Array.from(source.querySelectorAll('img')).flatMap(image => {
            const src = image.currentSrc || image.src || image.dataset.src || '';
            if (!src || seenImages.has(src)) return [];
            const width = image.naturalWidth || image.width || Number.parseInt(image.getAttribute('width') || '0', 10);
            const height = image.naturalHeight || image.height || Number.parseInt(image.getAttribute('height') || '0', 10);
            if ((width && width < 160) || (height && height < 100)) return [];
            seenImages.add(src);
            return [{ url: src, alt: (image.alt || '').trim() }];
          }).slice(0, 40);
          return {
            title: document.title || location.hostname,
            byline: author ? author.textContent.trim() : '',
            publication: textOf('meta[property="og:site_name"], meta[name="application-name"]'),
            section: textOf('meta[property="article:section"], meta[name="section"]'),
            publishedAt: textOf('meta[property="article:published_time"], time[datetime]'),
            images,
            blocks
          };
        })()
        """

    static func article(from value: Any?) -> ReaderArticle? {
        guard let object = value as? [String: Any],
              let title = object["title"] as? String else { return nil }
        let blocks = blocks(from: object["blocks"])
        guard !blocks.isEmpty else { return nil }
        let byline = (object["byline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReaderArticle(
            title: title.isEmpty ? String(localized: "Reader Mode") : title,
            byline: byline?.isEmpty == true ? nil : byline,
            blocks: blocks,
            publication: nonEmptyString(object["publication"]),
            section: nonEmptyString(object["section"]),
            publishedAt: date(from: object["publishedAt"]),
            images: images(from: object["images"])
        )
    }

    private static func images(from value: Any?) -> [ReaderImage] {
        guard let objects = value as? [[String: Any]] else { return [] }
        var seen: Set<String> = []
        return objects.compactMap { object in
            guard let value = object["url"] as? String,
                  let url = URL(string: value),
                  url.scheme == "http" || url.scheme == "https",
                  seen.insert(url.absoluteString).inserted else { return nil }
            return ReaderImage(url: url, altText: nonEmptyString(object["alt"]))
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
    }

    private static func date(from value: Any?) -> Date? {
        guard let value = nonEmptyString(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func blocks(from value: Any?) -> [ReaderBlock] {
        guard let objects = value as? [[String: Any]] else { return [] }
        return objects.compactMap { object in
            guard let kind = object["kind"] as? String else { return nil }
            switch kind {
            case "heading":
                let level = min(max(object["level"] as? Int ?? 2, 1), 6)
                let runs = runs(from: object["runs"])
                return runs.isEmpty ? nil : .heading(level: level, runs: runs)
            case "paragraph":
                let runs = runs(from: object["runs"])
                return runs.isEmpty ? nil : .paragraph(runs: runs)
            case "listItem":
                let runs = runs(from: object["runs"])
                guard !runs.isEmpty else { return nil }
                return .listItem(
                    ordered: object["ordered"] as? Bool ?? false,
                    ordinal: object["ordinal"] as? Int,
                    depth: max(object["depth"] as? Int ?? 0, 0),
                    runs: runs
                )
            case "quote":
                let runs = runs(from: object["runs"])
                return runs.isEmpty ? nil : .quote(runs: runs)
            case "code":
                guard let text = (object["text"] as? String)?.trimmedNonEmpty else {
                    return nil
                }
                return .code(text)
            case "caption":
                let runs = runs(from: object["runs"])
                return runs.isEmpty ? nil : .caption(runs: runs)
            default:
                return nil
            }
        }
    }

    private static func runs(from value: Any?) -> [ReaderInline] {
        guard let objects = value as? [[String: Any]] else { return [] }
        return objects.compactMap { object in
            guard let text = object["text"] as? String, !text.isEmpty else { return nil }
            return ReaderInline(
                text: text,
                link: safeLink(from: object["href"]),
                isStrong: object["strong"] as? Bool ?? false,
                isEmphasized: object["emphasized"] as? Bool ?? false,
                isCode: object["code"] as? Bool ?? false
            )
        }
    }

    private static func safeLink(from value: Any?) -> URL? {
        guard let string = value as? String,
              let url = URL(string: string),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }
}

enum BrowserLibrarySection: String, CaseIterable, Identifiable {
    case bookmarks = "Bookmarks"
    case history = "History"

    var id: Self { self }
}

#if os(macOS)
struct BrowserLibraryView: View {
    let bookmarks: [Bookmark]
    let initialSection: BrowserLibrarySection
    let onOpen: (URL) -> Void
    let onClose: () -> Void
    let onUpdateBookmark: (Bookmark, String, URL, String?) -> Void
    let onDeleteBookmark: (Bookmark) -> Void
    let onDeleteHistory: (URL) -> Void
    let onClearHistory: () -> Void
    @ObservedObject private var historyStore: BrowsingHistoryStore

    @State private var section: BrowserLibrarySection
    @State private var query = ""
    @State private var editingBookmark: Bookmark?
    @State private var errorMessage: String?

    init(
        bookmarks: [Bookmark],
        historyStore: BrowsingHistoryStore = .shared,
        initialSection: BrowserLibrarySection,
        onOpen: @escaping (URL) -> Void,
        onClose: @escaping () -> Void,
        onUpdateBookmark: @escaping (Bookmark, String, URL, String?) -> Void,
        onDeleteBookmark: @escaping (Bookmark) -> Void,
        onDeleteHistory: @escaping (URL) -> Void,
        onClearHistory: @escaping () -> Void
    ) {
        self.bookmarks = bookmarks
        self.historyStore = historyStore
        self.initialSection = initialSection
        self.onOpen = onOpen
        self.onClose = onClose
        self.onUpdateBookmark = onUpdateBookmark
        self.onDeleteBookmark = onDeleteBookmark
        self.onDeleteHistory = onDeleteHistory
        self.onClearHistory = onClearHistory
        _section = State(initialValue: initialSection)
    }

    private var filteredBookmarks: [Bookmark] {
        guard !query.isEmpty else { return bookmarks }
        return bookmarks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
                || ($0.category?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var filteredHistory: [URL] {
        let urls = historyStore.recentVisits.map(\.url)
        guard !query.isEmpty else { return urls }
        return urls.filter { $0.absoluteString.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 680, height: 520)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser Library")
        .accessibilityAddTraits(.isModal)
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .sheet(item: $editingBookmark) { bookmark in
            BookmarkEditor(
                bookmark: bookmark,
                onSave: { title, url, category in
                    onUpdateBookmark(bookmark, title, url, category)
                    editingBookmark = nil
                },
                onCancel: { editingBookmark = nil }
            )
        }
        .alert("Export Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Library")
                    .font(.title2.bold())
                Spacer()
                if section == .bookmarks {
                    Button("Export…", action: exportBookmarks)
                } else if !filteredHistory.isEmpty {
                    Button("Clear History", role: .destructive, action: onClearHistory)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Library")
            }

            Picker("Library Section", selection: $section) {
                ForEach(BrowserLibrarySection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)

            TextField("Search \(section.rawValue.lowercased())", text: $query)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if section == .bookmarks {
            if filteredBookmarks.isEmpty {
                emptyState("No bookmarks", systemImage: "star")
            } else {
                List {
                    ForEach(bookmarkFolders, id: \.name) { folder in
                        Section(folder.name) {
                            ForEach(folder.bookmarks) { bookmark in
                                bookmarkRow(bookmark)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        } else if filteredHistory.isEmpty {
            emptyState("No browsing history", systemImage: "clock")
        } else {
            List(filteredHistory, id: \.absoluteString) { url in
                historyRow(url)
            }
            .listStyle(.inset)
        }
    }

    private var bookmarkFolders: [(name: String, bookmarks: [Bookmark])] {
        let grouped = Dictionary(grouping: filteredBookmarks) {
            let category = $0.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return category.isEmpty ? String(localized: "Bookmarks") : category
        }
        return grouped.keys.sorted().map { name in
            (
                name,
                (grouped[name] ?? []).sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            )
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        HStack {
            Button {
                onOpen(bookmark.url)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.title).lineLimit(1)
                    Text(bookmark.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button("Edit") { editingBookmark = bookmark }
            Button(role: .destructive) {
                onDeleteBookmark(bookmark)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(bookmark.title)")
        }
    }

    private func historyRow(_ url: URL) -> some View {
        HStack {
            Button {
                onOpen(url)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(historyTitle(for: url))
                        .lineLimit(1)
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                onDeleteHistory(url)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(url.absoluteString) from history")
        }
    }

    private func historyTitle(for url: URL) -> String {
        historyStore.recentVisits.first {
            $0.url.absoluteString == url.absoluteString
        }?.title
            ?? url.host
            ?? url.absoluteString
    }

    private func emptyState(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportBookmarks() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Browser Bookmarks.html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BrowserLibrary.bookmarkHTML(bookmarks).write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BookmarkEditor: View {
    let bookmark: Bookmark
    let onSave: (String, URL, String?) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var urlString: String
    @State private var category: String

    init(
        bookmark: Bookmark,
        onSave: @escaping (String, URL, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.bookmark = bookmark
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: bookmark.title)
        _urlString = State(initialValue: bookmark.url.absoluteString)
        _category = State(initialValue: bookmark.category ?? "")
    }

    private var validURL: URL? {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Bookmark").font(.headline)
            TextField("Title", text: $title)
            TextField("URL", text: $urlString)
            TextField("Folder", text: $category)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    guard let validURL else { return }
                    let folder = category.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(
                        title.trimmingCharacters(in: .whitespacesAndNewlines),
                        validURL,
                        folder.isEmpty ? nil : folder
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validURL == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
#endif
