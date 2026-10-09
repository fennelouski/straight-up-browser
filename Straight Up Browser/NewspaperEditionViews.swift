import SwiftUI

struct NewspaperEditionCover: View {
    let article: NewspaperArticle
    let style: NewspaperEditionStyle
    var compact = false
    @AppStorage(NewspaperPreferences.Key.photoLimit) private var photoLimit = NewspaperPreferences.defaultPhotoLimit
    @AppStorage(NewspaperEditionPreferences.cutout, store: NewspaperPreferences.presentationStore) private var cutout = false
    @AppStorage(NewspaperEditionPreferences.texture, store: NewspaperPreferences.presentationStore) private var paperRaw = NewspaperPaperTexture.recommended.rawValue
    @AppStorage(NewspaperEditionPreferences.textureStrength, store: NewspaperPreferences.presentationStore) private var paperStrength = 0.55
    @AppStorage(NewspaperNaming.titleKey, store: NewspaperPreferences.presentationStore) private var personalTitle = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .bottomLeading) {
                NewspaperProceduralPaper(texture: selectedPaper, strength: paperStrength)
                LinearGradient(colors: [style.accent.opacity(0.20), .clear, style.accent.opacity(0.32)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if photoLimit > 0, let image = article.leadImage {
                    NewspaperCoverPhoto(url: image.url, cutout: cutout, layer: .photo)
                        .frame(width: width, height: geometry.size.height * 0.92)
                        .clipped()
                        .opacity(0.55)
                        .accessibilityHidden(true)
                }
                // The masthead stays behind the optional isolated foreground.
                VStack {
                    Text(NewspaperNaming.title(personalTitle, fallback: style.title).uppercased())
                        .font(.system(size: min(compact ? 25 : 56, width * 0.12), weight: .black, design: style.sansSerif ? .default : .serif))
                        .tracking(style == .atelier ? 3 : 0.3)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, width * 0.035)
                        .padding(.top, width * 0.08)
                    Text("YOUR READING EDITION").font(.system(size: max(9, width * 0.022), weight: .semibold)).tracking(2)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                if photoLimit > 0, cutout, let image = article.leadImage {
                    NewspaperCoverPhoto(url: image.url, cutout: true, layer: .subject)
                        .frame(width: width, height: geometry.size.height * 0.92)
                        .clipped()
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: compact ? 6 : 12) {
                    Text(article.section.uppercased()).font(.system(size: compact ? 10 : 12, weight: .black)).tracking(1.4)
                    Text(article.title)
                        .font(.system(size: min(compact ? 24 : 42, width * 0.095), weight: .black, design: style.sansSerif ? .default : .serif))
                        .lineLimit(compact ? 4 : 5)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(coverByline)
                        .font(.system(size: compact ? 9 : 11, weight: .semibold))
                        .lineLimit(2)
                }
                .padding(width * 0.07)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedPaper.color(dark: scheme == .dark).opacity(0.9))
                .padding(width * 0.035)
            }
            .overlay { Rectangle().strokeBorder(style.accent, lineWidth: coverBorderWidth) }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .aspectRatio(0.72, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(article.title)
        .accessibilityValue("\(style.title) cover · \(article.estimatedReadingMinutes) minutes")
    }
    private var selectedPaper: NewspaperPaperTexture {
        let selected = NewspaperPaperTexture(rawValue: paperRaw) ?? .recommended
        return selected == .recommended ? style.recommendedPaper : selected
    }
    private var coverByline: String {
        let publication = article.publication ?? article.url.host ?? "SAVED ARTICLE"
        return "\(article.estimatedReadingMinutes) MIN · \(publication)"
    }
    private var coverBorderWidth: CGFloat {
        switch style {
        case .boldWeekly: compact ? 3 : 5
        case .fieldNotes: compact ? 2 : 4
        default: 0.5
        }
    }
}

struct NewspaperCoverLink: View {
    let article: NewspaperArticle
    let style: NewspaperEditionStyle
    var compact = false
    let actions: NewspaperArticleActions
    var body: some View {
        NavigationLink(value: article.id) { NewspaperEditionCover(article: article, style: style, compact: compact) }
            .buttonStyle(BrowserPressStyle())
            .contextMenu {
                Button(article.isRead ? "Mark Unread" : "Mark Finished") { actions.markRead(article, !article.isRead) }
                Button("Read Next") { actions.setPriority(article, .next) }
                Button("Remove from Newspaper", role: .destructive) { actions.remove(article) }
            }
    }
}

struct NewspaperVisualIssue: View {
    let articles: [NewspaperArticle]
    let layout: NewspaperLayout
    let style: NewspaperEditionStyle
    let actions: NewspaperArticleActions
    let shopping: [NewspaperShoppingSignal]
    let onOpenOriginal: (URL) -> Void

    var body: some View {
            LazyVStack(spacing: 24) {
                if layout == .cover { coverAndContents }
                else if layout == .feed { feed }
                else { stand }
                if !shopping.isEmpty {
                    NewspaperShoppingCards(signals: shopping, articles: articles, onOpen: onOpenOriginal)
                }
            }
            .padding(20)
            .frame(maxWidth: layout == .feed ? 720 : 1400)
            .frame(maxWidth: .infinity)
        .newspaperMotion(articles.map(\.id))
    }

    @ViewBuilder private var coverAndContents: some View {
        if let lead = articles.first {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    NewspaperCoverLink(article: lead, style: style, actions: actions).frame(minWidth: 320, maxWidth: 440)
                    contents.frame(minWidth: 240, maxWidth: 400)
                }
                VStack(spacing: 24) {
                    NewspaperCoverLink(article: lead, style: style, actions: actions).frame(maxWidth: 440)
                    contents
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("newspaper-cover-issue")
        }
    }
    private var contents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inside this edition").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ForEach(Array(articles.enumerated()), id: \.element.id) { index, article in
                NavigationLink(value: article.id) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(format: "%02d", index + 1)).font(.title3.monospacedDigit()).foregroundStyle(style.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(article.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                            Text("\(article.section) · \(article.estimatedReadingMinutes) min").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 8)
                }.buttonStyle(BrowserPressStyle())
                Divider()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newspaper-table-of-contents")
    }
    private var feed: some View {
        ForEach(articles) { article in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "doc.text.image").foregroundStyle(style.accent)
                    Text(article.publication ?? article.url.host ?? "Saved article").font(.caption.bold())
                    Spacer()
                    Text(article.addedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
                NewspaperStoryLink(article: article, layout: .feed, prominence: .lead, actions: actions)
            }
            .padding(12)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.2)).frame(height: 0.5) }
            .transition(BrowserMotion.panel)
        }
    }
    private var stand: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 24)], alignment: .center, spacing: 28) {
            ForEach(articles) { article in
                let medium = NewspaperMedium.forArticle(article, eclectic: layout == .eclectic)
                VStack(spacing: 10) {
                    if medium == .paper {
                        NewspaperStoryLink(article: article, layout: .broadsheet, prominence: .lead, actions: actions)
                            .background(NewspaperProceduralPaper(texture: .newsprint, strength: 0.6))
                            .rotationEffect(.degrees(-1.2))
                            .padding(.horizontal, 3)
                    } else if medium == .card {
                        NewspaperStoryLink(article: article, layout: .magazine, prominence: .standard, actions: actions)
                            .rotationEffect(.degrees(0.8))
                            .padding(.horizontal, 3)
                    } else {
                        NewspaperCoverLink(article: article, style: layout == .eclectic ? NewspaperMedium.style(for: article) : style, compact: true, actions: actions)
                    }
                    Text(medium.title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Rectangle().fill(style.accent.opacity(0.25)).frame(height: 3)
                }
                .shadow(color: .black.opacity(0.10), radius: 7, x: 1, y: 6)
                .transition(BrowserMotion.panel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newspaper-newsstand")
    }
}

enum NewspaperMedium {
    case paper, magazine, card
    var title: String { switch self { case .paper: "Newspaper"; case .magazine: "Magazine"; case .card: "Reading card" } }
    static func forArticle(_ article: NewspaperArticle, eclectic: Bool) -> Self {
        guard eclectic else { return .magazine }
        if article.leadImage != nil { return .magazine }
        return article.estimatedReadingMinutes >= 4 ? .paper : .card
    }
    static func style(for article: NewspaperArticle) -> NewspaperEditionStyle {
        let subject = (article.section + " " + article.title).lowercased()
        if subject.contains("food") || subject.contains("recipe") { return .table }
        if subject.contains("garden") || subject.contains("home") { return .gardenHome }
        if subject.contains("sport") { return .arena }
        if subject.contains("music") { return .amplifier }
        if subject.contains("science") { return .discovery }
        if subject.contains("technology") || subject.contains("software") { return .signal }
        if subject.contains("design") || subject.contains("fashion") { return .atelier }
        return .fieldNotes
    }
}

struct NewspaperEditionStylePreview: View {
    let style: NewspaperEditionStyle
    var paper: NewspaperPaperTexture? = nil
    var strength = 0.7
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(style.title).font(.system(size: 17, weight: .black, design: style.sansSerif ? .default : .serif)).lineLimit(2)
            Rectangle().fill(style.accent).frame(height: style.isMagazine ? 4 : 1)
            if style.isMagazine {
                RoundedRectangle(cornerRadius: 2).fill(LinearGradient(colors: [style.accent.opacity(0.55), style.accent.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(height: 28)
            }
            HStack(alignment: .top, spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { row in
                            Rectangle().fill(Color.primary.opacity(row == 0 ? 0.65 : 0.25)).frame(height: row == 0 ? 3 : 1.5)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(height: 112, alignment: .top)
        .background(NewspaperProceduralPaper(texture: paper ?? style.recommendedPaper, strength: strength))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}

struct NewspaperEditionSettings: View {
    @AppStorage(NewspaperEditionPreferences.style, store: NewspaperPreferences.presentationStore) private var selected = NewspaperEditionStyle.metropolitan.rawValue
    @AppStorage(NewspaperEditionPreferences.texture, store: NewspaperPreferences.presentationStore) private var texture = NewspaperPaperTexture.recommended.rawValue
    @AppStorage(NewspaperEditionPreferences.textureStrength, store: NewspaperPreferences.presentationStore) private var strength = 0.55
    @AppStorage(NewspaperEditionPreferences.regionalStyle, store: NewspaperPreferences.presentationStore) private var regional = true
    @AppStorage(NewspaperEditionPreferences.cutout, store: NewspaperPreferences.presentationStore) private var cutout = false
    @AppStorage(NewspaperEditionPreferences.welcomeEnabled, store: NewspaperPreferences.presentationStore) private var welcome = true
    @AppStorage(NewspaperEditionPreferences.motionDuration, store: NewspaperPreferences.presentationStore) private var duration = 0.28
    @AppStorage(NewspaperEditionPreferences.motionSpring, store: NewspaperPreferences.presentationStore) private var spring = true
    @AppStorage(NewspaperPreferences.Key.layout, store: NewspaperPreferences.presentationStore) private var layout = NewspaperPreferences.defaultLayout
    @AppStorage(NewspaperPreferences.Key.appearance, store: NewspaperPreferences.presentationStore) private var appearance = NewspaperPreferences.defaultAppearance
    @Environment(\.colorScheme) private var systemScheme
    private var style: NewspaperEditionStyle { NewspaperEditionStyle(rawValue: selected) ?? .metropolitan }
    var body: some View {
        CollapsibleSection(searchID: "newspaper.style", initiallyCollapsed: true) {
            Text(style.description).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach(NewspaperEditionStyle.allCases) { option in
                    Button { selected = option.rawValue } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            NewspaperEditionStylePreview(style: option)
                                .environment(\.colorScheme, (NewspaperAppearance(rawValue: appearance) ?? .system).colorScheme ?? systemScheme)
                                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(option == style ? option.accent : .secondary.opacity(0.3), lineWidth: option == style ? 2 : 1) }
                            Text(option.title).font(.caption.bold())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(BrowserPressStyle())
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(option == style ? .isSelected : [])
                    .transition(BrowserMotion.panel)
                }
            }.padding(3)
            .newspaperMotion(selected)
            Button("Use this style's recommended format and paper") {
                layout = style.recommendedLayout.rawValue
                texture = NewspaperPaperTexture.recommended.rawValue
            }
            HStack(spacing: 12) {
                VStack {
                    NewspaperEditionStylePreview(style: style, paper: selectedPaper, strength: strength).environment(\.colorScheme, .light)
                    Text("Light").font(.caption)
                }
                VStack {
                    NewspaperEditionStylePreview(style: style, paper: selectedPaper, strength: strength).environment(\.colorScheme, .dark)
                    Text("Dark").font(.caption)
                }
            }
            Picker("Paper", selection: $texture) { ForEach(NewspaperPaperTexture.allCases) { Text($0.title).tag($0.rawValue) } }
                .accessibilityIdentifier("newspaper-paper-texture")
            HStack {
                Text("Texture strength")
                Slider(value: $strength, in: 0...1).accessibilityLabel("Paper texture strength")
            }
            NewspaperProceduralPaper(texture: NewspaperPaperTexture(rawValue: texture).flatMap { $0 == .recommended ? style.recommendedPaper : $0 } ?? style.recommendedPaper, strength: strength)
                .frame(height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
            Toggle("Lift image subjects over magazine mastheads", isOn: $cutout)
            Text("Optional subject cutouts use Apple Vision on this device. Photos load only in visual formats when allowed by your photo limit; an unavailable photo or cutout falls back gracefully.").font(.caption).foregroundStyle(.secondary)
            Toggle("Recommend the first style from my device region and language", isOn: $regional)
            Text("Used only when you first open Newspaper without a chosen style. No location service, IP lookup or network request. Your selected style is always retained.").font(.caption).foregroundStyle(.secondary)
            Toggle("Include Browser's launch story and help if my first edition is empty", isOn: $welcome)
            HStack {
                Text("Animation duration")
                Slider(value: $duration, in: 0...1).accessibilityLabel("Newspaper animation duration")
                Text(duration == 0 ? "Off" : "\(Int(duration * 1000)) ms").font(.caption.monospacedDigit()).frame(minWidth: 48)
            }
            Toggle("Spring motion", isOn: $spring).disabled(duration == 0)
        } header: { Label("Publication Style & Paper", systemImage: "paintpalette") }
        footer: { Text("Original styles inspired by editorial traditions. Style, reading format, appearance and paper can be mixed independently. System Reduce Motion takes precedence.") }
    }
    private var selectedPaper: NewspaperPaperTexture {
        let selected = NewspaperPaperTexture(rawValue: texture) ?? .recommended
        return selected == .recommended ? style.recommendedPaper : selected
    }
}
