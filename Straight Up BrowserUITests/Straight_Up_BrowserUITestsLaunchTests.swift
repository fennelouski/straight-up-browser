//
//  Straight_Up_BrowserUITestsLaunchTests.swift
//  Straight Up BrowserUITests
//
//  Created by Nathan Fennel on 1/9/26.
//

import XCTest

final class Straight_Up_BrowserUITestsLaunchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchExposesABrowserWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-ApplePersistenceIgnoreState", "YES",
            "-acceptedEULAVersion", "1",
            "-tabBarWidth", "200",
        ]
        launchBrowserForUITesting(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
}
