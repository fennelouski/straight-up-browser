#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

private extension UTType {
    nonisolated static let browserPaneArrangement = UTType(exportedAs: "com.straightupbrowser.internal-pane-arrangement")
}

nonisolated struct PaneArrangementDrag: Codable, Transferable {
    var sessionID: UUID
    var sourceID: UUID
    var revision: UInt64
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .browserPaneArrangement)
    }
}

extension Notification.Name {
    static let browserArrangePanes = Notification.Name("browserArrangePanes")
}

struct PaneArrangementContent: Identifiable {
    var reference: PaneContentReference
    var title: String
    var isProtected: Bool
    var id: UUID { reference.id }
}

/// A linear keyboard/VoiceOver equivalent of spatial placement. Nothing in this
/// panel changes geometry, creates a tab, or navigates until Apply is pressed.
struct PaneArrangementPanel: View {
    @ObservedObject var tabManager: TabManager
    let tabs: [Tab]
    let content: [PaneArrangementContent]
    let store: LocalLayoutRecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: UUID?
    @State private var targetID: UUID?
    @State private var placement = PanePlacement.center
    @State private var preview: PaneLayoutPreview?
    @State private var issue: String?
    @State private var recipes: [LocalLayoutRecipe] = []
    @State private var recipeID: UUID?
    @State private var recipeName = ""
    @State private var recipeDraft: LocalLayoutRecipe?
    @State private var recipeUpdateDiff: LocalLayoutRecipeUpdateDiff?
    @State private var keepProtectedVisible = true
    @State private var deletedRecipe: LocalLayoutRecipe?
    @State private var includeStartingURLs = true
    // One nonce per presentation. Payloads from another window/session, external
    // strings/URLs/files, or an older layout revision are never accepted.
    @State private var arrangementSessionID = UUID()
    @State private var previewCanvasSize = CGSize.zero

    init(tabManager: TabManager, tabs: [Tab], content: [PaneArrangementContent], store: LocalLayoutRecipeStore = LocalLayoutRecipeStore()) {
        self.tabManager = tabManager
        self.tabs = tabs
        self.content = content
        self.store = store
    }

    private var current: PaneLayoutTree? { tabManager.currentPaneLayout() }
    private var selectedRecipe: LocalLayoutRecipe? { recipes.first { $0.id == recipeID } }
    private var displayedTree: PaneLayoutTree? { preview?.tree ?? current }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Arrange panes").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Toggle("Enable pane layouts", isOn: Binding(get: { tabManager.paneLayoutsEnabled }, set: { tabManager.setPaneLayoutsEnabled($0) }))
            Text("Choose content and a destination, review the final layout, then Apply. Tabs and documents keep their live sessions.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 18) {
                placementControls.frame(width: 245)
                VStack(alignment: .leading, spacing: 8) {
                    if let tree = displayedTree {
                        PaneLayoutPreviewCanvas(tree: tree, label: title, onDrop: handleDrop, onSize: { previewCanvasSize = $0 })
                            .frame(minWidth: 320, minHeight: 230)
                    }
                    if let preview {
                        Text(preview.summary).fixedSize(horizontal: false, vertical: true)
                        if !preview.newTabs.isEmpty {
                            Text(preview.newTabs.map { $0.startingURL?.absoluteString ?? $0.label }.joined(separator: "\n"))
                                .font(.caption).textSelection(.enabled)
                        }
                    } else {
                        Text("Current layout — no pending change").foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            recipeControls
            if let issue { Text(issue).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Undo Layout Change") { perform { try tabManager.undoPaneLayout(tabs: tabs); preview = nil } }
                    .disabled(!tabManager.canUndoPaneLayout)
                Button("Redo Layout Change") { perform { try tabManager.undoPaneLayout(tabs: tabs, redo: true); preview = nil } }
                    .disabled(!tabManager.canRedoPaneLayout)
                Spacer()
                Button("Cancel Preview") { preview = nil; recipeDraft = nil; issue = nil }
                    .disabled(preview == nil && recipeDraft == nil)
                Button("Apply Layout") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!tabManager.paneLayoutsEnabled || preview == nil || preview?.tree == current)
            }
        }
        .padding(20)
        .frame(minWidth: 660, idealWidth: 760, minHeight: 600)
        .onAppear {
            sourceID = tabManager.focusedDocumentId ?? tabManager.selectedTabId
            targetID = current?.panes.first?.id
            reloadRecipes()
        }
        .onChange(of: tabManager.paneLayoutRevision) { _, _ in
            if preview != nil { preview = nil; issue = "The layout changed. Preview again before applying." }
            if !((current?.panes ?? []).contains { $0.id == targetID }) { targetID = current?.panes.first?.id }
        }
        .onChange(of: tabManager.activeWorkspaceId) { _, _ in dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in dismiss() }
        .onExitCommand {
            if preview != nil || recipeDraft != nil { preview = nil; recipeDraft = nil }
            else { dismiss() }
        }
    }

    private var placementControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Content", selection: $sourceID) {
                Text("Choose content").tag(Optional<UUID>.none)
                ForEach(content) { item in Text(item.title + (item.isProtected ? " · Protected" : "")).tag(Optional(item.id)) }
            }
            Picker("Destination", selection: $targetID) {
                Text("Choose pane").tag(Optional<UUID>.none)
                ForEach(current?.panes ?? []) { pane in Text(title(pane.content.id)).tag(Optional(pane.id)) }
            }
            Button("Navigate Destinations with Arrow Keys") { }
                .onMoveCommand { direction in
                    let edge: PanePlacement
                    switch direction {
                    case .left: edge = .left
                    case .right: edge = .right
                    case .up: edge = .above
                    case .down: edge = .below
                    @unknown default: return
                    }
                    guard let tree = displayedTree, let targetID, previewCanvasSize.width > 0, previewCanvasSize.height > 0,
                          let next = tree.neighbor(of: targetID, toward: edge, in: CGRect(origin: .zero, size: previewCanvasSize)) else { return }
                    self.targetID = next
                }
                .accessibilityHint("When this button has focus, arrows choose the adjacent destination without wrapping. Placement and Preview Placement choose the operation.")
            Picker("Placement", selection: $placement) {
                ForEach(PanePlacement.allCases) { edge in Text(edge.label).tag(edge) }
            }
            Button("Preview Placement") {
                perform {
                    guard let source = content.first(where: { $0.id == sourceID }), let targetID else { throw PaneLayoutError.unavailableContent }
                    preview = try tabManager.previewPanePlacement(source: source.reference, targetPaneID: targetID, edge: placement, tabs: tabs)
                }
            }
            Button("Preview New Blank Split") {
                perform {
                    guard let targetID else { throw PaneLayoutError.unavailableContent }
                    preview = try tabManager.previewNewBlankPane(targetPaneID: targetID, edge: placement, tabs: tabs)
                }
            }.disabled(placement == .center)
            Button(tabManager.maximizedPaneContentID == nil ? "Temporarily Maximize Destination" : "Restore Full Layout") {
                perform {
                    guard let pane = current?.panes.first(where: { $0.id == targetID }) else { throw PaneLayoutError.unavailableContent }
                    try tabManager.togglePaneMaximize(pane.content.id, tabs: tabs)
                }
            }.disabled(!tabManager.paneLayoutsEnabled)
            if let sourceID, let source = content.first(where: { $0.id == sourceID }) {
                Label("Drag \(source.title)", systemImage: "hand.draw")
                    .font(.callout)
                    .padding(8)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
                    .draggable(PaneArrangementDrag(sessionID: arrangementSessionID, sourceID: sourceID, revision: tabManager.paneLayoutRevision)) {
                        Label(source.title, systemImage: "rectangle.split.2x1").padding(8)
                    }
                    .accessibilityHint("Drag to a labeled center or edge in the preview. Keyboard users can use Placement and Preview Placement.")
            }
            Divider()
            Menu("Preview Arrangement") {
                Button("Columns") { preset { PaneLayoutTree.columns($0) } }
                Button("Rows") { preset { PaneLayoutTree.columns($0, axis: .y) } }
                Button("Grid") { preset { PaneLayoutTree.legacy($0) } }
                Button("Large Left + Cluster") { preset { PaneLayoutTree.largeLeading($0) } }
                Button("Large Top + Cluster") { preset { PaneLayoutTree.largeLeading($0, axis: .y) } }
            }
            if let tree = displayedTree {
                Menu("Resize / Equalize Divider") {
                    ForEach(tree.geometry(in: CGRect(x: 0, y: 0, width: 1000, height: 1000)).dividers, id: \.id) { divider in
                        Menu("\(divider.axis == .x ? "Column" : "Row") · \(Int(divider.ratio * 100))%") {
                            Button("Decrease by 2%") { resize(divider.id, ratio: divider.ratio - 0.02) }
                            Button("Equalize 50/50") { resize(divider.id, ratio: 0.5) }
                            Button("Increase by 2%") { resize(divider.id, ratio: divider.ratio + 0.02) }
                        }
                    }
                }
            }
        }
        .disabled(current == nil)
    }

    private var recipeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved workspace layouts · On this Mac").font(.headline)
            if tabManager.hasUnsavedPaneLayoutChanges { Text("Layout changed · saved starting setup is unchanged").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Picker("Saved layout", selection: $recipeID) {
                    Text("Choose saved layout").tag(Optional<UUID>.none)
                    ForEach(recipes) { recipe in Text("\(recipe.name) · v\(recipe.revision)").tag(Optional(recipe.id)) }
                }
                Button("Preview Open") {
                    perform {
                        guard let recipe = selectedRecipe else { return }
                        if tabManager.revealLiveLayoutRecipe(recipe.id) { dismiss(); return }
                        preview = try tabManager.previewLayoutRecipe(recipe, tabs: tabs, keepProtectedVisible: keepProtectedVisible)
                        recipeDraft = nil
                    }
                }.disabled(selectedRecipe == nil)
            }
            Toggle("Keep protected tabs visible alongside", isOn: $keepProtectedVisible)
            HStack {
                TextField("Layout name", text: $recipeName).textFieldStyle(.roundedBorder)
                Button("Review Save as New") { prepareSave(updating: false) }
                Button("Review Update") { prepareSave(updating: true) }.disabled(selectedRecipe == nil)
            }
            Toggle("Include safe starting pages", isOn: $includeStartingURLs)
            if let draft = recipeDraft {
                Text(recipeUpdateDiff == nil
                     ? "Save \(draft.tree.panes.count) panes, divider ratios, focus, and the references below. Private panes are excluded; sensitive and meeting links become manual slots."
                     : "Review changes to the saved starting setup below. Updating does not change or close live content.")
                    .font(.caption)
                if let diff = recipeUpdateDiff {
                    LocalLayoutRecipeDiffReview(diff: diff)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(draft.slots) { slot in Text(savedDescription(slot)).font(.caption).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 85)
                }
                HStack {
                    Text(selectedRecipe?.id == draft.id ? "Update v\(draft.revision) → v\(draft.revision + 1); previous version retained." : "Create a separate local layout.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Reviewed Layout") { saveDraft() }.buttonStyle(.borderedProminent)
                        .disabled(recipeUpdateDiff?.isEmpty == true)
                }
            }
            HStack {
                Button("Delete Saved Layout") { deleteRecipe() }.disabled(selectedRecipe == nil)
                Button("Undo Delete") { restoreDeleted() }.disabled(deletedRecipe == nil)
                Button("Restore Previous Saved Version") { restorePrevious() }.disabled(selectedRecipe == nil)
                Spacer()
            }
            Text("Opening a saved layout shows a preview. Cold starts open only reviewed safe pages; meeting slots require choosing a current tab. Updates never happen automatically.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: recipeName) { _, _ in recipeDraft = nil }
        .onChange(of: includeStartingURLs) { _, _ in recipeDraft = nil }
        .onChange(of: recipeID) { _, _ in recipeDraft = nil; preview = nil }
    }

    private func title(_ id: UUID) -> String {
        if let item = content.first(where: { $0.id == id }) { return item.title }
        if let plan = preview?.newTabs.first(where: { $0.id == id }) { return plan.label }
        return "Layout slot"
    }
    private func savedDescription(_ slot: LayoutRecipeSlot) -> String {
        switch slot.restore {
        case .document: return "Document reference · resolved by the existing document provider"
        case .safeStarter(let url): return url.absoluteString
        case .chooseCurrentMeeting: return "Meeting / protected tab · choose current tab manually"
        case .empty: return "Empty slot · choose content manually"
        }
    }
    private func perform(_ action: () throws -> Void) {
        issue = nil
        do { try action() } catch { issue = error.localizedDescription }
    }
    private func preset(_ build: ([LayoutPane]) -> PaneLayoutTree?) {
        perform {
            guard let current, let tree = build(current.panes) else { return }
            preview = try tabManager.previewPaneTree(tree, summary: "Rearrange current panes. All content stays open.", tabs: tabs)
        }
    }
    private func resize(_ nodeID: UUID, ratio: Double) {
        perform {
            guard let tree = displayedTree else { return }
            preview = try tabManager.previewPaneTree(tree.settingRatio(nodeID: nodeID, ratio: ratio), summary: "Resize one divider; retain all live content.", tabs: tabs, action: .resize)
        }
    }
    private func apply() {
        perform {
            guard let pending = preview else { return }
            _ = try tabManager.applyPaneLayout(pending, tabs: tabs)
            preview = nil
        }
    }
    private func handleDrop(_ payload: PaneArrangementDrag, targetPaneID: UUID, edge: PanePlacement) -> Bool {
        do {
            guard payload.sessionID == arrangementSessionID, payload.revision == tabManager.paneLayoutRevision else { throw PaneLayoutError.stalePreview }
            guard let source = content.first(where: { $0.id == payload.sourceID }),
                  current?.panes.contains(where: { $0.id == targetPaneID }) == true else { throw PaneLayoutError.unavailableContent }
            preview = try tabManager.previewPanePlacement(source: source.reference, targetPaneID: targetPaneID, edge: edge, tabs: tabs)
            issue = nil
            return true
        } catch {
            issue = error.localizedDescription
            return false
        }
    }
    private func reloadRecipes() { perform { recipes = try store.recipes() } }
    private func prepareSave(updating: Bool) {
        perform {
            let old = updating ? selectedRecipe : nil
            var draft = try tabManager.makeLayoutRecipe(named: recipeName.isEmpty ? (old?.name ?? "Workspace Layout") : recipeName, tabs: tabs, updating: old)
            if !includeStartingURLs {
                for index in draft.slots.indices {
                    if case .safeStarter = draft.slots[index].restore { draft.slots[index].restore = .empty }
                }
            }
            recipeUpdateDiff = try old.map { try LocalLayoutRecipeUpdateDiff(before: $0, proposed: draft) }
            recipeDraft = draft
        }
    }
    private func saveDraft() {
        perform {
            guard let draft = recipeDraft else { return }
            // The reviewed snapshot is authority. A fresh recipe list must not
            // silently promote an old draft to a newer optimistic-lock revision.
            let expected = recipeUpdateDiff?.beforeRevision
            if let expected { guard draft.revision == expected else { throw PaneLayoutError.stalePreview } }
            let saved = try store.save(draft, expectedRevision: expected)
            invalidateRecipeDraft()
            tabManager.markLayoutRecipeSaved(saved.id)
            PowerUpLearning.shared.recordSuccess(feature: .savedWorkspace, method: .button, isPrivate: false)
            recipes = try store.recipes(); recipeID = saved.id; recipeDraft = nil
        }
    }
    private func deleteRecipe() {
        perform {
            guard let recipe = selectedRecipe else { return }
            try store.delete(recipe.id, expectedRevision: recipe.revision)
            invalidateRecipeDraft()
            deletedRecipe = recipe; recipeID = nil; recipes = try store.recipes()
        }
    }
    private func restoreDeleted() {
        perform {
            guard let recipe = deletedRecipe else { return }
            _ = try store.save(recipe, expectedRevision: nil)
            invalidateRecipeDraft()
            recipes = try store.recipes(); recipeID = recipe.id; deletedRecipe = nil
        }
    }
    private func restorePrevious() {
        perform {
            guard let selectedRecipe, var previous = try store.previousVersions(of: selectedRecipe.id).last else { return }
            previous.revision = selectedRecipe.revision
            _ = try store.save(previous, expectedRevision: selectedRecipe.revision)
            invalidateRecipeDraft()
            recipes = try store.recipes()
            issue = "Previous saved version restored. Use Preview Open to apply it to the live layout."
        }
    }

    private func invalidateRecipeDraft() { recipeDraft = nil; recipeUpdateDiff = nil }
}

private struct LocalLayoutRecipeDiffReview: View {
    let diff: LocalLayoutRecipeUpdateDiff
    var body: some View {
        if diff.isEmpty {
            Text("No saved configuration changes. Split identifiers and timestamps alone do not create an update.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Saved v\(diff.beforeRevision)").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Proposed v\(diff.proposedRevision)").frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption.bold())
                    ForEach(diff.changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.subject).font(.caption.bold())
                            HStack(alignment: .top, spacing: 12) {
                                Text(change.before).frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityLabel("Saved: \(change.before)")
                                Text(change.after).frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityLabel("Proposed: \(change.after)")
                            }
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 170)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .accessibilityLabel("Saved layout changes before saving")
        }
    }
}

private struct PaneLayoutPreviewCanvas: View {
    let tree: PaneLayoutTree
    let label: (UUID) -> String
    let onDrop: (PaneArrangementDrag, UUID, PanePlacement) -> Bool
    let onSize: (CGSize) -> Void
    var body: some View {
        GeometryReader { proxy in
            let geometry = tree.geometry(in: CGRect(origin: .zero, size: proxy.size), topLeftOrigin: true)
            ZStack(alignment: .topLeading) {
                ForEach(tree.panes) { pane in
                    if let frame = geometry.panes[pane.content.id] {
                        VStack(spacing: 3) {
                            Text(label(pane.content.id)).font(.caption).lineLimit(1)
                            PaneArrangementDropZone(label: "Above", paneID: pane.id, edge: .above, onDrop: onDrop)
                            HStack(spacing: 3) {
                                PaneArrangementDropZone(label: "Left", paneID: pane.id, edge: .left, onDrop: onDrop)
                                PaneArrangementDropZone(label: "Center", paneID: pane.id, edge: .center, onDrop: onDrop)
                                PaneArrangementDropZone(label: "Right", paneID: pane.id, edge: .right, onDrop: onDrop)
                            }
                            PaneArrangementDropZone(label: "Below", paneID: pane.id, edge: .below, onDrop: onDrop)
                        }
                            .padding(5)
                            .frame(width: max(0, frame.width - 3), height: max(0, frame.height - 3))
                            .background(.quaternary, in: .rect(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.4)))
                            .position(x: frame.midX, y: frame.midY)
                            .accessibilityLabel("\(label(pane.content.id)), layout preview")
                    }
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Final arrangement preview")
    }
}

private struct PaneArrangementDropZone: View {
    let label: String
    let paneID: UUID
    let edge: PanePlacement
    let onDrop: (PaneArrangementDrag, UUID, PanePlacement) -> Bool
    @State private var targeted = false
    var body: some View {
        Text(label).font(.system(size: 10)).lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 20)
            .background(targeted ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(targeted ? Color.accentColor : Color.clear))
            .dropDestination(for: PaneArrangementDrag.self) { payloads, _ in
                guard payloads.count == 1, let payload = payloads.first else { return false }
                return onDrop(payload, paneID, edge)
            } isTargeted: { targeted = $0 }
            .accessibilityLabel("\(label) placement target. Drop to preview, then Apply Layout.")
    }
}
#endif
