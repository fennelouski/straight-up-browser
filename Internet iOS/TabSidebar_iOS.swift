//
//  TabSidebar_iOS.swift
//  Internet (iPadOS)
//
//  The NavigationSplitView sidebar: the tab list grouped by TabGroup, with a
//  new-tab button and group/workspace menu. Uses a native List so a hardware
//  keyboard's arrow keys move the selection for free. Favicons come from
//  Tab.favicon; a SwiftUI letter avatar stands in when there isn't one
//  (replacing the Mac's NSImage DomainInitialsGenerator).
//

import SwiftUI
import SwiftData

struct TabSidebar_iOS: View {
    @ObservedObject var tabManager: TabManager
    let tabs: [Tab]
    let tabGroups: [TabGroup]
    let progressValue: Double
    let isLoading: Bool
    let onNewTab: () -> Void
    let onCloseTab: (Tab) -> Void
    let onNewGroup: () -> Void
    let onDeleteGroup: (TabGroup) -> Void
    let onMoveTab: (Tab, UUID?) -> Void
    let onSaveWorkspace: () -> Void
    let onSettings: () -> Void
    let onShortcuts: () -> Void
    let workspaceMenu: AnyView

    private var groupedTabs: [(group: TabGroup?, tabs: [Tab])] {
        let byGroup = Dictionary(grouping: tabs) { $0.groupId }
        var result: [(group: TabGroup?, tabs: [Tab])] = []
        if let ungrouped = byGroup[nil] {
            result.append((nil, ungrouped.sorted { $0.orderIndex < $1.orderIndex }))
        }
        for group in tabGroups.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            if let groupTabs = byGroup[group.id] {
                result.append((group, groupTabs.sorted { $0.orderIndex < $1.orderIndex }))
            }
        }
        return result
    }

    var body: some View {
        List(selection: Binding(
            get: { tabManager.selectedTabId },
            set: { if let id = $0 { tabManager.selectedTabId = id } }
        )) {
            ForEach(groupedTabs, id: \.group?.id) { section in
                if let group = section.group {
                    Section {
                        tabRows(section.tabs)
                    } header: {
                        HStack {
                            Circle().fill(group.color).frame(width: 9, height: 9)
                            Text(group.name)
                            Spacer()
                            Menu {
                                Button(role: .destructive) { onDeleteGroup(group) } label: {
                                    Label("Delete Group", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis").font(.caption)
                            }
                        }
                    }
                } else {
                    tabRows(section.tabs)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Internet")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewTab) { Image(systemName: "plus") }
                    .help("New Tab")
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button(action: onNewGroup) { Label("New Group…", systemImage: "folder.badge.plus") }
                    Button(action: onSaveWorkspace) { Label("Save Workspace…", systemImage: "square.and.arrow.down") }
                    Divider()
                    workspaceMenu
                    Divider()
                    Button(action: onSettings) { Label("Settings", systemImage: "gearshape") }
                    Button(action: onShortcuts) { Label("Keyboard Shortcuts", systemImage: "keyboard") }
                } label: {
                    Image(systemName: "square.stack.3d.up")
                }
            }
        }
    }

    @ViewBuilder
    private func tabRows(_ rowTabs: [Tab]) -> some View {
        ForEach(rowTabs) { tab in
            TabRow_iOS(tab: tab,
                       isActive: tab.id == tabManager.selectedTabId,
                       progressValue: progressValue,
                       isLoading: isLoading)
                .tag(tab.id)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { onCloseTab(tab) } label: {
                        Label("Close", systemImage: "xmark")
                    }
                }
                .contextMenu {
                    Button { onCloseTab(tab) } label: { Label("Close Tab", systemImage: "xmark") }
                    if !tabGroups.isEmpty || tab.groupId != nil {
                        Menu("Move to Group") {
                            Button("None") { onMoveTab(tab, nil) }
                            ForEach(tabGroups) { group in
                                Button(group.name) { onMoveTab(tab, group.id) }
                            }
                        }
                    }
                }
        }
    }
}

// A single tab row: favicon (or letter avatar) + title.
struct TabRow_iOS: View {
    let tab: Tab
    let isActive: Bool
    let progressValue: Double
    let isLoading: Bool

    private var displayTitle: String {
        if !tab.title.isEmpty && tab.title != String(localized: "New Tab") { return tab.title }
        return Tab.extractDomain(from: tab.url)
    }

    var body: some View {
        HStack(spacing: 10) {
            TabFaviconView(tab: tab, showProgress: isActive && isLoading, progress: progressValue)
            Text(displayTitle)
                .lineLimit(1)
                .font(.system(size: 15))
            Spacer(minLength: 0)
            if tab.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// Favicon image if we have one, else a colored circle with the domain's first
// letter. Optional progress ring while the active tab loads.
struct TabFaviconView: View {
    let tab: Tab
    var showProgress: Bool = false
    var progress: Double = 0

    private var host: String { Tab.extractDomain(from: tab.url) }
    private var letter: String { host.first.map { String($0).uppercased() } ?? "•" }

    // Stable hue from the host string (djb2 — Swift's String.hashValue is
    // per-process-randomized, so the same site would recolor every launch).
    private var avatarColor: Color {
        var hash = 5381
        for scalar in host.unicodeScalars { hash = ((hash << 5) &+ hash) &+ Int(scalar.value) }
        return Color(hue: Double(abs(hash) % 360) / 360.0, saturation: 0.55, brightness: 0.75)
    }

    var body: some View {
        ZStack {
            if let data = tab.favicon, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Circle().fill(avatarColor)
                    .frame(width: 18, height: 18)
                    .overlay(Text(letter).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
            }
            if showProgress {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 24, height: 24)
            }
        }
        .frame(width: 24, height: 24)
    }
}
