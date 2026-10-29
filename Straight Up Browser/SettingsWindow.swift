//
//  SettingsWindow.swift
//  Straight Up Browser
//
//  The settings window: a sidebar of cards, each one a grouped Form. This file holds the
//  small design system behind it (one tint per area, a label that colours only its icon,
//  and the caption + "?" popover), the container, and the native token field for list
//  settings. The panes live in SettingsPanes.swift; their demos in SettingsDemos.swift.
//
//  Created by Nathan Fennel on 1/9/26.
//

import AppKit
import SwiftUI

// MARK: - Design system

/// Each area of settings owns a hue. The tint colours the *icon only* — the text stays in the
/// standard label colour — so the window reads as calm at a glance while each section is still
/// recognisable by its colour. Same idiom as System Settings.
enum SettingsTint {
    static let general = Color.blue
    static let agent = Color.purple
    static let content = Color.purple
    static let newspaper = Color.brown
    static let downloads = Color.teal
    static let appearance = Color.pink
    static let security = Color.orange
    static let privacy = Color.indigo
    static let memory = Color.mint
    static let shortcuts = Color.green
    static let screenshots = Color.cyan
    static let autofill = Color.brown
}

/// A settings row or section header: title in the standard text colour, icon in its area's tint.
/// A plain `Label` renders its icon in the accent colour, which would make every row blue.
struct SettingsLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color

    init(_ title: LocalizedStringKey, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}

// MARK: - Caption + info popover

/// A setting's caption with a trailing info button — the standard row under a control whose
/// effect is easier to show than to describe.
struct SettingCaptionRow<Value: Equatable, Demo: View>: View {
    let caption: LocalizedStringKey
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey
    @Binding var value: Value
    var settingID: BrowserSettingID? = nil
    @ViewBuilder let demo: (Binding<Value>) -> Demo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            SettingInfoButton(title: title, explanation: explanation, value: $value, settingID: settingID, demo: demo)
        }
    }
}

struct SettingInfoButton<Value: Equatable, Demo: View>: View {
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey
    @Binding var value: Value
    var settingID: BrowserSettingID? = nil
    @ViewBuilder let demo: (Binding<Value>) -> Demo

    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        // Without .plain the button's hit area swallows the whole Form row.
        .buttonStyle(BrowserPressStyle())
        .accessibilityLabel("Learn more")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            SettingInfoPopover(title: title, explanation: explanation, value: $value, settingID: settingID, demo: demo)
        }
    }
}

private struct SettingInfoPopover<Value: Equatable, Demo: View>: View {
    private enum Tab: Hashable { case demo, about }

    let title: LocalizedStringKey
    let explanation: LocalizedStringKey
    @Binding var value: Value
    var settingID: BrowserSettingID? = nil
    @ViewBuilder let demo: (Binding<Value>) -> Demo

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .demo
    /// What the demo actually edits. Seeded from the live value, written back only on Save.
    @State private var draft: Value
    @State private var draftID = UUID()
    @State private var showingCloseConfirmation = false

    init(
        title: LocalizedStringKey,
        explanation: LocalizedStringKey,
        value: Binding<Value>,
        settingID: BrowserSettingID? = nil,
        @ViewBuilder demo: @escaping (Binding<Value>) -> Demo
    ) {
        self.title = title
        self.explanation = explanation
        self._value = value
        self.settingID = settingID
        self.demo = demo
        self._draft = State(initialValue: value.wrappedValue)
    }

    private var isDirty: Bool { draft != value }

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: $tab) {
                Text("Demo").tag(Tab.demo)
                Text("About").tag(Tab.about)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Both tabs share a floor so switching between them doesn't resize the popover
            // out from under the pointer.
            Group {
                switch tab {
                case .demo:
                    demo($draft)
                case .about:
                    Text(explanation)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .top)

            Divider()

            HStack {
                Spacer()
                if isDirty {
                    Button("Cancel") { showingCloseConfirmation = true }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        saveAndDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .interactiveDismissDisabled(isDirty)
        .onAppear {
            updateDraftProtection()
            if let settingID { SettingsTransactionCoordinator.shared.setDraft(settingID, owner: draftID, isOpen: true) }
        }
        .onChange(of: isDirty) { _, _ in updateDraftProtection() }
        .onChange(of: showingCloseConfirmation) { _, shown in
            if !shown { SettingsDraftProtection.shared.keepEditing() }
        }
        .onDisappear {
            SettingsDraftProtection.shared.remove(draftID)
            if let settingID { SettingsTransactionCoordinator.shared.setDraft(settingID, owner: draftID, isOpen: false) }
        }
        .onExitCommand { if isDirty { showingCloseConfirmation = true } else { dismiss() } }
        .confirmationDialog("Save changes before closing?", isPresented: $showingCloseConfirmation) {
            Button("Save") { saveAndDismiss() }
            Button("Discard", role: .destructive) { discardAndDismiss() }
            Button("Keep editing", role: .cancel) { SettingsDraftProtection.shared.keepEditing() }
        } message: {
            Text("Your changes remain in the preview until you save them.")
        }
    }
    private func updateDraftProtection() {
        if isDirty {
            SettingsDraftProtection.shared.register(draftID) { showingCloseConfirmation = true }
        } else { SettingsDraftProtection.shared.remove(draftID) }
    }
    private func saveAndDismiss() {
        value = draft
        SettingsDraftProtection.shared.remove(draftID)
        dismiss()
        SettingsDraftProtection.shared.finishClose()
    }
    private func discardAndDismiss() {
        SettingsDraftProtection.shared.remove(draftID)
        dismiss()
        SettingsDraftProtection.shared.finishClose()
    }
}

// MARK: - Token field (native, accommodates both one-at-a-time and pasted lists)

/// A thin wrapper around AppKit's `NSTokenField`, bound to the stored "comma-or-space separated"
/// string. Type a value and press comma/return/space to make a pill, or paste a whole list at
/// once — both work. Writes back on end-editing (blur/return), so mid-type churn can't re-tokenize
/// the word you're still spelling. Storage stays the same string `SettingsManager` already splits.
struct TokenField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ", \n\t")
        field.placeholderString = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        let tokens = Self.tokens(from: text)
        // Only replace when the model genuinely differs, or we'd stomp in-progress editing.
        if (field.objectValue as? [String]) != tokens {
            field.objectValue = tokens
        }
    }

    static func tokens(from string: String) -> [String] {
        string.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TokenField
        init(_ parent: TokenField) { self.parent = parent }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTokenField else { return }
            // A failed cast returns early rather than clobbering the setting with "". An empty
            // array (the user cleared every pill) still casts fine, so clearing works.
            guard let tokens = field.objectValue as? [String] else { return }
            let joined = tokens.joined(separator: ", ")
            if joined != parent.text { parent.text = joined }
        }
    }
}

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case agent
    case shortcuts
    case autofill
    case content
    case newspaper
    case downloads
    case screenshots
    case appearance
    case security
    case memory
    case privacy
    case powerUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .agent: return String(localized: "Agent")
        case .shortcuts: return String(localized: "Shortcuts")
        case .autofill: return String(localized: "Autofill")
        case .content: return String(localized: "Content")
        case .newspaper: return String(localized: "Newspaper")
        case .downloads: return String(localized: "Downloads")
        case .screenshots: return String(localized: "Screenshots")
        case .appearance: return String(localized: "Appearance")
        case .security: return String(localized: "Security")
        case .memory: return String(localized: "Memory")
        case .privacy: return String(localized: "Privacy")
        case .powerUp: return String(localized: "Power Up")
        }
    }

    /// What's actually inside, so the sidebar answers "which pane was that in?" without making
    /// you click through all of them.
    var subtitle: String {
        switch self {
        case .general: return String(localized: "Search, omnibar, hotkey")
        case .agent: return String(localized: "Models, automation, memory, privacy")
        case .shortcuts: return String(localized: "Customize keyboard shortcuts")
        case .autofill: return String(localized: "Profiles, contacts, form filling")
        case .content: return String(localized: "JavaScript and page content")
        case .newspaper: return String(localized: "Appearance, discovery, weather, offline text")
        case .downloads: return String(localized: "Image downloads, folder")
        case .screenshots: return String(localized: "Capture shortcuts, formats, folders")
        case .appearance: return String(localized: "Theme and loading progress")
        case .security: return String(localized: "SSL, ad blocking, automation")
        case .memory: return String(localized: "Free RAM from idle tabs")
        case .privacy: return String(localized: "Clear data, manage cookies")
        case .powerUp: return String(localized: "Discover and practice Browser skills")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .agent: return "sparkles"
        case .shortcuts: return "keyboard"
        case .autofill: return "text.append"
        case .content: return "curlybraces"
        case .newspaper: return "newspaper"
        case .downloads: return "arrow.down.circle"
        case .screenshots: return "camera"
        case .appearance: return "paintbrush"
        case .security: return "lock.shield"
        case .memory: return "memorychip"
        case .privacy: return "hand.raised"
        case .powerUp: return "bolt.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: return SettingsTint.general
        case .agent: return SettingsTint.agent
        case .shortcuts: return SettingsTint.shortcuts
        case .autofill: return SettingsTint.autofill
        case .content: return SettingsTint.content
        case .newspaper: return SettingsTint.newspaper
        case .downloads: return SettingsTint.downloads
        case .screenshots: return SettingsTint.screenshots
        case .appearance: return SettingsTint.appearance
        case .security: return SettingsTint.security
        case .memory: return SettingsTint.memory
        case .privacy: return SettingsTint.privacy
        case .powerUp: return SettingsTint.general
        }
    }
}

// MARK: - Container

/// Width follows the actual localized labels at the user's effective font size, without a cap
/// that can truncate them. A compact picker replaces the sidebar when detail cannot stay useful.
enum SettingsNavigationLayout {
    static func sidebarWidth(labelWidths: [CGFloat]) -> CGFloat {
        max(224, ceil(labelWidths.max() ?? 0) + 14 + 18 + 10 + 14 + 24)
    }
    static func usesCompactNavigation(availableWidth: CGFloat, sidebarWidth: CGFloat) -> Bool {
        availableWidth < sidebarWidth + 420
    }
    static func orderedPanes(_ saved: String) -> [SettingsPane] {
        var seen = Set<SettingsPane>()
        let stored = saved.split(separator: ",").compactMap { SettingsPane(rawValue: String($0)) }
        return (stored + SettingsPane.allCases).filter { seen.insert($0).inserted }
    }
}

struct SettingsWindow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("settingsPane", store: BrowserProfile.defaults) private var paneRaw = SettingsPane.general.rawValue
    @AppStorage("settingsPaneOrder", store: BrowserProfile.defaults) private var paneOrderRaw = ""
    @BrowserThemeStorage private var theme
    @State private var searchQuery = ""
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var headingFocused: Bool
    private var searchNav: SettingsSearchNavigation { .shared }
    private var pane: SettingsPane { SettingsPane(rawValue: paneRaw) ?? .general }
    private var paneOrder: [SettingsPane] { SettingsNavigationLayout.orderedPanes(paneOrderRaw) }
    private var sidebarWidth: CGFloat {
        // Read both environment values so localization/accessibility changes remeasure this view.
        _ = locale; _ = dynamicTypeSize
        let font = NSFont.preferredFont(forTextStyle: .body)
        return SettingsNavigationLayout.sidebarWidth(labelWidths: paneOrder.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        })
    }
    private var colorScheme: ColorScheme? {
        switch theme { case "Light": return .light; case "Dark": return .dark; default: return nil }
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = SettingsNavigationLayout.usesCompactNavigation(availableWidth: geometry.size.width, sidebarWidth: sidebarWidth)
            HStack(spacing: 0) {
                if !compact { sidebar.frame(width: sidebarWidth); Divider() }
                // One stable detail subtree: resizing never replaces its fields or scroll position.
                VStack(spacing: 0) {
                    header(compact: compact)
                    Divider()
                    ScrollViewReader { proxy in
                        detail
                            .id(paneRaw)
                            .onChange(of: searchNav.pendingScrollID) { _, id in
                                guard let id else { return }
                                Task {
                                    try? await Task.sleep(for: .milliseconds(80))
                                    guard !Task.isCancelled else { return }
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { proxy.scrollTo(id, anchor: .top) }
                                    searchNav.highlightedID = id
                                    searchNav.pendingScrollID = nil
                                    try? await Task.sleep(for: .milliseconds(1500))
                                    if searchNav.highlightedID == id { searchNav.highlightedID = nil }
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(paneShortcuts)
        .background(SettingsWindowInteraction(onResignEditing: { headingFocused = true }))
        .textSelection(.enabled)
        .frame(minWidth: 520, minHeight: 520)
        .preferredColorScheme(colorScheme)
    }

    private var sidebar: some View {
        List {
            ForEach(paneOrder) { target in
                navigationRow(target)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            }
            .onMove { offsets, destination in
                var order = paneOrder
                order.move(fromOffsets: offsets, toOffset: destination)
                paneOrderRaw = order.map(\.rawValue).joined(separator: ",")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Settings categories")
    }

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if compact {
                Picker("Category", selection: $paneRaw) {
                    ForEach(paneOrder) { Text($0.title).fixedSize(horizontal: false, vertical: true).tag($0.rawValue) }
                }
                .accessibilityIdentifier("settings-category-menu")
            }
            Text(pane.title).font(.title2.weight(.semibold))
                .focusable().focused($headingFocused)
                .accessibilityAddTraits(.isHeader)
            Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Settings", text: $searchQuery).textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .accessibilityIdentifier("settings-search")
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear Settings search")
                }
            }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            if !searchQuery.isEmpty {
                if matchingSearchEntries.isEmpty { Text("No matching settings").font(.callout).foregroundStyle(.secondary) }
                ForEach(matchingSearchEntries) { entry in
                    Button { openSetting(entry.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: entry.pane.systemImage).frame(width: 18)
                            Text(entry.title)
                            Spacer()
                            Text(entry.pane.title).foregroundStyle(.secondary)
                        }.font(.callout).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            // The child observes both opt-ins so toggling them refreshes this entry immediately.
            SettingsAssistantView(openSetting: openSetting)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var matchingSearchEntries: [SettingsSearchEntry] {
        guard !searchQuery.isEmpty else { return [] }
        return Array(SettingsSearchIndex.entries.filter { $0.matches(searchQuery) }.prefix(6))
    }
    private func openSetting(_ id: String) {
        guard let entry = SettingsSearchIndex.entries.first(where: { $0.id == id }) else { return }
        paneRaw = entry.pane.rawValue
        searchNav.pendingScrollID = entry.id
        searchQuery = ""
        searchFieldFocused = false
    }
    @ViewBuilder private var paneShortcuts: some View {
        Group {
            ForEach(paneOrder.prefix(9)) { target in
                if let index = paneOrder.firstIndex(of: target) {
                    Button("") { paneRaw = target.rawValue }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            Button("") { searchFieldFocused = true }.keyboardShortcut("f", modifiers: .command)
        }
        .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
    }
    private func navigationRow(_ target: SettingsPane) -> some View {
        let selected = target == pane
        return HStack(spacing: 10) {
            Image(systemName: target.systemImage).frame(width: 18)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Text(target.title).font(.body).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(minHeight: 34)
        .background(selected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // List needs mouse-down ownership for native reorder drags; keyboard/VO gets an action.
        .onTapGesture { paneRaw = target.rawValue }
        .focusable(interactions: .activate)
        .onKeyPress(.return) { paneRaw = target.rawValue; return .handled }
        .onKeyPress(.space) { paneRaw = target.rawValue; return .handled }
        .contextMenu {
            Button("Move category up") { move(target, by: -1) }.disabled(paneOrder.first == target)
            Button("Move category down") { move(target, by: 1) }.disabled(paneOrder.last == target)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("settings-pane-\(target.rawValue)")
        .accessibilityLabel(target.title)
        .accessibilityHint(target.subtitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { paneRaw = target.rawValue }
    }
    private func move(_ target: SettingsPane, by delta: Int) {
        var order = paneOrder
        guard let index = order.firstIndex(of: target), order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta)
        paneOrderRaw = order.map(\.rawValue).joined(separator: ",")
    }
    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: GeneralSettingsView()
        case .agent:
            if BrowserProfile.isIsolated {
                ContentUnavailableView("External integrations disabled", systemImage: "lock.shield")
            } else {
                VStack(spacing: 0) {
                    SettingsHelpSetupView()
                    AgentSettingsView()
                }
            }
        case .shortcuts: ShortcutsSettingsView()
        case .autofill: AutofillSettingsView()
        case .content: ContentSettingsView()
        case .newspaper: NewspaperSettingsView()
        case .downloads: DownloadsSettingsView()
        case .screenshots: ScreenshotsSettingsView()
        case .appearance: AppearanceSettingsView()
        case .security: SecuritySettingsView()
        case .memory: MemorySettingsView()
        case .privacy: PrivacySettingsView()
        case .powerUp: PowerUpView()
        }
    }
}

#Preview { SettingsWindow() }
