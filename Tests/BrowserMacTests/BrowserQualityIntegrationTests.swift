import AppKit
import BrowserCore
import BrowserEngine
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class BrowserQualityIntegrationTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8768")!
    private func wait(_ message: String, until condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !condition() && Date() < end { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertTrue(condition(), message)
    }
    func testSiteRulesPersistByExactOriginAndPrivateRulesNeverPersist() throws {
        let name = "OrivQuality-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = BrowserSettings(defaults: defaults)
        let site = URL(string: "https://example.test:8443/page")!
        var normal = SiteRule(); normal.camera = .block
        settings.setRule(normal, for: site, isPrivate: false)
        var privateRule = SiteRule(); privateRule.microphone = .block
        settings.setRule(privateRule, for: site, isPrivate: true)
        let restored = BrowserSettings(defaults: defaults)
        XCTAssertEqual(restored.rule(for: site, isPrivate: false).camera, .block)
        XCTAssertEqual(restored.rule(for: site, isPrivate: true), SiteRule())
        XCTAssertEqual(restored.rule(for: URL(string: "https://example.test")!, isPrivate: false), SiteRule())
        settings.endPrivateSession()
        XCTAssertEqual(settings.rule(for: site, isPrivate: true), SiteRule())
        defaults.removeObject(forKey: "browser.siteRules")
    }
    func testClosingLastPrivateTabClearsOnlyPrivateSiteRules() {
        let settings = BrowserSettings(defaults: nil)
        let session = BrowserSession(dataStore: .nonPersistent(), settings: settings)
        defer { session.tabs.forEach { $0.close() } }
        let site = URL(string: "https://example.test")!
        var rule = SiteRule(); rule.camera = .block
        settings.setRule(rule, for: site, isPrivate: false)
        let tab = session.addTab(isPrivate: true)
        settings.setRule(rule, for: site, isPrivate: true)
        session.closeTab(tab.id)
        XCTAssertEqual(settings.rule(for: site, isPrivate: true), SiteRule())
        XCTAssertEqual(settings.rule(for: site, isPrivate: false).camera, .block)
    }
    func testPinnedTabsOrderMovementAndBulkCloseProtectPrivacyGroups() throws {
        let session = BrowserSession(dataStore: .nonPersistent(), settings: BrowserSettings(defaults: nil))
        defer { session.tabs.forEach { $0.close() } }
        let a = try XCTUnwrap(session.selectedTab)
        let pinned = session.addTab(); session.togglePinned(pinned.id)
        let b = session.addTab(), c = session.addTab(), privateTab = session.addTab(isPrivate: true)
        session.moveTab(c.id, offset: -1)
        XCTAssertEqual(session.orderedTabs.map(\.id), [pinned.id, a.id, c.id, b.id, privateTab.id])
        session.selectNumberedTab(1); XCTAssertEqual(session.selectedTabID, pinned.id)
        session.selectRelativeTab(1); XCTAssertEqual(session.selectedTabID, a.id)
        session.closeOtherTabs(c.id)
        XCTAssertEqual(Set(session.tabs.map(\.id)), Set([pinned.id, c.id, privateTab.id]))
        XCTAssertFalse(session.snapshot().tabs.contains { $0.id == privateTab.id })
        XCTAssertTrue(session.snapshot().tabs.first { $0.id == pinned.id }?.isPinned == true)
        // A later-created pinned tab is displayed before ordinary tabs. Closing to
        // its right follows that visible order, not its original storage position.
        let lastPinned = session.addTab(); session.togglePinned(lastPinned.id)
        session.closeOtherTabs(lastPinned.id, toRight: true)
        XCTAssertEqual(Set(session.tabs.map(\.id)), Set([pinned.id, lastPinned.id, privateTab.id]))
    }
    func testFreshStartRetainsPinnedTabsAndHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionFileStore(fileURL: dir.appendingPathComponent("session.json"))
        let pinned = TabRecord(title: "Pinned", url: URL(string: "https://example.test/pinned"), isPinned: true)
        let ordinary = TabRecord(title: "Ordinary", url: URL(string: "https://example.test"))
        try store.save(BrowserSnapshot(tabs: [ordinary, pinned], selectedTabID: ordinary.id, history: [HistoryEntry(title: "History", url: ordinary.url!)]))
        let settings = BrowserSettings(defaults: nil); settings.restoreTabs = false
        let session = BrowserSession(store: store, dataStore: .nonPersistent(), settings: settings)
        defer { session.tabs.forEach { $0.close() } }
        XCTAssertEqual(session.tabs.map(\.id), [pinned.id]); XCTAssertEqual(session.selectedTabID, pinned.id)
        XCTAssertEqual(session.history.count, 1); XCTAssertFalse(session.tabs[0].isInstantiated)
    }
    func testHistoryRangeRemovalDiscardsBackupAndReopenHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionFileStore(fileURL: dir.appendingPathComponent("session.json"))
        let url = URL(string: "https://example.test")!, now = Date()
        try store.save(BrowserSnapshot(tabs: [TabRecord()], history: [HistoryEntry(title: "New", url: url, visitedAt: now), HistoryEntry(title: "Old", url: url, visitedAt: now.addingTimeInterval(-7200))]))
        let session = BrowserSession(store: store, dataStore: .nonPersistent(), settings: BrowserSettings(defaults: nil))
        defer { session.tabs.forEach { $0.close() } }
        let tab = session.addTab(); session.closeTab(tab.id); XCTAssertTrue(session.canReopenTab)
        session.clearHistory(since: now.addingTimeInterval(-3600))
        XCTAssertEqual(session.history.map(\.title), ["Old"]); XCTAssertFalse(session.canReopenTab)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
    }
    func testFindReaderPDFAndArchiveUseActualWebKitPage() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent(), settings: BrowserSettings(defaults: nil))
        defer { tab.close() }
        tab.navigate(to: base.appendingPathComponent("quality"))
        try await wait("Page loaded") { tab.title == "Browser quality fixture" && !tab.isLoading }
        tab.find("Alpha", caseSensitive: true)
        try await wait("Find matched") { tab.findResult != nil }
        XCTAssertEqual(tab.findResult, true)
        tab.clearFind(); tab.find("missing-unique-string", backwards: true)
        try await wait("No match reported") { tab.findResult != nil }
        XCTAssertEqual(tab.findResult, false)
        let capture = try await PageCaptureService.readerText(tab)
        XCTAssertTrue(capture.text.contains("Alpha beta Alpha"))
        let pdf = try await tab.webView.pdf(configuration: WKPDFConfiguration())
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        let archive: Data = try await withCheckedThrowingContinuation { continuation in tab.webView.createWebArchiveData { continuation.resume(with: $0) } }
        let plist = try PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any]
        XCTAssertNotNil(plist?["WebMainResource"])
    }
    func testReaderOnPrivatePageDoesNotPersistBrowsingData() async throws {
        let tab = BrowserTab(isPrivate: true, dataStore: .nonPersistent())
        defer { tab.close() }
        tab.navigate(to: base.appendingPathComponent("quality"))
        try await wait("Private fixture loaded") { tab.title == "Browser quality fixture" && !tab.isLoading }
        let local = try await PageCaptureService.readerText(tab)
        XCTAssertTrue(local.text.contains("No personal information"))
        XCTAssertTrue(tab.isPrivate)
        XCTAssertFalse(tab.record.url == nil)
    }
    func testBasicAuthenticationChallengeCompletesWithoutChangingTrustHandling() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        var challenged = false
        tab.onAuthentication = { challenge, completion in
            challenged = true
            XCTAssertEqual(challenge.protectionSpace.authenticationMethod, NSURLAuthenticationMethodHTTPBasic)
            completion(.useCredential, URLCredential(user: "test", password: "pass", persistence: .none))
        }
        tab.navigate(to: base.appendingPathComponent("basic-auth"))
        try await wait("Authenticated page loaded") { tab.title == "Authenticated fixture" && !tab.isLoading }
        XCTAssertTrue(challenged); XCTAssertFalse(tab.isSecure)
    }
    func testClearingWebsiteDataUsesOnlyTheChosenDataStore() async throws {
        let first = WKWebsiteDataStore.nonPersistent(), other = WKWebsiteDataStore.nonPersistent()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "example.test", .path: "/", .name: "synthetic", .value: "1"]))
        await first.httpCookieStore.setCookie(cookie); await other.httpCookieStore.setCookie(cookie)
        let manager = WebsiteDataManager(store: first)
        await manager.clear(since: .distantPast, cacheOnly: false)
        let cleared = await first.httpCookieStore.allCookies(), retained = await other.httpCookieStore.allCookies()
        XCTAssertTrue(cleared.isEmpty); XCTAssertEqual(retained.count, 1)
    }
    func testDownloadsCompleteWithQuarantineAndCancelPreservesExistingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("download.bin")
        let manager = DownloadManager(), view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        manager.chooseDestination = { _ in destination }
        view.startDownload(using: URLRequest(url: base.appendingPathComponent("download"))) { manager.begin($0) }
        try await wait("Download completed") { manager.items.first?.isFinished == true }
        XCTAssertEqual(manager.items.first?.status, "Completed")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Personal Browser download verification.\n")
        XCTAssertNotNil(try (destination as NSURL).resourceValues(forKeys: [.quarantinePropertiesKey])[.quarantinePropertiesKey])
        let original = try Data(contentsOf: destination)
        view.startDownload(using: URLRequest(url: base.appendingPathComponent("large-download"))) { manager.begin($0) }
        try await wait("Second download progresses") { manager.items.count == 2 && manager.items.first!.bytesReceived > 65536 }
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertFalse(item.isFinished); manager.cancel(item)
        try await wait("Cancelled") { item.isFinished }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertNil(item.temporaryURL)
    }
    func testDownloadPauseAndResumeWithRangeServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("resumed.bin")
        let manager = DownloadManager(), view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        manager.chooseDestination = { _ in destination }
        view.startDownload(using: URLRequest(url: base.appendingPathComponent("large-download"))) { manager.begin($0) }
        try await wait("Download progresses") { manager.items.first?.bytesReceived ?? 0 > 65536 }
        let item = try XCTUnwrap(manager.items.first); manager.pause(item)
        try await wait("Paused") { item.isFinished }
        XCTAssertTrue(item.canResume, item.status)
        manager.resume(item)
        try await wait("Resumed download completed") { item.isFinished && !item.isPaused }
        XCTAssertEqual(item.status, "Completed")
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 81, count: 8 * 1024 * 1024))
    }
    func testDownloadFilenameIsBoundedAndCannotEscapeDestination() {
        XCTAssertEqual(DownloadManager.safeFilename("../../test.txt"), "test.txt")
        XCTAssertEqual(DownloadManager.safeFilename("..\\..\\test.txt"), "test.txt")
        XCTAssertEqual(DownloadManager.safeFilename(".."), "Download")
        XCTAssertFalse(DownloadManager.safeFilename("bad\nfile.txt").contains("\n"))
        XCTAssertEqual(DownloadManager.safeFilename(String(repeating: "a", count: 500)).count, 200)
    }
}
