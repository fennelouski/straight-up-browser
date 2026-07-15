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
    static let content = Color.purple
    static let downloads = Color.teal
    static let appearance = Color.pink
    static let security = Color.orange
    static let privacy = Color.indigo
    static let memory = Color.mint
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
    @ViewBuilder let demo: (Binding<Value>) -> Demo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            SettingInfoButton(title: title, explanation: explanation, value: $value, demo: demo)
        }
    }
}

struct SettingInfoButton<Value: Equatable, Demo: View>: View {
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey
    @Binding var value: Value
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
        .buttonStyle(.plain)
        .accessibilityLabel("Learn more")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            SettingInfoPopover(title: title, explanation: explanation, value: $value, demo: demo)
        }
    }
}

private struct SettingInfoPopover<Value: Equatable, Demo: View>: View {
    private enum Tab: Hashable { case demo, about }

    let title: LocalizedStringKey
    let explanation: LocalizedStringKey
    @Binding var value: Value
    @ViewBuilder let demo: (Binding<Value>) -> Demo

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .demo
    /// What the demo actually edits. Seeded from the live value, written back only on Save.
    @State private var draft: Value

    init(
        title: LocalizedStringKey,
        explanation: LocalizedStringKey,
        value: Binding<Value>,
        @ViewBuilder demo: @escaping (Binding<Value>) -> Demo
    ) {
        self.title = title
        self.explanation = explanation
        self._value = value
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
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        value = draft
                        dismiss()
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
    case content
    case downloads
    case appearance
    case security
    case memory
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .content: return String(localized: "Content")
        case .downloads: return String(localized: "Downloads")
        case .appearance: return String(localized: "Appearance")
        case .security: return String(localized: "Security")
        case .memory: return String(localized: "Memory")
        case .privacy: return String(localized: "Privacy")
        }
    }

    /// What's actually inside, so the sidebar answers "which pane was that in?" without making
    /// you click through all of them.
    var subtitle: String {
        switch self {
        case .general: return String(localized: "Search, omnibar, hotkey")
        case .content: return String(localized: "JavaScript and page content")
        case .downloads: return String(localized: "Option-click downloads, folder")
        case .appearance: return String(localized: "Theme and loading progress")
        case .security: return String(localized: "SSL, ad blocking, automation")
        case .memory: return String(localized: "Free RAM from idle tabs")
        case .privacy: return String(localized: "Clear data, manage cookies")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .content: return "curlybraces"
        case .downloads: return "arrow.down.circle"
        case .appearance: return "paintbrush"
        case .security: return "lock.shield"
        case .memory: return "memorychip"
        case .privacy: return "hand.raised"
        }
    }

    var tint: Color {
        switch self {
        case .general: return SettingsTint.general
        case .content: return SettingsTint.content
        case .downloads: return SettingsTint.downloads
        case .appearance: return SettingsTint.appearance
        case .security: return SettingsTint.security
        case .memory: return SettingsTint.memory
        case .privacy: return SettingsTint.privacy
        }
    }
}

// MARK: - Container

struct SettingsWindow: View {
    @AppStorage("settingsPane") private var paneRaw = SettingsPane.general.rawValue
    // Same "theme" key SettingsManager reads — one store, no desync. Reading it here (rather than
    // SettingsManager.shared.colorScheme) re-tints the window live when Theme changes.
    @AppStorage("theme") private var theme = "System"

    private var pane: SettingsPane { SettingsPane(rawValue: paneRaw) ?? .general }

    private var colorScheme: ColorScheme? {
        switch theme {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        NavigationSplitView {
            // Cards rather than list rows: bare rows left most of the sidebar empty, and the
            // room was better spent saying what's in each pane.
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(SettingsPane.allCases) { pane in
                        card(pane)
                    }
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detail
                .navigationTitle(pane.title)
        }
        .frame(minWidth: 720, minHeight: 520)
        .preferredColorScheme(colorScheme)
    }

    private func card(_ target: SettingsPane) -> some View {
        let selected = target == pane
        return Button {
            paneRaw = target.rawValue
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: target.systemImage)
                    .font(.system(size: 14))
                    // Selected, the card is already the accent colour — a tinted glyph on top of
                    // it would be unreadable.
                    .foregroundStyle(selected ? Color.white : target.tint)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(target.subtitle)
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(selected ? 0 : 0.10), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(target.title). \(target.subtitle)")
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettingsView()
        case .content: ContentSettingsView()
        case .downloads: DownloadsSettingsView()
        case .appearance: AppearanceSettingsView()
        case .security: SecuritySettingsView()
        case .memory: MemorySettingsView()
        case .privacy: PrivacySettingsView()
        }
    }
}

#Preview {
    SettingsWindow()
}
