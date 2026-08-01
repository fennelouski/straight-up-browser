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
            "-hasSeenGestureGuide", "YES",
        ]
        app.launch()

        let browserControls = app.descendants(matching: .any)["Browser Controls"]
        XCTAssertTrue(browserControls.waitForExistence(timeout: 10))
        browserControls.tap()

        XCTAssertTrue(app.textFields["Search or enter address"].waitForExistence(timeout: 5))
    }
}
