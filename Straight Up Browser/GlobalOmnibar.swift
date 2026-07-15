//
//  GlobalOmnibar.swift
//  Straight Up Browser
//
//  Spotlight-style omnibar: a Carbon global hotkey summons a floating,
//  non-activating panel over whatever app is frontmost, so you can search or
//  open a URL without leaving what you're doing.
//

import AppKit
import SwiftUI
import Carbon.HIToolbox

// Global hotkey via Carbon RegisterEventHotKey: the app consumes the keypress
// (it never reaches the focused app) and no Accessibility permission is
// needed, unlike NSEvent global monitors.
enum GlobalOmnibarHotkey {
    static let defaultsKey = "globalOmnibarHotkey"
    static let defaultChord = "optSpace"

    private static var hotKeyRef: EventHotKeyRef?
    private static var onPress: (() -> Void)?
    private static var appliedChord: String?

    static func install(_ handler: @escaping () -> Void) {
        onPress = handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalOmnibarHotkey.onPress?() }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    // Called at launch and on every UserDefaults change; no-ops unless the
    // chord setting actually changed.
    static func applyFromDefaults() {
        let chord = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultChord
        guard chord != appliedChord else { return }
        appliedChord = chord

        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }

        let modifiers: UInt32
        switch chord {
        case "optSpace": modifiers = UInt32(optionKey)
        case "ctrlOptSpace": modifiers = UInt32(controlKey | optionKey)
        default: return // "off"
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5355_4252), id: 1) // 'SUBR'
        RegisterEventHotKey(UInt32(kVK_Space), modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// A borderless panel can't become key unless it says so; without key status
// typing and Esc never reach it.
private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Esc
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class GlobalOmnibarController: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel?

    func toggle() {
        if panel != nil { close() } else { show() }
    }

    private func show() {
        let content = OmnibarView(
            isPresented: Binding(get: { true }, set: { [weak self] shown in
                if !shown { self?.close() }
            }),
            urlString: .constant(""),
            onNavigate: { GlobalOmnibarController.openInBrowser($0) },
            errorMessage: nil,
            tabs: [], // ponytail: no history/bookmark suggestions in the global panel
            bookmarkSuggestions: []
        )
        let hosting = NSHostingView(rootView: content)
        hosting.setFrameSize(hosting.fittingSize)

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: hosting.frame.size),
            styleMask: [.borderless, .nonactivatingPanel], // nonactivating: the frontmost app stays active
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // OmnibarView draws its own shadow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - hosting.frame.width / 2,
                y: frame.minY + frame.height * 0.72 - hosting.frame.height / 2
            ))
        }

        self.panel = panel
        panel.makeKeyAndOrderFront(nil) // keyboard focus without activating the app
    }

    func close() {
        guard let panel else { return }
        panel.delegate = nil // avoid re-entrant windowDidResignKey
        panel.orderOut(nil)
        self.panel = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // Opens the (already normalized) URL string in a new browser tab.
    static func openInBrowser(_ urlString: String) {
        NSApp.activate(ignoringOtherApps: true)

        let browserWindow = NSApp.windows.first {
            $0.isVisible && !($0 is NSPanel)
                && $0.identifier?.rawValue.contains("settings") != true
        }
        if browserWindow != nil {
            browserWindow?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .browserOpenURL, object: nil,
                                            userInfo: ["url": urlString, "newTab": true])
        } else {
            // Window closed: reopen it the way a Dock click would, then post once
            // ContentView.onAppear has re-armed the notification observers.
            // ponytail: fixed delay; replace with a pending-URL handoff if it races.
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .browserOpenURL, object: nil,
                                                userInfo: ["url": urlString, "newTab": true])
            }
        }
    }
}
