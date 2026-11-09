import XCTest
import BrowserCore
import BrowserEngine
import WebKit

@MainActor final class BrowserExperienceTests: XCTestCase {
    private func session(store: SessionFileStore? = nil) -> BrowserSession {
        BrowserSession(store: store, dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
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
        tab.navigate(to: URL(string: "http://127.0.0.1:8768/quality")!)
        try await wait { tab.title == "Browser quality fixture" && !tab.isLoading }
        XCTAssertFalse(session.requiresCloseConfirmation(tab.id))
        _ = try await tab.webView.callAsyncJavaScript("window.webkit.messageHandlers.editedField.postMessage(true)", arguments: [:], in: nil, contentWorld: .world(name: "OrivTabState"))
        try await wait { session.requiresCloseConfirmation(tab.id) }
        tab.navigate(to: URL(string: "http://127.0.0.1:8768/two")!)
        try await wait { !tab.isLoading && !session.requiresCloseConfirmation(tab.id) }
        XCTAssertFalse(session.requiresCloseConfirmation(UUID()))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = Date.now.addingTimeInterval(20)
        while !predicate() && Date.now < end { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertTrue(predicate())
    }
}
