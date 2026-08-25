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
        Section {
            if !isCollapsed { content() }
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
            if !isCollapsed { footer() }
        }
    }
}

extension CollapsibleSection where Footer == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder header: @escaping () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}
