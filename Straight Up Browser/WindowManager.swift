//
//  WindowManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import AppKit

class WindowManager {
    func configureWindow(showTitleBar: Bool) {
        #if os(macOS)
        DispatchQueue.main.async {
            // Get the key window or main window
            let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first
            
            guard let window = window else { return }
            
            if showTitleBar {
                // Show standard macOS title bar
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.styleMask.remove(.fullSizeContentView)
                window.isMovableByWindowBackground = false
            } else {
                // Hide the title bar and traffic lights for maximum screen space
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = false
            }
            
            // Force window to update
            window.invalidateShadow()
            window.display()
        }
        #endif
    }
}
