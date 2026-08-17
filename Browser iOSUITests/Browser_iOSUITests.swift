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
        app.launch()
        dismissInitialOmnibarIfNeeded(in: app)

        let browserControls = app.descendants(matching: .any)["Browser Controls"]
        XCTAssertTrue(browserControls.waitForExistence(timeout: 10))
        browserControls.tap()

        XCTAssertTrue(app.textFields["Search or enter address"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTopBrowserMenusAreDiscoverable() throws {
        let app = configuredApplication()
        app.launch()
        dismissInitialOmnibarIfNeeded(in: app)

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

    @MainActor
    func testSettingsGroupSafeAgentDefinitionSync() throws {
        let app = configuredApplication()
        app.launch()

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
        XCTAssertTrue(app.staticTexts["Agent Definition Sync"].exists)
    }

    @MainActor
    func testPhoneKeepsSplitCommandsUnavailable() throws {
        let app = configuredApplication()
        app.launch()
        guard app.frame.width < 600 else { throw XCTSkip("iPhone-only contract") }

        let tabsMenu = app.buttons["browser.tabsMenu"]
        XCTAssertTrue(tabsMenu.waitForExistence(timeout: 10))
        tabsMenu.tap()
        XCTAssertFalse(app.buttons["Toggle Split Pane"].exists)
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

    @MainActor
    private func dismissInitialOmnibarIfNeeded(in app: XCUIApplication) {
        let omnibar = app.textFields["browser.omnibar"]
        guard omnibar.waitForExistence(timeout: 2) else { return }
        app.buttons["Close Address and Search"].tap()
    }
}
