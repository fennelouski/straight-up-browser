//
//  PageSecurity.swift
//  Straight Up Browser
//
//  Shared, user-visible connection and protection state.
//

import Combine
import Foundation
import SwiftUI

nonisolated enum PageSecurityEvaluator {
    static func level(
        for url: URL?,
        hasOnlySecureContent: Bool,
        certificateWasOverridden: Bool
    ) -> SecurityLevel {
        guard let url, let scheme = url.scheme?.lowercased() else { return .none }

        switch scheme {
        case "https":
            if certificateWasOverridden { return .insecure }
            return hasOnlySecureContent ? .secure : .mixed
        case "http":
            return .insecure
        case "about", "data", "file":
            return .none
        default:
            return .insecure
        }
    }
}

nonisolated enum ContentBlockingStatus: Equatable {
    case off
    case requestedNotActive
    case active

    static func resolve(enabled: Bool, active: Bool) -> Self {
        guard enabled else { return .off }
        return active ? .active : .requestedNotActive
    }

    var label: String {
        switch self {
        case .off: return String(localized: "Ad and tracker blocking is off")
        case .requestedNotActive: return String(localized: "Ad and tracker blocking is on but not active for this tab")
        case .active: return String(localized: "Ad and tracker blocking is active")
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "shield.slash"
        case .requestedNotActive: return "exclamationmark.shield.fill"
        case .active: return "checkmark.shield.fill"
        }
    }
}

struct PageProtectionSummary: Equatable {
    let securityLevel: SecurityLevel
    let contentBlocking: ContentBlockingStatus
    let javaScriptEnabled: Bool

    var title: String {
        switch securityLevel {
        case .none: return String(localized: "No connection information")
        case .secure: return String(localized: "Secure connection")
        case .mixed: return String(localized: "Mixed-content connection")
        case .insecure: return String(localized: "Connection is not secure")
        }
    }

    var connectionDetail: String {
        switch securityLevel {
        case .none:
            return String(localized: "This is a local or blank page.")
        case .secure:
            return String(localized: "The page used HTTPS and all loaded content was secure.")
        case .mixed:
            return String(localized: "The page used HTTPS, but WebKit reported content that was not fully secure.")
        case .insecure:
            return String(localized: "The page used HTTP or continued after a certificate warning.")
        }
    }

    var systemImage: String {
        switch securityLevel {
        case .none: return "info.circle"
        case .secure: return "lock.fill"
        case .mixed: return "exclamationmark.lock.fill"
        case .insecure: return "lock.open.fill"
        }
    }

    var tint: Color {
        switch securityLevel {
        case .none: return .secondary
        case .secure: return .green
        case .mixed: return .orange
        case .insecure: return .red
        }
    }
}

@MainActor
final class PageProtectionStore: ObservableObject {
    static let shared = PageProtectionStore()

    @Published private(set) var contentBlockingActiveTabIds: Set<UUID> = []

    private init() {}

    func setContentBlocking(_ active: Bool, for tabId: UUID) {
        if active {
            contentBlockingActiveTabIds.insert(tabId)
        } else {
            contentBlockingActiveTabIds.remove(tabId)
        }
    }

    func isContentBlockingActive(for tabId: UUID?) -> Bool {
        tabId.map(contentBlockingActiveTabIds.contains) ?? false
    }
}

struct PageProtectionButton: View {
    let summary: PageProtectionSummary
    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails.toggle()
        } label: {
            Image(systemName: summary.systemImage)
                .foregroundStyle(summary.tint)
        }
        .buttonStyle(.plain)
        .delayedHelp(summary.title)
        .accessibilityLabel(summary.title)
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Label(summary.title, systemImage: summary.systemImage)
                    .font(.headline)
                    .foregroundStyle(summary.tint)
                Text(summary.connectionDetail)
                    .font(.callout)
                Divider()
                Label(summary.contentBlocking.label, systemImage: summary.contentBlocking.systemImage)
                Label(
                    summary.javaScriptEnabled
                        ? String(localized: "JavaScript is enabled")
                        : String(localized: "JavaScript is blocked"),
                    systemImage: summary.javaScriptEnabled ? "chevron.left.forwardslash.chevron.right" : "nosign"
                )
            }
            .frame(width: 320, alignment: .leading)
            .padding()
        }
    }
}
