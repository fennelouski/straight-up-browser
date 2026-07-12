//
//  TabRowView.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct TabDropDelegate: DropDelegate {
    let tabId: UUID
    let onReorder: ((UUID, UUID) -> Void)?


    func performDrop(info: DropInfo) -> Bool {
        Logger.log("TabDropDelegate performDrop called for tabId: \(tabId)", type: "TabRowView")
        guard let itemProvider = info.itemProviders(for: [UTType.text]).first else {
            Logger.log("No text item provider found", type: "TabRowView")
            return false
        }

        itemProvider.loadObject(ofClass: NSString.self) { (string, error) in
            DispatchQueue.main.async {
                let draggedTabIdString = string as? String
                if let draggedTabIdString = draggedTabIdString,
                   let draggedTabId = UUID(uuidString: draggedTabIdString) {
                    Logger.log("Dropped tab \(draggedTabId) onto tab \(self.tabId)", type: "TabRowView")
                    if draggedTabId != self.tabId {
                        // Call the reorder function with source and target tab IDs
                        self.onReorder?(draggedTabId, self.tabId)
                    }
                } else {
                    Logger.log("Failed to parse dragged tab ID: \(draggedTabIdString ?? "nil")", type: "TabRowView")
                }
            }
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        // Could add visual feedback here if desired
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
}

struct TabRowView: View {
    let tab: Tab
    let selectedTabId: UUID?
    let availableWidth: CGFloat
    let showOnlyIcons: Bool
    let tabBarWidth: CGFloat
    let onSelect: () -> Void
    let onReorder: ((UUID, UUID) -> Void)? // sourceTabId, targetTabId

    private var isSelected: Bool {
        selectedTabId == tab.id
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
                if showOnlyIcons {
                    // Centered favicon layout for icon-only mode
                    // Use ZStack with explicit frame to ensure content stays within tab bar bounds
                    ZStack {
                        // Show favicon if available, otherwise show default icon
                        if let faviconData = tab.favicon, let nsImage = NSImage(data: faviconData) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                                .clipped()
                        } else if tab.url != nil {
                            Image(systemName: "globe")
                                .font(.system(size: 14))
                                .foregroundColor(isSelected ? .blue : .gray)
                        } else {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 14))
                                .foregroundColor(isSelected ? .blue : .gray)
                        }
                    }
                    .frame(width: availableWidth, height: 32)
                    .background(isSelected ? Color.blue.opacity(0.15) : Color(.windowBackgroundColor).opacity(0.01))
                    .contentShape(Rectangle())
                    .clipped() // Ensure content doesn't overflow
                } else {
                    // Standard layout with icon and text
                    HStack(spacing: 4) {
                        // Show favicon if available, otherwise show default icon
                        if let faviconData = tab.favicon, let nsImage = NSImage(data: faviconData) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .frame(width: 16, height: 16)
                        } else if tab.url != nil {
                            Image(systemName: "globe")
                                .font(.system(size: 12))
                                .foregroundColor(isSelected ? .blue : .gray)
                        } else {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 12))
                                .foregroundColor(isSelected ? .blue : .gray)
                        }

                        Text(displayTitle)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundColor(isSelected ? .blue : .primary)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(isSelected ? Color.blue.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
        .onDrag {
            Logger.log("TabRowView onDrag called for tab: \(tab.id)", type: "TabRowView")
            // Provide the tab ID as the drag item
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], delegate: TabDropDelegate(tabId: tab.id, onReorder: onReorder))
        .contentShape(Rectangle()) // Make the entire area droppable
    }
}
