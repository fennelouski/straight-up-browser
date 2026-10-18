#if os(macOS)
import AppKit

/// Isolation never opens another application or reads/writes the system clipboard.
/// These adapters preserve the original AppKit operation without the explicit flag.
@MainActor enum BrowserProfileSystem {
    static var pasteboard: NSPasteboard {
        guard let paths = BrowserProfile.paths else { return .general }
        return NSPasteboard(name: .init("Browser.IsolatedTest." + paths.identifier))
    }

    @discardableResult static func open(_ url: URL) -> Bool {
        guard !BrowserProfile.isIsolated else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func open(_ urls: [URL], withApplicationAt application: URL,
                     configuration: NSWorkspace.OpenConfiguration) {
        guard !BrowserProfile.isIsolated else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration)
    }

    static func reveal(_ urls: [URL]) {
        guard !BrowserProfile.isIsolated else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
#endif
