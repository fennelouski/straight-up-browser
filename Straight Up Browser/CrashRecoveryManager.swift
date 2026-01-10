//
//  CrashRecoveryManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import SwiftData
import AppKit

class CrashRecoveryManager {
    private let crashFlagKey = "app_crashed_flag"
    private let savedSessionKey = "saved_session_data"
    private let autosaveInterval: TimeInterval = 5.0 // 5 seconds

    private var autosaveTimer: Timer?
    private var modelContext: ModelContext?
    private var wasCrashDetected: Bool = false

    init() {
        // Check if crash flag is already set (from previous session)
        // If it's true, that means the previous session didn't terminate normally
        wasCrashDetected = UserDefaults.standard.bool(forKey: crashFlagKey)
        
        print("CrashRecoveryManager init: wasCrashDetected = \(wasCrashDetected)")
        
        // Set crash flag for this session (will be cleared on normal exit)
        UserDefaults.standard.set(true, forKey: crashFlagKey)
        UserDefaults.standard.synchronize()
    }

    func setup(with modelContext: ModelContext) {
        self.modelContext = modelContext
        startAutosave()
        clearCrashFlagOnNormalExit()
    }

    private func startAutosave() {
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: autosaveInterval, repeats: true) { [weak self] _ in
            self?.performAutosave()
        }
    }

    private func performAutosave() {
        guard let modelContext = modelContext else { return }

        // Get all tabs
        let descriptor = FetchDescriptor<Tab>()
        guard let tabs = try? modelContext.fetch(descriptor) else { return }

        // Create session data
        let sessionData = SessionData(
            tabs: tabs.enumerated().map { (index, tab) in
                SavedTab(
                    id: tab.id,
                    title: tab.title,
                    url: tab.url,
                    isActive: tab.isActive,
                    historyStrings: tab.historyStrings,
                    currentHistoryIndex: tab.currentHistoryIndex,
                    isPinned: tab.isPinned,
                    isMuted: tab.isMuted,
                    zoomLevel: tab.zoomLevel,
                    orderIndex: index
                )
            },
            selectedTabId: tabs.first(where: { $0.isActive })?.id
        )

        // Save to UserDefaults
        if let encoded = try? JSONEncoder().encode(sessionData) {
            UserDefaults.standard.set(encoded, forKey: savedSessionKey)
            UserDefaults.standard.synchronize()
        }
    }

    func shouldOfferRecovery() -> Bool {
        // Only offer recovery if we detected a crash from the previous session
        print("CrashRecoveryManager shouldOfferRecovery: wasCrashDetected = \(wasCrashDetected)")
        return wasCrashDetected
    }

    func getSavedSession() -> SessionData? {
        guard let data = UserDefaults.standard.data(forKey: savedSessionKey),
              let sessionData = try? JSONDecoder().decode(SessionData.self, from: data) else {
            return nil
        }
        return sessionData
    }

    func restoreSession(_ sessionData: SessionData, in modelContext: ModelContext) {
        // Clear existing tabs
        let descriptor = FetchDescriptor<Tab>()
        if let existingTabs = try? modelContext.fetch(descriptor) {
            for tab in existingTabs {
                modelContext.delete(tab)
            }
        }

        // Restore tabs
        for savedTab in sessionData.tabs {
            let tab = Tab(title: savedTab.title, url: savedTab.url, isActive: savedTab.isActive)
            tab.id = savedTab.id
            tab.historyStrings = savedTab.historyStrings
            tab.currentHistoryIndex = savedTab.currentHistoryIndex
            tab.isPinned = savedTab.isPinned
            tab.isMuted = savedTab.isMuted
            tab.zoomLevel = savedTab.zoomLevel
            tab.orderIndex = savedTab.orderIndex
            // Update title to use domain name
            tab.updateTitleFromURL()
            modelContext.insert(tab)
        }

        // Clear saved session after successful restore
        UserDefaults.standard.removeObject(forKey: savedSessionKey)
        UserDefaults.standard.synchronize()
    }

    private func clearCrashFlagOnNormalExit() {
        // Clear crash flag on normal exit using notification
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearCrashFlag()
        }
    }

    private func clearCrashFlag() {
        print("CrashRecoveryManager clearCrashFlag: clearing crash flag on normal exit")
        UserDefaults.standard.set(false, forKey: crashFlagKey)
        // Also clear the saved session on normal exit - it's only needed for crash recovery
        UserDefaults.standard.removeObject(forKey: savedSessionKey)
        UserDefaults.standard.synchronize()
    }

    func cleanup() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        cleanup()
    }
}

// Data structures for session persistence
struct SessionData: Codable {
    let tabs: [SavedTab]
    let selectedTabId: UUID?
}

struct SavedTab: Codable {
    let id: UUID
    let title: String
    let url: URL?
    let isActive: Bool
    let historyStrings: [String]
    let currentHistoryIndex: Int
    let isPinned: Bool
    let isMuted: Bool
    let zoomLevel: Double
    let orderIndex: Int
}
