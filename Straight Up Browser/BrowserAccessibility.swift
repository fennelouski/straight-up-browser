//
//  BrowserAccessibility.swift
//  Straight Up Browser
//
//  Shared nonvisual descriptions for browser controls.
//

import Foundation

/// Explicitly marks values crossing legacy callback boundaries whose runtime
/// queue/actor guarantee is stronger than their imported Objective-C type.
struct MainActorTransfer<Value>: @unchecked Sendable {
    nonisolated(unsafe) let value: Value

    nonisolated init(value: Value) {
        self.value = value
    }
}

nonisolated enum BrowserAccessibility {
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
