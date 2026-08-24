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
    static let livePreviewsKey = "visualTabLivePreviews"
    static let switcherKey = "visualTabSwitcherStrip"

    static let defaultAspectRatio = 1.6

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

/// ⌃Tab moves fast enough that the sidebar highlight is easy to lose. This is
/// the same cards, laid out in one row across the middle of the window, up only
/// while you're cycling. ponytail: the switch commits on every press (Chrome's
/// behaviour, and it reuses the existing shortcut path) — the strip shows where
/// you landed rather than where you're about to. Defer the commit to Control-up
/// if hopping across a big tab set starts feeling expensive.
struct TabSwitcherStrip: View {
    let tabs: [Tab]
    let selectedTabId: UUID?
    var thumbnail: (UUID) -> NSImage?
    var labels: ((Tab) -> (title: String, detail: String))? = nil

    private static let cardWidth: CGFloat = 132
    private static let cardHeight: CGFloat = 82

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tabs) { tab in
                        card(for: tab).id(tab.id)
                    }
                }
                .padding(14)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: selectedTabId) { _, _ in scroll(proxy) }
        }
        .frame(maxWidth: 720)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 22, y: 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let selectedTabId else { return }
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(selectedTabId, anchor: .center) }
    }

    private func card(for tab: Tab) -> some View {
        let isCurrent = tab.id == selectedTabId
        return VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image = thumbnail(tab.id) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Group {
                        if let data = tab.favicon, let icon = NSImage(data: data) {
                            Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                        } else {
                            Image(systemName: "macwindow").font(.system(size: 18)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.12))
                }
            }
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Text(labels?(tab).title ?? (tab.title.isEmpty ? Tab.extractDomain(from: tab.url) : tab.title))
                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(width: Self.cardWidth, alignment: .leading)
        }
        .padding(5)
        .background(isCurrent ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor, lineWidth: isCurrent ? 2 : 0)
        )
        .scaleEffect(isCurrent ? 1 : 0.94)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: isCurrent)
    }
}

struct TabGridView: View {
    @Binding var isPresented: Bool
    let tabs: [Tab]
    let selectedTabId: UUID?
    var thumbnail: (UUID) -> NSImage?
    var onSelect: (UUID) -> Void
    var refreshLivePreviews: (() -> Void)? = nil
    var labels: ((Tab) -> (title: String, detail: String))? = nil
    var onHover: ((Tab) -> Void)? = nil

    @State private var index = 0
    @State private var keyMonitor: Any?
    @State private var previewRefresh = 0
    @State private var columns = 1
    @AppStorage(VisualTabPreferences.aspectRatioKey)
    private var aspectRatio = VisualTabPreferences.defaultAspectRatio
    @AppStorage(VisualTabPreferences.livePreviewsKey)
    private var livePreviews = true

    private static let cardWidth: CGFloat = 220
    private static let spacing: CGFloat = 16
    private static let gridPadding: CGFloat = 24
    private static let outerPadding: CGFloat = 40
    private var cardHeight: CGFloat {
        Self.cardWidth / CGFloat(min(2.4, max(0.75, aspectRatio)))
    }

    // As many columns as fit the window, so the grid always fits on screen
    // and only the last row (if not full) leaves empty space.
    private func columns(for availableWidth: CGFloat) -> Int {
        let usable = availableWidth - 2 * (Self.outerPadding + Self.gridPadding)
        let perCard = Self.cardWidth + Self.spacing
        return max(1, Int((usable + Self.spacing) / perCard))
    }

    private var gridWidth: CGFloat {
        CGFloat(columns) * (Self.cardWidth + Self.spacing) - Self.spacing + 2 * Self.gridPadding
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.45)
                    .edgesIgnoringSafeArea(.all)
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cardWidth), spacing: Self.spacing),
                                                 count: columns), spacing: Self.spacing) {
                            let _ = previewRefresh
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { position, tab in
                                card(for: tab, isFocused: position == index)
                                    .id(tab.id)
                                    .onTapGesture { choose(tab.id) }
                                    .onHover { hovering in
                                        guard hovering else { return }
                                        index = position
                                        onHover?(tab)
                                    }
                            }
                        }
                        .padding(Self.gridPadding)
                    }
                    .onChange(of: index) { _, new in
                        if tabs.indices.contains(new) {
                            withAnimation { proxy.scrollTo(tabs[new].id, anchor: .center) }
                        }
                    }
                }
                .frame(width: gridWidth,
                       height: max(100, geometry.size.height - 2 * Self.outerPadding))
                .background(Color(.windowBackgroundColor).opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 16)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: geometry.size.width, initial: true) { _, width in
                columns = columns(for: width)
            }
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

            let label = labels?(tab)
            VStack(alignment: .leading, spacing: 1) {
                Text(label?.title ?? (tab.title.isEmpty ? (tab.url?.host ?? String(localized: "New Tab")) : tab.title))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(label?.detail ?? tab.url?.host ?? "")
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
