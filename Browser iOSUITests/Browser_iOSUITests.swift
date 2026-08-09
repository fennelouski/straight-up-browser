//
//  Browser_iOSUITests.swift
//  Browser iOSUITests
//

import XCTest

final class Browser_iOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBrowserControlsOpenTheAddressBar() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-tabSyncEnabled", "NO",
            "-hasSeenGestureGuide", "YES",
        ]
        app.launch()

        let browserControls = app.descendants(matching: .any)["Browser Controls"]
        XCTAssertTrue(browserControls.waitForExistence(timeout: 10))
        browserControls.tap()

        XCTAssertTrue(app.textFields["Search or enter address"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTopBrowserMenusAreDiscoverable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-tabSyncEnabled", "NO",
            "-hasSeenGestureGuide", "YES",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["Tabs Menu"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Page Menu"].exists)

        app.buttons["Tabs Menu"].tap()
        XCTAssertTrue(app.buttons["New Tab"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Close Tab"].exists)

        app.tap()
        app.buttons["Page Menu"].tap()
        XCTAssertTrue(app.buttons["Change URL…"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Navigation"].exists)
        XCTAssertTrue(app.buttons["Page"].exists)
        XCTAssertTrue(app.buttons["Share & Export"].exists)
        XCTAssertTrue(app.buttons["Library"].exists)
        XCTAssertTrue(app.buttons["Tabs, Groups & Workspaces…"].exists)
        XCTAssertTrue(app.buttons["Privacy & Sessions"].exists)
        XCTAssertTrue(app.buttons["Rotation Lock"].exists)

        app.buttons["Share & Export"].tap()
        XCTAssertTrue(app.buttons["Share URL…"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Share Screenshot…"].exists)
        XCTAssertTrue(app.buttons["Share Image from Page…"].exists)
        XCTAssertTrue(app.buttons["Share Page Text…"].exists)
        XCTAssertTrue(app.buttons["Share Whole Page as PDF…"].exists)
        XCTAssertTrue(app.buttons["Share Whole Page as PNG…"].exists)
        XCTAssertTrue(app.buttons["Share Whole Page as JPEG…"].exists)
    }
}
