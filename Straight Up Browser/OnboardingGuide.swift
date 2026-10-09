#if os(macOS)
import AppKit
import SwiftUI

enum OnboardingAction { case omnibar, hideOmnibar, shortcuts, workspace, document, translationPacks, newWindow }

struct BrowserOnboardingPresentation: ViewModifier {
    let windowID: UUID
    let action: (OnboardingAction) -> Void
    @ObservedObject private var guide = BrowserOnboarding.shared
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
        .accessibilityHidden(guide.windowID == windowID && (guide.invitation || guide.progress.track == nil))
        .overlayPreferenceValue(OnboardingAnchors.self) { anchors in
            GeometryReader { geometry in
                if guide.windowID == windowID {
                    let focus = guide.step?.target.flatMap { anchors[$0] }.map { geometry[$0] }
                    OnboardingOverlay(guide: guide, size: geometry.size, focus: focus, action: action)
                }
            }
        }
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard !args.contains("-uiTesting") || args.contains("-onboardingUITesting") else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let window = BrowserWindows.shared.window(windowID) else { return }
            let size = window.screen?.visibleFrame.size ?? window.frame.size
            let context = OnboardingContext.make(screenSize: size,
                hour: Calendar.current.component(.hour, from: .now), dark: colorScheme == .dark)
            guide.offer(in: windowID, context: context)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let window = note.object as? NSWindow, BrowserWindows.shared.window(windowID) === window {
                guide.windowClosed(windowID)
            }
        }
        .onChange(of: guide.windowID) { _, id in
            if id == windowID, guide.step == nil || guide.invitation { action(.hideOmnibar) }
        }
    }
}

private struct OnboardingOverlay: View {
    @ObservedObject var guide: BrowserOnboarding
    let size: CGSize
    let focus: CGRect?
    let action: (OnboardingAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var overview: Bool { guide.invitation || guide.progress.track == nil || guide.progress.track == .quickStart }
    private var width: CGFloat { min(overview ? 650 : 440, max(280, size.width - 32)) }
    private var height: CGFloat {
        let ideal: CGFloat = guide.invitation ? 330 : guide.progress.track == nil ? 445 : overview ? 720 : 620
        return min(ideal, max(240, size.height - 40))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if !guide.invitation {
                if let focus { OnboardingSpotlight(focus: focus, moves: guide.animations) }
                let destination = shuttlePosition
                OnboardingShuttle(destination: destination, angle: shuttleAngle(from: destination),
                    moves: guide.animations, spring: guide.spring)
            }
            if !guide.minimized {
                if guide.invitation { Color.black.opacity(0.25).ignoresSafeArea() }
                OnboardingGuideCard(guide: guide, action: action)
                    .frame(width: width)
                    .frame(maxHeight: height)
                    .padding(overview ? 0 : 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: overview ? .center : .bottomTrailing)
                    .transition(BrowserMotion.panel)
            } else {
                Button { guide.minimized = false } label: {
                    HStack {
                        OnboardingAstronaut(pose: .floating, moves: false, spring: false).frame(width: 32, height: 38)
                        Text("Continue your guide").fontWeight(.medium)
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(BrowserPressStyle())
                .background(.regularMaterial, in: Capsule())
                .padding(18)
                .accessibilityIdentifier("onboarding-resume")
                .transition(BrowserMotion.panel)
            }
        }
        .animation(guide.animations && !reduceMotion
            ? (guide.spring ? .spring(response: 0.38, dampingFraction: 0.88) : .easeInOut(duration: 0.25)) : nil,
            value: guide.minimized)
    }

    private var shuttlePosition: CGPoint {
        guard let focus, !guide.invitation else {
            return CGPoint(x: max(45, (size.width - width) / 2 - 28), y: max(65, size.height / 2 - 130))
        }
        let x = focus.width > 200 ? focus.minX + 50 : focus.maxX + 65
        return CGPoint(x: min(size.width - 45, max(45, x)), y: min(size.height - 55, max(55, focus.minY + 65)))
    }
    private func shuttleAngle(from point: CGPoint) -> Double {
        guard let focus else { return 30 }
        return atan2(focus.midY - point.y, focus.midX - point.x) * 180 / .pi + 90
    }
}

private struct OnboardingGuideCard: View {
    @ObservedObject var guide: BrowserOnboarding
    let action: (OnboardingAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pose: OnboardingAstronautPose { .forLesson(guide.step) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                OnboardingAstronaut(pose: pose, moves: guide.animations, spring: guide.spring)
                    .frame(width: 68, height: 96)
                VStack(alignment: .leading, spacing: 5) {
                    Text(guide.invitation ? "Welcome aboard" : guide.step?.title ?? "Choose your flight")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text(guide.invitation ? "A little guidance, at your pace." : guide.progress.track?.title ?? "Three ways to get to know Browser.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !guide.invitation {
                    Button { guide.minimized = true } label: { Image(systemName: "minus") }
                        .help("Minimize the guide while you try a feature")
                        .accessibilityLabel("Minimize guide")
                        .accessibilityIdentifier("onboarding-minimize")
                }
            }.padding(.horizontal, 22).padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if guide.invitation { invitation }
                    else if guide.progress.track == nil { chooser }
                    else if let step = guide.step {
                        OnboardingLesson(step: step, guide: guide, action: action)
                            .id(step).transition(.opacity.combined(with: .offset(y: 7)))
                    }
                }.padding(.horizontal, 24).padding(.vertical, 14)
            }
            .animation(guide.animations && !reduceMotion ? .easeInOut(duration: 0.22) : nil, value: guide.step)

            if !guide.invitation { footer }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
    }

    private var invitation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(guide.progress.decision == .learning
                 ? "Your guide is saved. Pick up where you left off, or explore on your own."
                 : "Want a hand getting started? We can cover the essentials, make a few personal choices, or explore Browser in depth.")
            Button("Show me around") { guide.accept() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-show")
            HStack {
                Button("Maybe later") { guide.later() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("onboarding-later")
                Spacer()
                Button("I’m ready to explore") { guide.decline() }.accessibilityIdentifier("onboarding-decline")
            }
            Text("You can always open the guide from Help → Getting Started Guide.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chooser: some View {
        VStack(spacing: 12) {
            ForEach(OnboardingTrack.allCases) { track in
                Button { guide.choose(track) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: track == .quickStart ? "bolt" : track == .customization ? "slider.horizontal.3" : "sparkles")
                            .font(.title2).foregroundStyle(.blue).frame(width: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(track.title).font(.headline)
                            Text(track.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(BrowserPressStyle()).accessibilityIdentifier("onboarding-track-" + track.rawValue)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider()
            HStack {
                Menu {
                    Toggle("Animate the guide", isOn: $guide.animations).onChange(of: guide.animations) { guide.saveMotion() }
                    Toggle("Use spring motion", isOn: $guide.spring).onChange(of: guide.spring) { guide.saveMotion() }
                        .disabled(!guide.animations)
                    Divider()
                    Button("Choose another guide") { guide.changeTrack() }
                    Button("Save and close guide") { guide.pause() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Guide options")
                if guide.progress.track != nil {
                    Text("\(guide.position + 1) of \(guide.steps.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if guide.position > 0 {
                        Button("Back") { guide.move(-1) }.accessibilityIdentifier("onboarding-back")
                    }
                    Button(guide.step == .finished || guide.progress.track == .quickStart ? "Start exploring" : "Next") {
                        if guide.step == .finished || guide.progress.track == .quickStart { guide.finish() }
                        else { guide.move(1) }
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding-next")
                } else {
                    Spacer()
                    Button("Save for later") { guide.pause() }
                }
            }.padding(.horizontal, 22).padding(.bottom, 18)
        }
    }
}

private struct OnboardingLesson: View {
    let step: OnboardingStep
    @ObservedObject var guide: BrowserOnboarding
    let action: (OnboardingAction) -> Void
    @Environment(\.openSettings) private var openSettings
    @AppStorage("memorySaverEnabled") private var memory = false
    @AppStorage("showTraditionalTopTabs") private var topTabs = false
    @AppStorage("topTabsAutoHide") private var topAutoHide = true
    @AppStorage("tabBarWidth") private var sidebarWidth = 200.0
    @AppStorage("pageWhitePoint") private var whitePoint = 100.0
    @AppStorage("downloadsFolder") private var downloadFolder = ""
    @AppStorage(SettingsManager.aiFeaturesKey) private var ai = true
    @AppStorage(BrowserWindows.nativeFullScreenKey) private var fullScreen = false
    @State private var folderError = false
    @State private var defaultResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            switch step {
            case .essentials: essentials
            case .interests: interests
            case .navigation: navigation
            case .appearance: appearance
            case .windows: windows
            case .memory: memoryChoice
            case .workspaces: workspaceLesson
            case .sources: sourceLesson
            case .documents: documentLesson
            case .splits: splitLesson
            case .screenshots: screenshots
            case .downloads: downloads
            case .translation: translation
            case .newspaper: newspaper
            case .ai: aiChoice
            case .automation: automation
            case .finished:
                Text("Your browser, your pace. Nothing here is a one-time choice: Settings keeps your preferences, and Help keeps this guide.")
                Text("Try a project workspace next. Give it a name, open two useful pages, and keep the sources worth returning to.")
                Button("Create a workspace") { tryFeature(.workspace) }
            }
        }.font(.system(size: 13))
    }

    private var essentials: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("The essentials to start browsing.")
            keys([.openLocation, .omnibar, .quickOpen, .newTab, .closeTab, .reopenTab, .nextTab, .findInPage])
            Text("Type an address, a search, or the name of an open tab in the omnibar. Alternative opening keys work when a website claims a shortcut.")
            HStack {
                Button("Try the omnibar") { tryFeature(.omnibar) }
                Button("Show all key commands") { tryFeature(.shortcuts) }
            }
            Text("Find commands any time in Help → Keyboard Shortcuts or Settings → Shortcuts. The keys below follow your custom bindings.")
                .font(.caption).foregroundStyle(.secondary)
            memoryChoice
            Button("Make Browser my default") { makeDefault() }
            if let defaultResult { Text(defaultResult).foregroundStyle(.secondary) }
            if guide.context.largeScreen { windowKeys }
        }
    }
    private var interests: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Do you work in any of these areas? We’ll include screenshot and appearance tools when they’re useful. This choice stays on your Mac.")
            ForEach(OnboardingRole.allCases) { role in
                Toggle(role.rawValue, isOn: Binding(get: { guide.progress.roles.contains(role) }, set: { _ in guide.toggleRole(role) }))
                    .toggleStyle(.checkbox)
            }
            Text("None of these? Just continue. You can still find every feature in Help.").foregroundStyle(.secondary)
        }
    }
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One field for addresses, searches, history, bookmarks, and open tabs. Start typing as soon as it opens.")
            keys([.openLocation, .omnibar, .quickOpen, .newTab, .nextTab, .reopenTab, .shortcutOverlay])
            Text("The alternate keys are handy when a website uses the same command. Rebind commands in Settings → Shortcuts; this guide shows your actual bindings.")
            HStack {
                Button("Try the omnibar") { tryFeature(.omnibar) }
                Button("Show key commands") { tryFeature(.shortcuts) }
            }
            settingsButton("Customize shortcuts", .shortcuts, "shortcuts.keyboard")
        }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(guide.context.nightInDarkMode ? "A dark room, a dark browser… and a bright white page? Bring the page down to a comfortable brightness." : "Choose where your tabs live, then make bright pages comfortable to read.")
            HStack {
                Button("Side tabs") { topTabs = false; sidebarWidth = max(200, sidebarWidth) }
                    .buttonStyle(.borderedProminent).tint(topTabs ? .gray : .blue)
                Button("Top tabs") { topTabs = true; topAutoHide = false; sidebarWidth = 0 }
                    .buttonStyle(.borderedProminent).tint(topTabs ? .blue : .gray)
            }
            Text("The browser changes as you choose. Settings → Appearance can also put the sidebar on the right.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Max page brightness").fontWeight(.semibold); Spacer(); Text("\(Int(whitePoint))%").monospacedDigit() }
                Slider(value: $whitePoint, in: 25...100, step: 5).accessibilityLabel("Max page brightness")
                Text("Lower this to dim white page backgrounds while keeping dark text readable. 100% leaves pages unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Text("A bright page"); Spacer(); Text("Aa").font(.title2) }
                    .foregroundStyle(.black).padding(15)
                    .background(Color(white: min(1, max(0.25, whitePoint / 100))), in: RoundedRectangle(cornerRadius: 10))
            }
            settingsButton("Theme, brightness schedule, and appearance", .appearance, "appearance.white-point")
        }
    }
    private var memoryChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable memory saving", isOn: $memory).accessibilityIdentifier("onboarding-memory")
            Text("Let idle tabs release memory when needed. Returning to a released tab reloads it. Sites you always need ready can be kept in memory from their tab menu.")
                .font(.caption).foregroundStyle(.secondary)
            settingsButton("Review memory policies", .memory, "memory.saving")
        }
    }
    private var windows: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your display has room to spread out. Use these keys to move a window to each half of the screen.")
            windowKeys
            Text("⌘N opens another window with its own workspace. File → Rename Window gives it a useful name.")
            Toggle("Use native full-screen Spaces", isOn: $fullScreen)
            keys([.fullScreen])
            Text("With this on, each full-screen window gets its own macOS Space. Browser chrome stays hidden; your configured trackpad gesture moves between Spaces. The omnibar still opens immediately.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open a new window") { tryFeature(.newWindow) }
        }
    }
    private var windowKeys: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Room to move").font(.headline)
            keys([.windowSnapLeft, .windowSnapRight, .windowSnapTop, .windowSnapBottom, .windowLayout])
        }
    }
    private var workspaceLesson: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A workspace keeps a project’s tabs, sources, and documents together. Give research, planning, and personal browsing separate homes.")
            lesson("1. Give it a name", "Open the folder menu in the sidebar → Turn This Into a Workspace. Your current tabs become the workspace’s tabs. A new window already starts with a workspace of its own.")
            lesson("2. Come back to it", "The same folder menu lists saved workspaces. Switching one window’s workspace doesn’t change the other windows.")
            lesson("3. Keep identity separate", "Groups organize tabs within a workspace. Containers keep site sign-ins separate. A workspace is the project around them.")
            Button("Name a workspace") { tryFeature(.workspace) }
            Text("If the folder menu is hidden, select Side tabs in the appearance step or show the sidebar with its keyboard command.")
                .font(.caption).foregroundStyle(.secondary)
            keys([.toggleTabBar])
        }
    }
    private var sourceLesson: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browsing is exploration. Capturing a source says ‘this one matters’. The workspace ledger preserves what you keep so it can support the work you write later.")
            keys([.captureSource, .anchorSelection])
            lesson("Keep a source", "Capture a useful page into the workspace. Highlight a precise passage and anchor the selection when the exact evidence matters.")
            lesson("Close with intention", "Closing a source tab rejects that source. Closing the workspace preserves its tabs. Archive the workspace when the project is done, keeping the sources you captured.")
            lesson("Follow the evidence", "Use the graph and audit view to revisit sources and see how they connect to the project.")
            keys([.auditView, .bibliographySearch])
        }
    }
    private var documentLesson: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workspaces hold documents as well as pages. Keep notes beside the source you’re reading, then turn anchored evidence into a draft.")
            lesson("Write next to your sources", "Use New Document in the sidebar. A document can occupy a split pane alongside a page.")
            lesson("Connect claims to evidence", "Anchor selected text into a document, search the bibliography, and use Claims & Research Plan to organize the next questions.")
            keys([.newWorkspaceDocument, .anchorSelection, .claimsPanel, .transcriptPanel])
            Text("Open a workspace first. Documents use iCloud Drive, which needs to be available on your Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Create a workspace document") { tryFeature(.document) }
        }
    }
    private var splitLesson: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare, read, or write without switching back and forth. A split supports two, three, or four panes.")
            lesson("Two tabs side by side", "Right-click a background tab → Open in Split. The current tab stays beside it. Or Option-click a link to open its destination in a split pane.")
            lesson("Add a third or fourth", "Right-click another tab → Add to Split. Drag the dividers to give each pane the room it needs.")
            lesson("Return to one page", "Right-click a split tab → Remove from Split. This changes the arrangement without closing the tab.")
            Text("A workspace document can share the arrangement too. The split belongs to this window; other windows keep their own views.")
        }
    }
    private var screenshots: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture a design detail, a bug, or a product decision without leaving Browser.")
            keys([.screenshotVisible, .screenshotFullPage, .screenshotElement, .screenshotWindow])
            Text("Screenshots can go to the clipboard, a shared folder, or a folder for that shortcut. Choose PNG, JPEG, or PDF in Settings → Screenshots.")
            settingsButton("Choose screenshot destinations and formats", .screenshots, "screenshots.all")
            settingsButton("Adjust appearance for your work", .appearance, "appearance.white-point")
        }
    }
    private var downloads: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloads use your Mac’s Downloads folder by default. Pick another location only if it fits how you work.")
            Label(downloadFolder.isEmpty ? "System Downloads folder" : downloadFolder, systemImage: "folder")
                .lineLimit(2).textSelection(.enabled)
            HStack {
                Button("Choose a folder…") { chooseDownloads() }
                if !downloadFolder.isEmpty {
                    Button("Use Downloads folder") { DownloadFolderAccess.shared.useSystemDownloadsFolder(); downloadFolder = "" }
                }
            }
            if folderError { Text("Browser couldn’t save access to that folder. Choose it again or keep the Downloads folder.").foregroundStyle(.red) }
            keys([.showDownloads])
            settingsButton("More download settings", .downloads, "downloads.folder")
        }
    }
    private var translation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Page translation runs on your Mac. Set the languages you read and download language packs when you want offline translation.")
            keys([.toggleTranslation, .translateInSplit])
            Text("Hold Option over translated text to peek at the original. Right-click selected text to translate just that passage; View → Translate Page To/From chooses languages.")
            settingsButton("Languages and translation settings", .content, "content.translation")
            Button("Review offline language packs") { tryFeature(.translationPacks) }
        }
    }
    private var newspaper: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Newspaper is your place to collect articles and read them without the clutter of the original page.")
            lesson("Save something to read", "Use the newspaper menu → Add Current Page, or right-click a tab → Add to Newspaper. Saved article text is available offline.")
            lesson("Make it your reading space", "Open Newspaper from that menu. Settings → Newspaper controls layout, article length, and offline text.")
            Text("Use Reader Mode for a cleaner view of the page you’re reading right now.")
            keys([.readerMode])
            settingsButton("Customize Newspaper", .newspaper, "newspaper.layout")
        }
    }
    private var aiChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Want AI features? You choose the provider and model, connect your own account, and decide when to use it. A cloud provider may receive the content you send to it.")
            Text("Local and on-device options depend on what your Mac supports. Cloud models require your provider’s account or API credentials and may incur its usage charges.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Enable AI features and review setup") { ai = true; settings(.agent, nil) }
                .buttonStyle(.borderedProminent)
            Button("Keep AI features off") { ai = false }
            Text(ai ? "AI features are enabled. Provider setup remains your choice." : "AI features are off. You can enable them later in Settings.")
                .foregroundStyle(.secondary)
        }
    }
    private var automation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Would you like an external AI tool, such as Claude or Codex, to interact with Browser through its CLI or MCP server?")
            Text("Navigation and tab control have a master switch. Reading pages, running scripts, screenshots, and genuine mouse clicks each have separate permissions. Review what you want to allow before enabling access.")
            Button("Review agent permissions") { settings(.security, "security.agent-automation") }
                .buttonStyle(.borderedProminent)
            Button("Keep external-agent access off") { UserDefaults.standard.set(false, forKey: CLIAuthorization.Key.enabled) }
            Text("This guide does not grant permissions automatically. The Security pane includes the CLI location and client setup instructions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func keys(_ commands: [ShortcutCommand]) -> some View {
        VStack(spacing: 7) {
            ForEach(commands) { command in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(localized: command.title)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(ShortcutStore.shared.shortcut(for: command).displayString)
                        .font(.system(.body, design: .monospaced)).fontWeight(.medium)
                    if let alternate = ShortcutStore.shared.alternate(for: command) {
                        Text("or " + alternate.displayString).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
    private func lesson(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).fontWeight(.semibold)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func settingsButton(_ title: String, _ pane: SettingsPane, _ section: String?) -> some View {
        Button(title) { settings(pane, section) }
    }
    private func settings(_ pane: SettingsPane, _ section: String?) {
        UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
        SettingsSearchNavigation.shared.pendingScrollID = section
        openSettings()
    }
    private func tryFeature(_ feature: OnboardingAction) { guide.minimized = true; action(feature) }
    private func makeDefault() {
        Task {
            let result = await DefaultBrowser.makeDefault()
            defaultResult = result == .succeeded ? "Browser is your default browser." : "You can change this later in Settings → General."
        }
    }
    private func chooseDownloads() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.message = "Choose where Browser saves downloads"
        guard let id = guide.windowID, let window = BrowserWindows.shared.window(id) else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                folderError = !DownloadFolderAccess.shared.remember(url)
                if !folderError { downloadFolder = url.path }
            }
        }
    }
}
#endif
