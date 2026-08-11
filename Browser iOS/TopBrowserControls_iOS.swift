//
//  TopBrowserControls_iOS.swift
//  Browser (iOS)
//
//  Two small, persistent menus that occupy the otherwise-unused strip beside a
//  notch or Dynamic Island. Kept out of BrowserView_iOS so the main browser view
//  remains tractable for SwiftUI's type checker.
//

import SwiftUI
import UIKit

struct BrowserControlActions_iOS {
    let showTabs: () -> Void
    let newTab: () -> Void
    let newRegularTab: () -> Void
    let newIncognitoTab: () -> Void
    let reopenTab: () -> Void
    let nextTab: () -> Void
    let previousTab: () -> Void
    let duplicateTab: () -> Void
    let toggleSplit: () -> Void
    let togglePinned: () -> Void
    let toggleMuted: () -> Void
    let closeTab: () -> Void
    let closeTabSet: () -> Void
    let changeURL: () -> Void
    let back: () -> Void
    let forward: () -> Void
    let reloadOrStop: () -> Void
    let hardReload: () -> Void
    let reloadAll: () -> Void
    let find: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let actualSize: () -> Void
    let readerMode: () -> Void
    let toggleTranslation: () -> Void
    let translateInSplit: () -> Void
    let toggleBookmark: () -> Void
    let shareURL: () -> Void
    let sharePageImage: () -> Void
    let sharePageText: () -> Void
    let printPage: () -> Void
    let exportPDF: () -> Void
    let screenshotVisible: () -> Void
    let screenshotFullPage: () -> Void
    let screenshotFullPageJPEG: () -> Void
    let showBookmarks: () -> Void
    let showHistory: () -> Void
    let showDownloads: () -> Void
    let newContainer: () -> Void
    let convertToIncognito: () -> Void
    let clearSiteData: () -> Void
    let clearSessionData: () -> Void
    let clearAllData: () -> Void
    let showSettings: () -> Void
    let showShortcuts: () -> Void
    let showGestures: () -> Void
}

struct TopBrowserControls_iOS: View {
    let activeTab: Tab?
    let showsTabsMenu: Bool
    let allowsSplitPanes: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let isLoading: Bool
    let canReopenTab: Bool
    let isCurrentBookmarked: Bool
    let actions: BrowserControlActions_iOS

    @ObservedObject private var orientationLock = OrientationLockController.shared

    var body: some View {
        GeometryReader { geometry in
            if usesSensorSideLayout(in: geometry.size) {
                sideControls(in: geometry)
                    .transition(.opacity)
            } else {
                topControls
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: UIDevice.current.orientation)
    }

    private var topControls: some View {
        HStack(spacing: 0) {
            if showsTabsMenu { tabMenu }
            Spacer(minLength: 96)
            pageMenu
        }
        .padding(.horizontal, 7)
        .padding(.top, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
    }

    private func sideControls(in geometry: GeometryProxy) -> some View {
        let sensorIsLeading = geometry.safeAreaInsets.leading >= geometry.safeAreaInsets.trailing
        return VStack(spacing: 0) {
            if showsTabsMenu { tabMenu }
            Spacer(minLength: 96)
            pageMenu
        }
        .padding(.vertical, 7)
        .padding(sensorIsLeading ? .leading : .trailing, 3)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: sensorIsLeading ? .leading : .trailing
        )
        .ignoresSafeArea(edges: sensorIsLeading ? .leading : .trailing)
    }

    private func usesSensorSideLayout(in size: CGSize) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone && size.width > size.height
    }

    private var tabMenu: some View {
        Menu {
            Button(action: actions.showTabs) {
                Label("Show All Tabs", systemImage: "square.stack")
            }
            Divider()
            Button(action: actions.newTab) {
                Label("New Tab", systemImage: "plus.square")
            }
            Button(action: actions.newRegularTab) {
                Label("New Regular Tab", systemImage: "globe")
            }
            Button(action: actions.newIncognitoTab) {
                Label("New Incognito Tab", systemImage: "eye.slash")
            }
            Button(action: actions.reopenTab) {
                Label("Reopen Last Closed Tab", systemImage: "arrow.uturn.backward.square")
            }
            .disabled(!canReopenTab)
            Divider()
            Menu("Switch Tab", systemImage: "arrow.left.arrow.right") {
                Button("Next Tab", action: actions.nextTab)
                Button("Previous Tab", action: actions.previousTab)
            }
            if let activeTab {
                Button(action: actions.duplicateTab) {
                    Label("Duplicate Tab", systemImage: "plus.square.on.square")
                }
                if allowsSplitPanes {
                    Button(action: actions.toggleSplit) {
                        Label("Toggle Split Pane", systemImage: "rectangle.split.2x1")
                    }
                }
                Button(action: actions.togglePinned) {
                    Label(activeTab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: "pin")
                }
                Button(action: actions.toggleMuted) {
                    Label(
                        activeTab.isMuted ? "Unmute Tab" : "Mute Tab",
                        systemImage: activeTab.isMuted ? "speaker.wave.2" : "speaker.slash"
                    )
                }
            }
            Divider()
            Button(role: .destructive, action: actions.closeTab) {
                Label("Close Tab", systemImage: "xmark.square")
            }
            .disabled(activeTab == nil)
            Button(role: .destructive, action: actions.closeTabSet) {
                Label("Close Tab Set", systemImage: "xmark.square.fill")
            }
            .disabled(activeTab == nil)
        } label: {
            controlLabel {
                if let activeTab {
                    TabFaviconView(tab: activeTab)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .accessibilityLabel("Tabs Menu")
        .accessibilityHint("Show tabs, open a new tab, or close the current tab")
        .accessibilityIdentifier("browser.tabsMenu")
    }

    private var pageMenu: some View {
        Menu {
            Button(action: actions.changeURL) {
                Label("Change URL…", systemImage: "text.cursor")
            }
            Divider()
            Menu("Navigation", systemImage: "arrow.triangle.turn.up.right.diamond") {
                Button(action: actions.back) {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!canGoBack)
                Button(action: actions.forward) {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .disabled(!canGoForward)
                Button(action: actions.reloadOrStop) {
                    Label(
                        isLoading ? "Stop Loading" : "Reload",
                        systemImage: isLoading ? "xmark" : "arrow.clockwise"
                    )
                }
                Button("Hard Reload", systemImage: "arrow.clockwise.circle", action: actions.hardReload)
                Button("Reload All Tabs", systemImage: "arrow.triangle.2.circlepath", action: actions.reloadAll)
            }
            Menu("Page", systemImage: "doc.text") {
                Button("Find on Page…", systemImage: "text.magnifyingglass", action: actions.find)
                    .disabled(activeTab?.url == nil)
                Menu("Zoom", systemImage: "plus.magnifyingglass") {
                    Button("Zoom In", action: actions.zoomIn)
                    Button("Zoom Out", action: actions.zoomOut)
                    Button("Actual Size", action: actions.actualSize)
                }
                Button("Reader Mode", systemImage: "doc.plaintext", action: actions.readerMode)
                Button("Toggle Translation", systemImage: "translate", action: actions.toggleTranslation)
                if allowsSplitPanes {
                    Button("Translate in Split Pane", systemImage: "rectangle.split.2x1", action: actions.translateInSplit)
                }
                Button(
                    isCurrentBookmarked ? "Remove Bookmark" : "Add Bookmark",
                    systemImage: isCurrentBookmarked ? "star.fill" : "star",
                    action: actions.toggleBookmark
                )
            }
            Menu("Share & Export", systemImage: "square.and.arrow.up") {
                Button("Share URL…", systemImage: "link", action: actions.shareURL)
                Button("Share Screenshot…", systemImage: "viewfinder", action: actions.screenshotVisible)
                Button("Share Image from Page…", systemImage: "photo", action: actions.sharePageImage)
                Button("Share Page Text…", systemImage: "text.alignleft", action: actions.sharePageText)
                Divider()
                Button("Share Whole Page as PDF…", systemImage: "doc.richtext", action: actions.exportPDF)
                Button("Share Whole Page as PNG…", systemImage: "photo", action: actions.screenshotFullPage)
                Button("Share Whole Page as JPEG…", systemImage: "photo.fill", action: actions.screenshotFullPageJPEG)
                Divider()
                Button("Print…", systemImage: "printer", action: actions.printPage)
            }
            Menu("Library", systemImage: "books.vertical") {
                Button("Bookmarks", systemImage: "star", action: actions.showBookmarks)
                Button("History", systemImage: "clock", action: actions.showHistory)
                Button("Downloads", systemImage: "arrow.down.circle", action: actions.showDownloads)
            }
            Button("Tabs, Groups & Workspaces…", systemImage: "square.stack.3d.up", action: actions.showTabs)
            Menu("Privacy & Sessions", systemImage: "hand.raised") {
                Button("New Regular Tab", systemImage: "globe", action: actions.newRegularTab)
                Button("New Incognito Tab", systemImage: "eye.slash", action: actions.newIncognitoTab)
                Button("New Container…", systemImage: "person.2", action: actions.newContainer)
                Button("Switch Tab to Incognito", systemImage: "eye.slash.fill", action: actions.convertToIncognito)
                    .disabled(activeTab == nil || activeTab?.sessionKind == .incognito)
                Divider()
                Button("Clear This Site’s Data…", systemImage: "eraser", action: actions.clearSiteData)
                    .disabled(activeTab?.url?.host == nil)
                Button("Clear This Session’s Data…", systemImage: "trash", action: actions.clearSessionData)
                    .disabled(activeTab == nil)
                Button("Clear All Browsing Data…", systemImage: "trash.fill", role: .destructive, action: actions.clearAllData)
            }
            orientationMenu
            Divider()
            Button(action: actions.showShortcuts) {
                Label("Keyboard Shortcuts", systemImage: "keyboard")
            }
            Button(action: actions.showGestures) {
                Label("Touch Gestures", systemImage: "hand.draw")
            }
            Button(action: actions.showSettings) {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            controlLabel {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
            }
        }
        .accessibilityLabel("Page Menu")
        .accessibilityHint("Navigation, sharing, address, find, and rotation controls")
        .accessibilityIdentifier("browser.pageMenu")
    }

    private func controlLabel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: 24, height: 24)
            .frame(width: 36, height: 36)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }

    private var orientationMenu: some View {
        Menu {
            orientationButton(.unlocked)
            Divider()
            orientationButton(.portrait)
            orientationButton(.landscapeLeft)
            orientationButton(.landscapeRight)
            if UIDevice.current.userInterfaceIdiom == .pad {
                orientationButton(.portraitUpsideDown)
            }
        } label: {
            Label("Rotation Lock", systemImage: orientationLock.selection.systemImage)
        }
    }

    private func orientationButton(_ selection: BrowserOrientationLock) -> some View {
        Button { orientationLock.apply(selection) } label: {
            if orientationLock.selection == selection {
                Label(selection.title, systemImage: "checkmark")
            } else {
                Text(selection.title)
            }
        }
    }
}
