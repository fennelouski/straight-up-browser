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
    func testOmnibarWeatherAppearsWhileTypingAndRetainsNormalNavigation() {
        let app = browserForUITesting()
        app.launchArguments += ["-weatherUITesting", "rain"]
        launchBrowserForUITesting(app)
        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click(); field.typeText("weather")
        XCTAssertTrue(app.descendants(matching: .any)["omnibar-weather-current"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Hourly forecast"].exists)
        XCTAssertTrue(app.buttons["omnibar-weather-location"].exists)
        field.typeText("\r")
        XCTAssertTrue(app.descendants(matching: .any)["omnibar-weather"].exists)
        XCTAssertEqual(field.value as? String, "weather")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Omnibar-Weather-Rain"; screenshot.lifetime = .keepAlways; add(screenshot)
        field.typeText(".com")
        XCTAssertTrue(app.descendants(matching: .any)["omnibar-weather"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "weather.com")
        field.typeKey("a", modifierFlags: .command); field.typeText("weather")
        XCTAssertTrue(app.descendants(matching: .any)["omnibar-weather"].waitForExistence(timeout: 5))
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["omnibar-weather"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testOmnibarWeatherSnowAndNightRemainUsableWithMotionDisabled() {
        for scene in ["snow", "clear"] {
            let app = browserForUITesting()
            app.launchArguments += ["-weatherUITesting", scene, "-omnibarAnimationDuration", "0"]
            launchBrowserForUITesting(app)
            let field = app.textFields["Search or enter address"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.click(); field.typeText("weather")
            XCTAssertTrue(app.descendants(matching: .any)["omnibar-weather-current"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Hourly forecast"].exists)
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "Omnibar-Weather-\(scene)"; screenshot.lifetime = .keepAlways; add(screenshot)
            app.buttons["omnibar-weather-location"].click()
            XCTAssertTrue(app.buttons["newspaper-weather-use-current"].waitForExistence(timeout: 5))
            app.buttons["Cancel"].click()
            field.typeKey(.escape, modifierFlags: [])
            app.terminate()
        }
    }

    @MainActor
    func testGlobalOmnibarWeatherExpandsAndLocationPopupStaysOpen() {
        let app = browserForUITesting()
        app.launchArguments += ["-weatherUITesting", "rain", "-globalOmnibarUITesting", "-newspaperWeatherCity", ""]
        launchBrowserForUITesting(app)
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Show Floating Omnibar"].click()
        let panel = app.dialogs["browser-global-omnibar"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let field = panel.textFields["Search or enter address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click(); field.typeText("weather")
        XCTAssertTrue(panel.descendants(matching: .any)["omnibar-weather-current"].waitForExistence(timeout: 10))
        XCTAssertTrue(panel.buttons["omnibar-weather-location"].isHittable)
        panel.buttons["omnibar-weather-location"].click()
        let city = app.textFields["newspaper-weather-city"]
        XCTAssertTrue(city.waitForExistence(timeout: 5))
        city.click(); city.typeText("Paris, France")
        XCTAssertEqual(city.value as? String, "Paris, France")
        XCTAssertTrue(panel.exists)
        app.buttons["Cancel"].click()
        let screenshot = XCTAttachment(screenshot: panel.screenshot())
        screenshot.name = "Omnibar-Weather-Global"; screenshot.lifetime = .keepAlways; add(screenshot)
        field.click(); field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testOmnibarLiveWeatherKitHourlyForecastAndAttribution() throws {
        guard ProcessInfo.processInfo.environment["RUN_WEATHERKIT_LIVE_TEST"] == "1" else {
            throw XCTSkip("Live WeatherKit is an explicit release-service check.")
        }
        let app = browserForUITesting()
        app.launchArguments += ["-newspaperShowWeather", "NO", "-newspaperWeatherCity", "Amsterdam, Netherlands", "-newspaperWeatherCurrentLocation", "NO"]
        launchBrowserForUITesting(app)
        let field = app.textFields["Search or enter address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click(); field.typeText("weather")
        XCTAssertTrue(app.descendants(matching: .any)["omnibar-weather-current"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Hourly forecast"].exists)
        let mark = app.descendants(matching: .any)["omnibar-weather-mark"]
        XCTAssertTrue(mark.exists)
        XCTAssertEqual(mark.label, "Apple Weather")
        XCTAssertTrue(app.links["omnibar-weather-attribution"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Omnibar-Live-WeatherKit"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor
    func testNewspaperAppearanceHeadlineAndDiscoveryControls() {
        let app = browserForUITesting()
        app.launchArguments += ["-newspaperUITesting", "-newspaperShowHeadline", "YES",
            "-newspaperDiscoverVisited", "NO", "-newspaperDiscoverPrefetched", "NO", "-newspaperDiscoverRelated", "NO", "-newspaperExternalValidation", "NO", "-newspaperShowWeather", "NO"]
        launchBrowserForUITesting(app)
        app.menuBars.menuBarItems["Edit"].click()
        app.menuItems["Open Newspaper"].click()
        let paper = app.windows["newspaper"]
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        XCTAssertTrue(paper.staticTexts["TODAY'S HEADLINE"].waitForExistence(timeout: 5))
        XCTAssertEqual(paper.buttons.matching(identifier: "Why the night sky still surprises us").count, 1)
        paper.buttons["Newspaper Settings"].click()
        let settings = app.windows["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        for _ in 0..<16 {
            if settings.popUpButtons["newspaper-appearance"].isHittable { break }
            settings.scrollViews.element(boundBy: 1).swipeUp()
        }
        settings.popUpButtons["newspaper-appearance"].click()
        app.menuItems["Dark"].click()
        settings.buttons["Broadsheet"].click()
        XCTAssertTrue(settings.buttons["Shelf"].exists)
        XCTAssertTrue(settings.staticTexts["Light"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.staticTexts["Dark"].firstMatch.exists)
        let previews = XCTAttachment(screenshot: settings.screenshot()); previews.name = "Newspaper-Settings-Previews"; previews.lifetime = .keepAlways; add(previews)
        let dark = XCTAttachment(screenshot: paper.screenshot()); dark.name = "Newspaper-Dark"; dark.lifetime = .keepAlways; add(dark)
        settings.popUpButtons["newspaper-appearance"].click()
        app.menuItems["Light"].click()
        settings.buttons["Ink"].click()
        XCTAssertEqual(settings.popUpButtons["newspaper-appearance"].value as? String, "Light")
        for _ in 0..<12 {
            if settings.switches["newspaper-discovery-visited"].isHittable { break }
            settings.scrollViews.element(boundBy: 1).swipeUp()
        }
        XCTAssertTrue(settings.switches["newspaper-discovery-visited"].waitForExistence(timeout: 5))
        XCTAssertEqual((settings.switches["newspaper-discovery-visited"].value as? NSNumber)?.intValue, 0)
        XCTAssertEqual((settings.switches["newspaper-discovery-external"].value as? NSNumber)?.intValue, 0)
        settings.typeKey("w", modifierFlags: .command)
        paper.click()
        let light = XCTAttachment(screenshot: paper.screenshot()); light.name = "Newspaper-Ink-Light"; light.lifetime = .keepAlways; add(light)
    }

    @MainActor
    func testNewspaperPublicationStylesAndVisualFormats() {
        let app = browserForUITesting()
        app.launchArguments += ["-newspaperUITesting", "-newspaperShowWeather", "NO", "-newspaperShowHeadline", "NO", "-newspaperNavigationStyle", "continuous"]
        launchBrowserForUITesting(app)
        app.menuBars.menuBarItems["Edit"].click()
        app.menuItems["Open Newspaper"].click()
        let paper = app.windows["newspaper"]
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        let sky = paper.buttons["Why the night sky still surprises us"]
        let gardens = paper.buttons["The gardens growing above our streets"]
        XCTAssertTrue(sky.waitForExistence(timeout: 5))
        XCTAssertTrue(gardens.waitForExistence(timeout: 5))
        XCTAssertLessThan(sky.frame.width, paper.frame.width * 0.6)
        XCTAssertEqual(sky.frame.minY, gardens.frame.minY, accuracy: 2)
        XCTAssertGreaterThan(gardens.frame.minX, sky.frame.maxX)
        let mastheadY = paper.staticTexts["Metropolitan"].frame.minY
        paper.scrollViews.firstMatch.swipeUp()
        XCTAssertLessThan(paper.staticTexts["Metropolitan"].frame.minY, mastheadY - 20)
        XCTAssertTrue(paper.buttons["Close Newspaper"].isHittable)
        XCTAssertGreaterThan(paper.buttons["Close Newspaper"].frame.maxX, paper.frame.maxX - 10)
        paper.scrollViews.firstMatch.swipeDown()
        let columns = XCTAttachment(screenshot: paper.screenshot()); columns.name = "Newspaper-Print-Columns"; columns.lifetime = .keepAlways; add(columns)
        paper.buttons["Newspaper Settings"].click()
        let settings = app.windows["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.buttons["Publication Style & Paper"].waitForExistence(timeout: 5))
        for _ in 0..<32 {
            if settings.buttons["Publication Style & Paper"].isHittable { break }
            settings.scrollViews.element(boundBy: 1).scroll(byDeltaX: 0, deltaY: 200)
        }
        XCTAssertFalse(settings.buttons["Bold Weekly"].exists)
        settings.buttons["Publication Style & Paper"].click()
        for _ in 0..<32 {
            if settings.buttons["Bold Weekly"].isHittable { break }
            settings.scrollViews.element(boundBy: 1).scroll(byDeltaX: 0, deltaY: -200)
        }
        XCTAssertTrue(settings.buttons["Bold Weekly"].waitForExistence(timeout: 5))
        settings.buttons["Bold Weekly"].click()
        for _ in 0..<32 {
            if settings.buttons["Use this style's recommended format and paper"].isHittable { break }
            settings.scrollViews.element(boundBy: 1).scroll(byDeltaX: 0, deltaY: -200)
        }
        settings.buttons["Use this style's recommended format and paper"].click()
        XCTAssertTrue(paper.descendants(matching: .any)["newspaper-cover-issue"].waitForExistence(timeout: 5))
        XCTAssertTrue(paper.descendants(matching: .any)["newspaper-table-of-contents"].exists)
        let cover = XCTAttachment(screenshot: paper.screenshot()); cover.name = "Newspaper-Cover-Contents"; cover.lifetime = .keepAlways; add(cover)
        for _ in 0..<32 {
            if settings.buttons["Eclectic"].isHittable { break }
            settings.scrollViews.element(boundBy: 1).scroll(byDeltaX: 0, deltaY: -200)
        }
        settings.buttons["Eclectic"].click()
        XCTAssertTrue(paper.descendants(matching: .any)["newspaper-newsstand"].waitForExistence(timeout: 5))
        let eclectic = XCTAttachment(screenshot: paper.screenshot()); eclectic.name = "Newspaper-Eclectic"; eclectic.lifetime = .keepAlways; add(eclectic)
        settings.buttons["Story Feed"].click()
        XCTAssertTrue(paper.buttons["Why the night sky still surprises us"].exists)
        settings.buttons["Flipbook"].click()
        XCTAssertTrue(paper.buttons["Next"].waitForExistence(timeout: 5))
        paper.buttons["Next"].click()
        XCTAssertTrue(paper.staticTexts["Page 2 of 3"].waitForExistence(timeout: 5))
        paper.swipeLeft()
        XCTAssertTrue(paper.staticTexts["Page 3 of 3"].waitForExistence(timeout: 5))
        paper.swipeRight()
        XCTAssertTrue(paper.staticTexts["Page 2 of 3"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNewspaperEditionNameIsManualAndReversibleWithoutAI() {
        let app = browserForUITesting()
        app.launchArguments += ["-newspaperUITesting", "-newspaperShowWeather", "NO"]
        launchBrowserForUITesting(app)
        app.menuBars.menuBarItems["Edit"].click(); app.menuItems["Open Newspaper"].click()
        let paper = app.windows["newspaper"]
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        paper.buttons["Newspaper Settings"].click()
        let settings = app.windows["settings"]
        XCTAssertTrue(settings.buttons["Edition Name"].waitForExistence(timeout: 5))
        for _ in 0..<32 {
            if settings.buttons["Edition Name"].isHittable { break }
            settings.scrollViews.element(boundBy: 1).scroll(byDeltaX: 0, deltaY: 200)
        }
        XCTAssertFalse(settings.textFields["newspaper-personal-name"].exists)
        settings.buttons["Edition Name"].click()
        let field = settings.textFields["newspaper-personal-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click(); field.typeText("The Orbit Journal")
        XCTAssertTrue(paper.staticTexts["The Orbit Journal"].waitForExistence(timeout: 5))
        XCTAssertFalse(settings.buttons["Send preview & suggest names"].exists)
        settings.buttons["Use the style's name"].click()
        XCTAssertTrue(paper.staticTexts["The Orbit Journal"].waitForNonExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: settings.screenshot()); screenshot.name = "Newspaper-Edition-Name"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor
    func testNewspaperWeatherIconOffersLocationWithoutRequestingIt() {
        let app = browserForUITesting()
        app.launchArguments += ["-newspaperUITesting", "-newspaperShowWeather", "NO", "-newspaperWeatherCurrentLocation", "NO", "-newspaperWeatherCity", ""]
        launchBrowserForUITesting(app)
        app.menuBars.menuBarItems["Edit"].click(); app.menuItems["Open Newspaper"].click()
        let paper = app.windows["newspaper"]
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        paper.buttons["newspaper-weather-location"].click()
        XCTAssertTrue(app.buttons["newspaper-weather-use-current"].waitForExistence(timeout: 5))
        let city = app.textFields["newspaper-weather-city"]
        XCTAssertTrue(city.exists)
        city.click(); city.typeText("Amsterdam, Netherlands")
        XCTAssertTrue(app.buttons["Use this city"].isEnabled)
        XCTAssertFalse(app.staticTexts["Loading weather…"].exists)
        XCTAssertFalse(app.staticTexts["Finding your location…"].exists)
        let shot = XCTAttachment(screenshot: paper.screenshot()); shot.name = "Newspaper-Weather-Location"; shot.lifetime = .keepAlways; add(shot)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testNewspaperLiveWeatherKitAttribution() throws {
        guard ProcessInfo.processInfo.environment["RUN_WEATHERKIT_LIVE_TEST"] == "1" else {
            throw XCTSkip("Live WeatherKit is an explicit release-service check.")
        }
        let app = browserForUITesting()
        app.launchArguments += ["-newspaperUITesting", "-newspaperShowWeather", "YES", "-newspaperWeatherCity", "Amsterdam, Netherlands", "-newspaperWeatherCurrentLocation", "NO"]
        launchBrowserForUITesting(app)
        app.menuBars.menuBarItems["Edit"].click()
        app.menuItems["Open Newspaper"].click()
        let paper = app.windows["newspaper"]
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        XCTAssertTrue(paper.descendants(matching: .any)["newspaper-weather-current"].waitForExistence(timeout: 60))
        XCTAssertTrue(paper.links["newspaper-weather-attribution"].exists)
        let screenshot = XCTAttachment(screenshot: paper.screenshot()); screenshot.name = "Newspaper-Live-WeatherKit"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor
    func testOnboardingQuickStartAndImmediateTyping() {
        let app = browserForUITesting()
        app.launchArguments += ["-onboardingUITesting"]
        launchBrowserForUITesting(app)
        XCTAssertTrue(app.buttons["onboarding-show"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["onboarding-later"].exists)
        XCTAssertTrue(app.buttons["onboarding-decline"].exists)
        app.buttons["onboarding-show"].click()
        app.buttons["onboarding-track-quickStart"].click()
        XCTAssertTrue(app.staticTexts["Your launch pad"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["onboarding-memory"].exists)
        app.buttons["Try the omnibar"].click()
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Search or enter address")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("onboarding typing")
        XCTAssertEqual(field.value as? String, "onboarding typing")
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["onboarding-resume"].click()
        app.buttons["onboarding-next"].click()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForNonExistence(timeout: 5))
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Getting Started Guide"].click()
        XCTAssertTrue(app.buttons["onboarding-track-deepDive"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOnboardingDeepDiveCoversWorkspacesAndOptionalTools() {
        let app = browserForUITesting()
        app.launchArguments += ["-onboardingUITesting"]
        launchBrowserForUITesting(app)
        XCTAssertTrue(app.buttons["onboarding-show"].waitForExistence(timeout: 10))
        app.buttons["onboarding-show"].click()
        app.buttons["onboarding-track-deepDive"].click()
        app.checkBoxes["Design"].click()
        app.buttons["onboarding-next"].click()
        app.buttons["onboarding-next"].click()
        XCTAssertTrue(app.staticTexts["A home for each project"].waitForExistence(timeout: 5))
        app.buttons["onboarding-next"].click()
        XCTAssertTrue(app.staticTexts["Keep the sources that matter"].waitForExistence(timeout: 5))
        app.buttons["onboarding-next"].click()
        XCTAssertTrue(app.buttons["Create a workspace document"].exists)
        app.buttons["onboarding-next"].click()
        XCTAssertTrue(app.staticTexts["See the bigger picture"].exists)
        // Finish the adaptable path without opting into external services.
        for _ in 0..<14 {
            if app.buttons["Review agent permissions"].exists { break }
            app.buttons["onboarding-next"].click()
        }
        XCTAssertTrue(app.buttons["Review agent permissions"].exists)
        XCTAssertTrue(app.buttons["Keep external-agent access off"].exists)
        app.buttons["onboarding-next"].click()
        XCTAssertTrue(app.staticTexts["Show what you mean"].exists)
        app.buttons["onboarding-next"].click()
        XCTAssertTrue(app.staticTexts["Ready for your own orbit"].exists)
        app.buttons["onboarding-next"].click()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testOnboardingCustomizationChangesTheLiveTabLayout() {
        let app = browserForUITesting()
        app.launchArguments += ["-onboardingUITesting"]
        // Live choices must not be shadowed by launch-argument defaults.
        if let index = app.launchArguments.firstIndex(of: "-tabBarWidth") {
            app.launchArguments.removeSubrange(index...(index + 1))
        }
        launchBrowserForUITesting(app)
        XCTAssertTrue(app.buttons["onboarding-show"].waitForExistence(timeout: 10))
        app.buttons["onboarding-show"].click()
        app.buttons["onboarding-track-customization"].click()
        app.buttons["onboarding-next"].click()
        XCTAssertTrue(app.staticTexts["Make yourself comfortable"].waitForExistence(timeout: 5))
        app.buttons["Side tabs"].click()
        XCTAssertTrue(app.buttons["Visual Tabs"].waitForExistence(timeout: 5))
        app.buttons["Top tabs"].click()
        XCTAssertTrue(app.buttons["Visual Tabs"].waitForNonExistence(timeout: 5))
        app.buttons["Side tabs"].click()
        XCTAssertTrue(app.buttons["Visual Tabs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Max page brightness"].exists)
        app.sliders["Max page brightness"].adjust(toNormalizedSliderPosition: 0.6)
        app.buttons["onboarding-minimize"].click()
        XCTAssertTrue(app.buttons["onboarding-resume"].waitForExistence(timeout: 5))
        app.buttons["onboarding-resume"].click()
        XCTAssertTrue(app.staticTexts["Make yourself comfortable"].exists)
    }

    @MainActor
    func testNamedWindowsOwnWorkspacesAndSupportNativeFullScreen() {
        let app = browserForUITesting()
        app.launchArguments += ["-nativeBrowserFullScreen", "YES"]
        launchBrowserForUITesting(app)
        XCTAssertTrue(app.windows["Browser"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(app.windows["Window 2"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 2)
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Rename Window…"].click()
        let name = app.sheets.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        app.typeKey("a", modifierFlags: [.command])
        name.typeText("Research")
        app.sheets.buttons["Save"].click()
        let research = app.windows["Research"]
        XCTAssertTrue(research.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        let sidebar = research.buttons["Visual Tabs"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(research.buttons["New Document"].exists)
        app.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(research.textFields.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(research.textFields.firstMatch.waitForNonExistence(timeout: 5))
        app.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        app.typeKey("w", modifierFlags: [.command, .option, .shift])
        XCTAssertTrue(research.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows["Browser"].exists)
    }

    @MainActor
    func testBrowserShellOpensTheAddressBarFromNewTab() throws {
        let app = browserForUITesting()
        launchBrowserForUITesting(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        // The address field is exposed through its placeholder, not a label,
        // so a plain app.textFields["…"] subscript never matches it.
        let omnibar = app.textFields.element(
            matching: NSPredicate(format: "placeholderValue == %@", "Search or enter address")
        )
        XCTAssertTrue(omnibar.waitForExistence(timeout: 10))
        omnibar.click()
        omnibar.typeText("C++ & C#")
        XCTAssertEqual(omnibar.value as? String, "C++ & C#")
    }

    @MainActor
    func testOmnibarLongURLSelectionUndoAndHistoryMode() throws {
        let app = browserForUITesting()
        launchBrowserForUITesting(app)
        let field = app.textFields.element(
            matching: NSPredicate(format: "placeholderValue == %@", "Search or enter address")
        )
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        let url = "https://example.com/" + String(repeating: "long-path/", count: 30) + "?q=café&emoji=🙂"
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
        let testChangeCount = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == testChangeCount {
                pasteboard.clearContents()
                pasteboard.writeObjects(saved.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
            }
        }
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(field.value as? String, url)
        app.typeKey(.leftArrow, modifierFlags: .command)
        for _ in 0..<8 { app.typeKey(.rightArrow, modifierFlags: []) }
        field.typeText("edited.")
        let edited = "https://edited." + String(url.dropFirst(8))
        XCTAssertEqual(field.value as? String, edited)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(field.value as? String, url)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(field.value as? String, edited)

        // Leave a mid-URL selection in place across multiple publication ticks.
        app.typeKey(.leftArrow, modifierFlags: .command)
        for _ in 0..<8 { app.typeKey(.rightArrow, modifierFlags: []) }
        for _ in 0..<7 { app.typeKey(.rightArrow, modifierFlags: .shift) }
        let ticks = expectation(description: "Two suggestion publication ticks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { ticks.fulfill() }
        wait(for: [ticks], timeout: 3)
        field.typeText("new.")
        XCTAssertEqual(field.value as? String, "https://new." + String(url.dropFirst(8)))

        app.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(app.buttons["omnibar-history"].value as? String, "Off")
        app.typeKey("y", modifierFlags: [.command, .option])
        let historyField = app.textFields.element(
            matching: NSPredicate(format: "placeholderValue == %@", "Search your history")
        )
        XCTAssertTrue(historyField.waitForExistence(timeout: 3))
        XCTAssertEqual(historyField.value as? String, "https://new." + String(url.dropFirst(8)))
        app.buttons["omnibar-history"].click()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText("editable")
        field.doubleClick()
        field.typeText("replacement")
        XCTAssertEqual(field.value as? String, "replacement")
    }

    @MainActor
    func testExternalLinkDismissesTheStartupAddressBar() {
        let app = browserForUITesting()
        launchBrowserForUITesting(app)
        let omnibar = app.textFields.element(
            matching: NSPredicate(format: "placeholderValue == %@", "Search or enter address")
        )
        XCTAssertTrue(omnibar.waitForExistence(timeout: 10))
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Browser.app")
        NSWorkspace.shared.open(
            [URL(string: "http://127.0.0.1:9/browser-ui-test")!],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
        XCTAssertTrue(omnibar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    @MainActor
    func testLocalPageDownloadCompletesAndAppearsInDownloads() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BROWSER_TEST_DOWNLOADS"] != "1",
            "Requires macOS Downloads access for the test app; set BROWSER_TEST_DOWNLOADS=1 after granting it."
        )
        let filename = "browser-ui-test-\(UUID().uuidString).txt"
        let page = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".html")
        let downloaded = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        defer {
            try? FileManager.default.removeItem(at: page)
            try? FileManager.default.removeItem(at: downloaded)
        }
        try """
        <!doctype html><meta charset="utf-8"><title>Download test</title>
        <a href="data:text/plain;base64,QnJvd3NlciBkb3dubG9hZCB0ZXN0" download="\(filename)">Download audit sample</a>
        """.write(to: page, atomically: true, encoding: .utf8)
        let app = browserForUITesting()
        app.launchArguments += ["-downloadsFolder", ""]
        launchBrowserForUITesting(app)
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Browser.app")
        NSWorkspace.shared.open([page], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        let link = app.links["Download audit sample"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: downloaded.path) },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        XCTAssertEqual(try String(contentsOf: downloaded, encoding: .utf8), "Browser download test")
        app.menuItems["Show Downloads"].click()
        XCTAssertTrue(app.staticTexts[filename].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHistoryShortcutOpensTheLibrary() throws {
        let app = browserForUITesting()
        launchBrowserForUITesting(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("y", modifierFlags: .command)
        // The library opens as a sheet; SwiftUI exposes its labelled container
        // as a group, not an "other" element.
        XCTAssertTrue(app.groups["Browser Library"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAgentRoadmapSettingsAreGroupedInOnePane() throws {
        let app = browserForUITesting()
        launchBrowserForUITesting(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        let agentPane = app.buttons["Agent. Models, automation, memory, privacy"]
        XCTAssertTrue(agentPane.waitForExistence(timeout: 5))
        agentPane.click()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Model Provider").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Provider Pricing").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Cowork Files").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Automation & Records").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Safety & Run Budgets").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Delegated Runs").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Scoped Agent Memory").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Observability & Page Signals").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Agent Definition Sync").firstMatch.exists)
    }

    @MainActor
    func testAutofillContactsExplainsTheLocalReferenceBoundary() throws {
        let app = browserForUITesting()
        app.launchArguments += ["-autofillIncludesMyCard", "NO"]
        launchBrowserForUITesting(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        let autofillPane = app.buttons["Autofill. Profiles, contacts, form filling"]
        XCTAssertTrue(autofillPane.waitForExistence(timeout: 5))
        autofillPane.click()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Contacts").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Use My Card"].exists)
        XCTAssertTrue(app.buttons["Add Contact…"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Manual Profiles").firstMatch.exists)
    }

    @MainActor
    func testEverySettingsPaneOpensAndRenders() {
        let app = browserForUITesting()
        launchBrowserForUITesting(app)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        for (pane, heading) in [
            ("General", "Sync"), ("Agent", "Model Provider"),
            ("Shortcuts", "Keyboard Shortcuts"), ("Autofill", "Contacts"),
            ("Content", "Web Content"), ("Newspaper", "Layout"),
            ("Downloads", "Option-Click Image Downloads"), ("Screenshots", "All Screenshots"),
            ("Appearance", "Tabs"), ("Security", "SSL / TLS"),
            ("Memory", "Memory Saving"), ("Privacy", "Incognito"),
        ] {
            XCTContext.runActivity(named: "Settings: " + pane) { activity in
                let buttons = app.buttons.matching(identifier: "settings-pane-" + pane.lowercased())
                XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 5))
                XCTAssertEqual(buttons.count, 1, "Each settings pane exposes one accessible action")
                buttons.element.click()
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: heading).firstMatch.waitForExistence(timeout: 5))
                let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                screenshot.name = "Settings-" + pane
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
            }
        }
    }

    @MainActor
    func testSettingsSectionCollapseRemovesControlsAndRestoresSelection() {
        #if os(macOS)
        let app = browserForUITesting()
        launchBrowserForUITesting(app)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        let appearance = app.buttons["settings-pane-appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.click()

        let right = app.radioButtons["Right"]
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        right.click()
        XCTAssertEqual((right.value as? NSNumber)?.intValue, 1)

        let tabs = app.buttons["Tabs"]
        tabs.click()
        XCTAssertTrue(right.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.switches["Show traditional tabs across the top"].exists)
        tabs.click()
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        XCTAssertEqual((right.value as? NSNumber)?.intValue, 1, "Collapsing a section must preserve its settings")
        app.radioButtons["Left"].click()
        #endif
    }

    @MainActor
    func testTabOverviewCardsAreAccessibleAndEscapeDismissesIt() {
        let app = browserForUITesting()
        launchBrowserForUITesting(app)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("o", modifierFlags: .command)
        let overview = app.descendants(matching: .any)["All Tabs"]
        let card = overview.buttons["New Tab, Tab"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(overview.waitForExistence(timeout: 1))
    }

    @MainActor
    func testCompactSidebarKeepsActionsAccessibleWithoutOverlapping() {
        let app = browserForUITesting(tabBarWidth: 80)
        launchBrowserForUITesting(app)
        app.typeKey(.escape, modifierFlags: [])
        let more = app.menuButtons["More Tab Actions"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        let newTab = app.buttons["New Tab"]
        XCTAssertLessThanOrEqual(newTab.frame.maxX, more.frame.minX)
        XCTAssertLessThanOrEqual(more.frame.maxX, app.windows.firstMatch.frame.minX + 80)
        more.click()
        for title in ["New Tab", "Visual Tabs", "Groups, Containers, and Workspaces", "Newspaper"] {
            XCTAssertTrue(more.menuItems[title].exists, title)
        }
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "CompactSidebarActions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        more.menuItems["Visual Tabs"].click()
        XCTAssertTrue(app.descendants(matching: .any)["All Tabs"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(more.waitForExistence(timeout: 5))
    }

}

@MainActor
func launchBrowserForUITesting(_ app: XCUIApplication) {
    app.launchArguments += ["-memorySaverEnabled", "YES", "-globalOmnibarHotkey", "off", "-namedBrowserWindows", "[]"]
    if !app.launchArguments.contains("-nativeBrowserFullScreen") {
        app.launchArguments += ["-nativeBrowserFullScreen", "NO"]
    }
    app.launch()

    #if os(macOS)
    // Some launches start a windowless process. Deliver an open event only
    // when needed; a second open event must not create an extra test window.
    let appURL = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("Browser.app")
    if !app.windows.firstMatch.waitForExistence(timeout: 10) {
        _ = NSWorkspace.shared.open(appURL)
    }
    app.activate()
    #endif
}

@MainActor
func browserForUITesting(tabBarWidth: Int = 200) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
        "-uiTesting", "-ApplePersistenceIgnoreState", "YES",
        "-acceptedEULAVersion", "1", "-tabSyncEnabled", "NO",
        "-tabBarWidth", String(tabBarWidth), "-defaultBrowserPromptEnabled", "NO",
        "-launchLayoutEnabled", "NO", "-showNewTabButton", "YES",
        "-tabSidebarSide", "left",
    ]
    return app
}
