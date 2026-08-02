//
//  BrowserAccessibility.swift
//  Straight Up Browser
//
//  Shared nonvisual descriptions for browser controls.
//

import Foundation

/// Narrow bridge for Foundation notifications delivered by a legacy observer.
/// The notification is read only after the receiving task reaches MainActor.
struct MainActorNotification: @unchecked Sendable {
    nonisolated(unsafe) let value: Notification

    nonisolated init(_ value: Notification) {
        self.value = value
    }
}

/// Narrow bridge for KVO's Objective-C callback payload. The callback copies
/// its references into this immutable value, then schedules all access on the
/// main actor instead of asserting that KVO happened to call on main.
struct MainActorKVOChange: @unchecked Sendable {
    nonisolated(unsafe) let object: Any?
    nonisolated(unsafe) let change: [NSKeyValueChangeKey: Any]?
    nonisolated(unsafe) let context: UnsafeMutableRawPointer?

    nonisolated init(
        object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer? = nil
    ) {
        self.object = object
        self.change = change
        self.context = context
    }
}

nonisolated enum BrowserAccessibility {
    static func backgroundIsHidden(
        sidebarPresented: Bool,
        omnibarPresented: Bool,
        modalPresented: Bool
    ) -> Bool {
        sidebarPresented || omnibarPresented || modalPresented
    }

    static func tabLabel(
        title: String,
        url: URL?,
        sessionKind: SessionKind,
        isPinned: Bool,
        isMuted: Bool = false,
        isInSplit: Bool
    ) -> String {
        let identity: String
        if !title.isEmpty && title != String(localized: "New Tab") {
            identity = title
        } else {
            identity = url?.host ?? String(localized: "New Tab")
        }

        var details: [String] = [identity]
        switch sessionKind {
        case .normal:
            details.append(String(localized: "Tab"))
        case .container:
            details.append(String(localized: "Container tab"))
        case .incognito:
            details.append(String(localized: "Incognito tab"))
        }
        if isPinned { details.append(String(localized: "Pinned")) }
        if isMuted { details.append(String(localized: "Muted")) }
        if isInSplit { details.append(String(localized: "Shown in split view")) }
        return details.joined(separator: ", ")
    }

    static func tabValue(
        isSelected: Bool,
        isLoading: Bool,
        loadProgress: Double,
        activeDownloadCount: Int
    ) -> String {
        var state: [String] = []
        if isSelected { state.append(String(localized: "Selected")) }
        if isLoading {
            let percent = Int((min(max(loadProgress, 0), 1) * 100).rounded())
            state.append(String(localized: "Loading, \(percent)%"))
        }
        if activeDownloadCount == 1 {
            state.append(String(localized: "1 download"))
        } else if activeDownloadCount > 1 {
            state.append(String(localized: "\(activeDownloadCount) downloads"))
        }
        return state.isEmpty ? String(localized: "Not selected") : state.joined(separator: ", ")
    }
}
