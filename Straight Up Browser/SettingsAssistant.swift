import Foundation
import Observation

// Settings assistance deliberately has no BrowserAgent, page, file, credential,
// provider, or arbitrary UserDefaults interface. This is the complete v1 catalog.
nonisolated enum BrowserSettingID: String, Codable, CaseIterable, Sendable {
    case fadeInPages = "appearance.fadeInPages"
    case fadeDuration = "appearance.fadeDurationMs"
    case theme = "appearance.theme"
    case automaticLinkSplit = "general.automaticLinkSplit"
}

nonisolated enum BrowserSettingValue: Equatable, Codable, Sendable {
    case bool(Bool)
    case number(Double)
    case choice(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else { self = .choice(try value.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .bool(let boolean): try value.encode(boolean)
        case .number(let number): try value.encode(number)
        case .choice(let choice): try value.encode(choice)
        }
    }

    var display: String {
        switch self {
        case .bool(let value): value ? "On" : "Off"
        case .number(let value): "\(value.formatted()) ms"
        case .choice(let value): value
        }
    }

    var defaultsValue: Any {
        switch self {
        case .bool(let value): value
        case .number(let value): value
        case .choice(let value): value
        }
    }
}

nonisolated struct BrowserSettingDescriptor: Identifiable, Equatable, Sendable {
    let id: BrowserSettingID
    let key: String
    let title: String
    let detail: String
    let destination: String
    let defaultValue: BrowserSettingValue
    let effect: String

    func accepts(_ value: BrowserSettingValue) -> Bool {
        switch (id, value) {
        case (.fadeInPages, .bool), (.automaticLinkSplit, .bool): true
        case (.theme, .choice(let name)): ["System", "Light", "Dark"].contains(name)
        case (.fadeDuration, .number(let duration)):
            duration.isFinite && (100...1000).contains(duration) && duration.truncatingRemainder(dividingBy: 50) == 0
        default: false
        }
    }
}

nonisolated enum SettingsRegistry {
    static let revision = 1
    static let descriptors: [BrowserSettingDescriptor] = [
        .init(id: .fadeInPages, key: "fadeInPages", title: "Fade pages in", detail: "Fade a page in once it has drawn.", destination: "appearance.page-fade", defaultValue: .bool(true), effect: "Takes effect immediately. Changes page presentation; does not reload or recreate tabs, calls, or permissions."),
        .init(id: .fadeDuration, key: "fadeInDuration", title: "Page fade length", detail: "How long a page takes to fade in, in milliseconds.", destination: "appearance.page-fade", defaultValue: .number(250), effect: "Takes effect on the next page fade. Does not turn fading on when it is off or reload a tab."),
        .init(id: .theme, key: "theme", title: "Theme", detail: "System, Light, or Dark appearance for Browser's chrome.", destination: "appearance.theme", defaultValue: .choice("System"), effect: "Redraws Browser's chrome immediately. Websites choose their own appearance; no tab reload is requested."),
        .init(id: .automaticLinkSplit, key: "automaticLinkSplitEnabled", title: "Open new links beside their source", detail: "Keep the source beside a new tab created by a website link.", destination: "general.new-tab-links", defaultValue: .bool(false), effect: "Applies to subsequent website-created new tabs. Command-click is unaffected; existing panes and calls are not rearranged."),
    ]

    static func descriptor(_ id: BrowserSettingID) -> BrowserSettingDescriptor {
        descriptors.first { $0.id == id }!
    }
}

nonisolated struct SettingsValueSnapshot: Equatable, Sendable {
    let settingID: BrowserSettingID
    let stored: BrowserSettingValue?
    let effective: BrowserSettingValue
    let revision: UInt64
    var source: String { stored == nil ? "Default" : "Saved on this Mac" }
}

nonisolated enum SettingsAssistantAvailability {
    static let enabledKey = "settingsAssistantEnabled"
    static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        let master = defaults.object(forKey: "aiFeaturesEnabled") == nil || defaults.bool(forKey: "aiFeaturesEnabled")
        return master && defaults.bool(forKey: enabledKey)
    }
}

nonisolated enum SettingsAssistantError: String, Error, LocalizedError, Equatable {
    case invalidProposal, unsupported, questionOnly, stalePreview, draftConflict, permissionDenied
    case expired, alreadySet, applyFailed, recoveryRequired, undoConflict, persistenceUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidProposal: "The suggestion is invalid. No setting changed."
        case .unsupported: "This change requires its native Settings control."
        case .questionOnly: "Ask mode only explains settings. Choose Preview a change to prepare a change."
        case .stalePreview: "This setting changed since the preview. Prepare a fresh preview."
        case .draftConflict: "This setting has an open manual draft. Save or cancel that draft first."
        case .permissionDenied: "Settings assistance is off. Open Agent settings to enable it."
        case .expired: "This preview expired. Prepare a fresh preview."
        case .alreadySet: "This setting already has that value. Nothing changed."
        case .applyFailed: "The setting could not be verified. Open its native control to check it."
        case .recoveryRequired: "An earlier change has an uncertain outcome. Check the native setting before making another change."
        case .undoConflict: "This setting was edited after the change. Undo will not replace your newer edit."
        case .persistenceUnavailable: "Apply is waiting for a verified persistence adapter. Use the native setting to make this change."
        }
    }
}

// The protocol makes the release gate mechanical: a UserDefaults cache read is
// not proof of a durable, recoverable commit. No production adapter currently
// attests to that property. The native manual controls remain fully functional.
@MainActor protocol SettingsPreferenceStore: AnyObject {
    var supportsRecoverableCommit: Bool { get }
    func read(_ descriptor: BrowserSettingDescriptor) -> BrowserSettingValue?
    func write(_ value: BrowserSettingValue?, for descriptor: BrowserSettingDescriptor) throws
    /// A production implementation must durably record/reconcile this operation
    /// identity and compare the expected stored state before writing. A thrown
    /// error is treated as uncertain, freezes the writer, and is never replayed.
    func commit(operationID: UUID, value: BrowserSettingValue?, expected: BrowserSettingValue?, for descriptor: BrowserSettingDescriptor) throws
}

@MainActor final class SettingsDefaultsStore: SettingsPreferenceStore {
    let supportsRecoverableCommit = false
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func read(_ descriptor: BrowserSettingDescriptor) -> BrowserSettingValue? {
        guard defaults.object(forKey: descriptor.key) != nil else { return nil }
        switch descriptor.id {
        case .fadeInPages, .automaticLinkSplit: return .bool(defaults.bool(forKey: descriptor.key))
        case .fadeDuration: return .number(defaults.double(forKey: descriptor.key))
        case .theme: return .choice(defaults.string(forKey: descriptor.key) ?? "System")
        }
    }

    func write(_ value: BrowserSettingValue?, for descriptor: BrowserSettingDescriptor) throws {
        if let value { defaults.set(value.defaultsValue, forKey: descriptor.key) }
        else { defaults.removeObject(forKey: descriptor.key) }
    }

    func commit(operationID: UUID, value: BrowserSettingValue?, expected: BrowserSettingValue?, for descriptor: BrowserSettingDescriptor) throws {
        throw SettingsAssistantError.persistenceUnavailable
    }
}

nonisolated struct SettingsValidatedProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    let settingID: BrowserSettingID
    let before: SettingsValueSnapshot
    let after: BrowserSettingValue
    let registryRevision: Int
    let sessionID: UUID
    let requestGeneration: UInt64
    let authorizationGeneration: UInt64
    let expiresAt: Date
    fileprivate init(settingID: BrowserSettingID, before: SettingsValueSnapshot, after: BrowserSettingValue, sessionID: UUID, requestGeneration: UInt64, authorizationGeneration: UInt64, expiresAt: Date) {
        id = UUID()
        self.settingID = settingID
        self.before = before
        self.after = after
        registryRevision = SettingsRegistry.revision
        self.sessionID = sessionID
        self.requestGeneration = requestGeneration
        self.authorizationGeneration = authorizationGeneration
        self.expiresAt = expiresAt
    }
}

nonisolated struct SettingsChangeReceipt: Identifiable, Equatable, Sendable {
    let id: UUID
    let settingID: BrowserSettingID
    let before: BrowserSettingValue?
    let after: BrowserSettingValue
    let postRevision: UInt64
}

/// Serializes native manual edits, draft ownership, validation, and commit. All
/// admission checks and the single write happen in one synchronous MainActor
/// turn. No approval object or write operation is exported as an agent tool.
@MainActor @Observable final class SettingsTransactionCoordinator {
    static let shared = SettingsTransactionCoordinator(store: SettingsDefaultsStore())
    private let store: any SettingsPreferenceStore
    private var snapshots: [BrowserSettingID: SettingsValueSnapshot] = [:]
    private var staged: [UUID: SettingsValidatedProposal] = [:]
    private var completed: [UUID: SettingsChangeReceipt] = [:]
    private var receipts: [UUID: SettingsChangeReceipt] = [:]
    private var receiptOrder: [UUID] = []
    private var completedOrder: [UUID] = []
    private var undone: Set<UUID> = []
    private var drafts: [BrowserSettingID: Set<UUID>] = [:]
    private(set) var authorizationGeneration: UInt64 = 0
    private(set) var recoveryRequired = false
    private(set) var changeGeneration: UInt64 = 0

    init(store: any SettingsPreferenceStore) { self.store = store }
    var canApply: Bool { store.supportsRecoverableCommit && !recoveryRequired }

    func snapshot(_ id: BrowserSettingID) -> SettingsValueSnapshot {
        let descriptor = SettingsRegistry.descriptor(id)
        let stored = store.read(descriptor)
        if let existing = snapshots[id], existing.stored == stored { return existing }
        let next = SettingsValueSnapshot(settingID: id, stored: stored, effective: stored ?? descriptor.defaultValue, revision: (snapshots[id]?.revision ?? 0) + 1)
        snapshots[id] = next
        return next
    }

    /// Called by known legacy/manual writers and defaults observation. A
    /// same-value edit still changes the revision and invalidates old consent.
    func noteManualWrite(_ id: BrowserSettingID) {
        let descriptor = SettingsRegistry.descriptor(id)
        let stored = store.read(descriptor)
        snapshots[id] = .init(settingID: id, stored: stored, effective: stored ?? descriptor.defaultValue, revision: (snapshots[id]?.revision ?? 0) + 1)
        changeGeneration &+= 1
    }

    func setManually(id: BrowserSettingID, value: BrowserSettingValue) {
        guard SettingsRegistry.descriptor(id).accepts(value) else { return }
        try? store.write(value, for: SettingsRegistry.descriptor(id))
        noteManualWrite(id)
    }

    func setDraft(_ id: BrowserSettingID, owner: UUID, isOpen: Bool) {
        if isOpen { drafts[id, default: []].insert(owner) }
        else { drafts[id]?.remove(owner) }
        changeGeneration &+= 1
    }

    func revoke() {
        authorizationGeneration &+= 1
        staged.removeAll()
        changeGeneration &+= 1
    }

    func invalidate(sessionID: UUID) {
        staged = staged.filter { $0.value.sessionID != sessionID }
    }

    func preview(id: BrowserSettingID, value: BrowserSettingValue, sessionID: UUID, generation: UInt64, questionOnly: Bool, available: Bool, now: Date = Date()) throws -> SettingsValidatedProposal {
        guard available else { throw SettingsAssistantError.permissionDenied }
        guard !questionOnly else { throw SettingsAssistantError.questionOnly }
        guard SettingsRegistry.descriptor(id).accepts(value) else { throw SettingsAssistantError.invalidProposal }
        guard drafts[id, default: []].isEmpty else { throw SettingsAssistantError.draftConflict }
        let before = snapshot(id)
        guard before.effective != value else { throw SettingsAssistantError.alreadySet }
        let proposal = SettingsValidatedProposal(settingID: id, before: before, after: value, sessionID: sessionID, requestGeneration: generation, authorizationGeneration: authorizationGeneration, expiresAt: now.addingTimeInterval(5 * 60))
        staged[proposal.id] = proposal
        return proposal
    }

    func check(_ proposal: SettingsValidatedProposal, sessionID: UUID, generation: UInt64, questionOnly: Bool, available: Bool, now: Date = Date()) throws {
        guard available, proposal.authorizationGeneration == authorizationGeneration else { throw SettingsAssistantError.permissionDenied }
        guard !questionOnly else { throw SettingsAssistantError.questionOnly }
        guard proposal.sessionID == sessionID, proposal.requestGeneration == generation, staged[proposal.id] == proposal, proposal.registryRevision == SettingsRegistry.revision else { throw SettingsAssistantError.stalePreview }
        guard now < proposal.expiresAt else { throw SettingsAssistantError.expired }
        guard drafts[proposal.settingID, default: []].isEmpty else { throw SettingsAssistantError.draftConflict }
        guard snapshot(proposal.settingID) == proposal.before else { throw SettingsAssistantError.stalePreview }
        guard SettingsRegistry.descriptor(proposal.settingID).accepts(proposal.after) else { throw SettingsAssistantError.invalidProposal }
    }

    /// This method may only be called by the native button with its visible,
    /// immutable card. The exact locally staged object is the one-use permit.
    func applyFromNativeUI(_ proposal: SettingsValidatedProposal, sessionID: UUID, generation: UInt64, questionOnly: Bool, available: Bool, now: Date = Date()) throws -> SettingsChangeReceipt {
        guard available, proposal.authorizationGeneration == authorizationGeneration else { throw SettingsAssistantError.permissionDenied }
        guard !questionOnly else { throw SettingsAssistantError.questionOnly }
        guard proposal.sessionID == sessionID, proposal.requestGeneration == generation else { throw SettingsAssistantError.stalePreview }
        if let receipt = completed[proposal.id] { return receipt }
        try check(proposal, sessionID: sessionID, generation: generation, questionOnly: questionOnly, available: available, now: now)
        guard !recoveryRequired else { throw SettingsAssistantError.recoveryRequired }
        guard store.supportsRecoverableCommit else { throw SettingsAssistantError.persistenceUnavailable }
        let descriptor = SettingsRegistry.descriptor(proposal.settingID)
        do {
            try store.commit(operationID: proposal.id, value: proposal.after, expected: proposal.before.stored, for: descriptor)
            guard store.read(descriptor) == proposal.after else { throw SettingsAssistantError.applyFailed }
        } catch {
            // A backend must reconcile operation identity before declaring its
            // support. Never blindly retry a write whose outcome is uncertain.
            recoveryRequired = true
            revoke()
            throw SettingsAssistantError.recoveryRequired
        }
        noteManualWrite(proposal.settingID)
        let receipt = SettingsChangeReceipt(id: proposal.id, settingID: proposal.settingID, before: proposal.before.stored, after: proposal.after, postRevision: snapshot(proposal.settingID).revision)
        completed[proposal.id] = receipt
        receipts[receipt.id] = receipt
        receiptOrder.append(receipt.id)
        completedOrder.append(receipt.id)
        staged.removeValue(forKey: proposal.id)
        if receiptOrder.count > 20 { receipts.removeValue(forKey: receiptOrder.removeFirst()) }
        if completedOrder.count > 100 { completed.removeValue(forKey: completedOrder.removeFirst()) }
        return receipt
    }

    func undoFromNativeUI(_ receipt: SettingsChangeReceipt, available: Bool, questionOnly: Bool) throws {
        guard available else { throw SettingsAssistantError.permissionDenied }
        guard !questionOnly else { throw SettingsAssistantError.questionOnly }
        guard canApply else { throw SettingsAssistantError.persistenceUnavailable }
        guard receipts[receipt.id] == receipt, !undone.contains(receipt.id) else { throw SettingsAssistantError.undoConflict }
        guard drafts[receipt.settingID, default: []].isEmpty else { throw SettingsAssistantError.draftConflict }
        let current = snapshot(receipt.settingID)
        guard current.revision == receipt.postRevision, current.stored == receipt.after else { throw SettingsAssistantError.undoConflict }
        do {
            try store.commit(operationID: UUID(), value: receipt.before, expected: receipt.after, for: SettingsRegistry.descriptor(receipt.settingID))
            guard store.read(SettingsRegistry.descriptor(receipt.settingID)) == receipt.before else { throw SettingsAssistantError.applyFailed }
        } catch {
            recoveryRequired = true
            revoke()
            throw SettingsAssistantError.recoveryRequired
        }
        noteManualWrite(receipt.settingID)
        undone.insert(receipt.id)
    }
}

nonisolated struct SettingsAssistantSuggestion: Decodable, Sendable {
    enum Kind: String, Decodable { case answer, clarify, proposal, manual, unsupported }
    struct Change: Decodable, Sendable {
        struct Scope: Decodable, Sendable { let kind: String }
        let settingID: BrowserSettingID
        let operation: String
        let scope: Scope
        let value: BrowserSettingValue
    }
    let schemaVersion: Int
    let requestContextID: String
    let kind: Kind
    let summary: String
    let settingReferences: [BrowserSettingID]
    let question: String?
    let changes: [Change]

    static func decode(_ data: Data, contextID: String, questionOnly: Bool) throws -> Self {
        guard data.count <= 16_384 else { throw SettingsAssistantError.invalidProposal }
        var parser = SettingsStrictJSON(data: data)
        try parser.validate()
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any], Set(root.keys) == Set(["schemaVersion", "requestContextID", "kind", "summary", "settingReferences", "question", "changes"]),
              let changes = root["changes"] as? [[String: Any]] else { throw SettingsAssistantError.invalidProposal }
        for change in changes {
            guard Set(change.keys) == Set(["settingID", "operation", "scope", "value"]), let scope = change["scope"] as? [String: Any], Set(scope.keys) == ["kind"] else { throw SettingsAssistantError.invalidProposal }
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 1, result.requestContextID == contextID, contextID.range(of: "^ctx_[A-Za-z0-9_-]{8,80}$", options: .regularExpression) != nil, !result.summary.isEmpty, result.summary.count <= 1_600, result.settingReferences.count <= 5, Set(result.settingReferences).count == result.settingReferences.count, result.question.map({ !$0.isEmpty && $0.count <= 300 }) ?? true else { throw SettingsAssistantError.invalidProposal }
        guard (result.kind == .clarify) == (result.question != nil) else { throw SettingsAssistantError.invalidProposal }
        guard result.changes.count <= 1 else { throw SettingsAssistantError.invalidProposal }
        if result.kind == .proposal {
            guard !questionOnly else { throw SettingsAssistantError.questionOnly }
            guard let change = result.changes.first, change.operation == "set", change.scope.kind == "app", SettingsRegistry.descriptor(change.settingID).accepts(change.value) else { throw SettingsAssistantError.invalidProposal }
        } else if !result.changes.isEmpty { throw SettingsAssistantError.invalidProposal }
        return result
    }
}

/// JSONDecoder accepts duplicate keys. Reject those and excessive nesting before
/// decoding provider output. The standard parser still validates Unicode,
/// number syntax, escape sequences, and finite values afterwards.
private nonisolated struct SettingsStrictJSON {
    let bytes: [UInt8]
    var index = 0
    init(data: Data) { bytes = Array(data) }
    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw SettingsAssistantError.invalidProposal }
    }
    mutating func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte: UInt8) -> Bool { whitespace(); if index < bytes.count, bytes[index] == byte { index += 1; return true }; return false }
    mutating func string() throws -> String {
        whitespace()
        guard index < bytes.count, bytes[index] == 34 else { throw SettingsAssistantError.invalidProposal }
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if !escaped && byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            if !escaped && byte == 92 { escaped = true } else { escaped = false }
        }
        throw SettingsAssistantError.invalidProposal
    }
    mutating func value(depth: Int) throws {
        guard depth <= 8 else { throw SettingsAssistantError.invalidProposal }
        whitespace()
        guard index < bytes.count else { throw SettingsAssistantError.invalidProposal }
        if take(123) {
            var keys: Set<String> = []
            if take(125) { return }
            repeat {
                guard keys.insert(try string()).inserted, take(58) else { throw SettingsAssistantError.invalidProposal }
                try value(depth: depth + 1)
            } while take(44)
            guard take(125) else { throw SettingsAssistantError.invalidProposal }
        } else if take(91) {
            if take(93) { return }
            repeat { try value(depth: depth + 1) } while take(44)
            guard take(93) else { throw SettingsAssistantError.invalidProposal }
        } else if bytes[index] == 34 { _ = try string() }
        else {
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard start < index else { throw SettingsAssistantError.invalidProposal }
        }
    }
}

/// Offline deterministic first slice. No model request, transcript persistence,
/// agent memory, automatic context capture, or provider fallback takes place.
@MainActor @Observable final class SettingsConversationCoordinator {
    enum Mode: String, CaseIterable, Identifiable {
        case ask = "Ask a question"
        case preview = "Preview a change"
        var id: Self { self }
    }
    let sessionID = UUID()
    private let transactions: SettingsTransactionCoordinator
    private(set) var generation: UInt64 = 0
    private(set) var answer = "What would you like Browser to do differently?"
    private(set) var references: [BrowserSettingID] = []
    private(set) var proposal: SettingsValidatedProposal?
    private(set) var receipt: SettingsChangeReceipt?
    private(set) var message: String?
    var mode: Mode = .ask { didSet { invalidate() } }
    var input = "" { didSet { if oldValue != input { invalidate() } } }

    init(transactions: SettingsTransactionCoordinator = .shared) { self.transactions = transactions }
    var questionOnly: Bool { mode == .ask }
    var applyIsAvailable: Bool { transactions.canApply }

    func invalidate() {
        generation &+= 1
        transactions.invalidate(sessionID: sessionID)
        proposal = nil
        message = nil
    }

    func revoke() { invalidate(); transactions.revoke() }

    func submit(available: Bool) {
        invalidate()
        references = []
        guard available else { message = SettingsAssistantError.permissionDenied.localizedDescription; return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= 2_000 else { answer = "Describe one setting or choose an example."; return }
        let isQuestion = questionOnly || text.hasSuffix("?") || ["why", "what", "how", "can ", "could ", "does ", "is "].contains(where: text.hasPrefix)
        if text.contains("call") || text.contains("research beside") {
            answer = "Keep the existing call tab in place and put research beside it with pane arrangements. Opening a URL cannot restore a live call. A preference cannot guarantee call continuity."
            return
        }
        let id: BrowserSettingID?
        if text.contains("fade") || text.contains("fading") { id = text.contains("duration") || text.contains("length") || text.contains(" ms") ? .fadeDuration : .fadeInPages }
        else if text.contains("theme") || text.contains("dark mode") || text.contains("light mode") { id = .theme }
        else if text.contains("link") && (text.contains("split") || text.contains("beside")) { id = .automaticLinkSplit }
        else { id = nil }
        guard let id else {
            answer = text.contains("motion") || text.contains("animation") ? "Page fades and interface motion are different controls. Which one would you like to change? You can open Appearance to explore them." : "Local Settings help covers page fading, fade length, theme, and website-created link splits. For another setting, use Settings search."
            return
        }
        references = [id]
        let descriptor = SettingsRegistry.descriptor(id)
        let current = transactions.snapshot(id)
        answer = "\(descriptor.detail) Current value: \(current.effective.display) (\(current.source.lowercased())). \(descriptor.effect)"
        guard !isQuestion else { return }
        // The first catalog is app-only. A narrower request must never be
        // silently broadened to every window or website on this Mac.
        if text.range(of: "\\b(this|that|current|only) (window|site|tab|host)\\b|https?://|\\b[a-z0-9-]+\\.[a-z]{2,}\\b|per[- ](site|window)", options: .regularExpression) != nil {
            answer += " This assistant only previews app-wide preferences. A window or website-specific request requires a supported native control; no app-wide change was prepared."
            return
        }
        if ["don't ", "do not ", "never ", "keep "].contains(where: text.hasPrefix) {
            answer += " No change was prepared."
            return
        }
        let value: BrowserSettingValue?
        switch id {
        case .fadeInPages, .automaticLinkSplit:
            if ["disable", "turn off", "stop ", " off"].contains(where: text.contains) { value = .bool(false) }
            else if ["enable", "turn on", " on"].contains(where: text.contains) { value = .bool(true) }
            else { value = nil }
        case .theme:
            if text.contains("dark") { value = .choice("Dark") }
            else if text.contains("light") { value = .choice("Light") }
            else if text.contains("system") { value = .choice("System") }
            else { value = nil }
        case .fadeDuration:
            let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
            value = numbers.count == 1 ? .number(numbers[0]) : nil
        }
        guard let value else { answer += " Choose the exact value in the native setting, or describe the value explicitly."; return }
        do { proposal = try transactions.preview(id: id, value: value, sessionID: sessionID, generation: generation, questionOnly: questionOnly, available: available) }
        catch { message = error.localizedDescription }
    }

    func staleReason(available: Bool) -> String? {
        guard let proposal else { return nil }
        do { try transactions.check(proposal, sessionID: sessionID, generation: generation, questionOnly: questionOnly, available: available); return nil }
        catch { return error.localizedDescription }
    }

    func apply(available: Bool) {
        guard let proposal else { return }
        do { receipt = try transactions.applyFromNativeUI(proposal, sessionID: sessionID, generation: generation, questionOnly: questionOnly, available: available); self.proposal = nil; message = "Applied. \(receipt!.after.display). Undo is available for this Settings session." }
        catch { message = error.localizedDescription }
    }

    func undo(available: Bool) {
        guard let receipt else { return }
        do { try transactions.undoFromNativeUI(receipt, available: available, questionOnly: questionOnly); self.receipt = nil; message = "Undone. The previous saved or default value is restored." }
        catch { message = error.localizedDescription }
    }
}
