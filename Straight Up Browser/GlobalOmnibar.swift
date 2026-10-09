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
            Task { @MainActor in GlobalOmnibarHotkey.onPress?() }
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
    private var compactHeight: CGFloat = 112
    private var expandedHeight: CGFloat = 560

    func toggle() {
        if panel != nil { close() } else { show() }
    }

    private func show() {
        expandedHeight = min(560, (NSScreen.main?.visibleFrame.height ?? 584) - 24)
        let content = GlobalOmnibarWeatherView(
            isPresented: Binding(get: { true }, set: { [weak self] shown in
                if !shown { self?.close() }
            }),
            urlString: .constant(""),
            // ponytail: no tab/split concept in the floating global panel, so
            // Shift/Cmd+Return behave the same as plain Return here.
            onNavigate: { url, _ in GlobalOmnibarController.openInBrowser(url) },
            onWeather: { [weak self] visible in self?.resizeForWeather(visible) },
            expandedHeight: expandedHeight
        )
        let hosting = NSHostingView(rootView: content)
        hosting.setFrameSize(hosting.fittingSize)
        compactHeight = hosting.frame.height

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: hosting.frame.size),
            styleMask: [.borderless, .nonactivatingPanel], // nonactivating: the frontmost app stays active
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("browser-global-omnibar")
        panel.setAccessibilityIdentifier("browser-global-omnibar")
        panel.title = String(localized: "Address and Search")
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

    private func resizeForWeather(_ visible: Bool) {
        guard let panel else { return }
        let height: CGFloat = visible ? expandedHeight : compactHeight
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        if let screen = panel.screen {
            frame.origin.y = max(screen.visibleFrame.minY + 12,
                min(frame.origin.y, screen.visibleFrame.maxY - height - 12))
        }
        panel.setFrame(frame, display: true)
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

private struct GlobalOmnibarWeatherView: View {
    @Binding var isPresented: Bool
    @Binding var urlString: String
    let onNavigate: (String, OmnibarCommit) -> Void
    let onWeather: (Bool) -> Void
    let expandedHeight: CGFloat
    @State private var weather = false
    @State private var surfaces: [CGRect] = []
    @State private var credited = false
    var body: some View {
        ZStack(alignment: .top) {
            if weather { OmnibarWeatherScene(layer: .sky, attributionVisible: credited).transition(OmnibarWeatherCurtain.transition) }
            OmnibarView(isPresented: $isPresented, urlString: $urlString, onNavigate: onNavigate,
                        errorMessage: nil, tabs: [], bookmarkSuggestions: [],
                        onWeatherVisibilityChanged: { weather = $0; onWeather($0) })
            if weather { OmnibarWeatherScene(layer: .precipitation, surfaces: surfaces, attributionVisible: credited).transition(OmnibarWeatherCurtain.transition) }
        }
        .frame(width: 600, height: weather ? expandedHeight : nil, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .coordinateSpace(name: "omnibarWeatherScene")
        .onPreferenceChange(OmnibarWeatherSurfaces.self) { surfaces = $0 }
        .onPreferenceChange(OmnibarWeatherCreditVisible.self) { credited = $0 }
        .omnibarMotion(weather)
    }
}
