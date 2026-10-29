#if os(macOS)
import AppKit
import SwiftUI

/// Only existing staged demo edits enroll. Immediate AppStorage controls do not become dirty.
@MainActor
final class SettingsDraftProtection {
    static let shared = SettingsDraftProtection()
    private var requests: [UUID: () -> Void] = [:]
    private weak var pendingWindow: NSWindow?
    var hasPendingDraft: Bool { !requests.isEmpty }
    func register(_ id: UUID, request: @escaping () -> Void) { requests[id] = request }
    func remove(_ id: UUID) { requests.removeValue(forKey: id) }
    func requestClose(_ window: NSWindow) {
        guard let request = requests.values.first else { return }
        pendingWindow = window
        request()
    }
    func keepEditing() { pendingWindow = nil }
    func finishClose() {
        let window = pendingWindow
        pendingWindow = nil
        guard let window else { return }
        // The editor/popover completes its own dismissal before the containing window closes.
        DispatchQueue.main.async { window.performClose(nil) }
    }
}

/// A tiny window-scoped bridge is necessary because native marked text, refusal to end editing,
/// physical key-repeat and the window close button are outside SwiftUI FocusState's contract.
struct SettingsWindowInteraction: NSViewRepresentable {
    let onResignEditing: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onResignEditing: onResignEditing) }
    func makeNSView(context: Context) -> NSView {
        let view = WindowProbe()
        view.attached = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onResignEditing = onResignEditing
        context.coordinator.attach(view.window)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    final class WindowProbe: NSView {
        var attached: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached?(window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        var onResignEditing: () -> Void
        private weak var window: NSWindow?
        // NSObject queries are nonisolated. Every access is explicitly main-thread guarded.
        nonisolated(unsafe) private weak var previousDelegate: (any NSWindowDelegate)?
        private var monitor: Any?
        private var menuObservers: [NSObjectProtocol] = []
        private var menuTracking = false
        private var escapeHeld = false

        init(onResignEditing: @escaping () -> Void) { self.onResignEditing = onResignEditing }
        func attach(_ window: NSWindow?) {
            guard let window, self.window !== window else { return }
            stop()
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
            let center = NotificationCenter.default
            menuObservers = [
                center.addMainActorObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = true },
                center.addMainActorObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = false },
                center.addMainActorObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.escapeHeld = false }
            ]
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, event.keyCode == 53 else { return event }
                if event.type == .keyUp { self.escapeHeld = false; return event }
                guard let window = self.window, event.window === window, window.isKeyWindow else { return event }
                if event.isARepeat || self.escapeHeld { return nil }
                self.escapeHeld = true
                // A transient owns the entire physical press, even if it dismisses before repeat.
                guard !self.menuTracking, window.attachedSheet == nil, NSApp.modalWindow == nil,
                      !(window.childWindows ?? []).contains(where: { $0.isVisible }) else { return event }
                if KeyRecorder.active?.isRecording == true { KeyRecorder.active?.stop(); return nil }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                    if editor.hasMarkedText() { return event }
                    guard window.makeFirstResponder(nil) else { return nil }
                    self.onResignEditing()
                    return nil
                }
                if SettingsDraftProtection.shared.hasPendingDraft { SettingsDraftProtection.shared.requestClose(window); return nil }
                window.performClose(nil)
                return nil
            }
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if let editor = sender.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            guard sender.makeFirstResponder(nil) else { return false }
            if SettingsDraftProtection.shared.hasPendingDraft { SettingsDraftProtection.shared.requestClose(sender); return false }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }
        // Preserve the SwiftUI scene delegate's other window callbacks.
        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            guard Thread.isMainThread else { return false }
            return previousDelegate?.responds(to: aSelector) == true
        }
        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if Thread.isMainThread {
                if previousDelegate?.responds(to: aSelector) == true { return previousDelegate }
            }
            return super.forwardingTarget(for: aSelector)
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }; menuObservers = []
            if let window, window.delegate === self { window.delegate = previousDelegate }
            window = nil; previousDelegate = nil; escapeHeld = false
        }
    }
}
#endif
