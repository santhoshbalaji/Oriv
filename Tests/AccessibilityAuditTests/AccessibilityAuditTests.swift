import XCTest

@MainActor final class AccessibilityAuditTests: XCTestCase {
    func testMainScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_A11Y_AUDIT"] == "1",
                          "Foreground pre-release audit requires explicit owner approval.")
        let app = XCUIApplication()
        app.launchEnvironment["BROWSER_TESTING"] = "1"
        app.launchEnvironment["ORIV_BACKGROUND_UI"] = "0"
        app.launch()
        defer { app.terminate() }

        #if os(macOS)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let toggle = window.buttons["sidebarToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["newTabButton"].exists)
        try audit(app, screen: "Start page, expanded sidebar")
        toggle.click()
        XCTAssertTrue(window.descendants(matching: .any)["railNewTabButton"].waitForExistence(timeout: 5))
        try audit(app, screen: "Sidebar rail")
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["orivSettingsWindow"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(settingsWindow.popUpButtons["Search engine"].exists)
        XCTAssertTrue(settingsWindow.popUpButtons["Default page zoom"].exists)
        try audit(app, screen: "Settings")
        #else
        let tabs = app.buttons["browserTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        try audit(app, screen: "Start page")
        tabs.tap()
        let done = app.buttons["tabGridDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        try audit(app, screen: "Tab grid")
        done.tap()
        let menu = app.buttons["browserPageMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        func menuItem(_ title: String) -> XCUIElement {
            let cell = app.cells[title].firstMatch
            if cell.exists { return cell }
            return app.buttons[title].firstMatch
        }
        let newTab = menuItem("New Tab")
        let bookmarks = menuItem("Bookmarks")
        let library = menuItem("Library")
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        XCTAssertTrue(bookmarks.waitForExistence(timeout: 5))
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertLessThan(newTab.frame.minY, bookmarks.frame.minY)
        XCTAssertLessThan(bookmarks.frame.minY, library.frame.minY)
        library.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        try audit(app, screen: "Library")
        app.buttons["Done"].firstMatch.tap()
        menu.tap()
        let settings = menuItem("Settings")
        if !settings.isHittable { app.collectionViews.firstMatch.swipeUp() }
        menuItem("Settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        try audit(app, screen: "Settings")
        #endif
    }

    private func audit(_ app: XCUIApplication, screen: String) throws {
        try XCTContext.runActivity(named: screen) { _ in
            try app.performAccessibilityAudit()
        }
    }
}
