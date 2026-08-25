//
//  AgentSettingsView.swift
//  Straight Up Browser
//
//  One home for the settings and management surfaces introduced by the
//  browser-agent roadmap. Safety invariants without a persisted runtime setting
//  are intentionally presented as read-only summaries rather than fake toggles.
//

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// UserDefaults keys already consumed by the agent runtime. Keeping their
/// spellings together prevents Settings from silently writing a decorative key
/// that the executor never reads.
enum AgentSettingsRuntimeKey {
    static let provider = "browserAgentProvider"
    static let endpoint = "browserAgentEndpoint"
    static let model = "browserAgentModel"
    static let webKitConsoleCapture = "agentWebKitConsoleCaptureEnabled"
    static let webKitDiagnosticContent = "agentWebKitDiagnosticContentEnabled"
    static let adjustsPageLayout = "browserAgentAdjustsPageLayout"
    static let loadsMorePageContent = AgentPageExpansionSettings.Key.enabled
    static let panelSide = BrowserChromePlacementSettings.Key.agentPanelSide

    static let allDefaultsKeys: Set<String> = [
        provider,
        endpoint,
        model,
        webKitConsoleCapture,
        webKitDiagnosticContent,
        adjustsPageLayout,
        loadsMorePageContent,
        panelSide,
        AgentMemorySettings.Key.enabled,
        AgentMemorySettings.Key.allowSensitiveProposals,
        AgentMemorySettings.Key.maximumRetrievedEntries,
        AgentMemorySettings.Key.maximumRetrievedTokens,
        AgentMemorySettings.Key.retention,
        AgentObservabilitySettings.Key.maximumTurns,
        AgentObservabilitySettings.Key.maximumToolCalls,
        AgentObservabilitySettings.Key.maximumWallMinutes,
        AgentObservabilitySettings.Key.maximumProviderTokens,
        AgentObservabilitySettings.Key.maximumProviderCostMicrounits,
        AgentObservabilitySettings.Key.maximumOpenPages,
        AgentObservabilitySettings.Key.maximumModelResultMiB,
        AgentObservabilitySettings.Key.maximumDownloads,
        AgentObservabilitySettings.Key.maximumDownloadMiB,
        AgentObservabilitySettings.Key.maximumArtifacts,
        AgentObservabilitySettings.Key.maximumArtifactMiB,
        AgentObservabilitySettings.Key.localMetricsEnabled,
        AgentObservabilitySettings.Key.metricRetentionDays,
        AgentHistoryRetentionSettings.Key.policy,
        AgentDefinitionSyncSettings.Key.schedules,
        AgentDefinitionSyncSettings.Key.providerPresets,
        AgentDefinitionSyncSettings.Key.userAuthoredMemory,
        AgentProviderPricingSettings.Key.providerID,
        AgentProviderPricingSettings.Key.model,
        AgentProviderPricingSettings.Key.currencyCode,
        AgentProviderPricingSettings.Key.inputMicrounitsPerMillionTokens,
        AgentProviderPricingSettings.Key.cachedInputMicrounitsPerMillionTokens,
        AgentProviderPricingSettings.Key.outputMicrounitsPerMillionTokens,
        AgentProviderPricingSettings.Key.blendedMicrounitsPerMillionTokens,
    ]
}

struct AgentSettingsView: View {
    @AppStorage(AgentSettingsRuntimeKey.provider)
    private var providerRaw = BrowserAgentProvider.appleIntelligence.rawValue
    @AppStorage(AgentSettingsRuntimeKey.adjustsPageLayout)
    private var adjustsPageLayout = false
    @AppStorage(AgentSettingsRuntimeKey.loadsMorePageContent)
    private var loadsMorePageContent = true
    @AppStorage(AgentSettingsRuntimeKey.panelSide)
    private var panelSideRaw = BrowserChromeSide.left.rawValue
    @AppStorage(SettingsManager.aiFeaturesKey) private var aiFeaturesEnabled = true
    @AppStorage(AgentSettingsRuntimeKey.endpoint)
    private var customEndpoint = ""
    @AppStorage(AgentSettingsRuntimeKey.model)
    private var savedModel = ""

    @AppStorage(AgentProviderPricingSettings.Key.providerID)
    private var pricingProviderID = ""
    @AppStorage(AgentProviderPricingSettings.Key.model)
    private var pricingModel = ""
    @AppStorage(AgentProviderPricingSettings.Key.currencyCode)
    private var pricingCurrencyCode = "USD"
    @AppStorage(AgentProviderPricingSettings.Key.inputMicrounitsPerMillionTokens)
    private var pricingInputRate = ""
    @AppStorage(AgentProviderPricingSettings.Key.cachedInputMicrounitsPerMillionTokens)
    private var pricingCachedInputRate = ""
    @AppStorage(AgentProviderPricingSettings.Key.outputMicrounitsPerMillionTokens)
    private var pricingOutputRate = ""
    @AppStorage(AgentProviderPricingSettings.Key.blendedMicrounitsPerMillionTokens)
    private var pricingBlendedRate = ""

    @AppStorage(AgentSettingsRuntimeKey.webKitConsoleCapture)
    private var webKitConsoleCapture = false
    @AppStorage(AgentSettingsRuntimeKey.webKitDiagnosticContent)
    private var webKitDiagnosticContent = false

    @AppStorage(AgentMemorySettings.Key.enabled)
    private var agentMemoryEnabled = false
    @AppStorage(AgentMemorySettings.Key.allowSensitiveProposals)
    private var allowSensitiveMemoryProposals = false
    @AppStorage(AgentMemorySettings.Key.maximumRetrievedEntries)
    private var maximumRetrievedMemoryEntries = 4
    @AppStorage(AgentMemorySettings.Key.maximumRetrievedTokens)
    private var maximumRetrievedMemoryTokens = 1_024
    @AppStorage(AgentMemorySettings.Key.retention)
    private var memoryRetention = AgentMemoryRetentionPolicy.untilManuallyDeleted.rawValue

    @AppStorage(AgentObservabilitySettings.Key.maximumTurns)
    private var maximumTurns = AgentExecutionLimits.defaults.maximumTurns
    @AppStorage(AgentObservabilitySettings.Key.maximumToolCalls)
    private var maximumToolCalls = AgentExecutionLimits.defaults.maximumToolCalls
    @AppStorage(AgentObservabilitySettings.Key.maximumWallMinutes)
    private var maximumWallMinutes = Int(
        AgentExecutionLimits.defaults.maximumElapsedMilliseconds / 60_000
    )
    @AppStorage(AgentObservabilitySettings.Key.maximumProviderTokens)
    private var maximumProviderTokens = 0
    @AppStorage(AgentObservabilitySettings.Key.maximumProviderCostMicrounits)
    private var maximumProviderCostMicrounits = 0
    @AppStorage(AgentObservabilitySettings.Key.maximumOpenPages)
    private var maximumOpenPages = AgentExecutionLimits.defaults.maximumOpenPages
    @AppStorage(AgentObservabilitySettings.Key.maximumModelResultMiB)
    private var maximumModelResultMiB = Int(
        AgentExecutionLimits.defaults.maximumModelResultBytes / 1_048_576
    )
    @AppStorage(AgentObservabilitySettings.Key.maximumDownloads)
    private var maximumDownloads = AgentExecutionLimits.defaults.maximumDownloads
    @AppStorage(AgentObservabilitySettings.Key.maximumDownloadMiB)
    private var maximumDownloadMiB = Int(
        AgentExecutionLimits.defaults.maximumDownloadBytes / 1_048_576
    )
    @AppStorage(AgentObservabilitySettings.Key.maximumArtifacts)
    private var maximumArtifacts = AgentExecutionLimits.defaults.maximumArtifacts
    @AppStorage(AgentObservabilitySettings.Key.maximumArtifactMiB)
    private var maximumArtifactMiB = Int(
        AgentExecutionLimits.defaults.maximumArtifactBytes / 1_048_576
    )
    @AppStorage(AgentObservabilitySettings.Key.localMetricsEnabled)
    private var localMetricsEnabled = true
    @AppStorage(AgentObservabilitySettings.Key.metricRetentionDays)
    private var metricRetentionDays = 30
    @AppStorage(AgentHistoryRetentionSettings.Key.policy)
    private var runHistoryRetention = AgentRetentionPolicy.days30.rawValue

    @AppStorage(AgentDefinitionSyncSettings.Key.schedules)
    private var syncSchedules = false
    @AppStorage(AgentDefinitionSyncSettings.Key.providerPresets)
    private var syncProviderPresets = false
    @AppStorage(AgentDefinitionSyncSettings.Key.userAuthoredMemory)
    private var syncUserAuthoredMemory = false

    @ObservedObject private var workspace = BrowserAgentWorkspace.shared
    @ObservedObject private var memoryController = AgentMemoryController.shared
    @ObservedObject private var observabilityController = AgentObservabilityController.shared
    @ObservedObject private var historyDeletionController = AgentHistoryDeletionController.shared
    @ObservedObject private var definitionSyncService = AgentDefinitionSyncService.shared
    @Environment(\.openWindow) private var openWindow
    @State private var apiKey = ""
    @State private var showingMemoryManager = false
    @State private var diagnosticPreview: AgentObservabilityDiagnosticPreview?
    @State private var diagnosticMessage: String?
    @State private var generatingDiagnosticPreview = false
    @State private var pendingSyncDisableCategory: AgentDefinitionSyncCategory?
    @State private var showingSyncDisableChoices = false
    @State private var showingDeleteAllAgentHistoryConfirmation = false

    private var provider: BrowserAgentProvider {
        BrowserAgentProvider(rawValue: providerRaw) ?? .openRouter
    }

    private var model: Binding<String> {
        Binding(
            get: { currentModelName },
            set: { savedModel = $0 }
        )
    }

    private var currentModelName: String {
        provider.resolvedModel(savedModel)
    }

    private var endpoint: String {
        provider.endpoint(customEndpoint: customEndpoint, model: currentModelName)
    }

    private var usesIncludedPricing: Bool {
        AgentProviderPricingSettings.metadata(
            providerID: provider.rawValue,
            model: currentModelName
        )?.source == .providerPublished
    }

    private var pricingMatchesCurrentModel: Bool {
        pricingProviderID == provider.rawValue && pricingModel == currentModelName
    }

    var body: some View {
        Form {
            availabilitySection
            if aiFeaturesEnabled {
                interfaceSection
                providerSection
                providerPricingSection
                coworkSection
                managementSection
                safetySection
                delegationSection
                memorySection
                diagnosticsSection
                syncSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = BrowserAgentKeychain.read(provider: provider)
            applyCatalogPricingIfNeeded()
            Task {
                await observabilityController.refresh()
                await definitionSyncService.start()
            }
        }
        .onChange(of: providerRaw) { oldValue, _ in
            if let oldProvider = BrowserAgentProvider(rawValue: oldValue) {
                BrowserAgentKeychain.write(apiKey, provider: oldProvider)
            }
            apiKey = BrowserAgentKeychain.read(provider: provider)
            savedModel = provider.defaultModel
            applyCatalogPricingIfNeeded()
            Task { await definitionSyncService.preferencesChanged() }
        }
        .onChange(of: apiKey) { _, value in
            BrowserAgentKeychain.write(value, provider: provider)
            Task { await definitionSyncService.localDependenciesChanged() }
        }
        .onChange(of: savedModel) { _, _ in
            applyCatalogPricingIfNeeded()
            guard syncProviderPresets else { return }
            Task { await definitionSyncService.preferencesChanged() }
        }
        .onChange(of: customEndpoint) { _, _ in
            guard syncProviderPresets else { return }
            Task { await definitionSyncService.preferencesChanged() }
        }
        .onChange(of: maximumRetrievedMemoryEntries) { _, _ in
            memoryController.reopenStore()
        }
        .onChange(of: maximumRetrievedMemoryTokens) { _, _ in
            memoryController.reopenStore()
        }
        .onChange(of: memoryRetention) { _, _ in
            memoryController.reopenStore()
        }
        .onChange(of: localMetricsEnabled) { _, _ in
            Task { await observabilityController.settingsChanged() }
        }
        .onChange(of: metricRetentionDays) { _, _ in
            Task { await observabilityController.settingsChanged() }
        }
        .onChange(of: runHistoryRetention) { _, _ in
            Task { await historyDeletionController.retentionPolicyChanged() }
        }
        .sheet(isPresented: $showingMemoryManager) {
            AgentMemoryManagementView(controller: memoryController)
        }
        .confirmationDialog(
            "Turn Off \(pendingSyncDisableCategory.map(syncCategoryLabel) ?? "Agent Definition") Sync?",
            isPresented: $showingSyncDisableChoices,
            titleVisibility: .visible
        ) {
            Button("Keep Copies on This Mac") {
                confirmSyncDisable(.keepLocalCopies)
            }
            Button("Delete Copies from iCloud", role: .destructive) {
                confirmSyncDisable(.deleteCloudCopies)
            }
            Button("Cancel", role: .cancel) {
                pendingSyncDisableCategory = nil
            }
        } message: {
            Text("Either choice stops new cloud writes. Local definitions remain available for later re-enabling; deleting from iCloud publishes conflict-safe tombstones.")
        }
        .confirmationDialog(
            "Delete All Agent History?",
            isPresented: $showingDeleteAllAgentHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Agent History", role: .destructive) {
                Task { await historyDeletionController.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every saved conversation, Run, Step, approval record, retained artifact, replay frame, scheduler occurrence record, private Cowork transaction workspace, and retired legacy history source. Scheduled task definitions, committed Cowork files, scoped memory, local metrics, provider credentials, and app integrations are preserved.")
        }
    }

    // The one place AI keeps its name when it's switched off — otherwise there
    // would be no way back. On-device Apple Intelligence has no UI of its own
    // and keeps its own toggles in General and Appearance.
    private var availabilitySection: some View {
        CollapsibleSection {
            Toggle("Show AI features", isOn: $aiFeaturesEnabled)
            Text("Off hides the Agent panel, its ⇧⌘A shortcut and keyboard-shortcut entry, AI Search, and every other AI affordance in the app. Nothing is deleted — your provider, keys, and history are still here when you switch it back on. Apple Intelligence features that run on your Mac (visual tab names, site nicknames) have no interface of their own and are switched separately.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            SettingsLabel("AI Features", systemImage: "sparkles", tint: SettingsTint.agent)
        }
    }

    private var interfaceSection: some View {
        CollapsibleSection {
            Picker("Panel side", selection: $panelSideRaw) {
                ForEach(BrowserChromeSide.allCases) { side in
                    Label(side.title, systemImage: side.systemImage).tag(side.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Resize the page when the Agent is open", isOn: $adjustsPageLayout)
            Text("Off keeps the Agent floating over its chosen edge. On gives it dedicated space and narrows the page and any Split panes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Load more of the page before answering", isOn: $loadsMorePageContent)
            Text("On lets the Agent briefly scroll through lazy-loaded pages and feeds behind a frozen view, then restores your exact position. Work is bounded, so endless feeds stop after a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            SettingsLabel("Agent Panel", systemImage: "sidebar.left", tint: SettingsTint.agent)
        }
    }

    private var providerSection: some View {
        CollapsibleSection {
            Picker("Provider", selection: $providerRaw) {
                ForEach(BrowserAgentProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider.rawValue)
                }
            }

            LabeledContent("Model") {
                ProviderModelPicker(
                    model: model,
                    provider: provider,
                    apiKey: apiKey,
                    customEndpoint: customEndpoint
                )
                .accessibilityIdentifier("agent-settings-model")
            }

            if provider == .compatible {
                TextField("Chat Completions URL", text: $customEndpoint)
                    .textFieldStyle(.roundedBorder)
            } else {
                LabeledContent("Endpoint") {
                    Text(endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if provider.needsAPIKey {
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            } else {
                Label("This provider runs through a local endpoint.", systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsLabel("Model Provider", systemImage: "cpu", tint: SettingsTint.agent)
        } footer: {
            Text("API keys are stored in Keychain for the selected provider. They are never stored in agent runs or synced to iCloud.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var providerPricingSection: some View {
        CollapsibleSection {
            LabeledContent("Pricing applies to") {
                Text(
                    pricingProviderID.isEmpty || pricingModel.isEmpty
                        ? "Not bound"
                        : "\(pricingProviderID) · \(pricingModel)"
                )
                .font(.caption.monospaced())
                .foregroundStyle(pricingMatchesCurrentModel ? Color.secondary : Color.orange)
                .textSelection(.enabled)
            }

            Button("Bind Pricing to Current Provider & Model") {
                pricingProviderID = provider.rawValue
                pricingModel = currentModelName
            }
            .disabled(currentModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if usesIncludedPricing {
                Label("Included pricing is filled automatically for this model.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Currency code (for example, USD)", text: $pricingCurrencyCode)
                .textFieldStyle(.roundedBorder)
            TextField("Input microunits per 1M tokens", text: $pricingInputRate)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
            TextField("Cached-input microunits per 1M tokens", text: $pricingCachedInputRate)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
            TextField("Output microunits per 1M tokens", text: $pricingOutputRate)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
            TextField("Estimated blended microunits per 1M tokens", text: $pricingBlendedRate)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()

            if !pricingProviderID.isEmpty || !pricingModel.isEmpty ||
                !pricingInputRate.isEmpty || !pricingCachedInputRate.isEmpty ||
                !pricingOutputRate.isEmpty || !pricingBlendedRate.isEmpty {
                Button("Clear Pricing", role: .destructive, action: clearProviderPricing)
            }
        } header: {
            SettingsLabel("Provider Pricing", systemImage: "banknote", tint: SettingsTint.agent)
        } footer: {
            Text("Pricing is used only for the exact bound provider and model. Input/output rates produce calculated cost; the blended rate is an estimate fallback. Missing or mismatched pricing stays unknown, so a finite cost cap stops the run safely.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var coworkSection: some View {
        CollapsibleSection {
            LabeledContent("Folder") {
                Text(workspace.rootURL?.path ?? "Not selected")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack {
                Button(workspace.rootURL == nil ? "Choose Cowork Folder…" : "Choose Another Folder…") {
                    workspace.chooseFolder()
                }
                Spacer()
                if workspace.rootURL != nil {
                    Button("Remove Access", role: .destructive) {
                        workspace.clear()
                    }
                }
            }
        } header: {
            SettingsLabel("Cowork Files", systemImage: "folder.badge.gearshape", tint: SettingsTint.agent)
        } footer: {
            Text("File tools are confined to this security-scoped folder. Changes are staged as transactions; replacements, moves, and deletions require a preview and approval before commit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var managementSection: some View {
        CollapsibleSection {
            Picker("Run history retention", selection: $runHistoryRetention) {
                Text("Do not retain").tag(AgentRetentionPolicy.never.rawValue)
                Text("24 hours").tag(AgentRetentionPolicy.hours24.rawValue)
                Text("7 days").tag(AgentRetentionPolicy.days7.rawValue)
                Text("30 days").tag(AgentRetentionPolicy.days30.rawValue)
                Text("Until manually deleted").tag(AgentRetentionPolicy.manual.rawValue)
            }
            .accessibilityIdentifier("agent-settings-run-history-retention")

            Button {
                openWindow(id: "agent-tasks")
            } label: {
                SettingsLabel("Scheduled Tasks…", systemImage: "clock.arrow.circlepath", tint: SettingsTint.agent)
            }

            Button {
                openWindow(id: "agent-integrations")
            } label: {
                SettingsLabel("App Integrations…", systemImage: "point.3.connected.trianglepath.dotted", tint: SettingsTint.agent)
            }

            Button {
                openWindow(id: "agent-audit")
            } label: {
                SettingsLabel("Timeline, Audit & Replay…", systemImage: "play.rectangle.on.rectangle", tint: SettingsTint.agent)
            }

            Button("Delete All Agent History…", role: .destructive) {
                showingDeleteAllAgentHistoryConfirmation = true
            }
            .disabled(historyDeletionController.isWorking)
            .accessibilityIdentifier("agent-settings-delete-all-history")

            if historyDeletionController.isWorking {
                ProgressView("Updating agent history…")
                    .controlSize(.small)
            } else if let outcome = historyDeletionController.outcome {
                Label(
                    outcome.message,
                    systemImage: outcome.isFailure
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(outcome.isFailure ? Color.red : Color.green)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agent-settings-history-outcome")
            }
        } header: {
            SettingsLabel("Automation & Records", systemImage: "bolt.badge.clock", tint: SettingsTint.agent)
        } footer: {
            Text("Manage recurring work, trusted MCP app connections, and the durable record of conversations, Runs, approvals, artifacts, and replay evidence. Scoped memory and local metrics have their own controls below and are not agent history.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var safetySection: some View {
        CollapsibleSection {
            LabeledContent("Effect approvals") {
                Text("Risk-scoped per run")
                    .foregroundStyle(.secondary)
            }

            Stepper(value: $maximumTurns, in: 1...256) {
                LabeledContent("Maximum turns") {
                    Text("\(maximumTurns)").monospacedDigit()
                }
            }
            Stepper(value: $maximumToolCalls, in: 0...2_048) {
                LabeledContent("Maximum tool calls") {
                    Text("\(maximumToolCalls)").monospacedDigit()
                }
            }
            Stepper(value: $maximumWallMinutes, in: 1...1_440) {
                LabeledContent("Maximum wall time") {
                    Text("\(maximumWallMinutes) minutes").monospacedDigit()
                }
            }
            Stepper(value: $maximumProviderTokens, in: 0...10_000_000, step: 1_024) {
                LabeledContent("Provider-token cap") {
                    Text(
                        maximumProviderTokens == 0
                            ? "No measurable cap"
                            : maximumProviderTokens.formatted()
                    )
                    .monospacedDigit()
                }
            }
            Stepper(
                value: $maximumProviderCostMicrounits,
                in: 0...1_000_000_000,
                step: 100_000
            ) {
                LabeledContent("Provider-cost cap") {
                    Text(
                        maximumProviderCostMicrounits == 0
                            ? "No known-cost cap"
                            : String(
                                format: "%.2f provider currency",
                                Double(maximumProviderCostMicrounits) / 1_000_000
                            )
                    )
                    .monospacedDigit()
                }
            }
            Stepper(value: $maximumOpenPages, in: 0...64) {
                LabeledContent("Maximum open pages") {
                    Text("\(maximumOpenPages)").monospacedDigit()
                }
            }
            Stepper(value: $maximumModelResultMiB, in: 1...256) {
                LabeledContent("Model-result cap") {
                    Text("\(maximumModelResultMiB) MiB").monospacedDigit()
                }
            }
            Stepper(value: $maximumDownloads, in: 0...512) {
                LabeledContent("Maximum downloads") {
                    Text("\(maximumDownloads)").monospacedDigit()
                }
            }
            Stepper(value: $maximumDownloadMiB, in: 0...16_384, step: 64) {
                LabeledContent("Download-byte cap") {
                    Text("\(maximumDownloadMiB) MiB").monospacedDigit()
                }
            }
            Stepper(value: $maximumArtifacts, in: 0...2_048) {
                LabeledContent("Maximum artifacts") {
                    Text("\(maximumArtifacts)").monospacedDigit()
                }
            }
            Stepper(value: $maximumArtifactMiB, in: 0...16_384, step: 64) {
                LabeledContent("Artifact-byte cap") {
                    Text("\(maximumArtifactMiB) MiB").monospacedDigit()
                }
            }
        } header: {
            SettingsLabel("Safety & Run Budgets", systemImage: "gauge.with.dots.needle.67percent", tint: SettingsTint.agent)
        } footer: {
            Text("These hard limits apply to new runs. Zero disables an optional provider token or known-cost cap; byte limits remain hard ceilings. Child runs can receive smaller budgets and less authority, never more.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var delegationSection: some View {
        CollapsibleSection {
            LabeledContent("Authority") {
                Text("Least-privilege subsets")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Page access") {
                Text("Exclusive leases")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Engine ceilings") {
                Text("Depth \(AgentRunGroup.maximumSupportedDepth) · fan-out \(AgentRunGroup.maximumSupportedFanOut) · \(AgentRunGroup.maximumSupportedTotalChildren) children")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsLabel("Delegated Runs", systemImage: "arrow.triangle.branch", tint: SettingsTint.agent)
        } footer: {
            Text("Child runs use explicit objectives, return schemas, budgets, and page leases. Cancellation and failure stay scoped to their run group.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var memorySection: some View {
        CollapsibleSection {
            Toggle("Use scoped memory in agent runs", isOn: $agentMemoryEnabled)
            Toggle("Allow proposals for sensitive memory", isOn: $allowSensitiveMemoryProposals)
                .disabled(!agentMemoryEnabled)

            Stepper(
                "Retrieve up to \(maximumRetrievedMemoryEntries) entries per turn",
                value: $maximumRetrievedMemoryEntries,
                in: 1...8
            )
            .disabled(!agentMemoryEnabled)

            Picker("Retrieval context budget", selection: $maximumRetrievedMemoryTokens) {
                Text("128 tokens").tag(128)
                Text("256 tokens").tag(256)
                Text("512 tokens").tag(512)
                Text("1,024 tokens").tag(1_024)
                Text("2,048 tokens").tag(2_048)
            }
            .disabled(!agentMemoryEnabled)

            Picker("Default retention", selection: $memoryRetention) {
                Text("Do not retain").tag(AgentMemoryRetentionPolicy.doNotRetain.rawValue)
                Text("24 hours").tag(AgentMemoryRetentionPolicy.hours24.rawValue)
                Text("7 days").tag(AgentMemoryRetentionPolicy.days7.rawValue)
                Text("30 days").tag(AgentMemoryRetentionPolicy.days30.rawValue)
                Text("Until manually deleted").tag(AgentMemoryRetentionPolicy.untilManuallyDeleted.rawValue)
            }

            LabeledContent("Scope isolation") {
                Text("Origin, task, conversation, session")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Sensitive memory") {
                Text("Explicit approval required")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Private browsing") {
                Text("Never persisted")
                    .foregroundStyle(.secondary)
            }

            if let summary = memoryController.storageSummary {
                LabeledContent("Stored memory") {
                    Text("\(summary.enabledEntryCount) active of \(summary.entryCount) · \(ByteCountFormatter.string(fromByteCount: Int64(summary.approximateBytes), countStyle: .file))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Button("Review & Manage Stored Memory…") {
                showingMemoryManager = true
            }
        } header: {
            SettingsLabel("Scoped Agent Memory", systemImage: "brain.head.profile", tint: SettingsTint.agent)
        } footer: {
            Text("Retrieved memory is supplied to the model as untrusted context and cannot grant tools, permissions, or new authority.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var diagnosticsSection: some View {
        CollapsibleSection {
            Toggle("Keep on-device run metrics", isOn: $localMetricsEnabled)
            Stepper(value: $metricRetentionDays, in: 1...365) {
                LabeledContent("Metrics retention") {
                    Text("\(metricRetentionDays) days").monospacedDigit()
                }
            }
            .disabled(!localMetricsEnabled)

            LabeledContent("Recorded metric events") {
                Text("\(observabilityController.eventCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let dashboard = observabilityController.dashboard {
                LabeledContent("Runs represented") {
                    Text("\(dashboard.runs.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Retries · limit events") {
                    Text("\(dashboard.aggregate.retries) · \(dashboard.aggregate.limitEvents)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Button("Clear Local Metrics", role: .destructive) {
                Task { await observabilityController.clear() }
            }
            .disabled(observabilityController.eventCount == 0)

            LabeledContent("Remote diagnostics") {
                Text("Off")
                    .foregroundStyle(.secondary)
            }

            if generatingDiagnosticPreview {
                ProgressView("Building metadata-only diagnostic preview…")
                    .controlSize(.small)
            } else {
                Button("Generate Redacted Diagnostic Preview", action: generateDiagnosticPreview)
            }

            if let preview = diagnosticPreview {
                DisclosureGroup("Diagnostic preview") {
                    LabeledContent("Size") {
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(preview.jsonData.count),
                            countStyle: .file
                        ))
                        .monospacedDigit()
                    }
                    LabeledContent("Redaction") {
                        Text(preview.manifest.redactionPolicy)
                    }
                    LabeledContent("Included content") {
                        Text("\(preview.manifest.includedContentCount)")
                            .monospacedDigit()
                    }
                    LabeledContent("Omitted content · incognito") {
                        Text("\(preview.manifest.omittedContentCount) · \(preview.manifest.omittedIncognitoContentCount)")
                            .monospacedDigit()
                    }
                    LabeledContent("Omitted timeline · metrics · errors") {
                        Text("\(preview.manifest.omittedTimelineEntryCount) · \(preview.manifest.omittedMetricEventCount) · \(preview.manifest.omittedErrorCount)")
                            .monospacedDigit()
                    }
                    LabeledContent("Remote upload") {
                        Text(preview.manifest.remoteUploadPerformed ? "Yes" : "No")
                    }
                    LabeledContent("SHA-256") {
                        Text(preview.sha256)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    Button("Export This Preview…") {
                        exportDiagnosticPreview(preview)
                    }
                }
            }

            if let diagnosticMessage {
                Text(diagnosticMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            Toggle("Capture console events for active agent runs", isOn: $webKitConsoleCapture)
            Toggle("Include diagnostic text in captured events", isOn: $webKitDiagnosticContent)

            if webKitDiagnosticContent {
                Label(
                    "Captured text can include page or dialog content. It remains scoped to the active run and is redacted from ordinary logs.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        } header: {
            SettingsLabel("Observability & Page Signals", systemImage: "waveform.path.ecg", tint: SettingsTint.agent)
        } footer: {
            Text("Metrics stay on this device and never include incognito runs. Navigation and lifecycle metadata is captured only while a run owns the page. Console capture and textual diagnostic content are off until you opt in. Remote reporting stays off and has no transport.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var syncSection: some View {
        CollapsibleSection {
            Toggle(
                "Sync scheduled task definitions",
                isOn: syncBinding(for: .schedules)
            )
            Toggle(
                "Sync provider presets",
                isOn: syncBinding(for: .providerPresets)
            )
            Toggle(
                "Sync user-authored memory",
                isOn: syncBinding(for: .userAuthoredMemory)
            )

            if definitionSyncService.isSyncing {
                ProgressView("Syncing agent definitions…")
                    .controlSize(.small)
            } else {
                LabeledContent("Last sync") {
                    Text(
                        definitionSyncService.lastSyncAt?.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ) ?? "Not yet synced"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            if let error = definitionSyncService.lastError {
                Label(error, systemImage: "exclamationmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !definitionSyncService.unavailableSchedules.isEmpty {
                DisclosureGroup(
                    "Imported schedules needing attention (\(definitionSyncService.unavailableSchedules.count))"
                ) {
                    ForEach(
                        definitionSyncService.unavailableSchedules.keys.sorted {
                            $0.uuidString < $1.uuidString
                        },
                        id: \.self
                    ) { id in
                        if let availability = definitionSyncService.unavailableSchedules[id] {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(syncedScheduleName(id))
                                    .font(.subheadline.weight(.semibold))
                                Text(availability.reasons.map(syncReasonLabel).joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let rootID = syncedScheduleCoworkRootID(id) {
                                    if definitionSyncService
                                        .locallyAuthorizedCoworkRootIDs.contains(rootID) {
                                        Button("Revoke Cowork Folder Binding", role: .destructive) {
                                            Task {
                                                await definitionSyncService
                                                    .revokeCoworkRootAuthorization(
                                                        for: id
                                                    )
                                            }
                                        }
                                    } else if missingCoworkRootID(availability) != nil {
                                        Button("Use Current Cowork Folder") {
                                            Task {
                                                _ = await definitionSyncService
                                                    .authorizeCurrentCoworkRoot(
                                                        for: id
                                                    )
                                            }
                                        }
                                        .disabled(workspace.rootURL == nil)
                                    }
                                }
                                if scheduleNeedsAuthorization(availability) {
                                    Button("Authorize on This Mac") {
                                        Task {
                                            await definitionSyncService.authorizeSchedule(id)
                                        }
                                    }
                                }
                                if definitionSyncService
                                    .locallyAuthorizedScheduleIDs.contains(id) {
                                    Button("Revoke Local Authorization", role: .destructive) {
                                        Task {
                                            await definitionSyncService.revokeScheduleAuthorization(id)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            let authorized = definitionSyncService.locallyAuthorizedScheduleIDs
                .filter(isKnownSyncedSchedule)
            if !authorized.isEmpty {
                DisclosureGroup("Authorized on This Mac (\(authorized.count))") {
                    ForEach(
                        authorized.sorted { $0.uuidString < $1.uuidString },
                        id: \.self
                    ) { id in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(syncedScheduleName(id))
                                Spacer()
                                Button("Revoke", role: .destructive) {
                                    Task {
                                        await definitionSyncService
                                            .revokeScheduleAuthorization(id)
                                    }
                                }
                            }
                            if let rootID = syncedScheduleCoworkRootID(id),
                               definitionSyncService
                                .locallyAuthorizedCoworkRootIDs.contains(rootID) {
                                Button("Revoke Cowork Folder Binding", role: .destructive) {
                                    Task {
                                        await definitionSyncService
                                            .revokeCoworkRootAuthorization(
                                                for: id
                                            )
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            }

            if !definitionSyncService.sensitiveMemoryAwaitingReview.isEmpty {
                DisclosureGroup(
                    "Sensitive memory awaiting review (\(definitionSyncService.sensitiveMemoryAwaitingReview.count))"
                ) {
                    ForEach(
                        definitionSyncService.sensitiveMemoryAwaitingReview.sorted {
                            $0.uuidString < $1.uuidString
                        },
                        id: \.self
                    ) { id in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(syncedMemoryText(id))
                                .lineLimit(3)
                                .textSelection(.enabled)
                            Text("This synced item is not available to runs until you explicitly approve its local import.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Approve Sensitive Memory Import") {
                                Task {
                                    await definitionSyncService.approveSensitiveMemory(id)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        } header: {
            SettingsLabel("Agent Definition Sync", systemImage: "icloud", tint: SettingsTint.agent)
        } footer: {
            Text("Each category is separately opt in and uses your private iCloud database. API keys, OAuth tokens, Cowork bookmarks, page handles, run history, transcripts, approvals, and artifacts never sync.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func syncBinding(
        for category: AgentDefinitionSyncCategory
    ) -> Binding<Bool> {
        Binding(
            get: { syncValue(for: category) },
            set: { enabled in
                if enabled {
                    setSyncValue(true, for: category)
                    Task {
                        if !(await definitionSyncService.enable(category)) {
                            setSyncValue(false, for: category)
                        }
                    }
                } else {
                    pendingSyncDisableCategory = category
                    showingSyncDisableChoices = true
                }
            }
        )
    }

    private func confirmSyncDisable(
        _ disposition: AgentDefinitionSyncDisableDisposition
    ) {
        guard let category = pendingSyncDisableCategory else { return }
        pendingSyncDisableCategory = nil
        Task {
            if await definitionSyncService.disable(category, disposition: disposition) {
                setSyncValue(false, for: category)
            }
        }
    }

    private func syncValue(for category: AgentDefinitionSyncCategory) -> Bool {
        switch category {
        case .schedules: syncSchedules
        case .providerPresets: syncProviderPresets
        case .userAuthoredMemory: syncUserAuthoredMemory
        }
    }

    private func setSyncValue(
        _ value: Bool,
        for category: AgentDefinitionSyncCategory
    ) {
        switch category {
        case .schedules: syncSchedules = value
        case .providerPresets: syncProviderPresets = value
        case .userAuthoredMemory: syncUserAuthoredMemory = value
        }
    }

    private func syncCategoryLabel(_ category: AgentDefinitionSyncCategory) -> String {
        switch category {
        case .schedules: "Scheduled Task"
        case .providerPresets: "Provider Preset"
        case .userAuthoredMemory: "User Memory"
        }
    }

    private func isKnownSyncedSchedule(_ id: UUID) -> Bool {
        definitionSyncService.definitions.contains { envelope in
            guard case .schedule(let schedule)? = envelope.payload else {
                return false
            }
            return schedule.id == id
        }
    }

    private func generateDiagnosticPreview() {
        generatingDiagnosticPreview = true
        diagnosticPreview = nil
        diagnosticMessage = nil
        Task {
            do {
                let store = try AgentRunStoreRegistry.store(
                    baseDirectory: BrowserCLI.supportDirectory
                )
                let runs = await store.listRuns()
                let metrics = await AgentObservabilityRuntime.shared.events()
                let timeline = runs.map { run in
                    AgentDiagnosticTimelineInput(
                        runID: run.id,
                        parentRunID: run.parentRunID,
                        entryPoint: run.entryPoint,
                        status: run.status,
                        startedAt: run.startedAt,
                        finishedAt: run.finishedAt,
                        // The default Settings export is deliberately
                        // metadata-only. It does not even hand a URL to the
                        // redactor.
                        targetURL: nil,
                        incognito: run.incognito
                    )
                }
                let info = Bundle.main.infoDictionary ?? [:]
                #if arch(arm64)
                let architecture = "arm64"
                #elseif arch(x86_64)
                let architecture = "x86_64"
                #else
                let architecture = "unknown"
                #endif
                let request = AgentObservabilityDiagnosticRequest(
                    versions: AgentDiagnosticVersionInfo(
                        appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                        buildVersion: info["CFBundleVersion"] as? String ?? "unknown",
                        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                        architecture: architecture,
                        agentSchemaVersion: AgentRun.schemaVersion
                    ),
                    // The generator exports only the shape of this allowlisted
                    // configuration. Endpoint identities, models, credentials,
                    // prompts, and file/page content are never supplied.
                    configuration: diagnosticConfigurationShapeInput,
                    timeline: timeline,
                    metricEvents: metrics,
                    errors: [],
                    content: [],
                    configuredSecrets: [],
                    generatedAt: Date()
                )
                let preview = try AgentObservabilityDiagnosticGenerator().preview(
                    request: request
                )
                diagnosticPreview = preview
                diagnosticMessage = "Preview generated locally. Nothing was uploaded."
            } catch {
                diagnosticMessage = "Could not generate diagnostics: \(error.localizedDescription)"
            }
            generatingDiagnosticPreview = false
        }
    }

    private var diagnosticConfigurationShapeInput: [String: JSONValue] {
        [
            "budgets": .object([
                "maximumTurns": .number(Double(maximumTurns)),
                "maximumToolCalls": .number(Double(maximumToolCalls)),
                "maximumWallMinutes": .number(Double(maximumWallMinutes)),
                "maximumProviderTokens": .number(Double(maximumProviderTokens)),
                "maximumProviderCostMicrounits": .number(Double(maximumProviderCostMicrounits)),
                "maximumOpenPages": .number(Double(maximumOpenPages)),
                "maximumModelResultMiB": .number(Double(maximumModelResultMiB)),
                "maximumDownloads": .number(Double(maximumDownloads)),
                "maximumDownloadMiB": .number(Double(maximumDownloadMiB)),
                "maximumArtifacts": .number(Double(maximumArtifacts)),
                "maximumArtifactMiB": .number(Double(maximumArtifactMiB)),
            ]),
            "memory": .object([
                "enabled": .boolean(agentMemoryEnabled),
                "sensitiveProposals": .boolean(allowSensitiveMemoryProposals),
                "retrievalEntries": .number(Double(maximumRetrievedMemoryEntries)),
                "retrievalTokens": .number(Double(maximumRetrievedMemoryTokens)),
            ]),
            "observability": .object([
                "localMetrics": .boolean(localMetricsEnabled),
                "retentionDays": .number(Double(metricRetentionDays)),
                "remoteDiagnostics": .boolean(false),
            ]),
            "definitionSync": .object([
                "schedules": .boolean(syncSchedules),
                "providerPresets": .boolean(syncProviderPresets),
                "userAuthoredMemory": .boolean(syncUserAuthoredMemory),
            ]),
        ]
    }

    private func exportDiagnosticPreview(
        _ preview: AgentObservabilityDiagnosticPreview
    ) {
        let panel = NSSavePanel()
        panel.title = "Export Redacted Agent Diagnostics"
        panel.nameFieldStringValue = "browser-agent-diagnostics-redacted.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let receipt = try AgentObservabilityDiagnosticExporter(
                writer: AgentAtomicDiagnosticBundleWriter()
            ).export(preview, to: destination)
            diagnosticMessage = "Exported \(receipt.byteCount.formatted()) bytes · SHA-256 \(receipt.sha256)"
        } catch {
            diagnosticMessage = "Could not export diagnostics: \(error.localizedDescription)"
        }
    }

    private func clearProviderPricing() {
        pricingProviderID = ""
        pricingModel = ""
        pricingCurrencyCode = "USD"
        pricingInputRate = ""
        pricingCachedInputRate = ""
        pricingOutputRate = ""
        pricingBlendedRate = ""
    }

    private func applyCatalogPricingIfNeeded() {
        guard let pricing = AgentProviderModelCatalog.pricing(
            provider: provider,
            model: currentModelName
        ), !pricingMatchesCurrentModel else { return }

        pricingProviderID = provider.rawValue
        pricingModel = currentModelName
        pricingCurrencyCode = pricing.currencyCode
        pricingInputRate = String(pricing.inputMicrounitsPerMillionTokens ?? 0)
        pricingCachedInputRate = String(pricing.cachedInputMicrounitsPerMillionTokens ?? 0)
        pricingOutputRate = String(pricing.outputMicrounitsPerMillionTokens ?? 0)
        pricingBlendedRate = pricing.estimatedBlendedMicrounitsPerMillionTokens.map(String.init) ?? ""
    }

    private func syncedScheduleName(_ id: UUID) -> String {
        for envelope in definitionSyncService.definitions {
            guard envelope.definitionID == id,
                  case .schedule(let schedule)? = envelope.payload else { continue }
            return schedule.name
        }
        return "Imported schedule"
    }

    private func syncedMemoryText(_ id: UUID) -> String {
        for envelope in definitionSyncService.definitions {
            guard envelope.definitionID == id,
                  case .userAuthoredMemory(let memory)? = envelope.payload else { continue }
            return memory.text
        }
        return "Sensitive synced memory"
    }

    private func scheduleNeedsAuthorization(
        _ availability: AgentDefinitionAvailability
    ) -> Bool {
        availability.reasons.contains { reason in
            switch reason {
            case .capabilityNotGranted, .scheduledPolicyNotSatisfied:
                true
            default:
                false
            }
        }
    }

    private func missingCoworkRootID(
        _ availability: AgentDefinitionAvailability
    ) -> UUID? {
        availability.reasons.lazy.compactMap { reason in
            guard case .missingCoworkScope(let id) = reason else { return nil }
            return id
        }.first
    }

    private func syncedScheduleCoworkRootID(_ id: UUID) -> UUID? {
        for envelope in definitionSyncService.definitions {
            guard envelope.definitionID == id,
                  !envelope.isTombstone,
                  case .schedule(let schedule)? = envelope.payload else {
                continue
            }
            return schedule.requiredCoworkRootID
        }
        return nil
    }

    private func syncReasonLabel(_ reason: AgentDefinitionUnavailabilityReason) -> String {
        switch reason {
        case .categorySyncDisabled:
            "Schedule sync is off"
        case .tombstone:
            "Deleted definition"
        case .definitionDisabled:
            "Disabled by its author"
        case .unsupportedSchema:
            "Unsupported definition version"
        case .unsupportedPlatform:
            "Unsupported on this platform"
        case .missingProviderPreset:
            "Provider preset is missing"
        case .missingLocalProviderAccess:
            "Provider access is not configured locally"
        case .missingMCPConnection:
            "A trusted app integration is missing"
        case .missingCoworkScope:
            "Cowork access is missing"
        case .missingBrowserSession:
            "Browser session is unavailable"
        case .unsupportedCapability:
            "Required capability is unsupported"
        case .capabilityNotGranted:
            "Local capability approval is required"
        case .scheduledPolicyNotSatisfied:
            "Scheduled-run authorization is required"
        }
    }
}

/// An editable native combo box: users can type any provider model ID, while
/// known IDs complete as they type and stay selectable with the arrow keys.
struct ModelAutocompleteField: NSViewRepresentable {
    @Binding var model: String
    let suggestions: [String]
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let field = NSComboBox()
        field.isEditable = true
        field.completes = true
        field.placeholderString = placeholder
        field.addItems(withObjectValues: suggestions)
        field.stringValue = model
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.suggestions != suggestions {
            field.removeAllItems()
            field.addItems(withObjectValues: suggestions)
            context.coordinator.suggestions = suggestions
        }
        if field.stringValue != model { field.stringValue = model }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ModelAutocompleteField
        var suggestions: [String]

        init(_ parent: ModelAutocompleteField) {
            self.parent = parent
            suggestions = parent.suggestions
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox else { return }
            parent.model = field.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox,
                  field.indexOfSelectedItem >= 0 else { return }
            parent.model = field.stringValue
        }
    }
}

/// An account-aware model input. The provider's own catalog takes precedence
/// over the small current fallback list used before a refresh.
struct ProviderModelPicker: View {
    @Binding var model: String
    let provider: BrowserAgentProvider
    let apiKey: String
    let customEndpoint: String

    @State private var discoveredModels: [String] = []
    @State private var status: String?
    @State private var isRefreshing = false
    @State private var hasRefreshed = false

    private var suggestions: [String] {
        guard !hasRefreshed else { return discoveredModels }
        return AgentProviderModelCatalog.modelIDs(for: provider)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ModelAutocompleteField(
                model: $model,
                suggestions: suggestions,
                placeholder: "Choose or refresh models"
            )
            HStack(spacing: 6) {
                if let status {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button(isRefreshing ? "Refreshing…" : "Refresh Available Models") {
                    refreshModels()
                }
                .disabled(isRefreshing)
            }
        }
        .id(provider)
    }

    private func refreshModels() {
        isRefreshing = true
        status = nil
        Task {
            do {
                let models = try await AgentProviderModelDiscovery.models(
                    for: provider,
                    apiKey: apiKey,
                    customEndpoint: customEndpoint
                )
                discoveredModels = models
                hasRefreshed = true
                status = models.isEmpty ? "No models found" : "\(models.count) models available"
            } catch {
                status = error.localizedDescription
            }
            isRefreshing = false
        }
    }
}

#Preview {
    AgentSettingsView()
        .frame(width: 620, height: 900)
}
#endif
