//
//  TabPeek.swift
//  Straight Up Browser
//
//  Hold Control and hover a tab to look in on it without leaving the tab you're
//  on. The panel can sit under the pointer, in the middle of the window, or
//  pinned to the top middle of the screen — that last one puts the page you're
//  checking directly under the webcam, so glancing at it still reads as eye
//  contact on a call.
//

import SwiftUI
import Combine
import WebKit
import AppKit

enum TabPeekPlacement: String, CaseIterable, Identifiable {
    case pointer
    case windowCenter
    case screenTop

    static let defaultsKey = "tabPeekPlacement"
    static let enabledKey = "tabPeekEnabled"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pointer: return String(localized: "Near the pointer")
        case .windowCenter: return String(localized: "Middle of the window")
        case .screenTop: return String(localized: "Top middle of the screen")
        }
    }
}

// What the panel is showing right now. Refreshed on a timer while it's up.
@MainActor
final class TabPeekModel: ObservableObject {
    @Published var image: NSImage?
    @Published var title = ""
    @Published var host = ""
    @Published var status: [String] = []
}

private final class TabPeekWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TabPeekController {
    static let shared = TabPeekController()

    private let model = TabPeekModel()
    private var panel: TabPeekWindow?
    private var refreshTask: Task<Void, Never>?
    private var peekedTabId: UUID?
    // Hover and modifier state are kept separately: holding Control after the
    // pointer has already reached a tab should open the peek just as reliably
    // as entering the tab with Control already held.
    private var hoveredTab: Tab?
    private weak var hoveredWebViewManager: WebViewManager?
    private var modifierMonitor: Any?
    private var refreshGeneration = 0
    private var onSidebarThumbnailUpdated: (() -> Void)?

    private static let panelSize = NSSize(width: 420, height: 322)

    private var placement: TabPeekPlacement {
        TabPeekPlacement(rawValue: UserDefaults.standard.string(forKey: TabPeekPlacement.defaultsKey) ?? "")
            ?? .screenTop
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: TabPeekPlacement.enabledKey) as? Bool ?? true
    }

    static func shouldPresent(
        isEnabled: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        isEnabled && modifierFlags.contains(.control)
    }

    /// Called whenever a tab begins receiving pointer hover. This records the
    /// target even before Control goes down, so a later modifier edge can start
    /// the live peek without asking the person to leave and re-enter the tab.
    func hovered(
        tab: Tab,
        webViewManager: WebViewManager?,
        onSidebarThumbnailUpdated: @escaping () -> Void
    ) {
        guard isEnabled else { return }
        guard let webViewManager else { return }

        hoveredTab = tab
        hoveredWebViewManager = webViewManager
        self.onSidebarThumbnailUpdated = onSidebarThumbnailUpdated
        installModifierMonitor()
        showPeekIfControlHeld()
    }

    /// Ends the current hover target. The panel itself ignores mouse events, so
    /// leaving its source tab is always what closes a Control-hover peek.
    func unhovered(tabId: UUID) {
        guard hoveredTab?.id == tabId else { return }
        hoveredTab = nil
        hoveredWebViewManager = nil
        onSidebarThumbnailUpdated = nil
        removeModifierMonitor()
        hide()
    }

    func hide() {
        refreshTask?.cancel()
        refreshTask = nil
        peekedTabId = nil
        refreshGeneration &+= 1
        panel?.orderOut(nil)
    }

    // MARK: - Hover and modifier tracking

    private func showPeekIfControlHeld(
        modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
        guard Self.shouldPresent(isEnabled: isEnabled, modifierFlags: modifierFlags),
              let tab = hoveredTab,
              let webViewManager = hoveredWebViewManager else {
            hide()
            return
        }
        guard peekedTabId != tab.id else { return }

        peekedTabId = tab.id
        model.image = webViewManager.thumbnail(for: tab.id)
        refreshMetadata(tab: tab, webViewManager: webViewManager)
        present()
        startRefreshing(tab: tab, webViewManager: webViewManager)
    }

    private func installModifierMonitor() {
        guard modifierMonitor == nil else { return }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.showPeekIfControlHeld(modifierFlags: event.modifierFlags)
            }
            return event
        }
    }

    private func removeModifierMonitor() {
        guard let modifierMonitor else { return }
        NSEvent.removeMonitor(modifierMonitor)
        self.modifierMonitor = nil
    }

    // MARK: - Contents

    private func refreshMetadata(tab: Tab, webViewManager: WebViewManager) {
        let webView = webViewManager.existingWebView(for: tab.id)
        model.title = tab.title.isEmpty ? Tab.extractDomain(from: tab.url) : tab.title
        model.host = tab.url?.host ?? ""

        var status: [String] = []
        if webView == nil {
            status.append(String(localized: "Not in memory"))
        } else if webView?.isLoading == true {
            status.append(String(localized: "Loading…"))
        } else {
            status.append(String(localized: "Ready"))
        }
        if tab.isMuted { status.append(String(localized: "Muted")) }
        if MemoryPinnedSites.isPinned(tab.url) { status.append(String(localized: "Kept in memory")) }
        if tab.sessionKind == .incognito { status.append(String(localized: "Private")) }
        model.status = status
    }

    private func startRefreshing(tab: Tab, webViewManager: WebViewManager) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard NSEvent.modifierFlags.contains(.control) else {
                    self?.hide()
                    return
                }

                self?.refreshMetadata(tab: tab, webViewManager: webViewManager)
                self?.refreshLiveImage(tab: tab, webViewManager: webViewManager)
                self?.reposition()
                // A one-second cadence keeps an open peek recognizably live
                // without turning an off-screen page into a continuous renderer.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshLiveImage(tab: Tab, webViewManager: WebViewManager) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        // The oven borrows a background tab only long enough to photograph it;
        // a displayed tab snapshots in place. Its completion gives the popup
        // the image first, then tells ContentView to redraw the sidebar card
        // from that same cache entry.
        webViewManager.captureLiveThumbnail(for: tab.id, url: tab.url) { [weak self] image in
            guard let self,
                  self.peekedTabId == tab.id,
                  self.refreshGeneration == generation,
                  let image else { return }
            self.model.image = image
            self.onSidebarThumbnailUpdated?()
        }
    }

    // MARK: - Window

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        reposition()
        panel.orderFrontRegardless()
    }

    private func makePanel() -> TabPeekWindow {
        let panel = TabPeekWindow(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isExcludedFromWindowsMenu = true
        // A peek must never eat the hover that is keeping it open.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.contentView = NSHostingView(rootView: TabPeekView(model: model))
        return panel
    }

    private func reposition() {
        guard let panel else { return }
        panel.setFrame(Self.frame(for: Self.panelSize, placement: placement), display: false)
    }

    // Exposed for the settings preview and for testing the placement math.
    static func frame(
        for size: NSSize,
        placement: TabPeekPlacement,
        pointer: NSPoint = NSEvent.mouseLocation,
        windowFrame: NSRect? = NSApp.keyWindow?.frame ?? NSApp.mainWindow?.frame,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSRect {
        let screen = screens.first { $0.frame.contains(pointer) } ?? screens.first
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin: NSPoint
        switch placement {
        case .pointer:
            origin = NSPoint(x: pointer.x + 18, y: pointer.y - size.height - 18)
        case .windowCenter:
            let host = windowFrame ?? bounds
            origin = NSPoint(x: host.midX - size.width / 2, y: host.midY - size.height / 2)
        case .screenTop:
            // visibleFrame, not frame: as close to the camera as a window can
            // get without hiding under the menu bar (or the notch).
            origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height)
        }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }
}

private struct TabPeekView: View {
    @ObservedObject var model: TabPeekModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = model.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 262)
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(model.host)
                        .lineLimit(1)
                    if !model.status.isEmpty {
                        Text("·")
                        Text(model.status.joined(separator: " · "))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 60, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}
