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
    app.launchArguments += ["-memorySaverEnabled", "YES", "-globalOmnibarHotkey", "off"]
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
