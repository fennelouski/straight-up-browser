#if DEBUG
import SwiftData
import Foundation

/// Synthetic received-record shapes for isolated integration acceptance. No
/// sync client is involved, and these records remain in the in-memory model.
@MainActor enum MobileAcceptanceFixtures {
    static func seedSuggestions(in context: ModelContext) {
        guard BrowserProfile.isIsolated, MobileTestConfiguration.isUITesting,
              ProcessInfo.processInfo.arguments.contains("-mobileTestSuggestions") else { return }
        let workspace = Workspace(name: "Synthetic received records")
        context.insert(workspace)
        let regular = Tab(title: "Airfoil Reference", url: URL(string: "https://received.example/reference"))
        regular.workspaceId = workspace.id
        context.insert(regular)
        let privateTab = Tab(title: "Airfoil Private", url: URL(string: "https://private.example/reference"))
        privateTab.workspaceId = workspace.id
        privateTab.sessionKind = .incognito
        context.insert(privateTab)
        try? context.save()
    }
}
#endif
