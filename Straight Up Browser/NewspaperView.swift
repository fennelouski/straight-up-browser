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
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
#endif

struct NewspaperView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NewspaperArticle.addedAt, order: .reverse)
    private var storedArticles: [NewspaperArticle]

    let onOpenOriginal: (URL) -> Void
    let onClose: () -> Void

    @AppStorage(NewspaperPreferences.Key.layout, store: NewspaperPreferences.presentationStore)
    private var layoutRaw = NewspaperPreferences.defaultLayout
    @AppStorage(NewspaperPreferences.Key.navigationStyle, store: NewspaperPreferences.presentationStore)
    private var navigationStyleRaw = NewspaperPreferences.defaultNavigationStyle
    @AppStorage(NewspaperPreferences.Key.fontFamily) private var fontFamily = ""

    @AppStorage(NewspaperPreferences.Key.appearance, store: NewspaperPreferences.presentationStore) private var appearance = NewspaperPreferences.defaultAppearance
    @AppStorage(NewspaperPreferences.Key.showHeadline) private var showHeadline = true
    @AppStorage(NewspaperPreferences.Key.headlineID) private var headlineID = ""
    @AppStorage(NewspaperEditionPreferences.style, store: NewspaperPreferences.presentationStore) private var styleRaw = NewspaperEditionStyle.metropolitan.rawValue
    @AppStorage(NewspaperEditionPreferences.showShopping) private var showShopping = true
    @AppStorage(NewspaperEditionPreferences.shoppingSignals) private var shoppingData = Data()
    @State private var preparingEdition = true
    @State private var showingSettings = false
    @State private var viewportWidth: CGFloat = 0
    @State private var nearLeft = false
    @State private var nearRight = false
    @ObservedObject private var discovery = NewspaperDiscoveryCoordinator.shared
    private var editionStyle: NewspaperEditionStyle { NewspaperEditionStyle(rawValue: styleRaw) ?? .metropolitan }
    private var shopping: [NewspaperShoppingSignal] { showShopping ? NewspaperShoppingStore.signals() : [] }
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    private var headline: NewspaperArticle? {
        guard showHeadline else { return nil }
        return sortedArticles.first { $0.id.uuidString == headlineID && $0.captureState == .ready }
            ?? sortedArticles.first { $0.captureState == .ready && !$0.isRead }
            ?? sortedArticles.first { $0.captureState == .ready }
    }
    private var supportingArticles: [NewspaperArticle] {
        sortedArticles.filter { $0.id != headline?.id }
    }
    private var issueArticles: [NewspaperArticle] {
        if let headline { return [headline] + supportingArticles }
        return sortedArticles
    }

    @State private var selectedSection = Self.allSections
    @State private var unreadOnly = false
    // `dismissed`'s one UI surface: sources rejected in every workspace are
    // hidden (ADR 0007's feed rule, wired here); this toggle reveals them, and
    // the card context menu can restore one per workspace.
    @State private var showDismissed = false
    @State private var pageIndex = 0
    @State private var pageTurnDirection = 1

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
            ScrollView {
              VStack(spacing: 0) {
                masthead
                Divider()
                sectionStrip
                Divider()

                if preparingEdition {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing your edition…").font(.headline)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if storedArticles.isEmpty {
                    emptyState
                } else if sortedArticles.isEmpty {
                    filteredEmptyState
                } else if layout == .flipbook || (navigationStyle == .pages && ![.cover, .feed, .newsstand, .eclectic].contains(layout)) {
                    NewspaperPagedIssue(
                        articles: issueArticles,
                        layout: layout,
                        pageIndex: $pageIndex,
                        direction: pageTurnDirection,
                        actions: actions
                    )
                } else if [.cover, .feed, .newsstand, .eclectic].contains(layout) {
                    NewspaperVisualIssue(articles: issueArticles, layout: layout, style: editionStyle, actions: actions, shopping: shopping, onOpenOriginal: onOpenOriginal)
                } else {
                    continuousIssue
                }
              }
            }
            .scrollIndicators(.visible)
            .overlay(alignment: .topTrailing) { closeButton.padding(4) }
            .overlay {
                if layout == .flipbook || navigationStyle == .pages {
                    HStack {
                        NewspaperEdgeChevron(direction: -1, nearby: nearLeft, disabled: pageIndex == 0) { turnPage(-1) }
                        Spacer()
                        NewspaperEdgeChevron(direction: 1, nearby: nearRight,
                            disabled: pageIndex >= NewspaperPageProjection.pageCount(articleCount: issueArticles.count, layout: layout) - 1) { turnPage(1) }
                    }.padding(.horizontal, 2)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): nearLeft = point.x < 110; nearRight = point.x > viewportWidth - 110
                case .ended: nearLeft = false; nearRight = false
                }
            }
            .background { NewspaperHorizontalPaging(onTurn: turnPage) }
            #if os(iOS)
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5,
                      abs(value.translation.width) > 70 else { return }
                turnPage(value.translation.width < 0 ? 1 : -1)
            })
            #endif
            .background(NewspaperPaper().ignoresSafeArea())
            .foregroundStyle(Color.primary)
            #if os(macOS)
            .ignoresSafeArea(.container, edges: .top)
            #endif
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
        .environment(\.newspaperEdition, editionStyle)
        .tint(editionStyle.accent)
        .preferredColorScheme((NewspaperAppearance(rawValue: appearance) ?? .system).colorScheme)
        #if os(macOS)
        .frame(minWidth: 900, idealWidth: 1120, minHeight: 650, idealHeight: 780)
        #endif
        .task {
            let firstEdition = !NewspaperPreferences.presentationStore.bool(forKey: NewspaperEditionPreferences.prepared)
            await NewspaperEditionPreparation.prepare(context: modelContext, includeWelcome: false)
            if !Task.isCancelled { preparingEdition = false }
            await discovery.catchUpRecentVisits(modelContext: modelContext)
            if firstEdition, !Task.isCancelled { NewspaperEditionPreparation.addWelcomeIfEmpty(context: modelContext) }
        }
        .newspaperMotion(preparingEdition)
        .newspaperMotion(layoutRaw)
        .newspaperMotion(styleRaw)
        .newspaperMotion(selectedSection)
        .newspaperMotion(unreadOnly)
        .newspaperMotion(showDismissed)
        .newspaperMotion(navigationStyleRaw)
        .newspaperMotion(shoppingData)
        #if os(iOS)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                NewspaperSettingsView().navigationTitle("Newspaper Settings")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } } }
            }
        }
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

    @AppStorage(NewspaperNaming.titleKey, store: NewspaperPreferences.presentationStore) private var personalTitle = ""

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark").font(.caption)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(BrowserPressStyle())
        .accessibilityLabel("Close Newspaper")
    }

    private func turnPage(_ direction: Int) {
        guard ![.cover, .feed, .newsstand, .eclectic].contains(layout), !issueArticles.isEmpty else { return }
        let count = NewspaperPageProjection.pageCount(articleCount: issueArticles.count, layout: layout)
        let next = min(max(pageIndex + direction, 0), max(0, count - 1))
        pageTurnDirection = direction
        navigationStyleRaw = NewspaperNavigationStyle.pages.rawValue
        pageIndex = next
    }

    private var masthead: some View {
        VStack(spacing: 8) {
            Text(editionStyle.isMagazine ? "YOUR READING EDITION" : "THE DAILY READ")
                    .font(NewspaperTypography.font(fontFamily, size: 9, weight: .bold))
                    .tracking(1.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            Text(NewspaperNaming.title(personalTitle, fallback: editionStyle.title))
                .font(NewspaperTypography.font(fontFamily, size: layout.isEditorial ? 48 : 32, weight: .black))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
            HStack(alignment: .firstTextBaseline) {
                Text(Date.now.formatted(date: .complete, time: .omitted))
                Spacer(minLength: 8)
                Text(issueSummary).foregroundStyle(.secondary)
            }
            .font(NewspaperTypography.font(fontFamily, size: 10))
            NewspaperWeatherMasthead()
            if discovery.isCatchingUp {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(discovery.catchUpStatus).font(.caption)
                    Button("Pause") {
                        UserDefaults.standard.set(false, forKey: NewspaperPreferences.Key.discoverRecent)
                    }.buttonStyle(BrowserPressStyle())
                }
            }
            Rectangle().fill(Color.primary.opacity(0.65)).frame(height: 0.5)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { issueControls }
                HStack(alignment: .top, spacing: 16) {
                    settingsButton
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 6) { readingControls }
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        #if os(macOS)
        .padding(.top, 28)
        .background {
            Color.clear.contentShape(Rectangle())
                .gesture(WindowDragGesture()).allowsWindowActivationEvents(true)
        }
        #else
        .padding(.top, 6)
        #endif
    }

    private var settingsButton: some View {
        Button {
            #if os(macOS)
            UserDefaults.standard.set("newspaper", forKey: "settingsPane")
            openWindow(id: "settings")
            #else
            showingSettings = true
            #endif
        } label: { Label("Newspaper Settings", systemImage: "gearshape").font(.caption) }
        .buttonStyle(BrowserPressStyle())
    }

    @ViewBuilder private var issueControls: some View {
        settingsButton
        Spacer(minLength: 8)
        readingControls
    }
    @ViewBuilder private var readingControls: some View {
        if ![.cover, .flipbook, .feed, .newsstand, .eclectic].contains(layout) {
            HStack(spacing: 12) {
                ForEach(NewspaperNavigationStyle.allCases) { style in
                    Button { navigationStyleRaw = style.rawValue } label: {
                        Text(style.title).fontWeight(navigationStyle == style ? .bold : .regular)
                            .underline(navigationStyle == style)
                    }
                    .buttonStyle(BrowserPressStyle())
                    .accessibilityAddTraits(navigationStyle == style ? .isSelected : [])
                }
            }
        }
        Button { unreadOnly.toggle() } label: {
            Text("Unread").fontWeight(unreadOnly ? .bold : .regular).underline(unreadOnly)
        }
        .buttonStyle(BrowserPressStyle()).accessibilityValue(unreadOnly ? "On" : "Off")
        .accessibilityAddTraits(unreadOnly ? .isSelected : [])
        Button { showDismissed.toggle() } label: {
            Text("Dismissed").fontWeight(showDismissed ? .bold : .regular).underline(showDismissed)
        }
        .buttonStyle(BrowserPressStyle()).accessibilityValue(showDismissed ? "On" : "Off")
        .accessibilityAddTraits(showDismissed ? .isSelected : [])
    }

    private var sectionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                    if index > 0 { Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 0.5, height: 10).accessibilityHidden(true) }
                    Button { selectedSection = section; pageIndex = 0 } label: {
                        Text(section.uppercased())
                            .font(NewspaperTypography.font(fontFamily, size: 10, weight: selectedSection == section ? .bold : .regular))
                            .tracking(0.5)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                if selectedSection == section { Rectangle().fill(Color.primary.opacity(0.7)).frame(height: 0.5).padding(.horizontal, 12) }
                            }
                    }
                    .buttonStyle(BrowserPressStyle())
                    .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                }
            }
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private var continuousIssue: some View {
            VStack(spacing: 0) {
                if let headline {
                    VStack(alignment: .leading, spacing: 8) {
                        NewspaperSectionRule(title: "Today's Headline", monochrome: true)
                        NewspaperStoryLink(article: headline, layout: layout, prominence: .headline, actions: actions)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                }
                switch layout {
                case .ink: NewspaperInkIssue(articles: supportingArticles, actions: actions)
                case .broadsheet: NewspaperBroadsheetIssue(articles: supportingArticles, actions: actions)
                case .magazine: NewspaperMagazineIssue(articles: supportingArticles, actions: actions)
                case .shelf: NewspaperShelfIssue(articles: supportingArticles, actions: actions)
                case .cover, .flipbook, .feed, .newsstand, .eclectic: EmptyView()
                }
                if !shopping.isEmpty {
                    NewspaperShoppingCards(signals: shopping, articles: issueArticles, onOpen: onOpenOriginal).padding(24)
                }
            }
            .frame(maxWidth: 1440)
            .frame(maxWidth: .infinity)
            .newspaperMotion(headline?.id)
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
        VStack(spacing: 10) {
            Text("Your newspaper is waiting").font(NewspaperTypography.font(fontFamily, size: 28, weight: .bold))
            Text("On any article, choose Add to Newspaper. Its readable text is saved for offline reading and syncs with your private browser data.")
                .font(NewspaperTypography.font(fontFamily, size: 16)).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var filteredEmptyState: some View {
        VStack(spacing: 8) {
            Text("No matching articles").font(NewspaperTypography.font(fontFamily, size: 24, weight: .bold))
            Text("Try another section or include finished articles.").font(NewspaperTypography.font(fontFamily, size: 15))
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var issueSummary: String {
        let unread = storedArticles.filter { !$0.isRead }.count
        return String(localized: "\(unread) unread · \(storedArticles.count) saved")
    }

}

struct NewspaperArticleActions {
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
                            Divider().overlay(Color.primary.opacity(0.25)).padding(.vertical, 12)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity)
    }
}

private struct NewspaperBroadsheetIssue: View {
    let articles: [NewspaperArticle]
    let actions: NewspaperArticleActions
    @State private var availableWidth: CGFloat = 0

    private var columnCount: Int {
        let width = availableWidth - 36
        return width >= 1040 ? 4 : width >= 770 ? 3 : width >= 500 ? 2 : 1
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(NewspaperPresentation.grouped(articles), id: \.0) { section, stories in
                VStack(alignment: .leading, spacing: 10) {
                    NewspaperSectionRule(title: section, monochrome: true)
                    columns(stories, count: columnCount)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(section + " columns")
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .newspaperMotion(columnCount)
        .accessibilityIdentifier("newspaper-editorial-columns")
    }
    private func columns(_ stories: [NewspaperArticle], count proposed: Int) -> some View {
        let count = min(proposed, max(1, stories.count))
        return HStack(alignment: .top, spacing: 16) {
            ForEach(0..<count, id: \.self) { column in
                if column > 0 { Divider().overlay(Color.primary.opacity(0.2)) }
                let start = column * stories.count / count
                let end = (column + 1) * stories.count / count
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(stories[start..<end].enumerated()), id: \.element.id) { row, article in
                        if row > 0 { Divider().overlay(Color.primary.opacity(0.2)) }
                        NewspaperStoryLink(article: article, layout: .broadsheet,
                            prominence: column == 0 && row == 0 ? .lead : .standard, actions: actions)
                    }
                }
                .frame(minWidth: proposed == 1 ? 0 : 230, maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
    let direction: Int
    let actions: NewspaperArticleActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(NewspaperEditionPreferences.motionDuration, store: NewspaperPreferences.presentationStore) private var duration = 0.28
    private var count: Int { NewspaperPageProjection.pageCount(articleCount: articles.count, layout: layout) }
    private var current: Int { min(max(0, pageIndex), max(0, count - 1)) }
    private var pageArticles: [NewspaperArticle] {
        let size = NewspaperPageProjection.articlesPerPage(layout)
        let start = min(articles.count, current * size)
        return Array(articles[start..<min(articles.count, start + size)])
    }
    var body: some View {
        VStack(spacing: 14) {
            Text("Page \(current + 1) of \(count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.top, 12)
            Group {
                if layout == .broadsheet { NewspaperBroadsheetIssue(articles: pageArticles, actions: actions) }
                else if layout == .ink { NewspaperInkIssue(articles: pageArticles, actions: actions) }
                else if let article = pageArticles.first {
                    NewspaperStoryLink(article: article, layout: layout, prominence: .page, actions: actions)
                        .frame(maxWidth: 760).padding(24)
                }
            }
            .id(current)
            .transition(reduceMotion || duration == 0 ? .opacity : NewspaperPageTurn.transition(direction: direction, variation: current % 3))
            .frame(maxWidth: 1440).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 46).padding(.bottom, 24)
        .newspaperMotion(pageIndex)
        .onChange(of: articles.count, initial: true) { _, _ in pageIndex = current }
    }
}

enum NewspaperStoryProminence {
    case standard
    case lead
    case headline
    case page
}

struct NewspaperStoryLink: View {
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
        .buttonStyle(BrowserPressStyle())
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
            Button("Make Today's Headline") {
                UserDefaults.standard.set(article.id.uuidString, forKey: NewspaperPreferences.Key.headlineID)
                UserDefaults.standard.set(true, forKey: NewspaperPreferences.Key.showHeadline)
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
        .accessibilityLabel(article.title)
        .accessibilityValue("\(article.section) · \(article.estimatedReadingMinutes) min")
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
                    .clipped()
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
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
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
                    .lineLimit(prominence == .page ? 14 : prominence == .headline ? 4 : prominence == .lead ? 7 : 5)
                    .foregroundStyle(layout.isEditorial ? Color.primary.opacity(0.85) : Color.secondary)
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
                    ? Color.primary.opacity(0.62)
                    : Color.secondary.opacity(0.62)
            )
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, maxHeight: prominence == .page ? .infinity : nil, alignment: .topLeading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius))
        .opacity(article.isRead ? 0.72 : 1)
    }

    private var titleFont: Font {
        switch prominence {
        case .page, .headline: NewspaperTypography.font(fontFamily, size: 38)
        case .lead: NewspaperTypography.font(fontFamily, size: 27)
        case .standard: NewspaperTypography.font(fontFamily, size: 20)
        }
    }

    private var bodyFont: Font {
        NewspaperTypography.font(fontFamily, size: prominence == .page ? 19 : prominence == .headline ? 17 : 15)
    }

    private var excerptLength: Int {
        switch prominence {
        case .page: 260
        case .headline: 90
        case .lead: 130
        case .standard: 80
        }
    }

    private var cardPadding: CGFloat {
        if layout.isEditorial { return prominence == .page ? 14 : 0 }
        return switch prominence {
        case .page: 30
        case .lead, .headline: 20
        case .standard: 16
        }
    }

    private var cardCornerRadius: CGFloat {
        layout == .shelf || layout == .feed ? 4 : 0
    }

    @ViewBuilder
    private var cardBackground: some View {
        if layout == .ink {
            Color.clear
        } else if layout == .shelf {
            NewspaperPaper().shadow(color: .black.opacity(0.08), radius: 3, x: 1, y: 2)
        } else { Color.clear }
    }
}

private struct NewspaperSectionRule: View {
    let title: String
    let monochrome: Bool

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().frame(height: 0.5)
            Text(title.uppercased())
                .font(.caption.weight(.black))
                .tracking(1.2)
                .fixedSize()
            Rectangle().frame(height: 0.5)
        }
        .foregroundStyle(Color.primary)
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
        .background(NewspaperPaper().ignoresSafeArea())
        .foregroundStyle(Color.primary)
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
            .foregroundStyle(Color.secondary)
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
                        .buttonStyle(BrowserPressStyle())
                        .accessibilityLabel("Rate \(rating) out of 5")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)


                Button {
                    onOpenOriginal(article.url)
                } label: {
                    Label("Open Web Page", systemImage: "safari")
                }

                Button(role: .destructive) { confirmRemoval = true } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .buttonStyle(BrowserPressStyle())
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
                .buttonStyle(BrowserPressStyle())
            } else if showsAllPhotos, article.imageURLs.count > max(photoLimit, 0) {
                Button("Show fewer photos") { showsAllPhotos = false }
                    .buttonStyle(BrowserPressStyle())
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
            .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 0.5) }
        case .failed:
            Label(
                article.captureError ?? "Readable text could not be captured. The source link is still saved.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .padding(14)
            .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 0.5) }
        case .deferred:
            // Recorded in the research ledger but never extracted — the source
            // and its link are real, the readable text just isn't here yet.
            Label(
                "This source is saved. Its readable text hasn't been captured yet.",
                systemImage: "text.badge.plus"
            )
            .foregroundStyle(.secondary)
            .padding(14)
            .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 0.5) }
        case .ready:
            if article.originalPayloadData == nil {
                Label(
                    "Saved text is still arriving on this device. The source and reading state are already available.",
                    systemImage: "icloud.and.arrow.down"
                )
                .foregroundStyle(.secondary)
                .padding(14)
                .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 0.5) }
            } else if article.document == nil {
                Label(
                    "This saved-text version cannot be opened. The original web page is still available.",
                    systemImage: "doc.badge.exclamationmark"
                )
                .foregroundStyle(.orange)
                .padding(14)
                .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 0.5) }
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
                .buttonStyle(BrowserPressStyle())

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

private struct NewspaperPaper: View {
    @Environment(\.newspaperEdition) private var style
    @AppStorage(NewspaperEditionPreferences.texture, store: NewspaperPreferences.presentationStore) private var texture = NewspaperPaperTexture.recommended.rawValue
    @AppStorage(NewspaperEditionPreferences.textureStrength, store: NewspaperPreferences.presentationStore) private var strength = 0.55
    var body: some View {
        let selected = NewspaperPaperTexture(rawValue: texture) ?? .recommended
        NewspaperProceduralPaper(texture: selected == .recommended ? style.recommendedPaper : selected, strength: strength)
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
                case .cover: cover
                case .flipbook: magazine
                case .feed: feed
                case .newsstand, .eclectic: shelf
                }
            }
            .padding(8)
        }
        .frame(width: 128, height: 88)
        .accessibilityHidden(true)
    }

    @Environment(\.colorScheme) private var scheme
    private var paper: Color {
        scheme == .dark ? Color(red: 0.12, green: 0.13, blue: 0.14)
                        : Color(red: 0.97, green: 0.96, blue: 0.925)
    }
    private var inkColor: Color { .primary }

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
                    .overlay(alignment: .trailing) { Rectangle().fill(inkColor.opacity(0.25)).frame(width: 0.5) }
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

    private var cover: some View {
        HStack(spacing: 8) {
            VStack(spacing: 4) {
                line(40, height: 4, opacity: 0.8)
                photo.frame(height: 35)
                line(40, height: 3, opacity: 0.7)
            }.padding(4).overlay { Rectangle().stroke(inkColor.opacity(0.6), lineWidth: 2) }
            lines(8, width: 40)
        }
    }
    private var feed: some View {
        VStack(spacing: 3) {
            line(70, height: 3, opacity: 0.8)
            photo.frame(height: 30)
            lines(4, width: 85)
        }
    }
}

struct NewspaperSettingsView: View {
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(NewspaperPreferences.Key.layout, store: NewspaperPreferences.presentationStore)
    private var layout = NewspaperPreferences.defaultLayout
    @AppStorage(NewspaperPreferences.Key.navigationStyle, store: NewspaperPreferences.presentationStore)
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

    @AppStorage(NewspaperPreferences.Key.appearance, store: NewspaperPreferences.presentationStore) private var appearance = NewspaperPreferences.defaultAppearance
    @AppStorage(NewspaperPreferences.Key.showHeadline) private var showHeadline = true

    var body: some View {
        Form {
            NewspaperEditionSettings()
            NewspaperNamingSettings()
            CollapsibleSection(searchID: "newspaper.layout") {
                layoutGallery
                Picker("Appearance", selection: $appearance) {
                    ForEach(NewspaperAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }.accessibilityIdentifier("newspaper-appearance")
                HStack(spacing: 16) {
                    VStack { NewspaperLayoutPreview(layout: NewspaperLayout(rawValue: layout) ?? .broadsheet).environment(\.colorScheme, .light); Text("Light").font(.caption) }
                    VStack { NewspaperLayoutPreview(layout: NewspaperLayout(rawValue: layout) ?? .broadsheet).environment(\.colorScheme, .dark); Text("Dark").font(.caption) }
                }
                Toggle("Show a front-page headline", isOn: $showHeadline)
                Button("Choose the headline automatically") {
                    UserDefaults.standard.removeObject(forKey: NewspaperPreferences.Key.headlineID)
                }
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
                    Text("Choose an installed font for headlines and article text, or use the publication style’s default face.")
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

            NewspaperDiscoverySettings()
            NewspaperShoppingSettings()
            NewspaperWeatherSettings()
            NewspaperLibrarySection()

            CollapsibleSection {
                NewspaperTintedLabel(title: "Readable text is retained for offline use", systemImage: "arrow.down.doc", tint: .green)
                NewspaperTintedLabel(title: "Remote photos are loaded only when shown", systemImage: "photo", tint: .orange)
                NewspaperTintedLabel(title: "Newspaper follows the main browser-data sync switch", systemImage: "icloud", tint: .blue)
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 14)], spacing: 14) {
            ForEach(NewspaperLayout.allCases) { option in
                let selected = option.rawValue == layout
                Button {
                    layout = option.rawValue
                } label: {
                    VStack(spacing: 6) {
                        NewspaperLayoutPreview(layout: option)
                            .environment(\.colorScheme, (NewspaperAppearance(rawValue: appearance) ?? .system).colorScheme ?? systemScheme)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2.5 : 1)
                            )
                        Label(option.title, systemImage: option.systemImage)
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                    }
                }
                .buttonStyle(BrowserPressStyle())
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 3)
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
