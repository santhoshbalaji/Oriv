import AppKit
import BrowserCore
import BrowserEngine
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class ProfileIntegrationTests: BackgroundUITestCase {
    func testSwitchingSeparatesBookmarksHistoryPrivateStoresAndOpenForms() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let personal = profiles.controller
        let saved = Bookmark(title: "Personal only", url: URL(string: "https://personal.test")!)
        personal.session.importBookmarks([saved])
        let regular = try XCTUnwrap(personal.session.selectedTab)
        regular.webView.loadHTMLString("<html><body><input id='draft' value='kept'><p>Personal document</p></body></html>", baseURL: URL(string: "https://profile.test"))
        for _ in 0..<200 { if !regular.webView.isLoading { break }; try await Task.sleep(for: .milliseconds(10)) }
        let privateTab = personal.session.addTab(isPrivate: true)
        let privateStore = privateTab.webView.configuration.websiteDataStore
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        try profiles.select(work.id)
        let workController = profiles.controller
        XCTAssertFalse(personal.session.isProfileActive)
        XCTAssertTrue(workController.session.isProfileActive)
        XCTAssertTrue(workController.session.bookmarks.isEmpty)
        XCTAssertTrue(workController.session.history.isEmpty)
        let workPrivate = workController.session.addTab(isPrivate: true)
        XCTAssertFalse(privateStore === workPrivate.webView.configuration.websiteDataStore)
        try profiles.select(BrowserProfile.personalID)
        XCTAssertTrue(profiles.controller === personal)
        XCTAssertEqual(personal.session.bookmarks, [saved])
        let retainedDraft = try await regular.webView.evaluateJavaScript("document.querySelector('#draft').value") as? String
        XCTAssertEqual(retainedDraft, "kept")
        XCTAssertTrue(regular.isProfileActive)
        XCTAssertFalse(workPrivate.isProfileActive)
    }
    func testProfilePersistenceMigrationAndRecoverableArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyTab = TabRecord(title: "Legacy", url: URL(string: "https://legacy.test"))
        try SessionFileStore(fileURL: root.appendingPathComponent("session.json")).save(BrowserSnapshot(tabs: [legacyTab], selectedTabID: legacyTab.id))
        let profiles = BrowserProfiles(rootDirectory: root, testing: true)
        XCTAssertEqual(profiles.controller.session.selectedTab?.id, legacyTab.id)
        let work = try profiles.create(name: "Work", color: .fern, symbol: .work)
        try profiles.select(work.id)
        let item = Bookmark(title: "Work saved link", url: URL(string: "https://work.test/saved")!)
        profiles.controller.session.importBookmarks([item])
        profiles.controller.session.addTab(url: URL(string: "https://work.test"), load: false)
        profiles.saveAll(); profiles.shutdown()
        let reopened = BrowserProfiles(rootDirectory: root, testing: true)
        defer { reopened.shutdown() }
        XCTAssertEqual(reopened.active.id, work.id)
        XCTAssertEqual(reopened.controller.session.bookmarks.first?.id, item.id)
        XCTAssertEqual(reopened.controller.session.selectedTab?.url?.host, "work.test")
        try reopened.select(BrowserProfile.personalID)
        try reopened.archive(work.id)
        XCTAssertThrowsError(try reopened.select(work.id))
        try reopened.restore(work.id); try reopened.select(work.id)
        XCTAssertEqual(reopened.controller.session.bookmarks.first?.id, item.id)
        XCTAssertEqual(reopened.controller.session.selectedTab?.url?.host, "work.test")
        XCTAssertThrowsError(try reopened.archive(BrowserProfile.personalID))
        XCTAssertThrowsError(try reopened.create(name: " work ", color: .ocean, symbol: .work))
    }
    func testWebsiteCookiesAndDataClearingStayInTheirNamedPersistentStore() async throws {
        let a = UUID(), b = UUID()
        do {
            let first = WKWebsiteDataStore(forIdentifier: a), second = WKWebsiteDataStore(forIdentifier: b)
            XCTAssertEqual(first.identifier, a); XCTAssertEqual(second.identifier, b)
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "profiles.example.test", .path: "/", .name: "login", .value: "synthetic-A"]))
            await first.httpCookieStore.setCookie(cookie)
            let isolated = await second.httpCookieStore.allCookies()
            XCTAssertTrue(isolated.isEmpty)
            let reopened = WKWebsiteDataStore(forIdentifier: a)
            let retained = await reopened.httpCookieStore.allCookies()
            XCTAssertEqual(retained.first?.value, "synthetic-A")
            await WebsiteDataManager(store: second).clear(since: .distantPast, cacheOnly: false)
            let untouched = await first.httpCookieStore.allCookies()
            XCTAssertEqual(untouched.count, 1)
        }
        try await WKWebsiteDataStore.remove(forIdentifier: a)
        try await WKWebsiteDataStore.remove(forIdentifier: b)
    }
    func testPreferencesAndPermissionsDoNotInheritAnotherProfile() throws {
        let bundle = "OrivProfileTest-\(UUID())"
        let a = BrowserProfile(name: "A"), b = BrowserProfile(name: "B")
        let an = try XCTUnwrap(a.defaultsName(bundleID: bundle)), bn = try XCTUnwrap(b.defaultsName(bundleID: bundle))
        let ad = try XCTUnwrap(UserDefaults(suiteName: an)), bd = try XCTUnwrap(UserDefaults(suiteName: bn))
        defer { ad.removePersistentDomain(forName: an); bd.removePersistentDomain(forName: bn) }
        let first = BrowserSettings(defaults: ad), second = BrowserSettings(defaults: bd)
        first.searchEngine = .google; first.defaultZoom = 1.5
        var rule = SiteRule(); rule.camera = .block
        first.setRule(rule, for: URL(string: "https://profile.test")!, isPrivate: false)
        XCTAssertEqual(second.searchEngine, .duckDuckGo); XCTAssertEqual(second.defaultZoom, 1)
        XCTAssertTrue(second.rules.isEmpty)
        XCTAssertEqual(BrowserSettings(defaults: ad).searchEngine, .google)
        XCTAssertEqual(BrowserSettings(defaults: ad).defaultZoom, 1.5)
    }

    func testSwitchIsBlockedDuringPageExportAndDoesNotChangeCurrentProfile() throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        let original = profiles.controller
        original.isExportingPage = true
        XCTAssertThrowsError(try profiles.select(work.id))
        XCTAssertTrue(profiles.controller === original)
        XCTAssertEqual(profiles.active.id, BrowserProfile.personalID)
        original.isExportingPage = false
        try profiles.select(work.id)
        XCTAssertEqual(profiles.active.id, work.id)
    }
    func testExternalLinksReuseProfilelessPrivateContextAndMoveCurrentURL() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let personal = profiles.controller
        let originalPersonalTabs = personal.session.tabs.map(\.id)
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        try profiles.select(work.id)
        let workController = profiles.controller
        let bookmark = Bookmark(title: "Work only", url: URL(string: "https://example.test/saved")!)
        workController.session.importBookmarks([bookmark])
        var opened = 0, closed = 0
        profiles.showExternalWindow = { opened += 1 }; profiles.closeExternalWindow = { closed += 1 }
        profiles.handleIncomingURL(URL(string: "https://example.test/original")!, sourceName: "Test App")
        let context = try XCTUnwrap(profiles.externalPrivate)
        XCTAssertNil(context.profile)
        XCTAssertTrue(context.session.tabs.allSatisfy(\.isPrivate))
        XCTAssertEqual(profiles.externalMoveProfileID, work.id)
        XCTAssertTrue(context.session.bookmarks.isEmpty); XCTAssertTrue(context.session.history.isEmpty)
        let store = try XCTUnwrap(context.session.selectedTab).webView.configuration.websiteDataStore
        XCTAssertFalse(store.isPersistent)
        profiles.handleIncomingURL(URL(string: "https://example.test/second")!)
        XCTAssertTrue(profiles.externalPrivate === context); XCTAssertEqual(context.session.tabs.count, 2); XCTAssertEqual(opened, 2)
        XCTAssertTrue(context.session.selectedTab?.webView.configuration.websiteDataStore === store)
        let current = URL(string: "https://example.test/after-navigation")!
        context.session.setProfileActive(false)
        context.session.selectedTab?.navigate(to: current)
        profiles.externalMoveProfileID = BrowserProfile.personalID
        let movedPrivateID = try XCTUnwrap(context.session.selectedTabID)
        try profiles.moveExternalTab()
        XCTAssertFalse(context.session.tabs.contains { $0.id == movedPrivateID })
        XCTAssertEqual(personal.session.tabs.count, originalPersonalTabs.count + 1)
        XCTAssertTrue(originalPersonalTabs.allSatisfy { id in personal.session.tabs.contains { $0.id == id } })
        XCTAssertTrue(personal.session.tabs.allSatisfy { !$0.isPrivate })
        XCTAssertTrue(profiles.controller === personal); XCTAssertEqual(personal.session.selectedTab?.url, current)
        XCTAssertFalse(personal.session.selectedTab?.isPrivate ?? true)
        XCTAssertEqual(context.session.tabs.count, 1)
        profiles.externalMoveProfileID = work.id
        try profiles.moveExternalTab()
        XCTAssertNil(profiles.externalPrivate); XCTAssertEqual(closed, 1)
        XCTAssertTrue(context.session.tabs.isEmpty); XCTAssertNil(context.session.selectedTabID)
        XCTAssertEqual(workController.session.bookmarks, [bookmark]); XCTAssertTrue(workController.session.history.isEmpty)
    }
    func testExternalSettingOffPreservesRegularRouteAndBadSchemesNeverMove() throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        profiles.openExternalLinksPrivately = false
        let url = URL(string: "https://example.test/regular")!
        profiles.handleIncomingURL(url)
        XCTAssertNil(profiles.externalPrivate); XCTAssertEqual(profiles.controller.session.selectedTab?.url, url)
        XCTAssertFalse(profiles.controller.session.selectedTab?.isPrivate ?? true)
        profiles.openExternalLinksPrivately = true
        profiles.handleIncomingURL(URL(string: "file:///tmp/synthetic")!)
        XCTAssertNil(profiles.externalPrivate)
        profiles.handleIncomingURL(URL(string: "https://example.test/private")!)
        let context = try XCTUnwrap(profiles.externalPrivate)
        context.session.addTab(load: false)
        let count = profiles.controller.session.tabs.count
        try profiles.moveExternalTab()
        XCTAssertEqual(profiles.controller.session.tabs.count, count)
        XCTAssertNotNil(profiles.externalPrivate)
        XCTAssertTrue(context.session.snapshot().tabs.isEmpty)
    }

}
