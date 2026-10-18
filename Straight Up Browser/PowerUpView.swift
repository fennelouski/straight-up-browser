#if os(macOS)
import AppKit
import SwiftUI

struct PowerUpSkill: Identifiable {
    let id: PowerUpFeatureID
    let title: String
    let benefit: String
    let category: String
    let aliases: String
    let commandID: String?
    let steps: Int

    static let all: [Self] = [
        .init(id: .globalOmnibar, title: "Open Browser from anywhere", benefit: "Bring up the omnibar without hunting for a window.", category: "Navigate", aliases: "global search hotkey open from anywhere omnibar", commandID: nil, steps: 3),
        .init(id: .quickOpen, title: "Find a page from the keyboard", benefit: "Use Quick Open to reach a tab, address or search.", category: "Shortcuts", aliases: "quick open search navigation keyboard commands", commandID: "quickOpen", steps: 2),
        .init(id: .splitLayout, title: "Build a five-pane view", benefit: "Keep a large reference beside four useful perspectives.", category: "Arrange", aliases: "split layout five panes large left four right", commandID: "arrangePanes", steps: 2),
        .init(id: .swapPanes, title: "Swap without rebuilding", benefit: "Trade two pane contents while keeping the structure.", category: "Arrange", aliases: "swap panes move rearrange arrangement", commandID: "arrangePanes", steps: 3),
        .init(id: .savedWorkspace, title: "Restore your setup", benefit: "Save an arrangement deliberately and return to it.", category: "Workspaces", aliases: "saved workspace preset restore my setup recipe", commandID: "arrangePanes", steps: 3),
        .init(id: .centerWindow, title: "Center at the right width", benefit: "Cycle centered widths at the full usable display height.", category: "Arrange", aliases: "window center width half third quarter snap", commandID: "windowSnapTop", steps: 3)
    ]

    static var activeGlobalBinding: String? {
        let allowed = ["optSpace", "ctrlOptSpace"]
        switch GlobalHotkeyStatus.shared.state {
        case .registered(let chord): return allowed.contains(chord) ? chord : nil
        case .failed:
            guard let retained = GlobalOmnibarHotkey.appliedBinding, allowed.contains(retained) else { return nil }
            return retained
        case .disabled: return nil
        }
    }
    func binding() -> String {
        if id == .globalOmnibar {
            guard let chord = Self.activeGlobalBinding else { return "Not assigned or unavailable" }
            let display = chord == "ctrlOptSpace" ? "⌃⌥Space" : "⌥Space"
            if case .failed = GlobalHotkeyStatus.shared.state { return display + " (previous working shortcut)" }
            return display
        }
        guard let commandID,
              let command = ShortcutCommand.availableOnCurrentPlatform.first(where: { $0.id == commandID }) else {
            return commandID == "arrangePanes" ? "Window → Arrange Panes" : "Set shortcut in Settings → Shortcuts"
        }
        return ShortcutStore.shared.shortcut(for: command).displayString
    }

    func matches(_ query: String) -> Bool {
        let haystack = "\(title) \(benefit) \(category) \(aliases) \(binding())"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            haystack.contains(String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
    }
}

struct PowerUpView: View {
    private enum Filter: String, CaseIterable { case forYou = "For you", all = "All skills", known = "Known" }
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var filter: Filter = .forYou
    @State private var category = "All categories"
    @State private var practice: PowerUpSkill?
    @State private var knownUndo: (PowerUpFeatureID, PowerUpRecord, PowerUpRecord)?
    @State private var confirmDeletion = false
    private var learning: PowerUpLearning { .shared }

    private var skills: [PowerUpSkill] {
        PowerUpSkill.all.filter { skill in
            skill.matches(query) && (category == "All categories" || category == skill.category)
                && (filter == .all || (filter == .known
                    ? learning.record(for: skill.id).knowledge == .mastered
                    : learning.isRecommended(skill.id)))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("A little faster. On your terms.").font(.title2.weight(.semibold)).id("power-up.library")
                Text("Find a useful move, try it safely, and leave the rest for later.").foregroundStyle(.secondary)
                TextField("Find a skill, shortcut, or way to work", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("power-up-search")
                ViewThatFits(in: .horizontal) {
                    HStack { filters; categories }
                    VStack(alignment: .leading) { filters; categories }
                }
                if filter == .known { Text("Already familiar. Revisit any skill whenever you like.").font(.callout).foregroundStyle(.secondary) }
                if skills.isEmpty {
                    ContentUnavailableView("No matching skills", systemImage: "magnifyingglass", description: Text("Try a task like ‘split’ or ‘open from anywhere,’ or choose All skills."))
                }
                ForEach(skills) { skill in skillCard(skill) }
                if let undo = knownUndo {
                    HStack {
                        Text("Marked as known.").font(.callout)
                        Spacer()
                        Button("Undo") {
                            // A later successful action wins over an old UI undo.
                            if learning.record(for: undo.0) == undo.2 { learning.restore(undo.1, for: undo.0) }
                            knownUndo = nil
                        }
                    }
                    .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                learningPreferences.id("power-up.learning")
                if !learning.supportsCurrentSchema {
                    Text("Learning data was saved by a newer Browser version. It is preserved, and this version can still show the library.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Open the Getting Started Guide") { openGuide() }
                    .help("Resume the existing guide without resetting its progress or earlier decision.")
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $practice) { PowerUpPracticeView(skill: $0) }
        .confirmationDialog("Delete Power Up learning history?", isPresented: $confirmDeletion) {
            Button("Delete learning history", role: .destructive) { learning.deleteHistory(); knownUndo = nil }
            Button("Keep history", role: .cancel) {}
        } message: {
            Text("This clears local action counts, knowledge and dismissal preferences. Your browser preferences and Getting Started progress stay as they are.")
        }
    }

    private var filters: some View {
        Picker("Skills", selection: $filter) {
            ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented)
    }
    private var categories: some View {
        Picker("Category", selection: $category) {
            ForEach(["All categories", "Navigate", "Arrange", "Workspaces", "Shortcuts"], id: \.self) { Text($0).tag($0) }
        }.labelsHidden().fixedSize()
    }
    private func skillCard(_ skill: PowerUpSkill) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(skill.category).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(skill.title).font(.headline)
            Text(skill.benefit).font(.callout).fixedSize(horizontal: false, vertical: true)
            if filter == .forYou {
                Text("Explore this skill when it helps.").font(.caption).foregroundStyle(.secondary)
            }
            if learning.record(for: skill.id).knowledge == .suppressed {
                Text("Suggestions suppressed. You can still practice or reset this skill.").font(.caption).foregroundStyle(.secondary)
            }
            Text(skill.binding()).font(.system(.callout, design: .monospaced))
                .accessibilityLabel("Current command: \(skill.binding())")
            if skill.commandID == "arrangePanes" {
                Text("Window → Arrange Panes opens the arrangement and saved-workspace panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(skill.steps) practice steps · Safe sample preview available").font(.caption).foregroundStyle(.secondary)
            if learning.adaptiveEnabled {
                let record = learning.record(for: skill.id)
                Text("Local counts: \(record.shortcutUses) keyboard actions, \(record.directUses) menu/button actions. Counts expire within 90 days.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Learn / Try") { practice = skill }
                Button("I know this") {
                    let previous = learning.markKnown(skill.id)
                    knownUndo = (skill.id, previous, learning.record(for: skill.id))
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Not now — hide for 30 days") { learning.snooze(skill.id) }
                    Button("Don’t suggest this") { learning.suppress(skill.id) }
                    Button("Reset this skill") { learning.reset(skill.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options for \(skill.title)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.13)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("power-up-skill-\(skill.id.rawValue)")
    }
    private var learningPreferences: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Learning on this Mac").font(.headline)
            Toggle("Use local Browser action counts for adaptive help", isOn: Binding(get: { learning.adaptiveEnabled }, set: { learning.setAdaptiveEnabled($0) }))
            Text("Off by default. Search and practice always work. When enabled, Power Up keeps bounded action counts and learning choices for these skills on this Mac; it receives no typed text, page titles, URLs or clipboard contents.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Pause tips until I resume them", isOn: Binding(get: { learning.tipsPaused }, set: { learning.setTipsPaused($0) }))
            Text("Suggestions stay in this library. Contextual teaching is held until Browser can verify a safe, relevant moment.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Delete learning history…") { confirmDeletion = true }
        }
        .disabled(!learning.supportsCurrentSchema)
    }
    private func openGuide() {
        let windows = BrowserWindows.shared
        let id = windows.activeID ?? windows.primaryID
        if !windows.hasWindows { openWindow(id: "browser", value: id) }
        windows.window(id)?.makeKeyAndOrderFront(nil)
        BrowserOnboarding.shared.show(in: id)
    }
}

private struct PowerUpPracticeView: View {
    let skill: PowerUpSkill
    @Environment(\.dismiss) private var dismiss
    @State private var sample = PowerUpSamplePractice()
    @State private var waitingForGlobal = false
    @State private var globalOpened = false
    @State private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(skill.title).font(.title2.weight(.semibold))
            Text("Practice uses sample content. Your open tabs, calls and workspace stay in place.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if skill.id == .globalOmnibar || skill.id == .quickOpen { omnibarLesson }
                    else { sampleLesson }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if sample.completed { Label("Sample practice completed", systemImage: "checkmark.circle").font(.callout) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(minWidth: 460, idealWidth: 560, minHeight: 450, idealHeight: 560)
        .accessibilityIdentifier("power-up-practice")
        .onReceive(NotificationCenter.default.publisher(for: .powerUpConfirmedAction)) { note in
            guard waitingForGlobal, note.userInfo?["feature"] as? String == PowerUpFeatureID.globalOmnibar.rawValue else { return }
            globalOpened = true; waitingForGlobal = false
            PowerUpLearning.shared.recordSuccess(feature: .globalOmnibar, method: .practice, isPrivate: false)
        }
    }

    private var omnibarLesson: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Current binding: \(skill.binding())").font(.headline)
            Text("The global omnibar searches and opens addresses using Browser’s existing search, suggestions and provider settings. Review General and Agent to choose those behaviors.")
            if skill.id == .globalOmnibar {
                if PowerUpSkill.activeGlobalBinding != nil {
                    Button("Start outside-app practice") { waitingForGlobal = true; globalOpened = false }
                    if waitingForGlobal {
                        Text("Switch to another app yourself, then invoke the registered shortcut. This lesson waits for Browser to confirm the omnibar opened; it does not monitor your keys or other apps.")
                        Button("Didn’t open? Configure shortcut") { openSettings(.general, section: "general.behavior") }
                    }
                    if globalOpened { Label("Opened — confirmed by Browser", systemImage: "checkmark.circle") }
                } else {
                    Text("The global shortcut is Off or unavailable. Choose another combination in General before outside-app practice.")
                    Button("Configure global shortcut") { openSettings(.general, section: "general.behavior") }
                }
            } else {
                Text("Use the displayed binding while a Browser window is active. The normal command reference and its custom shortcuts stay available in Settings.")
                Button("Configure shortcuts") { openSettings(.shortcuts, section: "shortcuts.keyboard") }
            }
            Button(showPreview ? "Hide sample preview" : "Show sample preview") { showPreview.toggle() }
            if showPreview {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Address and Search — sample", systemImage: "magnifyingglass").font(.headline)
                    Text("A place to enter an address, find a tab, or search.")
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Text("This is a preview. Opening it does not count as successful native practice or mastery.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sampleLesson: some View {
        VStack(alignment: .leading, spacing: 12) {
            if skill.id == .centerWindow {
                Text("Cycle 50% → 33⅓% → 25%. Every sample stays centered at full usable height.")
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2))
                        .frame(width: geometry.size.width * sample.centerRatio, height: geometry.size.height)
                        .overlay(Text(sample.centerLabel).font(.headline))
                        .frame(maxWidth: .infinity)
                }.frame(height: 150).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Button("Cycle sample width") { sample.cycleWidth(); finishSampleIfNeeded() }
                Text("The real command skips widths that cannot fit the browser window’s minimum size. Display and Dock bounds determine usable height.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(skill.id == .swapPanes ? "Choose a source, then a target. Review the sample swap before applying it." : skill.id == .savedWorkspace ? "Save this sample arrangement, change it, then restore the saved sample." : "Choose the large-left + four-right arrangement, then resize its leading divider.")
                samplePanes
                if skill.id == .splitLayout {
                    Button("Choose five-pane sample") { sample.selectFivePane() }
                    Slider(value: $sample.leadingRatio, in: 0.3...0.65).accessibilityLabel("Leading sample pane width")
                        .onChange(of: sample.leadingRatio) { _, _ in sample.resize(); finishSampleIfNeeded() }
                }
                if skill.id == .swapPanes {
                    if let preview = sample.swapPreview {
                        Text("Swap \(preview.0) with \(preview.1)? Layout sizes stay the same.")
                        HStack {
                            Button("Apply sample swap") { sample.applySwap(); finishSampleIfNeeded() }
                            Button("Cancel swap") { sample.cancelSwap() }
                        }
                    } else { Button("Cancel selection") { sample.cancelSwap() }.disabled(sample.source == nil) }
                }
                if skill.id == .savedWorkspace {
                    HStack {
                        Button("Save sample arrangement") { sample.saveSample() }
                        Button("Change sample") { sample.changeSample() }.disabled(!sample.hasSaved)
                        Button("Restore sample") { sample.restoreSample(); finishSampleIfNeeded() }.disabled(!sample.hasChangedSaved)
                    }
                    Text("Real workspace presets show what will reopen before saving. They are recipes, and do not save call state or form values.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onExitCommand { if sample.source != nil { sample.cancelSwap() } else { dismiss() } }
    }
    private var samplePanes: some View {
        GeometryReader { geometry in
            HStack(spacing: 6) {
                paneButton(0)
                    .frame(width: sample.fivePane || skill.id != .splitLayout ? (geometry.size.width - 6) * sample.leadingRatio : geometry.size.width)
                if sample.fivePane || skill.id != .splitLayout {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) { paneButton(1); paneButton(2) }
                        HStack(spacing: 6) { paneButton(3); paneButton(4) }
                    }.frame(maxWidth: .infinity)
                }
            }
        }.frame(height: 180)
    }
    private func paneButton(_ index: Int) -> some View {
        Button { if skill.id == .swapPanes { sample.select(index) } } label: {
            Text(sample.contents[index]).font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.accentColor.opacity(sample.source == index ? 0.24 : 0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
        }.buttonStyle(.plain).accessibilityLabel("Sample pane \(index + 1): \(sample.contents[index])")
    }
    private func finishSampleIfNeeded() {
        guard sample.completed else { return }
        PowerUpLearning.shared.recordSuccess(feature: skill.id, method: .practice, isPrivate: false)
    }
    private func openSettings(_ pane: SettingsPane, section: String) {
        UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
        SettingsSearchNavigation.shared.pendingScrollID = section
        dismiss()
    }
}

extension Notification.Name { static let powerUpConfirmedAction = Notification.Name("browserPowerUpConfirmedAction") }
#endif
