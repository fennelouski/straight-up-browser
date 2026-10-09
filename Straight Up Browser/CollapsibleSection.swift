//
//  CollapsibleSection.swift
//  Straight Up Browser
//
//  Shared with the iOS target (unlike SettingsWindow.swift, which is AppKit-only) because
//  NewspaperView.swift's settings pane, built for both platforms, uses it too.
//

import SwiftUI

/// A Form section whose header doubles as a disclosure control, so a pane full of sections can be
/// collapsed down to just their headers. Like the DisclosureGroups elsewhere in these panes, the
/// collapsed state is view-local rather than persisted — it resets when the pane reappears.
struct CollapsibleSection<Content: View, Header: View, Footer: View>: View {
    var content: () -> Content
    var header: () -> Header
    var footer: () -> Footer
    /// Stable identity for cross-pane settings search (see SettingsSearch.swift) to scroll to and
    /// briefly highlight this section. Nil for sections outside the search index — most callers,
    /// including every use on iOS and in NewspaperView.swift, don't pass one.
    var searchID: String?

    // Written explicitly (rather than relying on the synthesized memberwise init) so searchID
    // can lead as a plain labeled argument ahead of the three trailing closures, e.g.
    // `CollapsibleSection(searchID: "x") { ... } header: { ... } footer: { ... }`.
    init(
        searchID: String? = nil,
        initiallyCollapsed: Bool = false,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.searchID = searchID
        self._isCollapsed = State(initialValue: initiallyCollapsed)
        self.content = content
        self.header = header
        self.footer = footer
    }

    @State private var isCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // SettingsSearchNavigation drives cross-pane search on macOS only (SettingsWindow.swift,
    // which owns it, is AppKit-only) — this type wouldn't exist on the iOS build of this file.
    #if os(macOS)
    private var isHighlighted: Bool {
        searchID != nil && SettingsSearchNavigation.shared.highlightedID == searchID
    }
    #else
    private var isHighlighted: Bool { false }
    #endif

    var body: some View {
        // Let native controls draw their full bounds. A clip on every row cuts off
        // segmented caps, slider thumbs and focus rings even while expanded.
        // Remove collapsed rows from the Form so it also removes their separators/insets.
        let section = Section {
            if !isCollapsed {
                content()
            }
        } header: {
            Button {
                withAnimation(BrowserMotion.settle(reduceMotion)) { isCollapsed.toggle() }
            } label: {
                HStack {
                    header()
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .browserFeedbackMotion(isHighlighted)
            }
            .buttonStyle(BrowserPressStyle())
        } footer: {
            if !isCollapsed {
                footer()
            }
        }
        // A shared `nil` identity would collide across every non-indexed section in the same
        // Form and confuse SwiftUI's diffing, so only opt in when a searchID is actually given.
        if let searchID {
            section.id(searchID)
                .onAppear { if isHighlighted { isCollapsed = false } }
                .onChange(of: isHighlighted) { _, highlighted in
                    if highlighted { isCollapsed = false }
                }
        } else {
            section
        }
    }
}

extension CollapsibleSection where Footer == EmptyView {
    init(
        searchID: String? = nil,
        initiallyCollapsed: Bool = false,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder header: @escaping () -> Header
    ) {
        self.init(searchID: searchID, initiallyCollapsed: initiallyCollapsed, content: content, header: header, footer: { EmptyView() })
    }
}
