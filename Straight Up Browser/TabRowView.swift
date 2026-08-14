//
//  TabRowView.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let straightUpBrowserTab = UTType(exportedAs: "com.nathanfennel.straight-up-browser.tab")
}

func tabDragItemProvider(for tabId: UUID) -> NSItemProvider {
    let provider = NSItemProvider()
    let data = Data(tabId.uuidString.utf8)
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.straightUpBrowserTab.identifier,
        visibility: .ownProcess
    ) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}

private struct AutomaticLinkMitosisModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let cue: AutomaticLinkBirthCue?
    let tabId: UUID

    @State private var sourceCompressed = false
    @State private var childPresented = true
    @State private var glowVisible = false

    private enum Role { case source, child }

    private var role: Role? {
        guard let cue else { return nil }
        if cue.sourceTabId == tabId { return .source }
        if cue.childTabId == tabId { return .child }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(
                x: sourceCompressed ? 0.96 : (childPresented ? 1 : 0.52),
                y: sourceCompressed ? 1.04 : (childPresented ? 1 : 0.88),
                anchor: .leading
            )
            .offset(x: role == .child && !childPresented ? -14 : 0)
            .opacity(role == .child && !childPresented ? 0.3 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.accentColor.opacity(glowVisible ? 0.5 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .onAppear { play() }
            .onChange(of: cue?.token) { _, _ in play() }
    }

    private func play() {
        guard !reduceMotion, let role else {
            sourceCompressed = false
            childPresented = true
            glowVisible = false
            return
        }

        switch role {
        case .source:
            withAnimation(.easeOut(duration: 0.11)) {
                sourceCompressed = true
                glowVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.58)) {
                    sourceCompressed = false
                }
            }
        case .child:
            childPresented = false
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                    childPresented = true
                    glowVisible = true
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.easeOut(duration: 0.2)) { glowVisible = false }
        }
    }
}

extension View {
    func automaticLinkMitosis(cue: AutomaticLinkBirthCue?, tabId: UUID) -> some View {
        modifier(AutomaticLinkMitosisModifier(cue: cue, tabId: tabId))
    }
}

/// The row contracts, softens, and vanishes around its favicon instead of
/// silently closing. Used by Back-to-source and ordinary sidebar closes alike.
private struct TabPoofModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(progress, anchor: .leading)
            .opacity(progress)
            .blur(radius: (1 - progress) * 7)
            .rotationEffect(.degrees(Double(1 - progress) * -3), anchor: .leading)
    }
}

extension AnyTransition {
    static var tabPoof: AnyTransition {
        .modifier(
            active: TabPoofModifier(progress: 0.08),
            identity: TabPoofModifier(progress: 1)
        )
    }
}

struct TabDropDelegate: DropDelegate {
    let tabId: UUID
    let draggedTabId: UUID?
    let onReorder: ((UUID, UUID) -> Void)?
    let onDropFinished: (() -> Void)?

    func performDrop(info: DropInfo) -> Bool {
        Logger.log("TabDropDelegate performDrop called for tabId: \(tabId)", type: "TabRowView")
        // Reordering already happened as rows were crossed. Repeating the move
        // here would reverse the final hover move, so drop only commits/clears.
        onDropFinished?()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedTabId else { return }
        onReorder?(draggedTabId, tabId)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
}

struct TabRowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let tab: Tab
    let selectedTabId: UUID?
    let availableWidth: CGFloat
    let showOnlyIcons: Bool
    let tabBarWidth: CGFloat
    let onSelect: () -> Void
    let onReorder: ((UUID, UUID) -> Void)? // sourceTabId, targetTabId
    var onDragBegan: ((UUID) -> Void)? = nil
    var onDropFinished: (() -> Void)? = nil
    var draggedTabId: UUID? = nil
    var dropTargetTabId: UUID? = nil
    var loadingProgress: Double? = nil // non-nil draws a progress ring around the favicon
    var downloads: [ActiveDownload] = [] // concentric, independently colored transfer rings
    var sessionColor: Color? = nil      // container/incognito session tint; nil = normal tab
    var isIncognito: Bool = false
    var isDisplayedInSplit: Bool = false // visible as a split pane (dimmer highlight + glyph)
    var automaticLinkBirthCue: AutomaticLinkBirthCue? = nil
    var thumbnail: NSImage? = nil
    var expandedHeight: CGFloat? = nil

    private var isSelected: Bool {
        selectedTabId == tab.id
    }

    private var isBeingDragged: Bool { draggedTabId == tab.id }
    private var isDropTarget: Bool { draggedTabId != nil && dropTargetTabId == tab.id && !isBeingDragged }

    // Focused tab gets the full highlight; other displayed split members a dimmer one.
    private var rowHighlight: Color? {
        if isSelected { return accent.opacity(0.15) }
        if isDisplayedInSplit { return accent.opacity(0.07) }
        return nil
    }

    // The session tint drives the selection highlight so isolated sessions read as
    // distinct; normal tabs keep the familiar blue.
    private var accent: Color { sessionColor ?? .blue }

    // Favicon (or placeholder icon) with an optional loading ring around it
    @ViewBuilder
    private func faviconView(placeholderSize: CGFloat) -> some View {
        ZStack {
            if let faviconData = tab.favicon, let nsImage = NSImage(data: faviconData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .clipped()
            } else if tab.url != nil {
                Image(systemName: "globe")
                    .font(.system(size: placeholderSize))
                    .foregroundColor(isSelected ? accent : .gray)
            } else {
                Image(systemName: "plus.circle")
                    .font(.system(size: placeholderSize))
                    .foregroundColor(isSelected ? accent : .gray)
            }

            if let progress = loadingProgress {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1.5)
                    .frame(width: 21, height: 21)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 21, height: 21)
                    .animation(reduceMotion ? nil : .linear(duration: 0.1), value: progress)
            }

            ForEach(Array(downloads.enumerated()), id: \.element.id) { layer, transfer in
                let diameter = CGFloat(23 + min(layer, 5) * 3)
                Circle()
                    .stroke(DownloadVisuals.color(for: transfer.colorIndex).opacity(0.18), lineWidth: 2)
                    .frame(width: diameter, height: diameter)
                Circle()
                    .trim(from: 0, to: max(0.015, transfer.progress))
                    .stroke(
                        DownloadVisuals.color(for: transfer.colorIndex),
                        style: StrokeStyle(
                            lineWidth: 2,
                            lineCap: .round,
                            dash: transfer.state == .failed ? [2, 2] : []
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter, height: diameter)
                    .animation(reduceMotion ? nil : .linear(duration: 0.1), value: transfer.progress)
            }

            // Incognito badge on the favicon corner — visible in both layouts.
            if isIncognito {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(accent)
                    .padding(1)
                    .background(Circle().fill(Color(.windowBackgroundColor)))
                    .offset(x: 7, y: 7)
            }
        }
    }

    // SwiftUI's .lineLimit(1)/.truncationMode(.tail) handles width truncation
    private var displayTitle: String {
        if SettingsManager.shared.showWebpageTitlesInTabs && !tab.title.isEmpty {
            return tab.title
        }
        return Tab.extractDomain(from: tab.url)
    }

    var body: some View {
        ZStack {
            Button {
                onSelect()
            } label: {
                if let expandedHeight, expandedHeight > 52, !showOnlyIcons {
                    ZStack(alignment: .bottomLeading) {
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(height: expandedHeight)
                                .clipped()
                                .overlay(
                                    LinearGradient(
                                        colors: [.clear, .black.opacity(0.72)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        } else {
                            LinearGradient(
                                colors: [accent.opacity(0.34), accent.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        }
                        HStack(spacing: 8) {
                            faviconView(placeholderSize: 18)
                                .padding(5)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayTitle)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(thumbnail == nil ? Color.primary : Color.white)
                                    .lineLimit(2)
                                if let host = tab.url?.host {
                                    Text(host)
                                        .font(.caption2)
                                        .foregroundStyle(thumbnail == nil ? Color.secondary : Color.white.opacity(0.72))
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if tab.isPinned { Image(systemName: "pin.fill").font(.caption2) }
                        }
                        .padding(10)
                    }
                    .frame(height: expandedHeight)
                    .background(accent.opacity(isSelected ? 0.22 : 0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? accent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                    }
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                } else if showOnlyIcons {
                    // Centered favicon layout for icon-only mode
                    // Use ZStack with explicit frame to ensure content stays within tab bar bounds
                    faviconView(placeholderSize: 14)
                    .frame(width: availableWidth, height: 32)
                    .background(rowHighlight ?? Color(.windowBackgroundColor).opacity(0.01))
                    .contentShape(Rectangle())
                    .clipped() // Ensure content doesn't overflow
                } else {
                    // Standard layout with icon and text
                    HStack(spacing: 4) {
                        faviconView(placeholderSize: 12)

                        Text(displayTitle)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundColor(isSelected ? accent : .primary)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)

                        if tab.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }

                        if tab.isMuted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }

                        if isDisplayedInSplit {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: 9))
                                .foregroundColor(accent.opacity(isSelected ? 1 : 0.6))
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(rowHighlight ?? Color.clear)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(BrowserAccessibility.tabLabel(
                title: displayTitle,
                url: tab.url,
                sessionKind: tab.sessionKind,
                isPinned: tab.isPinned,
                isMuted: tab.isMuted,
                isInSplit: isDisplayedInSplit
            ))
            .accessibilityValue(BrowserAccessibility.tabValue(
                isSelected: isSelected,
                isLoading: loadingProgress != nil,
                loadProgress: loadingProgress ?? 0,
                activeDownloadCount: downloads.count
            ))
            .accessibilityHint("Select this tab")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        // Session tint stripe on the leading edge — makes container/incognito tabs
        // obvious even when they aren't selected.
        .overlay(alignment: .leading) {
            if let sessionColor {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(sessionColor)
                    .frame(width: 3)
                    .padding(.vertical, 3)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .padding(.vertical, 1)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(isBeingDragged ? 1.035 : 1)
        .opacity(isBeingDragged ? 0.68 : 1)
        .shadow(color: .black.opacity(isBeingDragged ? 0.18 : 0), radius: 5, y: 2)
        .zIndex(isBeingDragged ? 2 : (isDropTarget ? 1 : 0))
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.7),
                   value: isBeingDragged)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.74),
                   value: isDropTarget)
        .onDrag {
            Logger.log("TabRowView onDrag called for tab: \(tab.id)", type: "TabRowView")
            onDragBegan?(tab.id)
            return tabDragItemProvider(for: tab.id)
        }
        .onDrop(
            of: [.straightUpBrowserTab],
            delegate: TabDropDelegate(
                tabId: tab.id,
                draggedTabId: draggedTabId,
                onReorder: onReorder,
                onDropFinished: onDropFinished
            )
        )
        .contentShape(Rectangle()) // Make the entire area droppable
        .automaticLinkMitosis(cue: automaticLinkBirthCue, tabId: tab.id)
        // The full action menu lives in ContentView (it needs webViewManager,
        // tabManager, and sibling tabs) — a second .contextMenu here would
        // shadow it, so this row stays menu-free.
    }
}
