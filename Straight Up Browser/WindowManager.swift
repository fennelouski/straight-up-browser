//
//  WindowManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import AppKit

// The single place window chrome is configured. Keeps .titled (removing it
// breaks dragging, focus routing, and fullscreen) and hides everything else.
//
// This resolves the window from the view hierarchy rather than guessing at
// NSApplication.keyWindow / .windows.first, which is what made the traffic
// lights show up on some installs and not others: at onAppear the browser
// window frequently isn't key yet, so the guess either configured a different
// scene's window (Settings, Downloads) or found nothing and bailed — and since
// it only ran once, the buttons stayed visible for the rest of the session.
// viewDidMoveToWindow fires exactly when this view has a real window, per
// window, so it can't race and it works for a second browser window too.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.isMovableByWindowBackground = true
            window.backgroundColor = .windowBackgroundColor
        }
    }
}
