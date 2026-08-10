//
//  Straight_Up_BrowserUITests.swift
//  Straight Up BrowserUITests
//
//  Created by Nathan Fennel on 1/9/26.
//

import XCTest
#if os(macOS)
import AppKit
#endif

final class Straight_Up_BrowserUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBrowserShellOpensTheAddressBarFromNewTab() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-ApplePersistenceIgnoreState", "YES",
            "-acceptedEULAVersion", "1",
            "-tabSyncEnabled", "NO",
            "-tabBarWidth", "200",
        ]
        launchBrowserForUITesting(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        // The address field is exposed through its placeholder, not a label,
        // so a plain app.textFields["…"] subscript never matches it.
        let omnibar = app.textFields.element(
            matching: NSPredicate(format: "placeholderValue == %@", "Search or enter address")
        )
        XCTAssertTrue(omnibar.waitForExistence(timeout: 10))
    }

    @MainActor
    func testHistoryShortcutOpensTheLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-ApplePersistenceIgnoreState", "YES",
            "-acceptedEULAVersion", "1",
            "-tabSyncEnabled", "NO",
            "-tabBarWidth", "200",
        ]
        launchBrowserForUITesting(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("y", modifierFlags: .command)
        // The library opens as a sheet; SwiftUI exposes its labelled container
        // as a group, not an "other" element.
        XCTAssertTrue(app.groups["Browser Library"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAgentRoadmapSettingsAreGroupedInOnePane() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-ApplePersistenceIgnoreState", "YES",
            "-acceptedEULAVersion", "1",
            "-tabSyncEnabled", "NO",
            "-tabBarWidth", "200",
        ]
        launchBrowserForUITesting(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        let agentPane = app.buttons["Agent. Models, automation, memory, privacy"]
        XCTAssertTrue(agentPane.waitForExistence(timeout: 5))
        agentPane.click()

        XCTAssertTrue(app.staticTexts["Model Provider"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Provider Pricing"].exists)
        XCTAssertTrue(app.staticTexts["Cowork Files"].exists)
        XCTAssertTrue(app.staticTexts["Automation & Records"].exists)
        XCTAssertTrue(app.staticTexts["Safety & Run Budgets"].exists)
        XCTAssertTrue(app.staticTexts["Delegated Runs"].exists)
        XCTAssertTrue(app.staticTexts["Scoped Agent Memory"].exists)
        XCTAssertTrue(app.staticTexts["Observability & Page Signals"].exists)
        XCTAssertTrue(app.staticTexts["Agent Definition Sync"].exists)
    }
}

@MainActor
func launchBrowserForUITesting(_ app: XCUIApplication) {
    app.launch()

    #if os(macOS)
    // XCUIApplication.launch starts the SwiftUI process directly, which does
    // not deliver the open event that creates the WindowGroup window here.
    // Re-open the same bundle through LaunchServices after launch so the test
    // exercises the real browser window rather than a windowless process.
    let appURL = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("Browser.app")
    _ = NSWorkspace.shared.open(appURL)
    app.activate()
    #endif
}
