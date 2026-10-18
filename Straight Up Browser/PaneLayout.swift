import Foundation
import CoreGraphics

/// Geometry owns neither a Tab nor a WebKit/document session. Content UUIDs
/// remain the existing owners' identities; a pane's UUID survives tree moves.
enum PaneContentReference: Codable, Equatable, Hashable {
    case tab(UUID)
    case document(UUID)

    var id: UUID {
        switch self { case .tab(let id), .document(let id): return id }
    }
}

struct LayoutPane: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var content: PaneContentReference
}

enum PaneSplitAxis: String, Codable { case x, y }
enum PanePlacement: String, CaseIterable, Identifiable {
    case center, left, right, above, below
    var id: String { rawValue }
    var label: String {
        switch self {
        case .center: return "Swap / Place"
        case .left: return "Left"
        case .right: return "Right"
        case .above: return "Above"
        case .below: return "Below"
        }
    }
}

enum PaneLayoutError: Error, LocalizedError, Equatable {
    case invalidTree, unavailableContent, stalePreview, protectedPane, profileBoundary, privateLayout, wrongWorkspace, liveElsewhere, rolloutDisabled
    var errorDescription: String? {
        switch self {
        case .invalidTree: return "The arrangement is invalid or exceeds its limits."
        case .unavailableContent: return "A tab or document is no longer available. Open it first, then preview again."
        case .stalePreview: return "The layout changed. Preview again before applying."
        case .protectedPane: return "Keep the protected tab visible. Use an edge or include it in the layout."
        case .profileBoundary: return "Placement between different profiles or private sessions is unavailable."
        case .privateLayout: return "Private panes cannot be saved in a reusable layout."
        case .wrongWorkspace: return "Open the linked research workspace before applying this layout."
        case .liveElsewhere: return "This layout is already live in another Browser window. Reveal that window to keep its sessions."
        case .rolloutDisabled: return "Enable pane layouts before changing the live arrangement. Previews and saved layouts remain available."
        }
    }
}

enum PaneLayoutRolloutPolicy {
    // A new key deliberately does not inherit the old editor-only Apply toggle.
    static let defaultsKey = "paneLayoutsRolloutEnabled.v1"
    static let defaultEnabled = false
    enum RenderingMode: Equatable { case single, legacyColumns, legacyGrid, recursive }

    static func isEnabled(storedValue: Bool?) -> Bool { storedValue ?? defaultEnabled }
    static func newMembershipLimit(enabled: Bool) -> Int { enabled ? 8 : 4 }
    static func renderingMode(enabled: Bool, hasTree: Bool, memberCount: Int) -> RenderingMode {
        guard memberCount > 1 else { return .single }
        if enabled, hasTree { return .recursive }
        return memberCount == 4 ? .legacyGrid : .legacyColumns
    }
    static func canRestoreRetainedTree(enabled: Bool, retainedMembers: [PaneContentReference], currentMembers: [PaneContentReference], retainedWorkspaceID: UUID?, currentWorkspaceID: UUID?) -> Bool {
        enabled && retainedMembers == currentMembers && retainedWorkspaceID == currentWorkspaceID
    }
}

indirect enum PaneLayoutTree: Codable, Equatable {
    case pane(LayoutPane)
    case split(id: UUID, axis: PaneSplitAxis, ratio: Double, first: PaneLayoutTree, second: PaneLayoutTree)

    var panes: [LayoutPane] {
        switch self {
        case .pane(let pane): return [pane]
        case .split(_, _, _, let first, let second): return first.panes + second.panes
        }
    }
    var contentIDs: [UUID] { panes.map { $0.content.id } }

    func validated(maximumPanes: Int = 32) throws -> Self {
        var nodes = Set<UUID>(), contents = Set<UUID>(), count = 0
        func visit(_ node: Self, depth: Int) throws {
            count += 1
            guard count <= 255, depth <= 64 else { throw PaneLayoutError.invalidTree }
            switch node {
            case .pane(let pane):
                guard nodes.insert(pane.id).inserted, contents.insert(pane.content.id).inserted else { throw PaneLayoutError.invalidTree }
            case .split(let id, _, let ratio, let first, let second):
                guard nodes.insert(id).inserted, ratio.isFinite, ratio > 0, ratio < 1 else { throw PaneLayoutError.invalidTree }
                try visit(first, depth: depth + 1)
                try visit(second, depth: depth + 1)
            }
        }
        try visit(self, depth: 0)
        guard contents.count <= maximumPanes else { throw PaneLayoutError.invalidTree }
        return self
    }

    func replacing(_ paneID: UUID, with replacement: Self) -> Self {
        switch self {
        case .pane(let pane): return pane.id == paneID ? replacement : self
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: ratio,
                          first: first.replacing(paneID, with: replacement), second: second.replacing(paneID, with: replacement))
        }
    }

    func removing(_ paneID: UUID) -> Self? {
        switch self {
        case .pane(let pane): return pane.id == paneID ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            let a = first.removing(paneID), b = second.removing(paneID)
            if let a, let b { return .split(id: id, axis: axis, ratio: ratio, first: a, second: b) }
            return a ?? b
        }
    }

    /// Compatibility bridge for old sidebar/context-menu membership APIs.
    /// Removal prunes only the affected ancestors; adding splits the focused
    /// retained leaf. A legacy tree is created only when no old member remains.
    func reconciling(_ references: [PaneContentReference], anchorContentID: UUID?) throws -> Self? {
        guard Set(references.map(\.id)).count == references.count else { throw PaneLayoutError.invalidTree }
        let wanted = Set(references.map(\.id))
        if wanted == Set(contentIDs), references.count == panes.count {
            var result = self
            for (pane, ref) in zip(panes, references) { result = result.replacing(pane.id, with: .pane(LayoutPane(id: pane.id, content: ref))) }
            return try result.validated()
        }
        var result: Self? = self
        for pane in panes where !wanted.contains(pane.content.id) { result = result?.removing(pane.id) }
        guard var retained = result else { return Self.legacy(references.map { LayoutPane(content: $0) }) }
        for ref in references where !retained.contentIDs.contains(ref.id) {
            let target = retained.panes.first(where: { $0.content.id == anchorContentID }) ?? retained.panes.last!
            retained = try retained.placing(ref, at: target.id, edge: .right)
        }
        return try retained.validated()
    }

    /// A center swap changes occupants, preserving pane IDs and every ratio.
    /// An edge move removes its source first, so sibling/ancestor collapse is
    /// reflected in the very same final tree shown in the preview.
    func placing(_ content: PaneContentReference, at targetID: UUID, edge: PanePlacement) throws -> Self {
        guard let target = panes.first(where: { $0.id == targetID }) else { throw PaneLayoutError.unavailableContent }
        let source = panes.first { $0.content == content }
        if source?.id == targetID { return self }
        if edge == .center {
            var result = replacing(target.id, with: .pane(LayoutPane(id: target.id, content: content)))
            if let source { result = result.replacing(source.id, with: .pane(LayoutPane(id: source.id, content: target.content))) }
            return try result.validated()
        }
        let pruned = source.flatMap { removing($0.id) } ?? self
        let moving = PaneLayoutTree.pane(source ?? LayoutPane(content: content))
        let destination = PaneLayoutTree.pane(target)
        let leading = edge == .left || edge == .above
        let replacement = PaneLayoutTree.split(id: UUID(), axis: edge == .left || edge == .right ? .x : .y,
                                               ratio: 0.5, first: leading ? moving : destination,
                                               second: leading ? destination : moving)
        return try pruned.replacing(target.id, with: replacement).validated()
    }

    func settingRatio(nodeID: UUID, ratio newRatio: Double) -> Self {
        switch self {
        case .pane: return self
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: id == nodeID ? min(max(newRatio, 0.05), 0.95) : ratio,
                          first: first.settingRatio(nodeID: nodeID, ratio: newRatio), second: second.settingRatio(nodeID: nodeID, ratio: newRatio))
        }
    }

    static func columns(_ panes: [LayoutPane], axis: PaneSplitAxis = .x) -> Self? {
        guard let first = panes.first else { return nil }
        guard panes.count > 1, let rest = columns(Array(panes.dropFirst()), axis: axis) else { return .pane(first) }
        return .split(id: UUID(), axis: axis, ratio: 1 / Double(panes.count), first: .pane(first), second: rest)
    }

    /// Idempotent in-memory migration retains existing content UUIDs. Legacy
    /// four-pane membership was a grid, other sizes were ordered columns.
    static func legacy(_ panes: [LayoutPane]) -> Self? {
        guard panes.count == 4 else { return columns(panes) }
        return .split(id: UUID(), axis: .y, ratio: 0.5,
                      first: columns(Array(panes.prefix(2)))!, second: columns(Array(panes.suffix(2)))!)
    }

    static func largeLeading(_ panes: [LayoutPane], axis: PaneSplitAxis = .x) -> Self? {
        guard let first = panes.first, panes.count >= 3 else { return columns(panes, axis: axis) }
        let rest = Array(panes.dropFirst()), middle = (rest.count + 1) / 2
        let cluster = PaneLayoutTree.split(id: UUID(), axis: axis == .x ? .y : .x, ratio: 0.5,
                                          first: columns(Array(rest.prefix(middle)), axis: axis)!,
                                          second: columns(Array(rest.dropFirst(middle)), axis: axis)!)
        return .split(id: UUID(), axis: axis, ratio: 0.55, first: .pane(first), second: cluster)
    }

    struct Divider: Equatable {
        var id: UUID
        var axis: PaneSplitAxis
        var region: CGRect
        var ratio: Double
        var frame: CGRect
    }
    struct Geometry {
        var panes: [UUID: CGRect] = [:]
        var dividers: [Divider] = []
    }

    /// Preferred ratios are never rewritten for a small viewport. The native
    /// host can refuse an infeasible structural commit instead of losing them.
    func geometry(in bounds: CGRect, topLeftOrigin: Bool = false) -> Geometry {
        var result = Geometry()
        func visit(_ tree: Self, _ region: CGRect) {
            switch tree {
            case .pane(let pane): result.panes[pane.content.id] = region
            case .split(let id, let axis, let ratio, let first, let second):
                var a = region, b = region, divider = region
                let firstMinimum = first.minimumSize, secondMinimum = second.minimumSize
                if axis == .x {
                    let preferred = region.width * ratio
                    let applied = region.width >= firstMinimum.width + secondMinimum.width
                        ? min(max(preferred, firstMinimum.width), region.width - secondMinimum.width) : preferred
                    a.size.width = floor(applied)
                    b.origin.x += a.width; b.size.width -= a.width
                    divider.origin.x = b.minX - 4; divider.size.width = 8
                } else {
                    let preferred = region.height * ratio
                    let applied = region.height >= firstMinimum.height + secondMinimum.height
                        ? min(max(preferred, firstMinimum.height), region.height - secondMinimum.height) : preferred
                    a.size.height = floor(applied)
                    b.size.height -= a.height
                    if topLeftOrigin { b.origin.y += a.height; divider.origin.y = b.minY - 4 }
                    else { a.origin.y += b.height; divider.origin.y = a.minY - 4 }
                    divider.size.height = 8
                }
                let appliedRatio = axis == .x ? a.width / max(region.width, 1) : a.height / max(region.height, 1)
                result.dividers.append(Divider(id: id, axis: axis, region: region, ratio: appliedRatio, frame: divider))
                visit(first, a); visit(second, b)
            }
        }
        visit(self, bounds)
        return result
    }

    var minimumSize: CGSize {
        switch self {
        case .pane: return CGSize(width: 240, height: 160)
        case .split(_, let axis, _, let first, let second):
            let a = first.minimumSize, b = second.minimumSize
            return axis == .x ? CGSize(width: a.width + b.width, height: max(a.height, b.height))
                             : CGSize(width: max(a.width, b.width), height: a.height + b.height)
        }
    }

    /// A reversible runtime projection: keep every protected pane visible, then
    /// the focused pane when it fits. The saved tree/ratios never change. If a
    /// screen cannot even fit all protected panes, retain them all and let the
    /// host explicitly report the space constraint instead of hiding a call.
    func compactProjection(in size: CGSize, protecting protected: Set<UUID>, focused: UUID?) -> Self {
        func fits(_ tree: Self) -> Bool { tree.minimumSize.width <= size.width && tree.minimumSize.height <= size.height }
        if fits(self) { return self }
        var required = panes.filter { protected.contains($0.content.id) }
        if required.isEmpty, let focusedPane = panes.first(where: { $0.content.id == focused }) ?? panes.first { required = [focusedPane] }
        func best(_ leaves: [LayoutPane]) -> Self? {
            [Self.columns(leaves), Self.columns(leaves, axis: .y), Self.legacy(leaves), Self.largeLeading(leaves), Self.largeLeading(leaves, axis: .y)]
                .compactMap { $0 }.first(where: fits)
        }
        if let focusedPane = panes.first(where: { $0.content.id == focused }), !required.contains(focusedPane),
           let withFocus = best(required + [focusedPane]) { return withFocus }
        return best(required) ?? Self.columns(required) ?? self
    }

    /// Spatial keyboard navigation never wraps. Only panes on the requested
    /// side with perpendicular overlap are neighbors. Distance, center offset,
    /// overlap, then stable reading order resolve ties deterministically.
    func neighbor(of paneID: UUID, toward direction: PanePlacement, in bounds: CGRect) -> UUID? {
        guard direction != .center, let source = panes.first(where: { $0.id == paneID }) else { return nil }
        let frames = geometry(in: bounds, topLeftOrigin: true).panes
        guard let origin = frames[source.content.id] else { return nil }
        struct Candidate { var id: UUID; var gap: CGFloat; var offset: CGFloat; var overlap: CGFloat; var order: Int }
        var candidates: [Candidate] = []
        for (order, pane) in panes.enumerated() where pane.id != paneID {
            guard let frame = frames[pane.content.id] else { continue }
            let gap: CGFloat, offset: CGFloat, overlap: CGFloat
            switch direction {
            case .left:
                guard frame.maxX <= origin.minX + 0.5 else { continue }
                gap = origin.minX - frame.maxX; offset = abs(frame.midY - origin.midY)
                overlap = min(frame.maxY, origin.maxY) - max(frame.minY, origin.minY)
            case .right:
                guard frame.minX >= origin.maxX - 0.5 else { continue }
                gap = frame.minX - origin.maxX; offset = abs(frame.midY - origin.midY)
                overlap = min(frame.maxY, origin.maxY) - max(frame.minY, origin.minY)
            case .above:
                guard frame.maxY <= origin.minY + 0.5 else { continue }
                gap = origin.minY - frame.maxY; offset = abs(frame.midX - origin.midX)
                overlap = min(frame.maxX, origin.maxX) - max(frame.minX, origin.minX)
            case .below:
                guard frame.minY >= origin.maxY - 0.5 else { continue }
                gap = frame.minY - origin.maxY; offset = abs(frame.midX - origin.midX)
                overlap = min(frame.maxX, origin.maxX) - max(frame.minX, origin.minX)
            case .center: continue
            }
            if overlap > 0 { candidates.append(Candidate(id: pane.id, gap: max(0, gap), offset: offset, overlap: overlap, order: order)) }
        }
        return candidates.sorted {
            if $0.gap != $1.gap { return $0.gap < $1.gap }
            if $0.offset != $1.offset { return $0.offset < $1.offset }
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            return $0.order < $1.order
        }.first?.id
    }
}

struct PaneLayoutRecovery: Codable {
    var schemaVersion = 1
    var linkedResearchWorkspaceID: UUID?
    var tree: PaneLayoutTree
    var focusedContentID: UUID?
}

enum PaneLayoutAction: Equatable { case arrangement, swap, resize, newSplit, restoreRecipe }

struct PaneLayoutPreview: Equatable {
    var expectedRevision: UInt64
    var tree: PaneLayoutTree
    var focusedContentID: UUID?
    var summary: String
    var newTabs: [LayoutPlannedTab] = []
    var recipeID: UUID?
    var recipeBindings: [UUID: UUID] = [:]
    var action = PaneLayoutAction.arrangement
}

struct LayoutPlannedTab: Equatable {
    var id = UUID()
    var startingURL: URL?
    var profileID: UUID?
    var label: String
    var isPrivate = false
}

enum LayoutRestoreSpecification: Codable, Equatable {
    case document(UUID)
    case safeStarter(URL)
    case chooseCurrentMeeting
    case empty
}

struct LayoutRecipeSlot: Codable, Equatable, Identifiable {
    var id: UUID
    var restore: LayoutRestoreSpecification
    var profileID: UUID?
}

enum LayoutStarterURLPolicy {
    static func isMeeting(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        let providers = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "discord.com", "app.slack.com"]
        return providers.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    /// Conservative by default: query/fragment/authentication URLs require an
    /// explicit manual selection. This is omission, not a claim to detect all
    /// possible secrets or to resume website memory from a URL.
    static func safeStarter(_ url: URL?) -> URL? {
        guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, !isMeeting(url) else { return nil }
        let path = url.path.lowercased()
        guard !["login", "signin", "sign-in", "oauth", "callback", "token", "authorize", "signed", "download"].contains(where: path.contains) else { return nil }
        return url
    }
}

/// Tree tab references here are configuration slot UUIDs, never runtime TabIDs.
/// Runtime bindings live only on TabManager. Documents retain their existing
/// persistent provider identity; missing documents become a manual empty slot.
struct LocalLayoutRecipe: Codable, Equatable, Identifiable {
    var id = UUID()
    var schemaVersion = 1
    var revision = 1
    var name: String
    var linkedResearchWorkspaceID: UUID?
    var tree: PaneLayoutTree
    var slots: [LayoutRecipeSlot] = []
    var focusedContentID: UUID?
    var updatedAt = Date()

    func validated() throws -> Self {
        _ = try tree.validated()
        guard schemaVersion == 1, revision >= 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              slots.count == tree.panes.count, Set(slots.map(\.id)) == Set(tree.contentIDs) else { throw PaneLayoutError.invalidTree }
        for slot in slots {
            if case .safeStarter(let url) = slot.restore, LayoutStarterURLPolicy.safeStarter(url) != url { throw PaneLayoutError.invalidTree }
        }
        return self
    }
}

/// A deterministic before/after review of an explicit saved-recipe update.
/// Compare configuration slot identity, never URLs as identity. Split-node IDs
/// and timestamps are bookkeeping and cannot manufacture user-facing changes.
struct LocalLayoutRecipeUpdateDiff: Equatable {
    enum Kind: String, Equatable {
        case name, workspace, topology, dividerRatios, focus, addedContent, removedContent, position, restoreReference, profile
    }
    struct Change: Equatable, Identifiable {
        var id: String
        var kind: Kind
        var subject: String
        var before: String
        var after: String
    }
    let beforeRevision: Int
    let proposedRevision: Int
    let changes: [Change]
    var isEmpty: Bool { changes.isEmpty }

    init(before: LocalLayoutRecipe, proposed: LocalLayoutRecipe) throws {
        _ = try before.validated()
        _ = try proposed.validated()
        guard before.id == proposed.id else { throw PaneLayoutError.invalidTree }
        guard before.revision == proposed.revision else { throw PaneLayoutError.stalePreview }
        guard before.revision < Int.max else { throw PaneLayoutError.invalidTree }
        beforeRevision = before.revision
        proposedRevision = before.revision + 1
        var result: [Change] = []
        func append(_ kind: Kind, subject: String, before old: String, after new: String, identity: String = "") {
            guard old != new else { return }
            result.append(Change(id: kind.rawValue + identity, kind: kind, subject: subject, before: old, after: new))
        }
        var paneOrder = before.tree.panes.map(\.id)
        for pane in proposed.tree.panes where !paneOrder.contains(pane.id) { paneOrder.append(pane.id) }
        let paneLabels = Dictionary(uniqueKeysWithValues: paneOrder.enumerated().map { ($0.element, "Pane \($0.offset + 1)") })
        var slotOrder = before.tree.contentIDs
        for id in proposed.tree.contentIDs where !slotOrder.contains(id) { slotOrder.append(id) }
        let slotLabels = Dictionary(uniqueKeysWithValues: slotOrder.enumerated().map { ($0.element, "Content \($0.offset + 1)") })
        func topology(_ node: PaneLayoutTree) -> String {
            switch node {
            case .pane(let pane): return paneLabels[pane.id] ?? "Pane"
            case .split(_, let axis, _, let first, let second):
                return "\(axis == .x ? "Left / right" : "Top / bottom") (\(topology(first)); \(topology(second)))"
            }
        }
        struct Ratio: Equatable { var path: [Int]; var value: Double }
        func ratios(_ node: PaneLayoutTree, path: [Int] = []) -> [Ratio] {
            switch node {
            case .pane: return []
            case .split(_, _, let ratio, let first, let second):
                return [Ratio(path: path, value: ratio)] + ratios(first, path: path + [0]) + ratios(second, path: path + [1])
            }
        }
        func ratioDescription(_ node: PaneLayoutTree, path: String = "Layout", precise: Bool = false) -> String {
            switch node {
            case .pane: return ""
            case .split(_, let axis, let ratio, let first, let second):
                let firstName = axis == .x ? "Left" : "Top", secondName = axis == .x ? "Right" : "Bottom"
                let value = String(format: "%.6g", ratio * 100)
                let exact = precise ? " (saved fraction \(String(ratio)))" : ""
                return (["\(path): \(firstName.lowercased()) \(value)% / \(secondName.lowercased()) \(String(format: "%.6g", (1 - ratio) * 100))%\(exact)"]
                    + [ratioDescription(first, path: path + " › " + firstName, precise: precise), ratioDescription(second, path: path + " › " + secondName, precise: precise)]
                        .filter { !$0.isEmpty }).joined(separator: "\n")
            }
        }
        func positions(_ node: PaneLayoutTree, path: String = "Layout") -> [UUID: String] {
            switch node {
            case .pane(let pane): return [pane.content.id: "\(paneLabels[pane.id] ?? "Pane") · \(path)"]
            case .split(_, let axis, _, let first, let second):
                return positions(first, path: path + (axis == .x ? " › Left" : " › Top"))
                    .merging(positions(second, path: path + (axis == .x ? " › Right" : " › Bottom")), uniquingKeysWith: { old, _ in old })
            }
        }
        func restoreDescription(_ specification: LayoutRestoreSpecification) -> String {
            switch specification {
            case .document(let id): return "Document reference \(id.uuidString)"
            case .safeStarter(let url): return "Starting page: \(url.absoluteString)"
            case .chooseCurrentMeeting: return "Manual meeting slot · choose current meeting"
            case .empty: return "Empty slot · choose content manually"
            }
        }
        func profileDescription(_ profileID: UUID?) -> String { profileID.map { "Container \($0.uuidString)" } ?? "Normal profile" }
        func workspaceDescription(_ id: UUID?) -> String { id.map { "Research workspace \($0.uuidString)" } ?? "Standalone layout" }
        append(.name, subject: "Name", before: before.name.trimmingCharacters(in: .whitespacesAndNewlines), after: proposed.name.trimmingCharacters(in: .whitespacesAndNewlines))
        append(.workspace, subject: "Research workspace", before: workspaceDescription(before.linkedResearchWorkspaceID), after: workspaceDescription(proposed.linkedResearchWorkspaceID))
        append(.topology, subject: "Pane arrangement", before: topology(before.tree), after: topology(proposed.tree))
        if ratios(before.tree) != ratios(proposed.tree) {
            let oldDescription = ratioDescription(before.tree), newDescription = ratioDescription(proposed.tree)
            let needsExactFractions = oldDescription == newDescription
            result.append(Change(id: Kind.dividerRatios.rawValue, kind: .dividerRatios, subject: "Preferred divider sizes",
                                 before: oldDescription.isEmpty ? "No dividers" : ratioDescription(before.tree, precise: needsExactFractions),
                                 after: newDescription.isEmpty ? "No dividers" : ratioDescription(proposed.tree, precise: needsExactFractions)))
        }
        append(.focus, subject: "Preferred focus", before: before.focusedContentID.flatMap { slotLabels[$0] } ?? "No preference", after: proposed.focusedContentID.flatMap { slotLabels[$0] } ?? "No preference")
        let oldSlots = Dictionary(uniqueKeysWithValues: before.slots.map { ($0.id, $0) })
        let newSlots = Dictionary(uniqueKeysWithValues: proposed.slots.map { ($0.id, $0) })
        let oldPositions = positions(before.tree), newPositions = positions(proposed.tree)
        for id in slotOrder {
            let label = slotLabels[id] ?? "Content"
            switch (oldSlots[id], newSlots[id]) {
            case (.some(let old), .none):
                append(.removedContent, subject: "\(label) removed from saved layout",
                       before: "\(restoreDescription(old.restore))\n\(profileDescription(old.profileID))\n\(oldPositions[id] ?? "")",
                       after: "Not in saved layout · live content stays open", identity: id.uuidString)
            case (.none, .some(let new)):
                append(.addedContent, subject: "\(label) added to saved layout", before: "Not in saved layout",
                       after: "\(restoreDescription(new.restore))\n\(profileDescription(new.profileID))\n\(newPositions[id] ?? "")", identity: id.uuidString)
            case (.some(let old), .some(let new)):
                append(.position, subject: "\(label) position", before: oldPositions[id] ?? "", after: newPositions[id] ?? "", identity: id.uuidString)
                append(.restoreReference, subject: "\(label) restore reference", before: restoreDescription(old.restore), after: restoreDescription(new.restore), identity: id.uuidString)
                append(.profile, subject: "\(label) profile", before: profileDescription(old.profileID), after: profileDescription(new.profileID), identity: id.uuidString)
            case (.none, .none): break
            }
        }
        changes = result
    }
}

/// A separate file, outside SwiftData/CloudKit. Writes atomically retain the
/// preceding file, and stale editors cannot overwrite a newer local revision.
struct LocalLayoutRecipeStore {
    private struct Archive: Codable {
        var schemaVersion = 1
        var recipes: [LocalLayoutRecipe] = []
        var history: [LocalLayoutRecipe] = []
    }
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? BrowserProfile.applicationSupportURLs[0]
            .appendingPathComponent("Browser/LocalLayouts/recipes-v1.json")
    }
    private func read() throws -> Archive {
        guard FileManager.default.fileExists(atPath: url.path) else { return Archive() }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw PaneLayoutError.invalidTree }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.schemaVersion == 1, archive.recipes.count <= 100, archive.history.count <= 1_000,
              Set(archive.recipes.map(\.id)).count == archive.recipes.count else { throw PaneLayoutError.invalidTree }
        for recipe in archive.recipes + archive.history {
            _ = try recipe.validated()
        }
        return archive
    }
    func recipes() throws -> [LocalLayoutRecipe] { try read().recipes }
    func previousVersions(of id: UUID) throws -> [LocalLayoutRecipe] { try read().history.filter { $0.id == id } }
    private func write(_ archive: Archive) throws {
        let data = try JSONEncoder().encode(archive)
        guard data.count <= 1_048_576 else { throw PaneLayoutError.invalidTree }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous = try? Data(contentsOf: url) { try previous.write(to: url.appendingPathExtension("previous"), options: .atomic) }
        try data.write(to: url, options: .atomic)
    }
    @discardableResult func save(_ recipe: LocalLayoutRecipe, expectedRevision: Int?) throws -> LocalLayoutRecipe {
        _ = try recipe.validated()
        var archive = try read(), next = recipe
        next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.name.isEmpty, next.name.count <= 80 else { throw PaneLayoutError.invalidTree }
        if let index = archive.recipes.firstIndex(where: { $0.id == recipe.id }) {
            guard expectedRevision == archive.recipes[index].revision, recipe.revision == expectedRevision else { throw PaneLayoutError.stalePreview }
            guard archive.recipes[index].revision < Int.max else { throw PaneLayoutError.invalidTree }
            archive.history.append(archive.recipes[index])
            let same = archive.history.filter { $0.id == recipe.id }
            if same.count > 10 { archive.history.removeAll { item in same.prefix(same.count - 10).contains(item) } }
            next.revision = archive.recipes[index].revision + 1
            next.updatedAt = Date()
            archive.recipes[index] = next
        } else {
            guard expectedRevision == nil, archive.recipes.count < 100 else { throw PaneLayoutError.stalePreview }
            archive.recipes.append(next)
        }
        try write(archive)
        return next
    }
    func delete(_ id: UUID, expectedRevision: Int) throws {
        var archive = try read()
        guard let recipe = archive.recipes.first(where: { $0.id == id }), recipe.revision == expectedRevision else { throw PaneLayoutError.stalePreview }
        archive.recipes.removeAll { $0.id == id }
        // The bounded revision history and preceding file make deletion recoverable.
        archive.history.append(recipe)
        archive.history = Array(archive.history.suffix(1_000))
        try write(archive)
    }
}
