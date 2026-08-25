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
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.searchID = searchID
        self.content = content
        self.header = header
        self.footer = footer
    }

    @State private var isCollapsed = false

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
        // Collapsing hides content/footer by clipping them to zero height rather than removing
        // them from the Section, so the grouped box keeps drawing around just the header — an
        // empty Section renders without its box, which drops the header's icon/text formatting
        // and the spacing between sections.
        let section = Section {
            content()
                .frame(maxHeight: isCollapsed ? 0 : nil)
                .clipped()
                .opacity(isCollapsed ? 0 : 1)
                .disabled(isCollapsed)
                .accessibilityHidden(isCollapsed)
        } header: {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isCollapsed.toggle() }
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
                .animation(.easeInOut(duration: 0.3), value: isHighlighted)
            }
            .buttonStyle(.plain)
        } footer: {
            footer()
                .frame(maxHeight: isCollapsed ? 0 : nil)
                .clipped()
                .opacity(isCollapsed ? 0 : 1)
                .accessibilityHidden(isCollapsed)
        }
        // A shared `nil` identity would collide across every non-indexed section in the same
        // Form and confuse SwiftUI's diffing, so only opt in when a searchID is actually given.
        if let searchID {
            section.id(searchID)
        } else {
            section
        }
    }
}

extension CollapsibleSection where Footer == EmptyView {
    init(
        searchID: String? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder header: @escaping () -> Header
    ) {
        self.init(searchID: searchID, content: content, header: header, footer: { EmptyView() })
    }
}
