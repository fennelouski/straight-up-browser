//
//  Straight_Up_BrowserUITests.swift
//  Straight Up BrowserUITests
//
//  Created by Nathan Fennel on 1/9/26.
//

import XCTest

final class Straight_Up_BrowserUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBrowserShellOpensTheAddressBarFromNewTab() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-acceptedEULAVersion", "1",
            "-tabSyncEnabled", "NO",
            "-tabBarWidth", "200",
        ]
        app.launch()

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
            "-ApplePersistenceIgnoreState", "YES",
            "-acceptedEULAVersion", "1",
            "-tabSyncEnabled", "NO",
            "-tabBarWidth", "200",
        ]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("y", modifierFlags: .command)
        XCTAssertTrue(app.otherElements["Browser Library"].waitForExistence(timeout: 5))
    }
}
