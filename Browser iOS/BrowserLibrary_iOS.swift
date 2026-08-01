import SwiftUI
import UniformTypeIdentifiers

struct BrowserLibrary_iOS: View {
    @Environment(\.dismiss) private var dismiss

    let bookmarks: [Bookmark]
    let initialSection: BrowserLibrarySection
    let onOpen: (URL) -> Void
    let onUpdateBookmark: (Bookmark, String, URL, String?) -> Void
    let onDeleteBookmark: (Bookmark) -> Void
    let onImportBookmarks: ([ImportedLibraryBookmark]) -> Int
    let onDeleteHistory: (URL) -> Void
    let onClearHistory: () -> Void
    @ObservedObject private var historyStore: BrowsingHistoryStore

    @State private var section: BrowserLibrarySection
    @State private var query = ""
    @State private var editingBookmark: Bookmark?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var showClearHistoryConfirmation = false
    @State private var exportDocument = BookmarkHTMLDocument(text: "")
    @State private var statusMessage: String?

    init(
        bookmarks: [Bookmark],
        historyStore: BrowsingHistoryStore = .shared,
        initialSection: BrowserLibrarySection,
        onOpen: @escaping (URL) -> Void,
        onUpdateBookmark: @escaping (Bookmark, String, URL, String?) -> Void,
        onDeleteBookmark: @escaping (Bookmark) -> Void,
        onImportBookmarks: @escaping ([ImportedLibraryBookmark]) -> Int,
        onDeleteHistory: @escaping (URL) -> Void,
        onClearHistory: @escaping () -> Void
    ) {
        self.bookmarks = bookmarks
        self.historyStore = historyStore
        self.initialSection = initialSection
        self.onOpen = onOpen
        self.onUpdateBookmark = onUpdateBookmark
        self.onDeleteBookmark = onDeleteBookmark
        self.onImportBookmarks = onImportBookmarks
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

    private var filteredHistory: [HistoryVisit] {
        let visits = historyStore.recentVisits
        guard !query.isEmpty else { return visits }
        return visits.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Library Section", selection: $section) {
                    ForEach(BrowserLibrarySection.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                content
            }
            .navigationTitle("Library")
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search \(section.rawValue.lowercased())"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    actionsMenu
                }
            }
        }
        .sheet(item: $editingBookmark) { bookmark in
            BookmarkEditor_iOS(
                bookmark: bookmark,
                onSave: { title, url, category in
                    onUpdateBookmark(bookmark, title, url, category)
                    editingBookmark = nil
                }
            )
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.html, .plainText],
            allowsMultipleSelection: false,
            onCompletion: importBookmarks
        )
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .html,
            defaultFilename: "Browser Bookmarks"
        ) { result in
            if case .failure(let error) = result {
                statusMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Clear all browsing history?",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { onClearHistory() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Library",
            isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statusMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if section == .bookmarks {
            if filteredBookmarks.isEmpty {
                ContentUnavailableView("No bookmarks", systemImage: "star")
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
            }
        } else if filteredHistory.isEmpty {
            ContentUnavailableView("No browsing history", systemImage: "clock")
        } else {
            List(filteredHistory) { visit in
                historyRow(visit)
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            if section == .bookmarks {
                Button {
                    showImporter = true
                } label: {
                    Label("Import Bookmarks…", systemImage: "square.and.arrow.down")
                }
                Button {
                    exportDocument = BookmarkHTMLDocument(
                        text: BrowserLibrary.bookmarkHTML(bookmarks)
                    )
                    showExporter = true
                } label: {
                    Label("Export Bookmarks…", systemImage: "square.and.arrow.up")
                }
            } else {
                Button(role: .destructive) {
                    showClearHistoryConfirmation = true
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .disabled(historyStore.visits.isEmpty)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Library Actions")
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
        Button {
            onOpen(bookmark.url)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(bookmark.title).lineLimit(1)
                Text(bookmark.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                onDeleteBookmark(bookmark)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editingBookmark = bookmark
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button("Edit") { editingBookmark = bookmark }
            Button("Delete", role: .destructive) { onDeleteBookmark(bookmark) }
        }
    }

    private func historyRow(_ visit: HistoryVisit) -> some View {
        Button {
            onOpen(visit.url)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(visit.title).lineLimit(1)
                Text(visit.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                onDeleteHistory(visit.url)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func importBookmarks(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            let html = try String(contentsOf: url, encoding: .utf8)
            let parsed = BrowserLibrary.bookmarks(fromHTML: html)
            let added = onImportBookmarks(parsed)
            statusMessage = String(
                localized: "Imported \(added) of \(parsed.count) bookmarks."
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct BookmarkHTMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.html, .plainText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct BookmarkEditor_iOS: View {
    @Environment(\.dismiss) private var dismiss
    let bookmark: Bookmark
    let onSave: (String, URL, String?) -> Void

    @State private var title: String
    @State private var urlString: String
    @State private var category: String

    init(
        bookmark: Bookmark,
        onSave: @escaping (String, URL, String?) -> Void
    ) {
        self.bookmark = bookmark
        self.onSave = onSave
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
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("URL", text: $urlString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Folder", text: $category)
            }
            .navigationTitle("Edit Bookmark")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let validURL else { return }
                        let folder = category.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(
                            title.trimmingCharacters(in: .whitespacesAndNewlines),
                            validURL,
                            folder.isEmpty ? nil : folder
                        )
                        dismiss()
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || validURL == nil
                    )
                }
            }
        }
    }
}
