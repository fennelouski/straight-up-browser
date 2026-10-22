//
//  Browser_iOSUITests.swift
//  Browser iOSUITests
//

import XCTest
import UIKit

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
    func testWeatherAppearsWhileTypingAndFitsAboveThePhoneKeyboard() {
        let app = configuredApplication()
        app.launchArguments += ["-weatherUITesting", "rain"]
        app.launch()
        let field = app.textFields["browser.omnibar"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("weather")
        XCTAssertTrue(app.descendants(matching: .any)["omnibar-weather-current"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["weather-hourly-title"].exists)
        let credit = app.staticTexts["Preview weather · No live service requested"]
        XCTAssertTrue(credit.exists)
        XCTAssertTrue(app.frame.contains(credit.frame))
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(credit.frame.maxY, app.keyboards.firstMatch.frame.minY)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Omnibar-Weather-Phone"; screenshot.lifetime = .keepAlways; add(screenshot)
        field.typeText(".com")
        XCTAssertTrue(app.descendants(matching: .any)["omnibar-weather"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "weather.com")
        app.buttons["Close Address and Search"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testNewspaperCoverAndSettingsFitPhone() {
        let app = configuredApplication()
        app.launchArguments += ["-newspaperUITesting", "-newspaperOpenUITesting", "-newspaperShowWeather", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["Newspaper Settings"].waitForExistence(timeout: 10))
        let weather = app.buttons["newspaper-weather-location"]
        XCTAssertGreaterThanOrEqual(weather.frame.width, 44)
        XCTAssertGreaterThanOrEqual(weather.frame.height, 44)
        weather.tap()
        XCTAssertTrue(app.buttons["newspaper-weather-use-current"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["newspaper-weather-city"].exists)
        XCTAssertTrue(app.frame.contains(app.buttons["newspaper-weather-use-current"].frame))
        app.buttons["Cancel"].tap()
        app.buttons["Newspaper Settings"].tap()
        XCTAssertTrue(app.buttons["Publication Style & Paper"].waitForExistence(timeout: 5))
        app.buttons["Publication Style & Paper"].tap()
        for _ in 0..<16 { if app.buttons["Bold Weekly"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.buttons["Bold Weekly"].waitForExistence(timeout: 5))
        app.buttons["Bold Weekly"].tap()
        for _ in 0..<20 {
            if app.buttons["Use this style's recommended format and paper"].isHittable { break }
            app.swipeUp()
        }
        app.buttons["Use this style's recommended format and paper"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["newspaper-cover-issue"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Newspaper-Phone-Cover"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertTrue(app.frame.contains(app.buttons["Newspaper Settings"].frame))
        XCTAssertTrue(app.buttons["Close Newspaper"].isHittable)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Inside this edition"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHiddenGestureBarHasAnAccessibleRecoveryAction() {
        let app = configuredApplication()
        app.launchArguments += ["-mobileTestHiddenBar"]
        launchBrowser(app)
        XCTAssertFalse(app.descendants(matching: .any)["browser.controls"].exists)
        let pageMenu = app.buttons["browser.pageMenu"]
        XCTAssertGreaterThanOrEqual(pageMenu.frame.width, 44)
        XCTAssertGreaterThanOrEqual(pageMenu.frame.height, 44)
        pageMenu.tap()
        app.buttons["Show Gesture Bar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["browser.controls"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testVisualTabsHasAMenuRouteWithoutAnEdgeGesture() {
        let app = configuredApplication()
        launchBrowser(app)
        app.buttons["browser.tabsMenu"].tap()
        app.buttons["Visual Tabs"].tap()
        XCTAssertTrue(app.navigationBars["Visual Tabs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close Tab"].firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["browser.pageMenu"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testEnteringURLReplacesSelectionButSubsequentTypingAppends() {
        let app = configuredApplication()
        app.launchArguments += ["-openURL", "data:text/html,<title>Selection fixture</title><p>Local only</p>"]
        app.launch()
        let controls = app.descendants(matching: .any)["browser.controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        controls.tap()
        let field = app.textFields["browser.omnibar"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("replacement")
        XCTAssertEqual(field.value as? String, "replacement")
        // A second input after suggestion rendering must not re-select the URL.
        field.typeText(".example")
        XCTAssertEqual(field.value as? String, "replacement.example")
        XCUIDevice.shared.press(.home)
        app.activate()
        field.typeText(".continued")
        XCTAssertEqual(field.value as? String, "replacement.example.continued")
        app.buttons["Close Address and Search"].tap()
        controls.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("fresh")
        XCTAssertEqual(field.value as? String, "fresh")
    }

    @MainActor
    func testMinimumWidthAndPlacementSurviveRotation() {
        let app = configuredApplication()
        app.launchArguments += ["-openURL", localFixtureURL,
            "-mobileChrome.customPosition", "YES", "-mobileChrome.width", "0.3",
            "-mobileChrome.x", "0.2", "-mobileChrome.y", "0.65"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        let bar = app.descendants(matching: .any)["browser.controls"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(bar.frame.width, app.frame.width * 0.30 - 1)
        XCTAssertGreaterThanOrEqual(bar.frame.height, 44)
        XCTAssertTrue(app.frame.contains(bar.frame))
        XCTAssertTrue(app.webViews.buttons["Stationary Edge"].waitForExistence(timeout: 10))
        saveScreenshot(app, name: "Minimum-width-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        wait(for: [rotated], timeout: 10)
        XCTAssertGreaterThanOrEqual(bar.frame.width, app.frame.width * 0.30 - 1)
        XCTAssertTrue(app.frame.contains(bar.frame))
        app.webViews.buttons["Stationary Edge"].tap()
        saveScreenshot(app, name: "Minimum-width-landscape")
    }

    @MainActor
    func testOptionalEdgePanOpensVisualTabsAndRecovers() {
        let app = configuredApplication()
        app.launchArguments += ["-openURL", localFixtureURL,
            "-mobileChrome.visualTabsGesture", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["browser.controls"].waitForExistence(timeout: 15))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
        XCTAssertTrue(app.navigationBars["Visual Tabs"].waitForExistence(timeout: 5))
        saveScreenshot(app, name: "Visual-tabs-edge-pan")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["browser.pageMenu"].isHittable)
    }

    @MainActor
    func testOptionalGapGestureCanHideAndRestoreBar() {
        let app = configuredApplication()
        app.launchArguments += ["-openURL", localFixtureURL, "-mobileChrome.hideGesture", "YES"]
        app.launch()
        let bar = app.descendants(matching: .any)["browser.controls"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15))
        let gap = app.descendants(matching: .any)["browser.barVisibilityGesture"]
        XCTAssertTrue(gap.exists)
        gap.doubleTap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
        gap.doubleTap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
    }

    @MainActor
    func testStationaryBorderSnappingDoesNotFollowPageScroll() {
        let app = configuredApplication()
        app.launchArguments += ["-openURL", localFixtureURL, "-mobileChrome.customPosition", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["browser.controls"].waitForExistence(timeout: 15))
        app.buttons["browser.pageMenu"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let settings = app.collectionViews.firstMatch
        let mobileControls = app.descendants(matching: .any)["settings.mobileControls"]
        for _ in 0..<12 {
            if mobileControls.exists && mobileControls.isHittable { break }
            settings.swipeUp()
        }
        XCTAssertTrue(mobileControls.exists)
        mobileControls.tap()
        app.buttons["Move Bar on Page"].tap()
        let bar = app.descendants(matching: .any)["browser.controls"]
        XCTAssertTrue(app.buttons["Done Moving"].waitForExistence(timeout: 5))
        let edge = app.webViews.buttons["Stationary Edge"]
        XCTAssertTrue(edge.waitForExistence(timeout: 10))
        let target = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: bar.frame.midX, dy: edge.frame.minY + 6))
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: target)
        XCTAssertEqual(bar.frame.midY, edge.frame.minY, accuracy: 1.5)
        app.buttons["Done Moving"].tap()
        let before = bar.frame
        app.webViews.firstMatch.swipeUp()
        XCTAssertEqual(bar.frame.minY, before.minY, accuracy: 1)
        saveScreenshot(app, name: "Stationary-edge-and-page-colors")
    }

    @MainActor
    func testReceivedRecordsSuggestLocallyAndPrivateRecordsStayExcluded() {
        let app = configuredApplication()
        app.launchArguments += ["-openURL", localFixtureURL, "-mobileTestSuggestions"]
        app.launch()
        let controls = app.descendants(matching: .any)["browser.controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 15))
        controls.tap()
        let field = app.textFields["browser.omnibar"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("airfoil")
        XCTAssertTrue(app.buttons["Airfoil Reference"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Airfoil Private"].exists)
        saveScreenshot(app, name: "Synthetic-received-suggestions")
        field.typeText(".no-match")
        XCTAssertTrue(app.buttons["Airfoil Reference"].waitForNonExistence(timeout: 5))
        app.buttons["Close Address and Search"].tap()
        app.buttons["browser.tabsMenu"].tap()
        app.buttons["New Incognito Tab"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("airfoil")
        XCTAssertFalse(app.buttons["Airfoil Reference"].exists)
        XCTAssertFalse(app.buttons["Airfoil Private"].exists)
    }

    @MainActor
    func testDomainRotationLocksAllowsAndResetsWithoutForcing() throws {
        let address = try XCTUnwrap(ProcessInfo.processInfo.environment["MOBILE_FIXTURE_URL"])
        let app = configuredApplication()
        app.launchArguments += ["-openURL", address]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        XCTAssertTrue(app.webViews.buttons["Stationary Edge"].waitForExistence(timeout: 15))
        app.buttons["browser.pageMenu"].tap()
        app.buttons["Rotation Lock"].tap()
        app.buttons["Lock Current Orientation on 127.0.0.1"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let forbidden = expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        forbidden.isInverted = true
        wait(for: [forbidden], timeout: 2)
        XCTAssertGreaterThan(app.frame.height, app.frame.width)
        app.buttons["browser.pageMenu"].tap()
        app.buttons["Rotation Lock"].tap()
        app.buttons["Allow Rotation on 127.0.0.1"].tap()
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.orientation = .landscapeLeft
        let allowed = expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        wait(for: [allowed], timeout: 10)
        app.buttons["browser.pageMenu"].tap()
        app.buttons["Rotation Lock"].tap()
        app.buttons["Use App Rotation Setting for 127.0.0.1"].tap()
        XCUIDevice.shared.orientation = .portrait
        let reset = expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: app)
        wait(for: [reset], timeout: 10)
    }

    @MainActor
    func testSafeAreaColorsMatchIndependentPageEdges() {
        let app = configuredApplication()
        app.launchArguments += ["-openURL", localFixtureURL]
        app.launch()
        XCTAssertTrue(app.webViews.buttons["Stationary Edge"].waitForExistence(timeout: 15))
        let colored = expectation(for: NSPredicate { _, _ in
            let pair = self.edgePixels(app)
            return pair.top.0 > 200 && pair.top.1 < 100 && pair.top.2 < 100
                && pair.bottom.0 < 100 && pair.bottom.1 < 150 && pair.bottom.2 > 180
        }, evaluatedWith: app)
        wait(for: [colored], timeout: 10)
        saveScreenshot(app, name: "Independent-safe-area-colors")
    }

    @MainActor
    func testBrowserControlsHaveAccessibleTargetsAndDescriptions() throws {
        let app = configuredApplication()
        app.launchArguments += ["-openURL", "data:text/html,<title>Accessibility fixture</title><p>Local content</p>",
            "-mobileChrome.customPosition", "YES"]
        app.launch()
        let bar = app.descendants(matching: .any)["browser.controls"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15))
        for control in [bar, app.buttons["browser.tabsMenu"], app.buttons["browser.pageMenu"]] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertFalse(control.label.isEmpty)
        }
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription])
        saveScreenshot(app, name: "Idle-circles-and-accessible-controls")
        bar.tap()
        XCTAssertTrue(app.textFields["browser.omnibar"].waitForExistence(timeout: 5))
        saveScreenshot(app, name: "Navigation-circles-and-address-field")
    }

    @MainActor
    private func edgePixels(_ app: XCUIApplication) -> (top: (Int, Int, Int), bottom: (Int, Int, Int)) {
        guard let image = UIImage(data: app.screenshot().pngRepresentation)?.cgImage else { return ((0,0,0),(0,0,0)) }
        func pixel(_ y: Int) -> (Int, Int, Int) {
            guard let point = image.cropping(to: CGRect(x: image.width / 2, y: y, width: 1, height: 1)) else { return (0,0,0) }
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(point, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        }
        return (pixel(3), pixel(image.height - 3))
    }

    private var localFixtureURL: String {
        let html = "<meta name='viewport' content='width=device-width, initial-scale=1'><title>Mobile fixture</title><style>body{margin:0;height:2400px;background:#eee} .top,.bottom{position:fixed;left:0;width:100%;height:90px;pointer-events:none}.top{top:0;background:#ef3030}.bottom{bottom:0;background:#2040ef}button{position:fixed;left:0;top:180px;width:100%;height:40px;border:0;border-top:2px solid black;background:white}</style><div class='top'></div><div class='bottom'></div><button>Stationary Edge</button><p style='padding-top:300px'>Synthetic local fixture</p>"
        return "data:text/html," + html.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
            "-isolatedTestProfile", "MobileAir-" + UUID().uuidString,
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
