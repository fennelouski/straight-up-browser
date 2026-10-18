import Foundation

/// One per window. This policy owns admission records, never a Tab or WebKit
/// object. Its owner binds the returned navigation to the exact permit token.
@MainActor
final class ColdLayoutStarterScheduler {
    struct Starter: Equatable {
        let tabID: UUID
        let startingURL: URL?
        let profileID: UUID?
        let isPrivate: Bool
        let isAlreadyLive: Bool

        init(tabID: UUID, startingURL: URL?, profileID: UUID? = nil,
             isPrivate: Bool = false, isAlreadyLive: Bool = false) {
            self.tabID = tabID
            self.startingURL = startingURL
            self.profileID = profileID
            self.isPrivate = isPrivate
            self.isAlreadyLive = isAlreadyLive
        }
    }

    struct Token: Hashable {
        let generationID: UUID
        let tabID: UUID
        let loadID: UUID
    }

    struct Permit: Equatable {
        let token: Token
        let startingURL: URL
        let profileID: UUID?
        let workspaceID: UUID?
    }

    /// A policy decision can run while the native load call is still returning.
    /// Its later download conversion must keep the same token when the exact
    /// returned navigation identity becomes available.
    struct DownloadAssociation: Equatable {
        let token: Token
        private(set) var navigationID: ObjectIdentifier?

        init(token: Token, navigationID: ObjectIdentifier? = nil) {
            self.token = token
            self.navigationID = navigationID
        }

        @discardableResult mutating func bindReturnedNavigation(_ id: ObjectIdentifier, token expected: Token) -> Bool {
            guard token == expected, navigationID == nil || navigationID == id else { return false }
            navigationID = id
            return true
        }

        func matches(navigationID id: ObjectIdentifier, token expected: Token) -> Bool {
            navigationID == id && token == expected
        }
    }

    enum CancellationReason: Equatable {
        case replacedByRestore, workspaceChanged, layoutChanged, undo
        case rolloutDisabled, manualNavigation, closed
    }

    enum TerminalOutcome: Equatable {
        case finished, failed, cancelled, download, terminated, notStarted
    }

    private struct Generation {
        let id: UUID
        let workspaceID: UUID?
        let layoutRevision: UInt64
        var pending: [Starter]
    }

    static let maximumConcurrentLoads = 2
    private var generation: Generation?
    private var active: [Token: Permit] = [:]
    private var deferred: Set<UUID> = []
    private var ownedStarters: Set<UUID> = []
    private var ownedStarterSpecifications: [UUID: Starter] = [:]
    private(set) var lastCancellationReason: CancellationReason?

    var currentGenerationID: UUID? { generation?.id }
    var inFlightCount: Int { active.count }
    var pendingTabIDs: [UUID] { generation?.pending.map(\.tabID) ?? [] }
    var deferredTabIDs: Set<UUID> { deferred }

    func isDeferred(_ tabID: UUID) -> Bool { deferred.contains(tabID) }
    /// Failed or unstarted jobs remain owned to prevent automatic retries.
    /// A successful page retires into ordinary tab/session restoration.
    func ownsStarter(_ tabID: UUID) -> Bool {
        ownedStarters.contains(tabID) || activePermit(for: tabID) != nil
    }
    func activePermit(for tabID: UUID) -> Permit? {
        active.values.first { $0.token.tabID == tabID }
    }
    func registeredStarter(for tabID: UUID) -> Starter? {
        ownedStarters.contains(tabID) ? ownedStarterSpecifications[tabID] : nil
    }

    /// Register only the new tabs created by a reviewed recipe Apply, after its
    /// layout commit. Reused sessions must be passed as live or omitted. Safe URL
    /// policy is rechecked here; nil/manual/meeting slots never become jobs.
    @discardableResult
    func register(starters: [Starter], workspaceID: UUID?, layoutRevision: UInt64,
                  gateEnabled: Bool) -> UUID? {
        cancelPending(reason: .replacedByRestore)
        let activeIDs = Set(active.keys.map(\.tabID))
        let counts = Dictionary(grouping: starters, by: \.tabID).mapValues(\.count)
        let valid = starters.filter { starter in
            guard counts[starter.tabID] == 1, !activeIDs.contains(starter.tabID),
                  !starter.isAlreadyLive, !starter.isPrivate,
                  let url = starter.startingURL,
                  LayoutStarterURLPolicy.safeStarter(url) == url else { return false }
            return true
        }
        deferred.formUnion(valid.map(\.tabID))
        ownedStarters.formUnion(valid.map(\.tabID))
        for starter in valid { ownedStarterSpecifications[starter.tabID] = starter }
        guard gateEnabled, !valid.isEmpty else {
            if !gateEnabled { lastCancellationReason = .rolloutDisabled }
            return nil
        }
        let id = UUID()
        generation = Generation(id: id, workspaceID: workspaceID,
                                layoutRevision: layoutRevision, pending: valid)
        return id
    }

    /// An explicit Load Saved Page action rejoins bounded admission. It never
    /// turns a saved-page retry into an ordinary unbounded URL load. The caller
    /// still checks current tab/profile existence before requesting a permit.
    @discardableResult
    func retryDeferredStarter(starter: Starter, workspaceID: UUID?, layoutRevision: UInt64,
                              gateEnabled: Bool) -> Bool {
        guard ownedStarters.contains(starter.tabID), deferred.contains(starter.tabID),
              activePermit(for: starter.tabID) == nil,
              !starter.isPrivate, !starter.isAlreadyLive,
              let url = starter.startingURL, LayoutStarterURLPolicy.safeStarter(url) == url,
              let original = ownedStarterSpecifications[starter.tabID],
              original.startingURL == starter.startingURL, original.profileID == starter.profileID else { return false }
        guard gateEnabled else {
            cancelPending(reason: .rolloutDisabled)
            return false
        }
        if let current = generation,
           current.workspaceID == workspaceID, current.layoutRevision == layoutRevision {
            if !current.pending.contains(where: { $0.tabID == starter.tabID }) {
                generation?.pending.append(starter)
            }
        } else {
            cancelPending(reason: generation?.workspaceID != workspaceID ? .workspaceChanged : .layoutChanged)
            generation = Generation(id: UUID(), workspaceID: workspaceID,
                                    layoutRevision: layoutRevision, pending: [starter])
        }
        return true
    }

    /// Reserve before invoking restoreInteractionState, beginLoad, fade or load.
    /// The owner must first revalidate each candidate's actual URL/profile/live
    /// state and provide only currently projected, positive-area visible TabIDs.
    /// Capacity includes unfinished work from every retired generation.
    func reserveNext(visibleTabIDs: Set<UUID>, focusedTabID: UUID?, workspaceID: UUID?,
                     layoutRevision: UInt64, gateEnabled: Bool) -> Permit? {
        guard let current = generation else { return nil }
        guard gateEnabled else { cancelPending(reason: .rolloutDisabled); return nil }
        guard current.workspaceID == workspaceID else { cancelPending(reason: .workspaceChanged); return nil }
        guard current.layoutRevision == layoutRevision else { cancelPending(reason: .layoutChanged); return nil }
        guard active.count < Self.maximumConcurrentLoads else { return nil }
        let nextIndex: Int?
        if let focusedTabID,
           let focused = current.pending.firstIndex(where: { $0.tabID == focusedTabID && visibleTabIDs.contains($0.tabID) }) {
            nextIndex = focused
        } else {
            nextIndex = current.pending.firstIndex { visibleTabIDs.contains($0.tabID) }
        }
        guard let nextIndex else { return nil }
        let starter = current.pending[nextIndex]
        guard let url = starter.startingURL, activePermit(for: starter.tabID) == nil else { return nil }
        let token = Token(generationID: current.id, tabID: starter.tabID, loadID: UUID())
        let permit = Permit(token: token, startingURL: url,
                            profileID: starter.profileID, workspaceID: current.workspaceID)
        generation?.pending.remove(at: nextIndex)
        deferred.remove(starter.tabID)
        active[token] = permit
        return permit
    }

    /// Finish/fail/download/termination, including an immediate nil load result.
    /// Never resolve a terminal callback merely by its TabID: it must use the
    /// token bound to that callback's exact returned WKNavigation by the owner.
    @discardableResult
    func terminal(_ token: Token, outcome: TerminalOutcome = .finished) -> Bool {
        guard active.removeValue(forKey: token) != nil else { return false }
        if outcome == .finished {
            ownedStarters.remove(token.tabID)
            ownedStarterSpecifications.removeValue(forKey: token.tabID)
            deferred.remove(token.tabID)
        } else if ownedStarters.contains(token.tabID) {
            deferred.insert(token.tabID)
        }
        return true
    }

    /// Invalidate future starts without stopping, closing or replacing a live
    /// navigation. Its retained permit still occupies capacity until terminal.
    func cancelPending(reason: CancellationReason) {
        if let generation { deferred.formUnion(generation.pending.map(\.tabID)) }
        generation = nil
        lastCancellationReason = reason
    }

    /// Only a caller-certified ordinary navigation may retire deferral here.
    /// Never call from generic selection/Undo or Load Saved Page: saved-page
    /// retries use retryDeferredStarter and stay subject to bounded admission.
    /// A tab in the current queue remains queued; focused-first reserveNext
    /// promotes it without bypassing the concurrency bound.
    @discardableResult
    func releaseDeferredForUserAction(_ tabID: UUID) -> Bool {
        guard generation?.pending.contains(where: { $0.tabID == tabID }) != true,
              activePermit(for: tabID) == nil else { return false }
        let wasDeferred = deferred.remove(tabID) != nil
        let wasOwned = ownedStarters.remove(tabID) != nil
        ownedStarterSpecifications.removeValue(forKey: tabID)
        return wasDeferred || wasOwned
    }

    /// A deliberate new navigation supersedes the recipe's remaining automatic
    /// starts. Only its target loses deferral; other pending tabs stay cold.
    func cancelForManualNavigation(tabID: UUID) {
        cancelPending(reason: .manualNavigation)
        deferred.remove(tabID)
        ownedStarters.remove(tabID)
        ownedStarterSpecifications.removeValue(forKey: tabID)
    }

    /// The tab owner calls this only after a real close. Active navigation
    /// permits require their own terminal acknowledgement and are not inferred.
    func forgetDeferredTab(_ tabID: UUID) {
        generation?.pending.removeAll { $0.tabID == tabID }
        deferred.remove(tabID)
        ownedStarters.remove(tabID)
        ownedStarterSpecifications.removeValue(forKey: tabID)
    }
}
