//
//  TabGridView.swift
//  Straight Up Browser
//
//  ⌘O: every open tab as a card you can steer with the arrow keys. The sidebar
//  answers "which tabs do I have"; this answers "which one was the page I want",
//  which needs to show the page, not the title.
//

import SwiftUI
import AppKit

struct TabGridView: View {
    @Binding var isPresented: Bool
    let tabs: [Tab]
    let selectedTabId: UUID?
    var thumbnail: (UUID) -> NSImage?
    var onSelect: (UUID) -> Void

    @State private var index = 0
    @State private var keyMonitor: Any?

    private static let columns = 4
    private static let cardWidth: CGFloat = 220
    private static let cardHeight: CGFloat = 138

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .edgesIgnoringSafeArea(.all)
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cardWidth), spacing: 16),
                                             count: Self.columns), spacing: 16) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { position, tab in
                            card(for: tab, isFocused: position == index)
                                .id(tab.id)
                                .onTapGesture { choose(tab.id) }
                        }
                    }
                    .padding(24)
                }
                .onChange(of: index) { _, new in
                    if tabs.indices.contains(new) {
                        withAnimation { proxy.scrollTo(tabs[new].id, anchor: .center) }
                    }
                }
            }
            .frame(maxWidth: CGFloat(Self.columns) * (Self.cardWidth + 16) + 48)
            .background(Color(.windowBackgroundColor).opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 16)
            .padding(40)
        }
        .onAppear {
            index = tabs.firstIndex { $0.id == selectedTabId } ?? 0
            startMonitor()
        }
        .onDisappear { stopMonitor() }
    }

    private func card(for tab: Tab, isFocused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image = thumbnail(tab.id) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Never opened this session (or unloaded): favicon stands in.
                    Group {
                        if let data = tab.favicon, let icon = NSImage(data: data) {
                            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "macwindow")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.12))
                }
            }
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .clipped()

            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? (tab.url?.host ?? String(localized: "New Tab")) : tab.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(tab.url?.host ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Self.cardWidth - 16, alignment: .leading)
            .padding(8)
        }
        .background(isFocused ? Color.blue.opacity(0.18) : Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Color.accentColor : Color.gray.opacity(0.25),
                        lineWidth: isFocused ? 2 : 1)
        )
    }

    private func choose(_ id: UUID) {
        onSelect(id)
        isPresented = false
    }

    // A local NSEvent monitor rather than .onKeyPress: the overlay sits above a
    // WKWebView, which is a stubborn first responder (see OmnibarTextField).
    private func startMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !tabs.isEmpty else { return event }
            switch event.keyCode {
            case 53:  // Escape
                isPresented = false
            case 36:  // Return
                if tabs.indices.contains(index) { choose(tabs[index].id) }
            case 123: index = max(0, index - 1)                          // ←
            case 124: index = min(tabs.count - 1, index + 1)             // →
            case 126: index = max(0, index - Self.columns)               // ↑
            case 125: index = min(tabs.count - 1, index + Self.columns)  // ↓
            default: return event
            }
            return nil
        }
    }

    private func stopMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
