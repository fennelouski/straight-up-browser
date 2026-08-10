//
//  AdaptiveTabRail_iOS.swift
//  Browser (iOS)
//
//  An opt-in iPad tab rail that occupies the short edge of the current window.
//  Portrait-like windows use top/bottom; landscape-like windows use left/right.
//  When that axis changes, the old drawer retracts before the new one extends.
//

import SwiftUI
import UIKit

enum TabRailVisibility_iOS: String, CaseIterable, Identifiable {
    case off
    case always
    case portraitOnly
    case landscapeOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .always: "Always"
        case .portraitOnly: "Portrait Only"
        case .landscapeOnly: "Landscape Only"
        }
    }

    func isVisible(isLandscape: Bool) -> Bool {
        switch self {
        case .off: false
        case .always: true
        case .portraitOnly: !isLandscape
        case .landscapeOnly: isLandscape
        }
    }
}

enum PortraitTabRailEdge_iOS: String, CaseIterable, Identifiable {
    case top
    case bottom

    var id: String { rawValue }
    var title: String { self == .top ? "Top" : "Bottom" }
}

enum LandscapeTabRailEdge_iOS: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }
}

enum TabRailPlacement_iOS: Equatable {
    case top
    case bottom
    case left
    case right

    var edge: Edge {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    var isHorizontal: Bool { self == .top || self == .bottom }
}

struct AdaptiveTabRail_iOS: View {
    let desiredPlacement: TabRailPlacement_iOS?
    let tabs: [Tab]
    let selectedTabId: UUID?
    let progressValue: Double
    let isLoading: Bool
    let showFaviconProgress: Bool
    let sessionColor: (Tab) -> Color?
    let onSelect: (Tab) -> Void
    let onNewTab: () -> Void
    let onClose: (Tab) -> Void
    let onDuplicate: (Tab) -> Void
    let onTogglePinned: (Tab) -> Void
    let onToggleMuted: (Tab) -> Void
    let onToggleSplit: (Tab) -> Void
    let onReorder: (UUID, UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderedPlacement: TabRailPlacement_iOS?
    @State private var isOpen = false
    @State private var transitionTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            if let renderedPlacement, isOpen {
                rail(for: renderedPlacement)
                    .padding(insets(for: renderedPlacement, geometry: geometry))
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: alignment(for: renderedPlacement)
                    )
                    .transition(.move(edge: renderedPlacement.edge).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(isOpen)
        .onAppear { replacePlacement(with: desiredPlacement, animated: false) }
        .onChange(of: desiredPlacement) { _, placement in
            replacePlacement(with: placement, animated: true)
        }
        .onDisappear { transitionTask?.cancel() }
    }

    @ViewBuilder
    private func rail(for placement: TabRailPlacement_iOS) -> some View {
        if placement.isHorizontal {
            HStack(spacing: 3) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) { tabItems }
                }
                newTabButton
            }
            .padding(4)
            .padding(.trailing, placement == .top ? 48 : 0)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 3) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) { tabItems }
                }
                newTabButton
            }
            .padding(4)
            .padding(.top, placement == .right ? 48 : 0)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var tabItems: some View {
        ForEach(tabs) { tab in
            Button { onSelect(tab) } label: {
                TabFaviconView(
                    tab: tab,
                    showProgress: BrowserResourcePolicy.showFaviconProgress(
                        enabled: showFaviconProgress,
                        isActive: tab.id == selectedTabId,
                        isLoading: isLoading
                    ),
                    progress: progressValue
                )
                .frame(width: 36, height: 36)
                .background(
                    tab.id == selectedTabId
                        ? (sessionColor(tab) ?? Color.accentColor).opacity(0.18)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title.isEmpty ? Tab.extractDomain(from: tab.url) : tab.title)
            .accessibilityValue(tab.id == selectedTabId ? "Selected" : "")
            .contextMenu {
                Button { onDuplicate(tab) } label: {
                    Label("Duplicate Tab", systemImage: "plus.square.on.square")
                }
                Button { onTogglePinned(tab) } label: {
                    Label(tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: "pin")
                }
                Button { onToggleMuted(tab) } label: {
                    Label(
                        tab.isMuted ? "Unmute Tab" : "Mute Tab",
                        systemImage: tab.isMuted ? "speaker.wave.2" : "speaker.slash"
                    )
                }
                Button { onToggleSplit(tab) } label: {
                    Label("Toggle Split Pane", systemImage: "rectangle.split.2x1")
                }
                Divider()
                Button(role: .destructive) { onClose(tab) } label: {
                    Label("Close Tab", systemImage: "xmark")
                }
            }
            .draggable(tab.id.uuidString)
            .dropDestination(for: String.self) { values, _ in
                guard let raw = values.first, let source = UUID(uuidString: raw) else { return false }
                onReorder(source, tab.id)
                return true
            }
        }
    }

    private var newTabButton: some View {
        Button(action: onNewTab) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Tab")
    }

    private func replacePlacement(with placement: TabRailPlacement_iOS?, animated: Bool) {
        transitionTask?.cancel()
        guard renderedPlacement != placement || !isOpen else { return }

        if !animated || reduceMotion {
            renderedPlacement = placement
            isOpen = placement != nil
            return
        }

        withAnimation(.easeIn(duration: 0.12)) { isOpen = false }
        transitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            renderedPlacement = placement
            guard placement != nil else { return }
            withAnimation(.easeOut(duration: 0.18)) { isOpen = true }
        }
    }

    private func alignment(for placement: TabRailPlacement_iOS) -> Alignment {
        switch placement {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private func insets(
        for placement: TabRailPlacement_iOS,
        geometry: GeometryProxy
    ) -> EdgeInsets {
        let safe = geometry.safeAreaInsets
        return switch placement {
        case .top:
            EdgeInsets(top: 3, leading: max(3, safe.leading), bottom: 0, trailing: max(3, safe.trailing))
        case .bottom:
            EdgeInsets(top: 0, leading: max(3, safe.leading), bottom: max(3, safe.bottom), trailing: max(3, safe.trailing))
        case .left:
            EdgeInsets(top: max(3, safe.top), leading: max(3, safe.leading), bottom: max(3, safe.bottom), trailing: 0)
        case .right:
            EdgeInsets(top: max(3, safe.top), leading: 0, bottom: max(3, safe.bottom), trailing: max(3, safe.trailing))
        }
    }
}
