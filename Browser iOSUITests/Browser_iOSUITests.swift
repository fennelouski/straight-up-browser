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
        let app = configuredApplication()
        launchBrowser(app)

        let browserControls = app.descendants(matching: .any)["Browser Controls"]
        XCTAssertTrue(browserControls.waitForExistence(timeout: 10))
        browserControls.tap()

        XCTAssertTrue(app.textFields["Search or enter address"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTopBrowserMenusAreDiscoverable() throws {
        let app = configuredApplication()
        launchBrowser(app)

        XCTAssertTrue(app.buttons["Tabs Menu"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Page Menu"].exists)

        app.buttons["Tabs Menu"].tap()
        XCTAssertTrue(app.buttons["New Tab"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Close Tab"].exists)

        // On compact phones the menu covers the app's center; dismiss outside it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
        XCTAssertTrue(app.buttons["New Tab"].waitForNonExistence(timeout: 3))
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

    @MainActor
    func testSettingsGroupSafeAgentDefinitionSync() throws {
        let app = configuredApplication()
        launchBrowser(app)

        let pageMenu = app.buttons["browser.pageMenu"]
        XCTAssertTrue(pageMenu.waitForExistence(timeout: 10))
        pageMenu.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 3))
        app.buttons["Settings"].tap()

        XCTAssertTrue(
            app.switches["settings.agentSync.schedules"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.switches["settings.agentSync.providerPresets"].exists)
        XCTAssertTrue(app.switches["settings.agentSync.userMemory"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label ==[c] %@", "Agent Definition Sync")
        ).firstMatch.exists)
    }

    @MainActor
    func testPhoneKeepsSplitCommandsUnavailable() throws {
        let app = configuredApplication()
        launchBrowser(app)
        guard app.frame.width < 600 else { throw XCTSkip("iPhone-only contract") }

        let tabsMenu = app.buttons["browser.tabsMenu"]
        XCTAssertTrue(tabsMenu.waitForExistence(timeout: 10))
        tabsMenu.tap()
        XCTAssertFalse(app.buttons["Toggle Split Pane"].exists)
    }

    @MainActor
    func testOmnibarControlsKeepFullTouchTargets() throws {
        let app = configuredApplication()
        app.launchArguments += ["-openURL", "data:text/html,<title>Touch targets</title>"]
        app.launch()
        let controls = app.descendants(matching: .any)["Browser Controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        controls.tap()
        XCTAssertTrue(app.textFields["browser.omnibar"].waitForExistence(timeout: 5))

        let labels = [
            "Show Tabs", "Back", "Forward", "Reload",
            "Add to Newspaper", "Add Bookmark", "Close Address and Search",
        ]
        var frames: [CGRect] = []
        for label in labels {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), label)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, label)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, label)
            XCTAssertTrue(app.frame.contains(button.frame), label)
            XCTAssertTrue(frames.allSatisfy { !$0.intersects(button.frame.insetBy(dx: 1, dy: 1)) }, label)
            frames.append(button.frame)
        }
        let close = app.buttons["Close Address and Search"]
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchBrowser(_ app: XCUIApplication) {
        app.launch()
        // A fresh profile starts in the address bar. Dismiss it before testing
        // page controls, which correctly stay hidden behind this modal.
        XCTAssertTrue(app.textFields["browser.omnibar"].waitForExistence(timeout: 10))
        let close = app.buttons["Close Address and Search"]
        XCTAssertTrue(close.exists)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func configuredApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-ApplePersistenceIgnoreState", "YES",
            "-tabSyncEnabled", "NO",
            "-agentDefinitionSync.schedules.enabled", "NO",
            "-agentDefinitionSync.providerPresets.enabled", "NO",
            "-agentDefinitionSync.userAuthoredMemory.enabled", "NO",
            "-hasSeenGestureGuide", "YES",
        ]
        return app
    }
}
