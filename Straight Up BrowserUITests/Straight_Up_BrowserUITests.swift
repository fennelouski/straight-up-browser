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
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
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
    ]
    return app
}
