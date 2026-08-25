import SwiftData
import SwiftUI

#if os(macOS)
struct NewspaperWindowScene: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NewspaperView(
            onOpenOriginal: { url in
                NotificationCenter.default.post(
                    name: .browserOpenURL,
                    object: nil,
                    userInfo: ["url": url.absoluteString, "newTab": true]
                )
            },
            onClose: { dismiss() }
        )
    }
}
#endif

struct NewspaperView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NewspaperArticle.addedAt, order: .reverse)
    private var storedArticles: [NewspaperArticle]

    let onOpenOriginal: (URL) -> Void
    let onClose: () -> Void

    @AppStorage(NewspaperPreferences.Key.layout)
    private var layoutRaw = NewspaperPreferences.defaultLayout
    @AppStorage(NewspaperPreferences.Key.navigationStyle)
    private var navigationStyleRaw = NewspaperPreferences.defaultNavigationStyle
    @AppStorage(NewspaperPreferences.Key.fontFamily) private var fontFamily = ""

    @State private var selectedSection = Self.allSections
    @State private var unreadOnly = false
    // `dismissed`'s one UI surface: sources rejected in every workspace are
    // hidden (ADR 0007's feed rule, wired here); this toggle reveals them, and
    // the card context menu can restore one per workspace.
    @State private var showDismissed = false
    @State private var pageIndex = 0

    private static let allSections = "All Sections"

    private var layout: NewspaperLayout {
        NewspaperLayout(rawValue: layoutRaw) ?? .broadsheet
    }

    private var navigationStyle: NewspaperNavigationStyle {
        NewspaperNavigationStyle(rawValue: navigationStyleRaw) ?? .continuous
    }

    private var sortedArticles: [NewspaperArticle] {
        let hidden: Set<String> = showDismissed
            ? []
            : LedgerStore(modelContext: modelContext).hiddenFromFeedKeys()
        return storedArticles
            .filter { hidden.isEmpty || !hidden.contains($0.sourceKey) }
            .filter { !unreadOnly || !$0.isRead }
            .filter { selectedSection == Self.allSections || $0.section == selectedSection }
            .sorted {
                if $0.priorityRaw != $1.priorityRaw {
                    return $0.priorityRaw > $1.priorityRaw
                }
                if $0.isRead != $1.isRead { return !$0.isRead && $1.isRead }
                return $0.addedAt > $1.addedAt
            }
    }

    private var sections: [String] {
        let names = Set(storedArticles.map(\.section).filter { !$0.isEmpty })
        return [Self.allSections] + names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                masthead
                Divider()
                sectionStrip
                Divider()

                if storedArticles.isEmpty {
                    emptyState
                } else if sortedArticles.isEmpty {
                    filteredEmptyState
                } else if navigationStyle == .pages {
                    NewspaperPagedIssue(
                        articles: sortedArticles,
                        layout: layout,
                        pageIndex: $pageIndex,
                        actions: actions
                    )
                } else {
                    continuousIssue
                }
            }
            .background(issueBackground.ignoresSafeArea())
            .foregroundStyle(layout == .ink ? Color.black : Color.primary)
            .navigationDestination(for: UUID.self) { id in
                if let article = storedArticles.first(where: { $0.id == id }) {
                    NewspaperArticleView(
                        article: article,
                        layout: layout,
                        onOpenOriginal: onOpenOriginal,
                        onDelete: {
                            NewspaperStore(modelContext: modelContext).remove(article)
                        }
                    )
                } else {
                    ContentUnavailableView(
                        "Article Unavailable",
                        systemImage: "newspaper"
                    )
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 900, idealWidth: 1120, minHeight: 650, idealHeight: 780)
        #endif
        .onChange(of: storedArticles.map(\.section)) { _, _ in
            if !sections.contains(selectedSection) {
                selectedSection = Self.allSections
            }
        }
        .onChange(of: sortedArticles.count) { _, count in
            pageIndex = min(max(pageIndex, 0), max(count - 1, 0))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Newspaper")
    }

    private var masthead: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("THE DAILY READ")
                        .font(NewspaperTypography.font(fontFamily, size: 11, weight: .bold))
                        .tracking(2.4)
                    Text("Newspaper")
                        .font(NewspaperTypography.font(fontFamily, size: 34, weight: .black))
                        .accessibilityAddTraits(.isHeader)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Date.now.formatted(date: .complete, time: .omitted))
                        .font(.caption.weight(.semibold))
                    Text(issueSummary)
                        .font(.caption2)
                        .foregroundStyle(layout == .ink ? Color.black.opacity(0.65) : .secondary)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(layout == .ink ? Color.black.opacity(0.7) : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Newspaper")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { issueControls }
                VStack(alignment: .leading, spacing: 10) { issueControls }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var issueControls: some View {
        Picker("Layout", selection: $layoutRaw) {
            ForEach(NewspaperLayout.allCases) { layout in
                Label(layout.title, systemImage: layout.systemImage).tag(layout.rawValue)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Newspaper layout")

        Picker("Reading", selection: $navigationStyleRaw) {
            ForEach(NewspaperNavigationStyle.allCases) { style in
                Text(style.title).tag(style.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 230)

        Toggle(isOn: $unreadOnly) {
            Label("Unread", systemImage: "circle")
        }
        .toggleStyle(.button)

        Toggle(isOn: $showDismissed) {
            Label("Dismissed", systemImage: "archivebox")
        }
        .toggleStyle(.button)
    }

    private var sectionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sections, id: \.self) { section in
                    Button {
                        selectedSection = section
                        pageIndex = 0
                    } label: {
                        Text(section.uppercased())
                            .font(.caption2.weight(.bold))
                            .tracking(0.7)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                selectedSection == section
                                    ? sectionSelectionColor
                                    : Color.clear,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().strokeBorder(
                                    layout == .ink
                                        ? Color.black.opacity(0.5)
                                        : Color.secondary.opacity(0.3)
                                )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private var continuousIssue: some View {
        ScrollView {
            switch layout {
            case .ink:
                NewspaperInkIssue(articles: sortedArticles, actions: actions)
            case .broadsheet:
                NewspaperBroadsheetIssue(articles: sortedArticles, actions: actions)
            case .magazine:
                NewspaperMagazineIssue(articles: sortedArticles, actions: actions)
            case .shelf:
                NewspaperShelfIssue(articles: sortedArticles, actions: actions)
            }
        }
        .scrollIndicators(.visible)
    }

    private var actions: NewspaperArticleActions {
        NewspaperArticleActions(
            markRead: { article, value in
                NewspaperStore(modelContext: modelContext).markRead(article, isRead: value)
            },
            setPriority: { article, priority in
                NewspaperStore(modelContext: modelContext).setPriority(priority, for: article)
            },
            remove: { article in
                NewspaperStore(modelContext: modelContext).remove(article)
            }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your newspaper is waiting", systemImage: "newspaper")
        } description: {
            Text("On any article, choose Add to Newspaper. Its readable text is saved for offline reading and syncs with your private browser data.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView(
            "No matching articles",
            systemImage: unreadOnly ? "checkmark.circle" : "line.3.horizontal.decrease.circle",
            description: Text("Try another section or include finished articles.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var issueSummary: String {
        let unread = storedArticles.filter { !$0.isRead }.count
        return String(localized: "\(unread) unread · \(storedArticles.count) saved")
    }

    private var issueBackground: Color {
        layout == .ink ? Color(red: 0.96, green: 0.945, blue: 0.90) : .newspaperBackground
    }

    private var sectionSelectionColor: Color {
        layout == .ink ? Color.black.opacity(0.14) : Color.accentColor.opacity(0.16)
    }
}

private struct NewspaperArticleActions {
    let markRead: (NewspaperArticle, Bool) -> Void
    let setPriority: (NewspaperArticle, NewspaperPriority) -> Void
    let remove: (NewspaperArticle) -> Void
}

private struct NewspaperInkIssue: View {
    let articles: [NewspaperArticle]
    let actions: NewspaperArticleActions

    private var grouped: [(String, [NewspaperArticle])] {
        NewspaperPresentation.grouped(articles)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(grouped, id: \.0) { section, stories in
                VStack(alignment: .leading, spacing: 0) {
                    NewspaperSectionRule(title: section, monochrome: true)
                    ForEach(Array(stories.enumerated()), id: \.element.id) { index, article in
                        NewspaperStoryLink(
                            article: article,
                            layout: .ink,
                            prominence: index == 0 ? .lead : .standard,
                            actions: actions
                        )
                        if article.id != stories.last?.id {
                            Divider().overlay(Color.black.opacity(0.55))
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity)
    }
}

private struct NewspaperBroadsheetIssue: View {
    let articles: [NewspaperArticle]
    let actions: NewspaperArticleActions

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(NewspaperPresentation.grouped(articles), id: \.0) { section, stories in
                VStack(alignment: .leading, spacing: 14) {
                    NewspaperSectionRule(title: section, monochrome: false)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 18)],
                        alignment: .leading,
                        spacing: 18
                    ) {
                        ForEach(Array(stories.enumerated()), id: \.element.id) { index, article in
                            NewspaperStoryLink(
                                article: article,
                                layout: .broadsheet,
                                prominence: index == 0 ? .lead : .standard,
                                actions: actions
                            )
                        }
                    }
                }
            }
        }
        .padding(24)
    }
}

private struct NewspaperMagazineIssue: View {
    let articles: [NewspaperArticle]
    let actions: NewspaperArticleActions

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 275, maximum: 520), spacing: 20)],
            alignment: .leading,
            spacing: 20
        ) {
            ForEach(Array(articles.enumerated()), id: \.element.id) { index, article in
                NewspaperStoryLink(
                    article: article,
                    layout: .magazine,
                    prominence: index == 0 ? .lead : .standard,
                    actions: actions
                )
            }
        }
        .padding(24)
    }
}

private struct NewspaperShelfIssue: View {
    let articles: [NewspaperArticle]
    let actions: NewspaperArticleActions

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(NewspaperPresentation.grouped(articles), id: \.0) { section, stories in
                VStack(alignment: .leading, spacing: 12) {
                    NewspaperSectionRule(title: section, monochrome: false)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 18) {
                            ForEach(stories) { article in
                                NewspaperStoryLink(
                                    article: article,
                                    layout: .shelf,
                                    prominence: .standard,
                                    actions: actions
                                )
                                .frame(width: 270)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 6)
                    }
                }
            }
        }
        .padding(24)
    }
}

private struct NewspaperPagedIssue: View {
    let articles: [NewspaperArticle]
    let layout: NewspaperLayout
    @Binding var pageIndex: Int
    let actions: NewspaperArticleActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    private var clampedPageIndex: Int? {
        guard !articles.isEmpty else { return nil }
        return min(max(pageIndex, articles.startIndex), articles.index(before: articles.endIndex))
    }

    private var selection: (index: Int, article: NewspaperArticle)? {
        guard let index = clampedPageIndex else { return nil }
        return (index, articles[index])
    }

    var body: some View {
        Group {
            if let selection {
                page(article: selection.article, index: selection.index)
            } else {
                ContentUnavailableView(
                    "No pages",
                    systemImage: "newspaper",
                    description: Text("Add an article or change the current filters.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: clampPageIndex)
        .onChange(of: articles.map(\.id)) { _, _ in clampPageIndex() }
        .onChange(of: pageIndex) { _, _ in clampPageIndex() }
    }

    private func page(article: NewspaperArticle, index: Int) -> some View {
        VStack(spacing: 12) {
            HStack {
                Button { move(-1) } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .disabled(index == articles.startIndex)

                Spacer()
                Text("Page \(index + 1) of \(articles.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()

                Button { move(1) } label: {
                    Label("Next", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(index == articles.index(before: articles.endIndex))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            NewspaperStoryLink(
                article: article,
                layout: layout,
                prominence: .page,
                actions: actions
            )
            .id(article.id)
            .frame(maxWidth: 760, maxHeight: .infinity)
            .padding(24)
            .offset(x: dragOffset)
            .rotation3DEffect(
                reduceMotion ? .zero : .degrees(Double(dragOffset / 35)),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.35
            )
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { dragOffset = $0.translation.width }
                    .onEnded { value in
                        let direction = value.predictedEndTranslation.width < -80 ? 1
                            : value.predictedEndTranslation.width > 80 ? -1 : 0
                        move(direction)
                        withAnimation(.snappy(duration: 0.25)) { dragOffset = 0 }
                    }
            )
        }
    }

    private func move(_ direction: Int) {
        guard direction != 0, let current = clampedPageIndex else {
            clampPageIndex()
            return
        }
        let next = min(
            max(current + direction, articles.startIndex),
            articles.index(before: articles.endIndex)
        )
        guard next != current else {
            clampPageIndex()
            return
        }
        if reduceMotion {
            pageIndex = next
        } else {
            withAnimation(.snappy(duration: 0.28)) { pageIndex = next }
        }
    }

    private func clampPageIndex() {
        let clamped = clampedPageIndex ?? 0
        guard pageIndex != clamped else { return }
        pageIndex = clamped
    }
}

private enum NewspaperStoryProminence {
    case standard
    case lead
    case page
}

private struct NewspaperStoryLink: View {
    let article: NewspaperArticle
    let layout: NewspaperLayout
    let prominence: NewspaperStoryProminence
    let actions: NewspaperArticleActions

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workspace.orderIndex) private var workspaces: [Workspace]

    var body: some View {
        NavigationLink(value: article.id) {
            NewspaperStoryCard(article: article, layout: layout, prominence: prominence)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(article.isRead ? "Mark Unread" : "Mark Finished") {
                actions.markRead(article, !article.isRead)
            }
            Menu("Priority") {
                ForEach(NewspaperPriority.allCases) { priority in
                    Button {
                        actions.setPriority(article, priority)
                    } label: {
                        Label(priority.title, systemImage: priority.systemImage)
                    }
                }
            }
            // "Items movable afterward" (Phase 3, design §5): re-points the
            // most recent workspace reference; the Section never re-files.
            if !workspaces.isEmpty {
                Menu("Move to Workspace") {
                    ForEach(workspaces.filter { !$0.isArchived }) { workspace in
                        Button {
                            moveToWorkspace(workspace)
                        } label: {
                            if referencedWorkspaceIds.contains(workspace.id) {
                                Label(workspace.name, systemImage: "checkmark")
                            } else {
                                Text(workspace.name)
                            }
                        }
                    }
                }
            }
            // `dismissed`'s restore path: reverse a rejection per workspace,
            // the same verdict-reversal deliberately reopening the source makes.
            if !dismissedWorkspaces.isEmpty {
                Menu("Restore to Working Set") {
                    ForEach(dismissedWorkspaces, id: \.0) { entry in
                        Button(entry.1) {
                            LedgerStore(modelContext: modelContext)
                                .restoreDismissed(sourceKey: article.sourceKey, workspaceId: entry.0)
                        }
                    }
                }
            }
            Divider()
            Button("Remove from Newspaper", role: .destructive) {
                actions.remove(article)
            }
        }
        .accessibilityHint("Open the saved article")
    }

    private var referencedWorkspaceIds: Set<UUID> {
        Set(LedgerStore(modelContext: modelContext)
            .references(sourceKey: article.sourceKey).map(\.workspaceId))
    }

    /// Workspaces where this source is currently rejected, named for the menu.
    private var dismissedWorkspaces: [(UUID, String)] {
        LedgerStore(modelContext: modelContext)
            .references(sourceKey: article.sourceKey)
            .filter { $0.disposition == .dismissed }
            .compactMap { ref in
                workspaces.first { $0.id == ref.workspaceId }.map { (ref.workspaceId, $0.name) }
            }
    }

    private func moveToWorkspace(_ workspace: Workspace) {
        let ledger = LedgerStore(modelContext: modelContext)
        let refs = ledger.references(sourceKey: article.sourceKey)
        if let ref = refs.max(by: { $0.updatedAt < $1.updatedAt }) {
            ledger.moveReference(ref, to: workspace.id)
        } else {
            // Not in any workspace yet: moving IS adding.
            ledger.recordManualCapture(url: article.url, title: article.title, workspaceId: workspace.id)
        }
    }
}

private struct NewspaperStoryCard: View {
    let article: NewspaperArticle
    let layout: NewspaperLayout
    let prominence: NewspaperStoryProminence

    @AppStorage(NewspaperPreferences.Key.photoLimit)
    private var photoLimit = NewspaperPreferences.defaultPhotoLimit
    @AppStorage(NewspaperPreferences.Key.fontFamily) private var fontFamily = ""

    private var showsImage: Bool {
        layout.usesImages && photoLimit > 0 && article.leadImage != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: prominence == .lead ? 13 : 9) {
            if showsImage, let image = article.leadImage {
                NewspaperRemoteImage(image: image)
                    .frame(height: prominence == .page ? 280 : prominence == .lead ? 220 : 150)
                    .clipShape(RoundedRectangle(cornerRadius: layout == .magazine ? 16 : 8))
            }

            HStack(spacing: 7) {
                Text(article.section.uppercased())
                    .font(.caption2.weight(.black))
                    .tracking(0.8)
                if article.priority == .next {
                    Image(systemName: "arrow.up.to.line")
                        .accessibilityLabel("Read next")
                }
                Spacer()
                if article.isRead {
                    Label("Finished", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }

            Text(article.title)
                .font(titleFont)
                .fontWeight(prominence == .standard ? .bold : .black)
                .lineLimit(prominence == .page ? 4 : 3)
                .fixedSize(horizontal: false, vertical: true)

            if let byline = article.byline, !byline.isEmpty {
                Text(byline)
                    .font(.caption)
                    .foregroundStyle(layout == .ink ? Color.black.opacity(0.65) : .secondary)
                    .lineLimit(1)
            }

            if article.captureState == .capturing {
                Label("Saving readable text…", systemImage: "arrow.down.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if article.captureState == .failed {
                Label("Text needs another try", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(NewspaperPresentation.excerpt(article.cardExcerpt, words: excerptLength))
                    .font(bodyFont)
                    .lineSpacing(3)
                    .lineLimit(prominence == .page ? 14 : prominence == .lead ? 7 : 5)
                    .foregroundStyle(layout == .ink ? Color.black.opacity(0.82) : .secondary)
            }

            HStack(spacing: 8) {
                Text("\(article.estimatedReadingMinutes) min")
                if article.hasCurrentCondensedRendition {
                    Text("Condensed")
                }
                if article.rating > 0 {
                    Label("\(article.rating)", systemImage: "star.fill")
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(
                layout == .ink
                    ? Color.black.opacity(0.62)
                    : Color.secondary.opacity(0.62)
            )
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, maxHeight: prominence == .page ? .infinity : nil, alignment: .topLeading)
        .background(cardBackground)
        .overlay {
            if layout == .ink || layout == .broadsheet {
                Rectangle()
                    .strokeBorder(
                        layout == .ink ? Color.black.opacity(0.58) : Color.secondary.opacity(0.22),
                        lineWidth: layout == .ink ? 1 : 0.5
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius))
        .opacity(article.isRead ? 0.72 : 1)
    }

    private var titleFont: Font {
        switch prominence {
        case .page: NewspaperTypography.font(fontFamily, size: 38)
        case .lead: NewspaperTypography.font(fontFamily, size: 27)
        case .standard: NewspaperTypography.font(fontFamily, size: 20)
        }
    }

    private var bodyFont: Font {
        prominence == .page
            ? NewspaperTypography.font(fontFamily, size: 19)
            : NewspaperTypography.font(fontFamily, size: 15)
    }

    private var excerptLength: Int {
        switch prominence {
        case .page: 260
        case .lead: 130
        case .standard: 80
        }
    }

    private var cardPadding: CGFloat {
        switch prominence {
        case .page: 30
        case .lead: 20
        case .standard: 16
        }
    }

    private var cardCornerRadius: CGFloat {
        layout == .magazine || layout == .shelf ? 18 : 0
    }

    @ViewBuilder
    private var cardBackground: some View {
        if layout == .ink {
            Color.clear
        } else if layout == .magazine || layout == .shelf {
            RoundedRectangle(cornerRadius: cardCornerRadius)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
        } else {
            Color.primary.opacity(0.025)
        }
    }
}

private struct NewspaperSectionRule: View {
    let title: String
    let monochrome: Bool

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().frame(height: 2)
            Text(title.uppercased())
                .font(.caption.weight(.black))
                .tracking(1.2)
                .fixedSize()
            Rectangle().frame(height: 2)
        }
        .foregroundStyle(monochrome ? Color.black : Color.primary)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct NewspaperArticleView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let article: NewspaperArticle
    let layout: NewspaperLayout
    let onOpenOriginal: (URL) -> Void
    let onDelete: () -> Void

    @AppStorage(SettingsManager.aiFeaturesKey) private var aiFeaturesEnabled = true

    @AppStorage(NewspaperPreferences.Key.photoLimit)
    private var photoLimit = NewspaperPreferences.defaultPhotoLimit
    @AppStorage(NewspaperPreferences.Key.targetWordCount)
    private var targetWordCount = NewspaperPreferences.defaultTargetWordCount
    @AppStorage(NewspaperPreferences.Key.targetCharacterCount)
    private var targetCharacterCount = NewspaperPreferences.defaultTargetCharacterCount
    @AppStorage(NewspaperPreferences.Key.lengthUnit)
    private var lengthUnitRaw = NewspaperLengthUnit.words.rawValue
    @AppStorage(NewspaperPreferences.Key.fontFamily) private var fontFamily = ""

    @State private var showsOriginal = false
    @State private var showsAllPhotos = false
    @State private var confirmRemoval = false

    private var displayedText: String {
        if showsOriginal || article.condensedText == nil { return article.originalText }
        return article.condensedText ?? article.originalText
    }

    private var visibleImages: [ReaderImage] {
        guard layout.usesImages else { return [] }
        let images = article.images
        return showsAllPhotos ? images : Array(images.prefix(max(photoLimit, 0)))
    }

    private var preferredTarget: NewspaperLengthTarget {
        let unit = NewspaperLengthUnit(rawValue: lengthUnitRaw) ?? .words
        return NewspaperLengthTarget(
            unit: unit,
            maximum: unit == .words ? targetWordCount : targetCharacterCount
        )
    }

    private var sourceLengthForPreference: Int {
        preferredTarget.unit == .words
            ? article.sourceWordCount
            : article.sourceCharacterCount
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                articleHeader
                articleActions
                Divider()
                if layout.usesImages {
                    imageGallery
                }
                captureStatus
                readingModeControl
                articleText
                originalSourceFooter
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(
            (layout == .ink
                ? Color(red: 0.96, green: 0.945, blue: 0.90)
                : Color.newspaperBackground
            ).ignoresSafeArea()
        )
        .foregroundStyle(layout == .ink ? Color.black : Color.primary)
        .navigationTitle(article.section)
        .confirmationDialog(
            "Remove this article from your newspaper?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Article", role: .destructive) {
                dismiss()
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            article.lastReadAt = Date()
            if article.readingProgress == 0 { article.readingProgress = 0.05 }
            try? modelContext.save()
        }
    }

    private var articleHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(article.section.uppercased())
                if let publication = article.publication, !publication.isEmpty {
                    Text("·")
                    Text(publication.uppercased())
                }
            }
            .font(.caption.weight(.black))
            .tracking(1)

            Text(article.title)
                .font(NewspaperTypography.font(fontFamily, size: 42, weight: .black))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 7) {
                if let byline = article.byline, !byline.isEmpty { Text(byline) }
                if let date = article.publishedAt {
                    Text("·")
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                }
                Text("·")
                Text("\(article.estimatedReadingMinutes) min read")
            }
            .font(.subheadline)
            .foregroundStyle(layout == .ink ? Color.black.opacity(0.65) : .secondary)
        }
    }

    private var articleActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    NewspaperStore(modelContext: modelContext).markRead(
                        article,
                        isRead: !article.isRead
                    )
                } label: {
                    Label(
                        article.isRead ? "Mark Unread" : "Mark Finished",
                        systemImage: article.isRead ? "circle" : "checkmark.circle"
                    )
                }

                Menu {
                    ForEach(NewspaperPriority.allCases) { priority in
                        Button {
                            NewspaperStore(modelContext: modelContext)
                                .setPriority(priority, for: article)
                        } label: {
                            Label(priority.title, systemImage: priority.systemImage)
                        }
                    }
                } label: {
                    Label(article.priority.title, systemImage: article.priority.systemImage)
                }

                Menu {
                    ForEach(NewspaperPresentation.commonSections, id: \.self) { section in
                        Button(section) {
                            NewspaperStore(modelContext: modelContext)
                                .setSection(section, for: article)
                        }
                    }
                } label: {
                    Label("Move Section", systemImage: "rectangle.3.group")
                }

                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { rating in
                        Button {
                            NewspaperStore(modelContext: modelContext)
                                .setRating(article.rating == rating ? 0 : rating, for: article)
                        } label: {
                            Image(systemName: rating <= article.rating ? "star.fill" : "star")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rate \(rating) out of 5")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())

                Button {
                    onOpenOriginal(article.url)
                } label: {
                    Label("Open Web Page", systemImage: "safari")
                }

                Button(role: .destructive) { confirmRemoval = true } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var imageGallery: some View {
        if layout.usesImages {
            if !visibleImages.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(visibleImages, id: \.url.absoluteString) { image in
                        NewspaperRemoteImage(image: image)
                            .frame(height: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            if article.availableImageCount > visibleImages.count {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                        showsAllPhotos = true
                    }
                } label: {
                    Label(
                        "Show \(article.availableImageCount - visibleImages.count) more photos",
                        systemImage: "photo.stack"
                    )
                }
                .buttonStyle(.bordered)
            } else if showsAllPhotos, article.imageURLs.count > max(photoLimit, 0) {
                Button("Show fewer photos") { showsAllPhotos = false }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var captureStatus: some View {
        switch article.captureState {
        case .capturing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Saving the readable text for offline use…")
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed:
            Label(
                article.captureError ?? "Readable text could not be captured. The source link is still saved.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .deferred:
            // Recorded in the research ledger but never extracted — the source
            // and its link are real, the readable text just isn't here yet.
            Label(
                "This source is saved. Its readable text hasn't been captured yet.",
                systemImage: "text.badge.plus"
            )
            .foregroundStyle(.secondary)
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .ready:
            if article.originalPayloadData == nil {
                Label(
                    "Saved text is still arriving on this device. The source and reading state are already available.",
                    systemImage: "icloud.and.arrow.down"
                )
                .foregroundStyle(.secondary)
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if article.document == nil {
                Label(
                    "This saved-text version cannot be opened. The original web page is still available.",
                    systemImage: "doc.badge.exclamationmark"
                )
                .foregroundStyle(.orange)
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var readingModeControl: some View {
        if article.condensedText != nil {
            Picker("Article version", selection: $showsOriginal) {
                Text("Condensed · \(condensedLengthLabel)").tag(false)
                Text("Original · \(article.sourceWordCount) words").tag(true)
            }
            .pickerStyle(.segmented)
        } else if article.condensationState == .condensing {
            HStack(spacing: 10) {
                ProgressView()
                Text("Preserving the voice while shortening to \(article.targetLength) \(article.targetUnit.rawValue)…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if aiFeaturesEnabled,
                  article.captureState == .ready,
                  article.originalPayloadData != nil,
                  sourceLengthForPreference > preferredTarget.maximum {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task {
                        await NewspaperStore(modelContext: modelContext)
                            .condense(article, target: preferredTarget)
                    }
                } label: {
                    Label("Shorten to \(preferredTarget.label)", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)

                if let error = article.condensationError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var condensedLengthLabel: String {
        if article.targetUnit == .characters {
            return String(localized: "\(article.condensedCharacterCount) characters")
        }
        return String(localized: "\(article.condensedWordCount) words")
    }

    @ViewBuilder
    private var articleText: some View {
        if showsOriginal || article.condensedText == nil,
           let document = article.document {
            ForEach(document.blocks) { block in
                NewspaperDocumentBlockView(block: block.content)
            }
        } else if !displayedText.isEmpty {
            ForEach(Array(NewspaperPresentation.paragraphs(displayedText).enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(NewspaperTypography.font(fontFamily, size: 19))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if article.captureState == .ready {
            ContentUnavailableView(
                "Saved text unavailable",
                systemImage: "doc.badge.clock",
                description: Text("Try again after iCloud finishes syncing, or open the original web page.")
            )
        }
    }

    private var originalSourceFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Saved from \(article.url.host ?? article.url.absoluteString)")
                .font(.caption.weight(.semibold))
            Text(article.url.absoluteString)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("The original readable text stays available even when a condensed version is shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 16)
    }
}

private struct NewspaperRemoteImage: View {
    let image: ReaderImage

    var body: some View {
        AsyncImage(url: image.url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                imagePlaceholder(systemImage: "photo.badge.exclamationmark")
            case .empty:
                ZStack {
                    imagePlaceholder(systemImage: "photo")
                    ProgressView()
                }
            @unknown default:
                imagePlaceholder(systemImage: "photo")
            }
        }
        .clipped()
        .accessibilityLabel(image.altText ?? String(localized: "Article photo"))
    }

    private func imagePlaceholder(systemImage: String) -> some View {
        ZStack {
            Color.secondary.opacity(0.10)
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NewspaperDocumentBlockView: View {
    let block: ReaderBlock
    @AppStorage(NewspaperPreferences.Key.fontFamily) private var fontFamily = ""

    @ViewBuilder
    var body: some View {
        switch block {
        case .heading(let level, let runs):
            Text(attributedText(runs))
                .font(headingFont(level))
                .fontWeight(.bold)
                .accessibilityHeading(headingLevel(level))
                .padding(.top, level <= 2 ? 14 : 8)
        case .paragraph(let runs):
            Text(attributedText(runs))
                .font(NewspaperTypography.font(fontFamily, size: 19))
                .lineSpacing(6)
        case .listItem(let ordered, let ordinal, let depth, let runs):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ordered ? "\(ordinal ?? 1)." : "•")
                    .fontWeight(.bold)
                    .frame(width: 30, alignment: .trailing)
                    .accessibilityHidden(true)
                Text(attributedText(runs))
                    .font(NewspaperTypography.font(fontFamily, size: 19))
            }
            .padding(.leading, CGFloat(depth) * 22)
            .accessibilityElement(children: .combine)
        case .quote(let runs):
            HStack(spacing: 14) {
                Rectangle()
                    .frame(width: 3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(attributedText(runs))
                    .font(NewspaperTypography.font(fontFamily, size: 20))
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 15, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .caption(let runs):
            Text(attributedText(runs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func attributedText(_ runs: [ReaderInline]) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var fragment = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.isStrong { intent.insert(.stronglyEmphasized) }
            if run.isEmphasized { intent.insert(.emphasized) }
            if run.isCode { intent.insert(.code) }
            if !intent.isEmpty { fragment.inlinePresentationIntent = intent }
            fragment.link = run.link
            result.append(fragment)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle
        case 2: .title
        case 3: .title2
        case 4: .title3
        case 5: .headline
        default: .subheadline
        }
    }

    private func headingLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}

private enum NewspaperPresentation {
    static let commonSections = [
        String(localized: "Front Page"),
        String(localized: "World"),
        String(localized: "Ideas"),
        String(localized: "Technology"),
        String(localized: "Science"),
        String(localized: "Business"),
        String(localized: "Culture"),
        String(localized: "Life")
    ]

    static func grouped(_ articles: [NewspaperArticle]) -> [(String, [NewspaperArticle])] {
        let groups = Dictionary(grouping: articles) {
            $0.section.isEmpty ? String(localized: "Front Page") : $0.section
        }
        return groups.keys.sorted { left, right in
            if left == String(localized: "Front Page") { return true }
            if right == String(localized: "Front Page") { return false }
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }.map { ($0, groups[$0] ?? []) }
    }

    static func excerpt(_ text: String, words: Int) -> String {
        let pieces = text.split(whereSeparator: \.isWhitespace)
        guard pieces.count > words else { return text }
        return pieces.prefix(words).joined(separator: " ") + "…"
    }

    static func paragraphs(_ text: String) -> [String] {
        let blocks = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return blocks.isEmpty && !text.isEmpty ? [text] : blocks
    }
}

private extension Color {
    static var newspaperBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

// MARK: - Settings

/// Section header with the Newspaper tint on the icon only (same idiom as
/// SettingsLabel, which is macOS-only; this view is shared with iOS).
private struct NewspaperSettingsHeader: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.brown)
        }
    }
}

private struct NewspaperTintedLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = .brown

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}

/// A postage-stamp sketch of each layout, drawn with shapes so it needs no
/// articles to look right.
struct NewspaperLayoutPreview: View {
    let layout: NewspaperLayout

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(paper)
            Group {
                switch layout {
                case .ink: ink
                case .broadsheet: broadsheet
                case .magazine: magazine
                case .shelf: shelf
                }
            }
            .padding(8)
        }
        .frame(width: 128, height: 88)
        .accessibilityHidden(true)
    }

    private var paper: Color {
        layout == .ink ? Color(red: 0.96, green: 0.945, blue: 0.90) : Color.primary.opacity(0.04)
    }
    private var inkColor: Color { layout == .ink ? .black : .primary }

    private func line(_ width: CGFloat, height: CGFloat = 2, opacity: Double = 0.35) -> some View {
        Capsule().fill(inkColor.opacity(opacity)).frame(width: width, height: height)
    }
    private func lines(_ count: Int, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            ForEach(0..<count, id: \.self) { i in line(i == count - 1 ? width * 0.6 : width) }
        }
    }
    private var photo: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(LinearGradient(colors: [.brown.opacity(0.55), .orange.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var ink: some View {
        VStack(alignment: .leading, spacing: 4) {
            line(60, height: 4, opacity: 0.85)
            Rectangle().fill(inkColor.opacity(0.7)).frame(height: 1)
            HStack(alignment: .top, spacing: 6) {
                lines(6, width: 50)
                lines(6, width: 50)
            }
        }
    }

    private var broadsheet: some View {
        VStack(alignment: .leading, spacing: 4) {
            line(70, height: 4, opacity: 0.8)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 2) {
                        line(22, height: 3, opacity: 0.7)
                        lines(4, width: 32)
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 2).stroke(inkColor.opacity(0.25), lineWidth: 0.5))
                }
            }
        }
    }

    private var magazine: some View {
        HStack(spacing: 5) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 3) {
                    photo.frame(height: 30)
                    line(30, height: 3, opacity: 0.7)
                    lines(3, width: 44)
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(.regularMaterial))
            }
        }
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 4) {
            line(44, height: 3, opacity: 0.7)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        photo.frame(height: 26)
                        line(24, height: 2.5, opacity: 0.7)
                        lines(2, width: 28)
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
                    .offset(x: i == 2 ? 6 : 0)
                }
            }
            .clipped()
        }
    }
}

struct NewspaperSettingsView: View {
    @AppStorage(NewspaperPreferences.Key.layout)
    private var layout = NewspaperPreferences.defaultLayout
    @AppStorage(NewspaperPreferences.Key.navigationStyle)
    private var navigationStyle = NewspaperPreferences.defaultNavigationStyle
    @AppStorage(NewspaperPreferences.Key.photoLimit)
    private var photoLimit = NewspaperPreferences.defaultPhotoLimit
    @AppStorage(NewspaperPreferences.Key.fontFamily)
    private var fontFamily = ""
    @AppStorage(NewspaperPreferences.Key.condenseArticles)
    private var condenseArticles = false
    @AppStorage(NewspaperPreferences.Key.lengthUnit)
    private var lengthUnit = NewspaperLengthUnit.words.rawValue
    @AppStorage(NewspaperPreferences.Key.targetWordCount)
    private var targetWordCount = NewspaperPreferences.defaultTargetWordCount
    @AppStorage(NewspaperPreferences.Key.targetCharacterCount)
    private var targetCharacterCount = NewspaperPreferences.defaultTargetCharacterCount
    @AppStorage(NewspaperPreferences.Key.defaultSection)
    private var defaultSection = ""

    var body: some View {
        Form {
            CollapsibleSection {
                layoutGallery
                Picker(selection: $navigationStyle) {
                    ForEach(NewspaperNavigationStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                } label: {
                    NewspaperTintedLabel(title: "Move through an issue", systemImage: "book.pages")
                }
                Picker(selection: $photoLimit) {
                    Text("None").tag(0)
                    ForEach([1, 3, 5, 10], id: \.self) { count in
                        Text("Up to \(count)").tag(count)
                    }
                } label: {
                    NewspaperTintedLabel(title: "Photos per article", systemImage: "photo.on.rectangle", tint: .orange)
                }
            } header: {
                NewspaperSettingsHeader(title: "Layout", systemImage: "rectangle.3.group")
            } footer: {
                Text("Ink and Broadsheet stay image-free. Magazine and Shelf honor the photo limit; every article can reveal the rest on demand.")
            }

            CollapsibleSection {
                Picker(selection: $fontFamily) {
                    ForEach(NewspaperTypography.suggested) { choice in
                        Text(choice.title).font(NewspaperTypography.font(choice.family, size: 13)).tag(choice.family)
                    }
                    Divider()
                    ForEach(NewspaperTypography.installedFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                } label: {
                    NewspaperTintedLabel(title: "Font", systemImage: "textformat", tint: .indigo)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("The Quick Brown Fox Jumps Over the Lazy Dog")
                        .font(NewspaperTypography.font(fontFamily, size: 22, weight: .black))
                    Text("Every headline, excerpt, and article page in the Newspaper uses this face. Pick any installed family; the system serif is New York.")
                        .font(NewspaperTypography.font(fontFamily, size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                NewspaperSettingsHeader(title: "Typography", systemImage: "character.textbox")
            }

            CollapsibleSection {
                Toggle(isOn: $condenseArticles) {
                    NewspaperTintedLabel(title: "Shorten long articles on device", systemImage: "sparkles", tint: .purple)
                }
                if condenseArticles {
                    Picker("Limit by", selection: $lengthUnit) {
                        ForEach(NewspaperLengthUnit.allCases) { unit in
                            Text(unit.title).tag(unit.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    if lengthUnit == NewspaperLengthUnit.words.rawValue {
                        Stepper(
                            "Maximum: \(targetWordCount) words",
                            value: $targetWordCount,
                            in: NewspaperPreferences.minimumTargetWordCount...NewspaperPreferences.maximumTargetWordCount,
                            step: 100
                        )
                    } else {
                        Stepper(
                            "Maximum: \(targetCharacterCount) characters",
                            value: $targetCharacterCount,
                            in: NewspaperPreferences.minimumTargetCharacterCount...NewspaperPreferences.maximumTargetCharacterCount,
                            step: 500
                        )
                    }
                }
            } header: {
                NewspaperSettingsHeader(title: "Article Length", systemImage: "text.word.spacing")
            } footer: {
                Text("The original is always kept. Shortening uses Apple Intelligence on device when available, preserves the article's voice, and never gives the article tools or authority. You can switch back to the saved full text at any time.")
            }

            CollapsibleSection {
                HStack {
                    NewspaperTintedLabel(title: "Default section", systemImage: "folder", tint: .teal)
                    TextField("Front Page", text: $defaultSection)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                NewspaperSettingsHeader(title: "Filing", systemImage: "tray.full")
            } footer: {
                Text("A publisher's section takes precedence when the page provides one. You can move any saved article later.")
            }

            NewspaperLibrarySection()

            CollapsibleSection {
                NewspaperTintedLabel(title: "Readable text is retained for offline use", systemImage: "arrow.down.doc", tint: .green)
                NewspaperTintedLabel(title: "Remote photos are loaded only when shown", systemImage: "photo", tint: .orange)
                NewspaperTintedLabel(title: "Newspaper follows the main browser-data sync switch", systemImage: "icloud", tint: .blue)
                NewspaperTintedLabel(title: "A starter article arrives each day you read nothing new", systemImage: "calendar.badge.plus", tint: .pink)
            } header: {
                NewspaperSettingsHeader(title: "Offline & Sync", systemImage: "externaldrive.badge.icloud")
            } footer: {
                Text("Saved article documents and reading state use your private iCloud database when browser sync is enabled. Incognito pages cannot be added. Changing the main sync switch still takes effect after relaunch.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Newspaper")
    }

    private var layoutGallery: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(NewspaperLayout.allCases) { option in
                    let selected = option.rawValue == layout
                    Button {
                        layout = option.rawValue
                    } label: {
                        VStack(spacing: 6) {
                            NewspaperLayoutPreview(layout: option)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2.5 : 1)
                                )
                            Label(option.title, systemImage: option.systemImage)
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.accentColor : .primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Every article ever added or picked for the newspaper — including finished
/// ones and sources dismissed from the feed — searchable and removable.
private struct NewspaperLibrarySection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NewspaperArticle.addedAt, order: .reverse)
    private var articles: [NewspaperArticle]
    @State private var query = ""
    @State private var showAll = false

    private static let collapsedLimit = 8

    private var filtered: [NewspaperArticle] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return articles }
        return articles.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.section.localizedCaseInsensitiveContains(needle)
                || ($0.url.host ?? "").localizedCaseInsensitiveContains(needle)
                || ($0.byline ?? "").localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        let hidden = LedgerStore(modelContext: modelContext).hiddenFromFeedKeys()
        let visible = showAll || !query.isEmpty ? filtered : Array(filtered.prefix(Self.collapsedLimit))
        CollapsibleSection {
            if articles.isEmpty {
                Text("Nothing saved yet. Use Add to Newspaper on any article.")
                    .foregroundStyle(.secondary)
            } else {
                TextField("Search title, section, site, or byline", text: $query)
                    .textFieldStyle(.roundedBorder)
                ForEach(visible) { article in
                    row(article, dismissed: hidden.contains(article.sourceKey))
                }
                if visible.count < filtered.count {
                    Button("Show all \(filtered.count) articles") { showAll = true }
                }
            }
        } header: {
            HStack {
                NewspaperSettingsHeader(title: "Library", systemImage: "books.vertical")
                Text("\(articles.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.brown.opacity(0.18), in: Capsule())
            }
        } footer: {
            Text("\(articles.filter { !$0.isRead }.count) unread. Dismissed sources stay here so you can restore them from the Newspaper.")
        }
    }

    private func row(_ article: NewspaperArticle, dismissed: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol(article))
                .foregroundStyle(statusTint(article))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text(article.section.uppercased()).fontWeight(.semibold)
                    Text("·")
                    Text(article.url.host ?? article.url.absoluteString)
                    Text("·")
                    Text(article.addedAt.formatted(date: .abbreviated, time: .omitted))
                    if dismissed { Text("· Dismissed") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if article.rating > 0 {
                Label("\(article.rating)", systemImage: "star.fill")
                    .font(.caption).foregroundStyle(.yellow)
            }
            Text("\(article.estimatedReadingMinutes) min")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(article.isRead ? "Mark Unread" : "Mark Finished") {
                NewspaperStore(modelContext: modelContext).markRead(article, isRead: !article.isRead)
            }
            Button("Open Web Page") {
                NotificationCenter.default.post(
                    name: .browserOpenURL, object: nil,
                    userInfo: ["url": article.url.absoluteString, "newTab": true]
                )
            }
            Divider()
            Button("Remove from Newspaper", role: .destructive) {
                NewspaperStore(modelContext: modelContext).remove(article)
            }
        }
    }

    private func statusSymbol(_ article: NewspaperArticle) -> String {
        if article.isRead { return "checkmark.circle.fill" }
        switch article.captureState {
        case .capturing: return "arrow.down.circle.dotted"
        case .failed: return "exclamationmark.triangle.fill"
        case .deferred: return "text.badge.plus"
        case .ready: return article.priority == .next ? "arrow.up.to.line.circle.fill" : "doc.text.fill"
        }
    }

    private func statusTint(_ article: NewspaperArticle) -> Color {
        if article.isRead { return .green }
        switch article.captureState {
        case .capturing: return .blue
        case .failed: return .orange
        case .deferred: return .secondary
        case .ready: return article.priority == .next ? .pink : .brown
        }
    }
}
