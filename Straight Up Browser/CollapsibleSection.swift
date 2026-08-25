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
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header
    @ViewBuilder var footer: () -> Footer

    @State private var isCollapsed = false

    var body: some View {
        // Collapsing hides content/footer by clipping them to zero height rather than removing
        // them from the Section, so the grouped box keeps drawing around just the header — an
        // empty Section renders without its box, which drops the header's icon/text formatting
        // and the spacing between sections.
        Section {
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
            }
            .buttonStyle(.plain)
        } footer: {
            footer()
                .frame(maxHeight: isCollapsed ? 0 : nil)
                .clipped()
                .opacity(isCollapsed ? 0 : 1)
                .accessibilityHidden(isCollapsed)
        }
    }
}

extension CollapsibleSection where Footer == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder header: @escaping () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}
