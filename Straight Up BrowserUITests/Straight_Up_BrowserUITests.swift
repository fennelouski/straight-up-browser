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

        let newTab = app.buttons["New Tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 10))
        newTab.click()

        XCTAssertTrue(app.textFields["Search or enter address"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.otherElements["Browser Library"].waitForExistence(timeout: 5))
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
    #endif
}
