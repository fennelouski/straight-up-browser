import SwiftUI
import SwiftData

/// Original editorial identities, rather than publisher names or logos.
nonisolated enum NewspaperEditionStyle: String, CaseIterable, Identifiable {
    case metropolitan, lakefront, marketLedger, capitalRecord, westCoast, mountainDispatch
    case brightDaily, worldObserver, roseLedger, sundayChronicle, continental, iberian, alpine
    case pacificMorning, globalDaily, levantJournal
    case boldWeekly, extra, gardenHome, pocketReader, fieldNotes, amplifier, spotlight
    case testBench, atelier, signal, longform, discovery, table, arena

    var id: String { rawValue }
    var title: String {
        switch self {
        case .metropolitan: "Metropolitan"
        case .lakefront: "Lakefront"
        case .marketLedger: "Market Ledger"
        case .capitalRecord: "Capital Record"
        case .westCoast: "West Coast"
        case .mountainDispatch: "Mountain Dispatch"
        case .brightDaily: "Bright Daily"
        case .worldObserver: "World Observer"
        case .roseLedger: "Rose Ledger"
        case .sundayChronicle: "Sunday Chronicle"
        case .continental: "Continental"
        case .iberian: "Modern Iberian"
        case .alpine: "Alpine Review"
        case .pacificMorning: "Pacific Morning"
        case .globalDaily: "Global Daily"
        case .levantJournal: "Levant Journal"
        case .boldWeekly: "Bold Weekly"
        case .extra: "Extra!"
        case .gardenHome: "Garden & Home"
        case .pocketReader: "Pocket Reader"
        case .fieldNotes: "Field Notes"
        case .amplifier: "Amplifier"
        case .spotlight: "Spotlight"
        case .testBench: "Test Bench"
        case .atelier: "Atelier"
        case .signal: "Signal"
        case .longform: "Longform"
        case .discovery: "Discovery"
        case .table: "The Table"
        case .arena: "Arena"
        }
    }
    var isMagazine: Bool { Self.allCases.firstIndex(of: self)! >= Self.allCases.firstIndex(of: .boldWeekly)! }
    var description: String {
        switch self {
        case .metropolitan, .capitalRecord, .continental: "Classic serif headlines, strong rules, thoughtful columns."
        case .lakefront, .westCoast, .mountainDispatch: "A welcoming local daily with generous headlines and warm paper."
        case .marketLedger, .roseLedger: "A precise financial journal, compact type and restrained color."
        case .brightDaily, .worldObserver, .iberian: "A contemporary daily with confident color and open spacing."
        case .sundayChronicle, .alpine, .longform: "Quiet literary typography and room for a long read."
        case .pacificMorning, .globalDaily, .levantJournal: "A compact world edition with clear section markers."
        case .boldWeekly, .extra: "A punchy illustrated weekly with a framed cover."
        case .gardenHome, .table: "A warm lifestyle edition for homes, gardens and food."
        case .pocketReader: "Compact, friendly stories with simple ornament."
        case .fieldNotes: "An illustrated exploration journal with an ochre frame."
        case .amplifier, .arena: "Energetic display type for culture and sport."
        case .spotlight, .atelier: "A polished portrait magazine with elegant display lettering."
        case .testBench, .signal: "A crisp modern magazine for products, design and technology."
        case .discovery: "An inquisitive science magazine with a cool editorial palette."
        }
    }
    var accent: Color {
        switch self {
        case .boldWeekly, .extra, .amplifier: Color(red: 0.75, green: 0.16, blue: 0.19)
        case .fieldNotes, .arena: Color(red: 0.72, green: 0.49, blue: 0.10)
        case .gardenHome, .table: Color(red: 0.24, green: 0.46, blue: 0.31)
        case .roseLedger, .marketLedger: Color(red: 0.50, green: 0.30, blue: 0.26)
        case .brightDaily, .worldObserver, .discovery: Color(red: 0.12, green: 0.40, blue: 0.68)
        case .signal, .testBench: Color(red: 0.27, green: 0.42, blue: 0.47)
        case .spotlight, .atelier: Color(red: 0.56, green: 0.29, blue: 0.46)
        case .westCoast, .mountainDispatch: Color(red: 0.52, green: 0.36, blue: 0.23)
        default: Color(red: 0.31, green: 0.36, blue: 0.43)
        }
    }
    var sansSerif: Bool {
        [.brightDaily, .worldObserver, .iberian, .extra, .spotlight, .testBench, .signal, .discovery, .arena].contains(self)
    }
    var recommendedPaper: NewspaperPaperTexture {
        switch self {
        case .roseLedger: .rose
        case .marketLedger, .alpine: .ivory
        case .gardenHome, .table, .fieldNotes: .linen
        case .sundayChronicle, .longform, .continental: .laid
        default: isMagazine ? .smooth : .newsprint
        }
    }
    var recommendedLayout: NewspaperLayout { isMagazine ? .cover : .broadsheet }

    /// Device locale only: no GPS, IP service, browsing-history scan or network.
    static func recommendation(region: String?, language: String?, illustrated: Bool) -> Self {
        if illustrated { return .fieldNotes }
        switch region?.uppercased() {
        case "JP": return .pacificMorning
        case "IN": return .globalDaily
        case "IL": return .levantJournal
        case "CH": return .alpine
        case "GB", "IE": return .worldObserver
        case "FR": return .continental
        case "DE", "AT": return .alpine
        case "ES", "MX", "AR": return .iberian
        default:
            switch language {
            case "ja": return .pacificMorning
            case "fr": return .continental
            case "de": return .alpine
            case "es": return .iberian
            default: return .metropolitan
            }
        }
    }
}

nonisolated enum NewspaperPaperTexture: String, CaseIterable, Identifiable {
    case recommended, smooth, newsprint, ivory, rose, linen, laid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recommended: "Recommended for style"
        case .smooth: "Smooth"
        case .newsprint: "Newsprint"
        case .ivory: "Ivory"
        case .rose: "Rose"
        case .linen: "Linen"
        case .laid: "Laid paper"
        }
    }
    func color(dark: Bool) -> Color {
        if dark { return self == .rose ? Color(red: 0.17, green: 0.135, blue: 0.13) : Color(red: 0.12, green: 0.13, blue: 0.14) }
        switch self {
        case .rose: return Color(red: 0.98, green: 0.89, blue: 0.84)
        case .smooth: return Color(red: 0.985, green: 0.985, blue: 0.975)
        case .linen, .ivory: return Color(red: 0.97, green: 0.95, blue: 0.89)
        default: return Color(red: 0.97, green: 0.96, blue: 0.925)
        }
    }
}

enum NewspaperEditionPreferences {
    static let style = "newspaperEditionStyle"
    static let texture = "newspaperPaperTexture"
    static let textureStrength = "newspaperPaperStrength"
    static let cutout = "newspaperCoverCutout"
    static let regionalStyle = "newspaperRegionalStyle"
    static let prepared = "newspaperEditionPrepared"
    static let welcomeAdded = "newspaperWelcomeAdded"
    static let welcomeEnabled = "newspaperWelcomeEnabled"
    static let motionDuration = "newspaperMotionDuration"
    static let motionSpring = "newspaperMotionSpring"
    static let captureShopping = "newspaperCaptureShopping"
    static let showShopping = "newspaperShowShopping"
    static let shoppingSignals = "newspaperShoppingSignals"
}

extension EnvironmentValues {
    @Entry var newspaperEdition: NewspaperEditionStyle = .metropolitan
}

/// A fixed-cost tiled vector texture. Resolution-independent; no image assets,
/// per-frame randomness, screen-size allocation or animation timer.
struct NewspaperProceduralPaper: View {
    let texture: NewspaperPaperTexture
    let strength: Double
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            texture.color(dark: scheme == .dark)
            if texture != .smooth, strength > 0 {
                Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                    let tile: CGFloat = 72
                    let opacity = min(1, max(0, strength)) * (scheme == .dark ? 0.10 : 0.08)
                    var grain = Path()
                    var fibers = Path()
                    for row in 0...Int(size.height / tile) {
                        for column in 0...Int(size.width / tile) {
                            for dot in 0..<14 {
                                let x = CGFloat((dot * 37 + row * 13) % 71) + CGFloat(column) * tile
                                let y = CGFloat((dot * 19 + column * 7) % 71) + CGFloat(row) * tile
                                grain.addEllipse(in: CGRect(x: x, y: y, width: 0.7, height: 0.7))
                            }
                            if texture == .linen || texture == .laid {
                                let x = CGFloat(column) * tile
                                let y = CGFloat(row) * tile
                                fibers.move(to: CGPoint(x: x, y: y + 24))
                                fibers.addLine(to: CGPoint(x: x + tile, y: y + 24.4))
                                if texture == .linen {
                                    fibers.move(to: CGPoint(x: x + 36, y: y))
                                    fibers.addLine(to: CGPoint(x: x + 36.3, y: y + tile))
                                }
                            }
                        }
                    }
                    let ink: Color = scheme == .dark ? .white : .black
                    context.fill(grain, with: .color(ink.opacity(opacity)))
                    context.stroke(fibers, with: .color(ink.opacity(opacity * 0.55)), lineWidth: 0.5)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct NewspaperMotionModifier<Value: Equatable>: ViewModifier {
    let value: Value
    @AppStorage(NewspaperEditionPreferences.motionDuration, store: NewspaperPreferences.presentationStore) private var duration = 0.28
    @AppStorage(NewspaperEditionPreferences.motionSpring, store: NewspaperPreferences.presentationStore) private var spring = true
    @Environment(\.accessibilityReduceMotion) private var reduced
    func body(content: Content) -> some View {
        content.animation(OmnibarMotionPreferences(duration: duration, usesSpring: spring).animation(reducedMotion: reduced), value: value)
    }
}
extension View {
    func newspaperMotion<Value: Equatable>(_ value: Value) -> some View { modifier(NewspaperMotionModifier(value: value)) }
}

@MainActor enum NewspaperEditionPreparation {
    static func prepare(context: ModelContext, defaults: UserDefaults = NewspaperPreferences.presentationStore, locale: Locale = .current, includeWelcome: Bool = true) async {
        await Task.yield()
        guard !Task.isCancelled else { return }
        let firstEdition = !defaults.bool(forKey: NewspaperEditionPreferences.prepared)
        let articles = (try? context.fetch(FetchDescriptor<NewspaperArticle>())) ?? []
        if defaults.object(forKey: NewspaperEditionPreferences.style) == nil {
            let regional = defaults.object(forKey: NewspaperEditionPreferences.regionalStyle) as? Bool ?? true
            let illustrated = !articles.isEmpty && articles.filter { $0.leadImage != nil }.count * 2 > articles.count
            let style = regional ? NewspaperEditionStyle.recommendation(region: locale.region?.identifier, language: locale.language.languageCode?.identifier, illustrated: illustrated) : .metropolitan
            defaults.set(style.rawValue, forKey: NewspaperEditionPreferences.style)
            // Existing reader choices always win over a recommendation.
            if defaults.object(forKey: NewspaperPreferences.Key.layout) == nil { defaults.set(style.recommendedLayout.rawValue, forKey: NewspaperPreferences.Key.layout) }
        }
        defaults.set(true, forKey: NewspaperEditionPreferences.prepared)
        guard firstEdition, includeWelcome else { return }
        addWelcomeIfEmpty(context: context, defaults: defaults)
    }
    static func addWelcomeIfEmpty(context: ModelContext, defaults: UserDefaults = NewspaperPreferences.presentationStore) {
        guard (try? context.fetchCount(FetchDescriptor<NewspaperArticle>())) == 0,
              !defaults.bool(forKey: NewspaperEditionPreferences.welcomeAdded),
              defaults.object(forKey: NewspaperEditionPreferences.welcomeEnabled) as? Bool ?? true else { return }
        let store = NewspaperStore(modelContext: context)
        for entry in NewspaperWelcomeArticles.entries {
            let item = store.enqueue(url: entry.url, title: entry.article.title, section: "Getting Started").article
            store.finishCapture(item, article: entry.article)
        }
        defaults.set(true, forKey: NewspaperEditionPreferences.welcomeAdded)
    }
}

/// Bundled excerpts of the author's public pages, attributed and available
/// offline. No fake stories and no requests to fill an empty first edition.
enum NewspaperWelcomeArticles {
    struct Entry { let url: URL; let article: ReaderArticle }
    static let entries = [
        Entry(url: URL(string: "https://nathanfennel.com/blog/straight-up-browser")!, article: ReaderArticle(
            title: "A Browser I Made for Myself", byline: "Nathan Fennel · Launch-story excerpt",
            blocks: [
                .paragraph(runs: [.plain("The world did not need another browser. I built one anyway. It is my browser, it runs on macOS, and the download is smaller than most email attachments.")]),
                .heading(level: 2, runs: [.plain("A simpler browser")]),
                .paragraph(runs: [.plain("Every browser I've used lately wants to be a platform. Sync this, sign in to that, here's a sidebar of AI features, here's your shopping assistant. I want my browser to be a window: type an address, see the page, get out of the way.")]),
                .paragraph(runs: [.plain("So in January I started building one for myself. The name tells you the design philosophy: it's straight up a browser, nothing bolted on. On your Mac it installs as Browser.app, because once it's on your machine, that's all it is.")]),
                .heading(level: 2, runs: [.plain("The whole thing is a keyboard")]),
                .paragraph(runs: [.plain("The reason the UI can be this simple is that you're not supposed to touch it. The browser is keyboard driven from end to end, and the goal is to never need your mouse.")]),
                .paragraph(runs: [.plain("Hit ⌃Space or ⌘K, type a URL or a search or the name of a tab you already have open, hit return. That's the center of the app. There's a system-wide hotkey (⌥Space) that summons the same bar over whatever app you're in, so look something up no longer means find the browser first. Every tab, page, and navigation action has a key command, and ⇧⌘H pops a cheat sheet of all of them when you forget one.")]),
                .paragraph(runs: [.plain("This is an excerpt from the original launch story, preserved from July 15, 2026. Open the source for the complete post and the current download page for today's features.")])
            ], publication: "Nathan Fennel", section: "Getting Started", publishedAt: Date(timeIntervalSince1970: 1784073600))),
        Entry(url: URL(string: "https://nathanfennel.com/internet/support")!, article: ReaderArticle(
            title: "Browser: Help & Support", byline: "Nathan Fennel · Support-page excerpt",
            blocks: [
                .heading(level: 2, runs: [.plain("First things to try")]),
                .paragraph(runs: [.plain("A page will not load: reload it, then try the same address in Safari to check whether the site or connection is down. If it works there, check Enable JavaScript in Web Content settings and temporarily test without the content blocker.")]),
                .paragraph(runs: [.plain("The app is behaving strangely: close the affected tab and open it again. If the problem affects every tab, fully quit and reopen Browser. Your normal tabs and bookmarks are saved; incognito tabs are intentionally temporary.")]),
                .paragraph(runs: [.plain("A site has stale or broken state: clear data for that site from the page actions menu. For a wider reset, Privacy settings can clear browsing history, cookies, cache, and local storage. This may sign you out of websites.")]),
                .heading(level: 2, runs: [.plain("Private sync")]),
                .paragraph(runs: [.plain("On every device, sign in to the same Apple Account and make sure iCloud is available. In Browser Settings, turn on Sync browser data across your devices. The main sync switch takes effect after you relaunch Browser. Sync can take a little time after a device comes back online, but changes are saved locally first.")]),
                .paragraph(runs: [.plain("Open the source page for the complete support guide. Contact support@100apps.studio with what you expected, what happened instead, your Browser version and device model. Remove account details, API keys and other secrets from reports.")])
            ], publication: "Browser Support", section: "Getting Started"))
    ]
}
