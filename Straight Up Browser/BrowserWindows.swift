#if os(macOS)
import AppKit
import Combine
import SwiftUI

struct BrowserWindowRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var homeWorkspaceID: UUID?
    var workspaceID: UUID?
    var isOpen: Bool
}

/// Durable window identity; tabs remain in the existing workspace database.
final class BrowserWindows: ObservableObject {
    static let shared = BrowserWindows()
    static let storageKey = "namedBrowserWindows"
    static let nativeFullScreenKey = "nativeBrowserFullScreen"
    @Published private(set) var records: [BrowserWindowRecord]
    @Published private(set) var fullScreenIDs: Set<UUID> = []
    nonisolated(unsafe) private var tokens: [UUID: [NSObjectProtocol]] = [:]
    private let defaults: UserDefaults
    private let persistsRecords: Bool
    private var windows: [UUID: WeakWindow] = [:]
    var openWindowAction: ((UUID) -> Void)?
    var hasWindows: Bool { windows.values.contains { $0.value != nil } }
    private var restored = false
    private struct WeakWindow { weak var value: NSWindow? }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        persistsRecords = !ProcessInfo.processInfo.arguments.contains("-uiTesting")
        records = (persistsRecords ? defaults.data(forKey: Self.storageKey) : nil)
            .flatMap { try? JSONDecoder().decode([BrowserWindowRecord].self, from: $0) } ?? []
        if records.isEmpty {
            let workspace = defaults.string(forKey: TabManager.activeWorkspaceKey).flatMap(UUID.init(uuidString:))
            records = [BrowserWindowRecord(id: UUID(), name: "Browser", homeWorkspaceID: nil,
                                           workspaceID: workspace, isOpen: true)]
            persist()
        }
    }

    var primaryID: UUID { records.first(where: \.isOpen)?.id ?? records[0].id }
    func record(_ id: UUID) -> BrowserWindowRecord? { records.first { $0.id == id } }
    func window(_ id: UUID) -> NSWindow? { windows[id]?.value }
    var activeID: UUID? {
        let active = NSApp.keyWindow ?? NSApp.mainWindow
        return windows.first { $0.value.value === active }?.key
    }

    @discardableResult func create(name: String? = nil) -> UUID {
        let id = UUID(), workspace = UUID()
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        records.append(BrowserWindowRecord(id: id, name: name?.isEmpty == false ? name! : "Window \(records.count + 1)",
                                           homeWorkspaceID: workspace, workspaceID: workspace, isOpen: true))
        persist()
        return id
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].name = trimmed
        window(id)?.title = trimmed
        persist()
    }

    func setWorkspace(_ workspace: UUID?, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].workspaceID = workspace
        persist()
    }

    func attach(_ window: NSWindow, id: UUID) {
        windows[id] = WeakWindow(value: window)
        if tokens[id] == nil {
            let center = NotificationCenter.default
            tokens[id] = [
                center.addMainActorObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self, weak window] _ in
                    self?.fullScreenIDs.insert(id)
                    if let window { WindowLayout.applyCornerMask(to: window) }
                    NSApp.presentationOptions = [.fullScreen, .autoHideDock, .autoHideMenuBar]
                },
                center.addMainActorObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self, weak window] _ in
                    self?.fullScreenIDs.remove(id)
                    if let window {
                        WindowLayout.applyCornerMask(to: window)
                        Self.applyFullScreenPolicy(to: window)
                    }
                },
                center.addMainActorObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    self?.didClose(id)
                }
            ]
        }
        window.title = record(id)?.name ?? "Browser"
        window.isExcludedFromWindowsMenu = false
        if let index = records.firstIndex(where: { $0.id == id }), !records[index].isOpen {
            records[index].isOpen = true
            persist()
        }
    }

    func didClose(_ id: UUID) {
        BrowserOnboarding.shared.windowClosed(id)
        for token in tokens.removeValue(forKey: id) ?? [] { NotificationCenter.default.removeObserver(token) }
        fullScreenIDs.remove(id)
        windows.removeValue(forKey: id)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isOpen = false
        persist()
    }

    func close(_ id: UUID) {
        window(id)?.close()
    }

    func closeLastTab(in id: UUID) {
        if windows.values.filter({ $0.value != nil }).count > 1 { close(id) }
        else { NSApp.terminate(nil) }
    }

    func restoreOtherWindows(excluding id: UUID, open: (UUID) -> Void) {
        guard !restored else { return }
        restored = true
        for record in records where record.isOpen && record.id != id { open(record.id) }
    }

    func accepts(_ note: Notification, in id: UUID) -> Bool {
        guard let window = window(id) else { return false }
        if let target = note.object as? NSWindow { return target === window }
        return activeID == id
    }

    static func applyFullScreenPolicy(to window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        if UserDefaults.standard.bool(forKey: nativeFullScreenKey) {
            window.collectionBehavior.remove([.fullScreenNone, .fullScreenAuxiliary])
            window.collectionBehavior.insert(.fullScreenPrimary)
        } else {
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
        }
    }

    static func toggleFullScreen(_ window: NSWindow) {
        if window.styleMask.contains(.fullScreen) || UserDefaults.standard.bool(forKey: nativeFullScreenKey) {
            window.collectionBehavior.remove([.fullScreenAuxiliary, .fullScreenNone])
            window.collectionBehavior.insert(.fullScreenPrimary)
            // Preserve the content-only appearance while retaining the titled
            // style AppKit needs for native full-screen transitions.
            window.styleMask.insert(.titled)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.toggleFullScreen(nil)
        } else { WindowLayout.toggle(window) }
    }

    deinit {
        for token in tokens.values.flatMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
    }

    private func persist() {
        if persistsRecords, let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.storageKey) }
    }
}

struct BrowserWindowScene: View {
    let id: UUID
    @ObservedObject private var windows = BrowserWindows.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ContentView(windowID: id)
            .ignoresSafeArea()
            .navigationTitle(windows.record(id)?.name ?? "Browser")
            .toolbarVisibility(.hidden, for: .windowToolbar)
            .onAppear {
                windows.openWindowAction = { openWindow(id: "browser", value: $0) }
                BrowserWindows.shared.restoreOtherWindows(excluding: id) {
                    openWindow(id: "browser", value: $0)
                }
            }
    }
}
#endif
