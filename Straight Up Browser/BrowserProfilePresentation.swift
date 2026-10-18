import SwiftUI

/// An isolated process never constructs its interactive scene until WebKit's
/// network rule is installed. Failure leaves a labelled, inert error view.
struct BrowserProfileStartupView<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var ready = false
    @State private var failed = false

    var body: some View {
        Group {
            if !BrowserProfile.isIsolated {
                content()
            } else if ready {
                content()
            } else if failed {
                ContentUnavailableView("Isolated profile unavailable", systemImage: "lock.shield",
                    description: Text("Startup stopped before browser interaction. No production fallback."))
            } else {
                ProgressView("Preparing isolated profile…")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let paths = BrowserProfile.paths {
                Text("ISOLATED [\(paths.identifier)]")
                    .font(.caption.monospaced()).padding(5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(5).allowsHitTesting(false)
                    .accessibilityIdentifier("isolated-test-profile-label")
            }
        }
        .environment(\.openURL, OpenURLAction { _ in
            BrowserProfile.isIsolated ? .handled : .systemAction
        })
        .task {
            guard BrowserProfile.isIsolated else { return }
            do { try await BrowserProfileWebKit.prepare(); ready = true }
            catch { failed = true }
        }
    }
}
