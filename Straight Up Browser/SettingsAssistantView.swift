#if os(macOS)
import AppKit
import SwiftUI

/// Preserve the existing AppStorage writer and its live observers while
/// recording every deliberate edit, including same-value and ABA edits.
@MainActor enum SettingsTrackedBinding {
    static func binding<Value: Sendable>(_ original: Binding<Value>, id: BrowserSettingID) -> Binding<Value> {
        Binding(get: { original.wrappedValue }, set: {
            original.wrappedValue = $0
            SettingsTransactionCoordinator.shared.noteManualWrite(id)
        })
    }
}

/// Kept outside AgentSettingsView so the provider/model review source remains
/// unchanged. This setup entry stays discoverable under the AI master switch.
struct SettingsHelpSetupView: View {
    @AppStorage(SettingsAssistantAvailability.enabledKey, store: BrowserProfile.defaults) private var settingsAssistantEnabled = false
    @AppStorage("aiFeaturesEnabled", store: BrowserProfile.defaults) private var aiFeaturesEnabled = true

    var body: some View {
        GroupBox("Settings help") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show local Settings help", isOn: $settingsAssistantEnabled)
                    .disabled(!aiFeaturesEnabled)
                Text("Explains page fades, fade length, theme, and link splits using local rules. No text or values are sent to a provider. Theme supports a reviewed local Apply and Undo; the other preferences open their native controls.")
                Text("External Settings agents require authenticated pairing and separate scoped grants. Existing browser automation does not grant Settings access.")
                if !aiFeaturesEnabled { Text("Enable Show AI features in Agent to use local Settings help.") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

/// The optional Settings surface stays independent of manual search. All text
/// is inert/selectable native Text; a suggestion cannot manufacture a button.
struct SettingsAssistantView: View {
    let openSetting: (String) -> Void
    @AppStorage(SettingsAssistantAvailability.enabledKey, store: BrowserProfile.defaults) private var enabled = false
    @AppStorage("aiFeaturesEnabled", store: BrowserProfile.defaults) private var aiFeaturesEnabled = true
    @State private var isPresented = false

    var body: some View {
        Group {
          if enabled && aiFeaturesEnabled {
            HStack(spacing: 10) {
                Label("Settings help", systemImage: "sparkles")
                    .font(.callout.weight(.medium))
                Text("Explain a setting or preview a change.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Ask about Settings") { isPresented = true }
                    .accessibilityIdentifier("settings.ask")
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .sheet(isPresented: $isPresented) {
                SettingsAssistantConversationView(openSetting: { destination in
                    isPresented = false
                    // Preserve the intentional destination instead of restoring
                    // the Ask button's focus after this sheet is dismissed.
                    openSetting(destination)
                })
            }
          }
        }
        .onChange(of: enabled) { _, value in if !value { isPresented = false; SettingsTransactionCoordinator.shared.revoke() } }
        .onChange(of: aiFeaturesEnabled) { _, value in if !value { isPresented = false; SettingsTransactionCoordinator.shared.revoke() } }
    }
}

private struct SettingsAssistantConversationView: View {
    let openSetting: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsAssistantAvailability.enabledKey, store: BrowserProfile.defaults) private var enabled = false
    @AppStorage("aiFeaturesEnabled", store: BrowserProfile.defaults) private var aiFeaturesEnabled = true
    @State private var conversation = SettingsConversationCoordinator()
    @FocusState private var composerFocused: Bool
    @FocusState private var undoFocused: Bool

    private var available: Bool { enabled && aiFeaturesEnabled }
    private var mode: Binding<SettingsConversationCoordinator.Mode> {
        Binding(get: { conversation.mode }, set: { conversation.mode = $0 })
    }
    private var input: Binding<String> {
        Binding(get: { conversation.input }, set: { conversation.input = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ask about Settings").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Local Settings help · No model or external agent connected")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Help mode", selection: mode) {
                ForEach(SettingsConversationCoordinator.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("What would you like Browser to do differently?", text: input)
                .textFieldStyle(.roundedBorder)
                .focused($composerFocused)
                .onSubmit { conversation.submit(available: available) }
                .accessibilityIdentifier("settings.assistant.request")
            HStack {
                Button("Why do pages fade?") { conversation.input = "Why do pages fade?"; conversation.submit(available: available) }
                Button("Turn page fading off") { conversation.mode = .preview; conversation.input = "Turn page fading off"; conversation.submit(available: available) }
                Spacer()
                Button(conversation.questionOnly ? "Ask" : "Preview") { conversation.submit(available: available) }
                    .disabled(conversation.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(conversation.answer).textSelection(.enabled)
                        .accessibilityIdentifier("settings.assistant.answer")
                    ForEach(conversation.references, id: \.self) { id in
                        let descriptor = SettingsRegistry.descriptor(id)
                        Button("Open \(descriptor.title)") { openSetting(descriptor.destination) }
                    }
                    if let proposal = conversation.proposal, !conversation.questionOnly {
                        proposalCard(proposal)
                    }
                    if let message = conversation.message {
                        Text(message).font(.callout).textSelection(.enabled)
                            .accessibilityIdentifier("settings.assistant.result")
                    }
                    if conversation.receipt != nil && !conversation.questionOnly {
                        Button("Undo Settings change") { conversation.undo(available: available) }
                            .focused($undoFocused)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text("Only your submitted text and these four ordinary app preferences are used locally. No pages, call content, history, credentials, clipboard, or agent memory are read. This conversation is kept only while the panel is open. External Settings agents require a separately reviewed authenticated connection.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 660, minHeight: 480, idealHeight: 560)
        .onChange(of: available) { _, value in if !value { conversation.revoke(); dismiss() } }
        .onChange(of: conversation.receipt) { _, receipt in if receipt != nil { undoFocused = true } }
        .onDisappear { conversation.invalidate() }
        .onExitCommand {
            // Native text fields consume composition Escape first. A held key
            // must not both finish editing and dismiss the panel.
            guard NSApp.currentEvent?.isARepeat != true else { return }
            if composerFocused { composerFocused = false }
            else { dismiss() }
        }
    }

    private func proposalCard(_ proposal: SettingsValidatedProposal) -> some View {
        let descriptor = SettingsRegistry.descriptor(proposal.settingID)
        let stale = conversation.staleReason(available: available)
        return GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Text(descriptor.title).font(.headline)
                Text("\(proposal.before.effective.display) → \(proposal.after.display)").font(.title3.monospacedDigit())
                Text("Current source: \(proposal.before.source). Scope: Browser on this Mac, all windows.")
                Text(descriptor.effect)
                Text("Undo preserves the earlier saved value or restores the default only if there has been no newer edit. Undo history is limited to this app session.")
                    .font(.caption).foregroundStyle(.secondary)
                if let stale {
                    Text(stale).foregroundStyle(.secondary)
                    Button("Refresh preview") { conversation.submit(available: available) }
                } else if !conversation.applyIsAvailable {
                    // The reviewed plan requires withholding Apply when a
                    // cache-only adapter cannot prove outcome reconciliation.
                    Text(SettingsAssistantError.persistenceUnavailable.localizedDescription)
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open setting to make this change") { openSetting(descriptor.destination) }
                }
                HStack {
                    if conversation.applyIsAvailable {
                        Button("Apply \(descriptor.title)") { conversation.apply(available: available) }
                            .disabled(stale != nil)
                            .accessibilityIdentifier("settings.assistant.apply")
                    }
                    Button("Cancel preview") { conversation.invalidate() }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
