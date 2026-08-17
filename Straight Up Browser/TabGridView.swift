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

enum VisualTabPreferences {
    static let aspectRatioKey = "visualTabAspectRatio"
    static let columnCountKey = "visualTabColumnCount"
    static let livePreviewsKey = "visualTabLivePreviews"

    static let defaultAspectRatio = 1.6
    static let defaultColumnCount = 4

    static var livePreviewsEnabled: Bool {
        UserDefaults.standard.object(forKey: livePreviewsKey) == nil
            || UserDefaults.standard.bool(forKey: livePreviewsKey)
    }
}

struct NewspaperSaveFlight: View {
    let token: UUID?
    let destinationSide: BrowserChromeSide
    @State private var progress: CGFloat = 0
    @State private var visible = false

    var body: some View {
        GeometryReader { geometry in
            if token != nil {
                flight(in: geometry.size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: token) { _, newToken in
            guard newToken != nil else { return }
            progress = 0
            visible = true
            withAnimation(.spring(response: 0.68, dampingFraction: 0.76)) { progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
                withAnimation(.easeOut(duration: 0.2)) { visible = false }
            }
        }
    }

    private func flight(in size: CGSize) -> some View {
        let destinationX: CGFloat = destinationSide == .left ? -size.width / 2 + 28 : size.width / 2 - 28
        let destinationY: CGFloat = -size.height / 2 + 28
        return ZStack {
            Circle()
                .fill(Color.brown.opacity(0.24))
                .frame(width: 7, height: 7)
                .offset(x: destinationX * max(0, progress - 0.08),
                        y: destinationY * max(0, progress - 0.08))
            Image(systemName: "newspaper.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .padding(12)
                .background(Circle().fill(Color.brown.gradient))
                .shadow(color: .black.opacity(0.24), radius: 8, y: 4)
                .rotationEffect(.degrees(Double(progress) * 18))
                .scaleEffect(1 - progress * 0.42)
                .offset(x: destinationX * progress, y: destinationY * progress)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(visible ? 1 : 0)
    }
}

struct TabGridView: View {
    @Binding var isPresented: Bool
    let tabs: [Tab]
    let selectedTabId: UUID?
    var thumbnail: (UUID) -> NSImage?
    var onSelect: (UUID) -> Void
    var refreshLivePreviews: (() -> Void)? = nil

    @State private var index = 0
    @State private var keyMonitor: Any?
    @State private var previewRefresh = 0
    @AppStorage(VisualTabPreferences.aspectRatioKey)
    private var aspectRatio = VisualTabPreferences.defaultAspectRatio
    @AppStorage(VisualTabPreferences.columnCountKey)
    private var columnCount = VisualTabPreferences.defaultColumnCount
    @AppStorage(VisualTabPreferences.livePreviewsKey)
    private var livePreviews = true

    private static let cardWidth: CGFloat = 220
    private var columns: Int { min(6, max(1, columnCount)) }
    private var cardHeight: CGFloat {
        Self.cardWidth / CGFloat(min(2.4, max(0.75, aspectRatio)))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .edgesIgnoringSafeArea(.all)
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cardWidth), spacing: 16),
                                             count: columns), spacing: 16) {
                        let _ = previewRefresh
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
            .frame(maxWidth: CGFloat(columns) * (Self.cardWidth + 16) + 48)
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
        .task(id: livePreviews) {
            guard livePreviews else { return }
            while !Task.isCancelled {
                refreshLivePreviews?()
                try? await Task.sleep(for: .seconds(1.5))
                previewRefresh &+= 1
            }
        }
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
            .frame(width: Self.cardWidth, height: cardHeight)
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
            case 126: index = max(0, index - columns)               // ↑
            case 125: index = min(tabs.count - 1, index + columns)  // ↓
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
