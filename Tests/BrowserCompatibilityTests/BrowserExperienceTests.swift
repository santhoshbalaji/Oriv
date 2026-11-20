import XCTest
import BrowserCore
@testable import BrowserEngine
import WebKit
#if os(iOS)
import UIKit
#endif

@MainActor final class BrowserExperienceTests: XCTestCase {
    private func session(store: SessionFileStore? = nil, recordFixture: Bool = false) -> BrowserSession {
        BrowserSession(store: store, dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil), recordsQAFixtureHistory: recordFixture)
    }
    func testSuggestionsDeduplicateAndNeverCrossPrivacyOrProfileBoundaries() throws {
        let session = session(), otherProfile = self.session()
        defer { session.shutdown(); otherProfile.shutdown() }
        let regularURL = URL(string: "https://example.test/regular")!, privateURL = URL(string: "https://example.test/private")!
        let regular = session.addTab(url: regularURL, load: false)
        session.toggleBookmark()
        _ = session.importBookmarks([Bookmark(title: "Saved research", url: URL(string: "https://example.test/saved")!)])
        let privateTab = session.addTab(url: privateURL, isPrivate: true, load: false)
        let normal = session.suggestions(for: "  EXAMPLE.test  ", isPrivate: false)
        XCTAssertEqual(normal.map(\.url), [regularURL, URL(string: "https://example.test/saved")!])
        XCTAssertEqual(normal.first?.tabID, regular.id)
        XCTAssertEqual(session.suggestions(for: "example", isPrivate: true).map(\.tabID), [privateTab.id])
        XCTAssertTrue(session.suggestions(for: "Saved research", isPrivate: true).isEmpty)
        XCTAssertTrue(otherProfile.suggestions(for: "example", isPrivate: false).isEmpty)
        XCTAssertTrue(session.suggestions(for: " \n ", isPrivate: false).isEmpty)
        session.closeTab(privateTab.id)
        XCTAssertTrue(session.suggestions(for: "example", isPrivate: true).isEmpty)
    }
    func testBookmarkUndoPreservesMetadataOrderAndPersistenceWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionFileStore(fileURL: root.appendingPathComponent("session.json"))
        let session = session(store: store)
        defer { session.shutdown() }
        let first = Bookmark(title: "First", url: URL(string: "https://example.test/first")!, createdAt: Date(timeIntervalSince1970: 100))
        let second = Bookmark(title: "Second", url: URL(string: "https://example.test/second")!)
        session.importBookmarks([first, second]); session.removeBookmark(first.id)
        XCTAssertTrue(session.canUndoBookmarkRemoval); XCTAssertEqual(session.bookmarks, [second])
        session.undoBookmarkRemoval()
        XCTAssertEqual(session.bookmarks, [first, second]); XCTAssertFalse(session.canUndoBookmarkRemoval)
        session.flushPersistence()
        XCTAssertEqual(try store.load().snapshot?.bookmarks, [first, second])
        session.removeBookmark(first.id)
        let replacement = Bookmark(title: "Saved again", url: first.url)
        session.importBookmarks([replacement]); session.undoBookmarkRemoval()
        XCTAssertEqual(session.bookmarks.filter { $0.url == first.url }, [replacement])
        session.removeBookmark(second.id); session.dismissBookmarkUndo()
        session.undoBookmarkRemoval(); XCTAssertFalse(session.bookmarks.contains(second))
    }
    func testSavedLinkReusesOnlyEmptyRegularTabAndExplicitNewTabAlwaysAdds() throws {
        let session = session()
        defer { session.shutdown() }
        let initial = try XCTUnwrap(session.selectedTabID), url = URL(string: "http://127.0.0.1:8768/quality")!
        session.openSavedPage(url)
        XCTAssertEqual(session.selectedTabID, initial); XCTAssertEqual(session.tabs.count, 1)
        session.openSavedPage(url)
        XCTAssertNotEqual(session.selectedTabID, initial); XCTAssertEqual(session.tabs.count, 2)
        let privateTab = session.addTab(isPrivate: true)
        session.openSavedPage(url)
        XCTAssertNil(privateTab.url); XCTAssertFalse(try XCTUnwrap(session.selectedTab).isPrivate)
        let blank = session.addTab()
        session.openSavedPage(url, inNewTab: true)
        XCTAssertNil(blank.url); XCTAssertNotEqual(session.selectedTabID, blank.id)
    }
    func testEditedFieldSignalRequiresConfirmationUntilNextDocument() async throws {
        let session = session()
        defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        let detach = try mountWebFixture(tab)
        defer { detach() }
        let draft = URL(string: "https://fixture.invalid/draft")!
        try await waitForWebFixture(tab, at: draft, timeout: webFixtureTimeoutScale > 1 ? 20 : 75) {
            tab.webView.loadHTMLString("<title>Draft document</title><input aria-label='Draft'>", baseURL: draft)
        }
        XCTAssertFalse(session.requiresCloseConfirmation(tab.id))
        _ = try await tab.webView.callAsyncJavaScript("window.webkit.messageHandlers.editedField.postMessage(true)", arguments: [:], in: nil, contentWorld: .world(name: "OrivTabState"))
        try await wait("the edited-field bridge message") { session.requiresCloseConfirmation(tab.id) }
        let next = URL(string: "https://fixture.invalid/next")!
        try await waitForWebFixture(tab, at: next) {
            tab.webView.loadHTMLString("<title>Next document</title><p>A separate document.</p>", baseURL: next)
        }
        XCTAssertFalse(session.requiresCloseConfirmation(tab.id))
        XCTAssertFalse(session.requiresCloseConfirmation(UUID()))
    }
    func testLateDocumentTitleKVOUpdatesExistingHistoryVisit() async throws {
        let session = session(recordFixture: true); defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        let detach = try mountWebFixture(tab)
        defer { detach() }
        tab.navigate(to: URL(string: "http://127.0.0.1:8768/quality")!)
        try await wait { !tab.isLoading && session.history.first?.title == "Browser quality fixture" }
        let visit = try XCTUnwrap(session.history.first)
        _ = try await tab.webView.evaluateJavaScript("document.title = 'Title delivered after finish'; true")
        try await wait { session.history.first?.title == "Title delivered after finish" }
        XCTAssertEqual(session.history.count, 1); XCTAssertEqual(session.history[0].id, visit.id)
        XCTAssertEqual(session.history[0].visitedAt, visit.visitedAt)
    }
    func testSPAHistoryRecordsDebouncedRoutesAndExcludesPrivateAndFixtureByDefault() async throws {
        let base = URL(string: "http://127.0.0.1:8768")!
        let enabled = session(recordFixture: true), disabled = session()
        defer { enabled.shutdown(); disabled.shutdown() }
        let tab = try XCTUnwrap(enabled.selectedTab)
        let detach = try mountWebFixture(tab)
        defer { detach() }
        tab.navigate(to: base.appendingPathComponent("quality"))
        try await wait("the initial route to finish and record a visit") { !tab.isLoading && enabled.historyCount == 1 }
        _ = try await tab.webView.evaluateJavaScript("history.pushState({}, '', '/spa-route'); true")
        try await wait { enabled.history.first?.url.path == "/spa-route" }
        _ = try await tab.webView.evaluateJavaScript("""
            history.replaceState({}, '', '/replace-intermediate');
            history.replaceState({}, '', '/replace-final');
            document.title = 'Replacement route';
            true
            """)
        try await wait { enabled.history.first?.url.path == "/replace-final" }
        XCTAssertEqual(enabled.history.first?.title, "Replacement route")
        _ = try await tab.webView.evaluateJavaScript("location.hash = 'section'; true")
        try await wait { enabled.history.first?.url.fragment == "section" }
        let hash = try XCTUnwrap(enabled.history.first)
        _ = try await tab.webView.evaluateJavaScript("document.title = 'Section title'; true")
        try await wait { enabled.history.first?.title == "Section title" }
        let entries = enabled.history
        XCTAssertEqual(entries.first?.id, hash.id)
        XCTAssertEqual(entries.map(\.url.path), ["/replace-final", "/replace-final", "/spa-route", "/quality"])
        XCTAssertEqual(enabled.continuitySnapshot().history.map(\.url.path), ["/quality"])

        let privateTab = enabled.addTab(isPrivate: true, load: false)
        let detachPrivate = try mountWebFixture(privateTab)
        defer { detachPrivate() }
        privateTab.navigate(to: base.appendingPathComponent("one"))
        try await wait("the private fixture to finish") { !privateTab.isLoading && privateTab.title == "Browser foundation" }
        _ = try await privateTab.webView.evaluateJavaScript("history.pushState({}, '', '/private-route'); true")
        try await wait { privateTab.url?.path == "/private-route" }
        let fixture = try XCTUnwrap(disabled.selectedTab)
        let detachDefault = try mountWebFixture(fixture)
        defer { detachDefault() }
        fixture.navigate(to: base.appendingPathComponent("one"))
        try await wait("the default fixture to finish") { !fixture.isLoading && fixture.title == "Browser foundation" }
        _ = try await fixture.webView.evaluateJavaScript("history.pushState({}, '', '/fixture-route'); true")
        try await wait { fixture.url?.path == "/fixture-route" }
        XCTAssertEqual(enabled.history, entries)
        XCTAssertTrue(disabled.history.isEmpty)
    }

    func testHistoryIncludesOnlyFinalRedirectAndExcludesHTTPErrorAndDownload() async throws {
        let session = session(recordFixture: true)
        defer { session.shutdown() }
        let base = URL(string: "http://127.0.0.1:8768")!
        let tab = try XCTUnwrap(session.selectedTab)
        let detach = try mountWebFixture(tab)
        defer { detach() }
        try await waitForWebFixture(tab, at: base.appendingPathComponent("quality")) {
            try session.navigate(base.appendingPathComponent("history-redirect").absoluteString)
        }
        let expectedPaths = ["/quality"]
        XCTAssertEqual(session.history.map(\.url.path), expectedPaths)
        XCTAssertEqual(session.history.first?.typedCount, 1)
        try await waitForWebFixture(tab, at: base.appendingPathComponent("history-error")) {
            tab.navigate(to: base.appendingPathComponent("history-error"))
        }
        try await wait("the HTTP error document title") { tab.title == "Missing history fixture" }
        XCTAssertEqual(session.history.map(\.url.path), expectedPaths)
        var downloaded = false
        session.handleDownload = { download in downloaded = true; download.cancel { _ in } }
        tab.navigate(to: base.appendingPathComponent("download"))
        try await wait("the download callback") { downloaded }
        XCTAssertEqual(session.history.map(\.url.path), expectedPaths)
    }

    func testLegacyHistorySurvivesMigrationAndCannotResurrectAfterClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = SessionFileStore(fileURL: root.appendingPathComponent("session.json"))
        let url = try XCTUnwrap(URL(string: "https://migrated.example.test/page"))
        let entry = HistoryEntry(title: "Migrated Café", url: url, visitedAt: Date(timeIntervalSince1970: 1_000), visitCount: 9)
        let original = BrowserSnapshot(history: [entry])
        try legacy.save(original)
        try SessionFileStore(fileURL: legacy.backupURL).save(original)
        let upgraded = session(store: legacy)
        XCTAssertEqual(upgraded.historyPage(search: "CAFE"), [entry])
        XCTAssertEqual(try legacy.load().snapshot?.history, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.backupURL.path))
        upgraded.shutdown()

        // A stale legacy snapshot left after import must not duplicate rows.
        try legacy.save(original)
        let reopened = session(store: legacy)
        XCTAssertEqual(reopened.history, [entry])
        let suggestions = await reopened.indexedSuggestions(for: "migrated", isPrivate: false)
        XCTAssertEqual(suggestions.map(\.url), [url])
        reopened.clearHistory()
        let erased = await reopened.indexedSuggestions(for: "migrated", isPrivate: false)
        XCTAssertTrue(erased.isEmpty)
        reopened.shutdown()

        let final = session(store: legacy)
        XCTAssertTrue(final.history.isEmpty)
        final.shutdown()
    }
    private func wait(_ condition: String = "the fixture condition", file: StaticString = #filePath, line: UInt = #line,
                      _ predicate: @MainActor () -> Bool) async throws {
        try await waitForFixtureCondition(condition, timeout: 20, file: file, line: line, predicate)
    }
}

@MainActor func mountWebFixture(_ tab: BrowserTab) throws -> () -> Void {
    #if os(iOS)
    let controller = UIViewController()
    controller.view = tab.webView
    return try mountFixtureController(controller)
    #else
    return {}
    #endif
}

#if os(iOS)
@MainActor func mountFixtureController(_ controller: UIViewController) throws -> () -> Void {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive }
        ?? scenes.first { $0.keyWindow != nil }, "Expected a window scene in the simulator test host")
    let previousWindow = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    window.frame = scene.coordinateSpace.bounds
    window.rootViewController = controller
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    return {
        window.isHidden = true
        window.rootViewController = nil
        if previousWindow?.isHidden == false { previousWindow?.makeKey() }
    }
}
#endif

@MainActor func waitForWebFixture(_ tab: BrowserTab, at url: URL, timeout: TimeInterval = 20,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  navigate: () throws -> Void) async throws {
    let ready = XCTestExpectation(description: "Finished fixture navigation to \(url.path)")
    let previous = tab.onDocumentReady
    let revision = tab.documentRevision
    var finished = false
    tab.onDocumentReady = { [weak tab] destination in
        previous?(destination)
        guard let tab, tab.documentRevision > revision, destination == url, !finished else { return }
        finished = true
        ready.fulfill()
    }
    defer { tab.onDocumentReady = previous }
    let started = ContinuousClock.now
    try navigate()
    let result = await XCTWaiter.fulfillment(of: [ready], timeout: webFixtureTimeout(timeout))
    if result == .completed {
        logSlowWebWait(ready.description, started: started, timeout: timeout, file: file, line: line)
    }
    let state = "revision \(tab.documentRevision), loading \(tab.isLoading), browser error \(tab.errorMessage ?? "none")"
    _ = try XCTUnwrap(result == .completed ? true : nil,
                      "\(ready.description). Current state: \(state)",
                      file: file, line: line)
}
