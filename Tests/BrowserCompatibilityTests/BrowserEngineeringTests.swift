import BrowserCore
@testable import BrowserEngine
import Foundation
import WebKit
import XCTest

private final class CountingSessionStore: BrowserSessionStore {
    let file: SessionFileStore
    var attempts = 0, writes = 0
    var fail = false
    init(_ root: URL) { file = SessionFileStore(fileURL: root.appendingPathComponent("session.json")) }
    func load() throws -> SessionLoadResult { try file.load() }
    func save(_ snapshot: BrowserSnapshot, discardPrevious: Bool) throws -> Bool {
        attempts += 1
        if fail { throw URLError(.cannotWriteToFile) }
        let wrote = try file.save(snapshot, discardPrevious: discardPrevious)
        if wrote { writes += 1 }
        return wrote
    }
    func reset() { attempts = 0; writes = 0 }
}

/// Real WebKit configuration and delegate paths, with synthetic document state and no network requests.
@MainActor private final class EngineeringWebView: WKWebView {
    var pageURL: URL?, pageTitle: String?
    var simulatedLoading = false, fraction = 0.0, secure = false, reloads = 0
    override var url: URL? { pageURL }
    override var title: String? { pageTitle }
    override var isLoading: Bool { simulatedLoading }
    override var estimatedProgress: Double { fraction }
    override var hasOnlySecureContent: Bool { secure }
    override func reload() -> WKNavigation? { reloads += 1; return nil }
    override func load(_ request: URLRequest) -> WKNavigation? { pageURL = request.url; return nil }
}

@MainActor final class BrowserEngineeringTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OrivEngineering-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func session(_ store: (any BrowserSessionStore)? = nil) -> BrowserSession {
        BrowserSession(store: store, dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
    }
    private func view(for tab: BrowserTab) -> EngineeringWebView {
        tab.createWebView = { EngineeringWebView(frame: .zero, configuration: $0) }
        return tab.webView as! EngineeringWebView
    }
    private func commit(_ tab: BrowserTab, view: EngineeringWebView, method: String = "GET") {
        var request = URLRequest(url: view.pageURL!)
        request.httpMethod = method
        tab.recordAllowedMainFrameNavigation(request)
        tab.webView(view, didCommit: nil)
    }

    func testProgressAndLoadingChurnSchedulesZeroSaves() async throws {
        let store = CountingSessionStore(root), session = session(store)
        defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab), view = view(for: tab)
        view.pageURL = URL(string: "https://example.test/progress")
        view.pageTitle = "Steady title"
        tab.refresh(from: view); session.saveNow(); store.reset()
        var changes = 0
        let onChange = tab.onChange
        tab.onChange = { changes += 1; onChange?() }
        for tick in 0..<100 {
            view.simulatedLoading = tick.isMultiple(of: 2); view.fraction = Double(tick) / 100
            view.secure = tick.isMultiple(of: 3)
            tab.refresh(from: view)
        }
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(changes, 0); XCTAssertEqual(store.attempts, 0); XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(tab.progress, 0.99); XCTAssertEqual(tab.isLoading, view.simulatedLoading)
    }
    func testIdenticalSnapshotSkipsStoreAndContinuityNotification() throws {
        let store = CountingSessionStore(root), session = session(store)
        defer { session.shutdown() }
        var notifications = 0
        session.onContinuityChange = { notifications += 1 }
        session.saveNow(); XCTAssertEqual(store.writes, 1); XCTAssertEqual(notifications, 1)
        store.reset(); notifications = 0
        for _ in 0..<10 { session.saveNow() }
        XCTAssertEqual(store.attempts, 0); XCTAssertEqual(store.writes, 0); XCTAssertEqual(notifications, 0)
    }
    func testRestoredIdenticalSnapshotDoesNotWriteOrNotify() throws {
        let store = CountingSessionStore(root)
        let tab = TabRecord(title: "Page", url: URL(string: "https://example.test"))
        try store.file.save(BrowserSnapshot(tabs: [tab], selectedTabID: tab.id))
        let session = session(store)
        defer { session.shutdown() }
        var notifications = 0; session.onContinuityChange = { notifications += 1 }
        session.saveNow()
        XCTAssertEqual(store.writes, 0); XCTAssertEqual(notifications, 0)
    }
    func testRealURLChangeSavesWithinDebounceAndNotifiesOnce() async throws {
        let store = CountingSessionStore(root), session = session(store)
        defer { session.shutdown() }
        session.saveNow(); store.reset()
        var notifications = 0; session.onContinuityChange = { notifications += 1 }
        let tab = try XCTUnwrap(session.selectedTab), view = view(for: tab)
        let changed = URL(string: "https://example.test/changed")!
        view.pageURL = changed; tab.refresh(from: view)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.writes, 0)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        while store.writes == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.attempts, 1); XCTAssertEqual(store.writes, 1); XCTAssertEqual(notifications, 1)
        XCTAssertEqual(try store.file.load().snapshot?.tabs.first?.url, changed)
    }
    func testShutdownFlushesLatestStateAndCancelsPendingDebounce() async throws {
        let store = CountingSessionStore(root), session = session(store)
        session.saveNow(); store.reset()
        let tab = try XCTUnwrap(session.selectedTab)
        tab.setPinned(true); session.shutdown()
        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(try store.file.load().snapshot?.tabs.first?.isPinned, true)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.writes, 1)
    }
    func testPrivateDocumentChangesScheduleNoSaveOrHistory() async throws {
        let store = CountingSessionStore(root), session = session(store)
        defer { session.shutdown() }
        let tab = session.addTab(isPrivate: true, load: false), view = view(for: tab)
        session.saveNow(); store.reset()
        view.pageURL = URL(string: "https://private.test/secret"); view.pageTitle = "Private title"
        commit(tab, view: view); tab.webView(view, didFinish: nil)
        view.pageTitle = "Later private title"; tab.refresh(from: view)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.attempts, 0); XCTAssertTrue(session.history.isEmpty)
        let encoded = String(decoding: try Data(contentsOf: store.file.fileURL), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private.test")); XCTAssertFalse(encoded.contains("Private title"))
    }
    func testSaveFailureRetainsNoticeAndRetriesWithoutNotifyingEarly() throws {
        let store = CountingSessionStore(root), session = session(store)
        defer { session.shutdown() }
        session.saveNow(); store.reset()
        var notifications = 0; session.onContinuityChange = { notifications += 1 }
        session.selectedTab?.setPinned(true); store.fail = true; session.saveNow()
        XCTAssertTrue(session.persistenceNotice?.contains("could not be saved") == true)
        XCTAssertEqual(store.writes, 0); XCTAssertEqual(notifications, 0)
        store.fail = false; session.saveNow()
        XCTAssertEqual(store.writes, 1); XCTAssertEqual(notifications, 1)
    }
    func testContinuityApplicationRemainsDurableAndRollsBackOnFailure() throws {
        let store = CountingSessionStore(root), session = session(store)
        defer { session.shutdown() }
        session.saveNow(); store.reset()
        let entry = HistoryEntry(title: "Remote", url: URL(string: "https://remote.test")!)
        store.fail = true
        XCTAssertThrowsError(try session.applyContinuity(bookmarks: [], history: [entry]))
        XCTAssertTrue(session.history.isEmpty)
        store.fail = false; try session.applyContinuity(bookmarks: [], history: [entry])
        XCTAssertEqual(try store.file.load().snapshot?.history, [entry])
        store.reset(); session.saveNow(); XCTAssertEqual(store.attempts, 0)
    }
    func testLateTitleUpdatesNewestVisitWithoutChangingIdentityOrRecency() throws {
        let session = session(); defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab), view = view(for: tab)
        view.pageURL = URL(string: "http://127.0.0.1:8768/late-title"); view.pageTitle = "127.0.0.1"
        commit(tab, view: view); tab.webView(view, didFinish: nil)
        let visit = try XCTUnwrap(session.history.first)
        view.pageTitle = "The actual page title"; tab.refresh(from: view)
        XCTAssertEqual(session.history.count, 1); XCTAssertEqual(session.history[0].title, "The actual page title")
        XCTAssertEqual(session.history[0].id, visit.id); XCTAssertEqual(session.history[0].visitedAt, visit.visitedAt)
    }
    func testLateTitleLeavesDifferentNewestVisitAloneAndKeepsHistoryCap() throws {
        let session = session(); defer { session.shutdown() }
        let entries = (0..<500).map { HistoryEntry(title: "Page \($0)", url: URL(string: "https://history.test/\($0)")!) }
        try session.applyContinuity(bookmarks: [], history: entries)
        let tab = try XCTUnwrap(session.selectedTab), view = view(for: tab)
        view.pageURL = URL(string: "https://history.test/new"); view.pageTitle = "Host"
        commit(tab, view: view); tab.webView(view, didFinish: nil)
        view.pageTitle = "Late title"; tab.refresh(from: view)
        XCTAssertEqual(session.history.count, 500); XCTAssertEqual(session.history[0].title, "Late title")
        let newestTab = session.addTab(load: false), newestView = self.view(for: newestTab)
        newestView.pageURL = URL(string: "https://other.test/new"); newestView.pageTitle = "Newest"
        commit(newestTab, view: newestView); newestTab.webView(newestView, didFinish: nil)
        let before = session.history
        view.pageTitle = "Too late for newest visit"; tab.refresh(from: view)
        XCTAssertEqual(session.history, before); XCTAssertEqual(session.history.count, 500)
        session.clearHistory(); view.pageTitle = "After clear"; tab.refresh(from: view)
        XCTAssertTrue(session.history.isEmpty)
    }
    func testSuggestionRankingTableCoversStrengthSourcesAndLimit() throws {
        let file = SessionFileStore(fileURL: root.appendingPathComponent("session.json"))
        let open = URL(string: "https://needle-open.test")!, weak = URL(string: "https://other.test/path/needle")!
        let saved = URL(string: "https://www.needle-saved.test")!, recent = URL(string: "https://needle-recent.test")!
        let label = URL(string: "https://docs.needle-label.test")!, title = URL(string: "https://reference.test")!
        let substring = URL(string: "https://substring.test")!
        try file.save(BrowserSnapshot(tabs: [TabRecord(title: "Open", url: open), TabRecord(title: "Weak open", url: weak)],
            bookmarks: [Bookmark(title: "Saved", url: saved), Bookmark(title: "Needle guide", url: title)],
            history: [HistoryEntry(title: "Recent", url: recent, visitedAt: Date(timeIntervalSince1970: 300)),
                      HistoryEntry(title: "Label", url: label, visitedAt: Date(timeIntervalSince1970: 200)),
                      HistoryEntry(title: "Hayneedle", url: substring)]))
        let session = session(file); defer { session.shutdown() }
        let rows: [(String, [URL])] = [
            ("  NEEDLE  ", [open, saved, recent, label, title]),
            ("www.needle", [open, saved, recent, label]),
            ("needle gu", [title]), ("path/needle", [weak]), ("Hayneedle", [substring]), (" \n ", [])
        ]
        for (query, expected) in rows { XCTAssertEqual(session.suggestions(for: query, isPrivate: false).map(\.url), expected, query) }
    }
    func testSuggestionTiesUseBookmarkThenRecencyThenURLAndDeduplicateTabs() throws {
        let file = SessionFileStore(fileURL: root.appendingPathComponent("session.json"))
        let urls = ["a", "b", "c", "d"].map { URL(string: "https://tie.test/\($0)")! }
        let first = TabRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "First", url: urls[0])
        let duplicate = TabRecord(title: "Duplicate", url: urls[0])
        let history = urls.enumerated().map { HistoryEntry(title: "History", url: $0.element, visitedAt: Date(timeIntervalSince1970: $0.offset == 2 ? 300 : 100)) }
        try file.save(BrowserSnapshot(tabs: [duplicate, first] + urls.dropFirst().reversed().map { TabRecord(url: $0) },
            bookmarks: [Bookmark(title: "Saved", url: urls[3])], history: history))
        let session = session(file); defer { session.shutdown() }
        for _ in 0..<5 {
            let results = session.suggestions(for: "tie", isPrivate: false)
            XCTAssertEqual(results.map(\.url), [urls[3], urls[2], urls[0], urls[1]])
            XCTAssertEqual(results.first { $0.url == urls[0] }?.tabID, first.id)
        }
    }
    func testRankedPrivateSuggestionsUseOnlyPrivateOpenTabsInThisProfile() throws {
        let session = session(), other = self.session(); defer { session.shutdown(); other.shutdown() }
        let regular = session.addTab(url: URL(string: "https://match.test/regular"), load: false)
        session.toggleBookmark()
        try session.applyContinuity(bookmarks: session.bookmarks, history: [HistoryEntry(title: "Match history", url: URL(string: "https://match.test/history")!)])
        let privateTab = session.addTab(url: URL(string: "https://match.test/private"), isPrivate: true, load: false)
        let second = session.addTab(url: URL(string: "https://match.test/another"), isPrivate: true, load: false)
        XCTAssertEqual(session.suggestions(for: "MATCH", isPrivate: true).map(\.url), [second.url!, privateTab.url!])
        XCTAssertFalse(session.suggestions(for: "match", isPrivate: false).contains { $0.tabID == privateTab.id })
        XCTAssertTrue(other.suggestions(for: "match", isPrivate: false).isEmpty)
        XCTAssertEqual(session.suggestions(for: "regular", isPrivate: false).first?.tabID, regular.id)
    }
    func testSelectedProcessReloadsOnceAndUsesThirtySecondLoopGuard() throws {
        let session = session(); defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab), view = view(for: tab)
        view.pageURL = URL(string: "https://recovery.test")
        commit(tab, view: view)
        var now = 100.0; tab.recoveryClock = { now }
        tab.webViewWebContentProcessDidTerminate(view)
        XCTAssertEqual(view.reloads, 1); XCTAssertNil(tab.errorMessage)
        commit(tab, view: view)
        now = 110; tab.webViewWebContentProcessDidTerminate(view)
        XCTAssertEqual(view.reloads, 1); XCTAssertTrue(tab.errorMessage?.contains("Reload to continue") == true)
        now = 131; tab.activate()
        XCTAssertEqual(view.reloads, 2)
    }
    func testBackgroundCrashWaitsForSelectionAndInactiveProfileWaitsForActivation() throws {
        let session = session(); defer { session.shutdown() }
        let tab = session.addTab(select: false, load: false), view = view(for: tab)
        view.pageURL = URL(string: "https://recovery.test/background"); commit(tab, view: view)
        tab.webViewWebContentProcessDidTerminate(view); XCTAssertEqual(view.reloads, 0)
        session.selectTab(tab.id); XCTAssertEqual(view.reloads, 1)
        let inactive = session.addTab(load: false), inactiveView = self.view(for: inactive)
        inactiveView.pageURL = URL(string: "https://recovery.test/inactive"); commit(inactive, view: inactiveView)
        session.setProfileActive(false); inactive.webViewWebContentProcessDidTerminate(inactiveView)
        XCTAssertEqual(inactiveView.reloads, 0)
        session.setProfileActive(true); XCTAssertEqual(inactiveView.reloads, 1)
    }
    func testPOSTPendingPOSTUnknownAndEditedDocumentsKeepManualReloadFallback() throws {
        let session = session(); defer { session.shutdown() }
        for method in ["POST", "PUT", "UNKNOWN", "EDITED", "PENDING_POST"] {
            let tab = session.addTab(load: false), view = view(for: tab)
            view.pageURL = URL(string: "https://recovery.test/\(method)")
            if method != "UNKNOWN" { commit(tab, view: view, method: ["EDITED", "PENDING_POST"].contains(method) ? "GET" : method) }
            if method == "EDITED" { tab.recordFieldEdit() }
            if method == "PENDING_POST" {
                var request = URLRequest(url: view.pageURL!); request.httpMethod = "POST"
                tab.recordAllowedMainFrameNavigation(request)
            }
            tab.webViewWebContentProcessDidTerminate(view)
            XCTAssertEqual(view.reloads, 0, method)
            XCTAssertTrue(tab.errorMessage?.contains("Reload to continue") == true, method)
        }
    }
    func testPrivateRecoveryKeepsEphemeralStoreAndExportsNoMetadata() throws {
        let store = CountingSessionStore(root), session = session(store); defer { session.shutdown() }
        let tab = session.addTab(isPrivate: true, load: false), view = view(for: tab)
        view.pageURL = URL(string: "https://private.test/recover"); view.pageTitle = "Private recovery"
        commit(tab, view: view)
        let dataStore = view.configuration.websiteDataStore
        XCTAssertFalse(dataStore.isPersistent)
        session.saveNow(); store.reset()
        var notifications = 0; session.onContinuityChange = { notifications += 1 }
        tab.webViewWebContentProcessDidTerminate(view)
        XCTAssertEqual(view.reloads, 1); XCTAssertTrue(view.configuration.websiteDataStore === dataStore)
        tab.webView(view, didFinish: nil); session.saveNow()
        XCTAssertTrue(session.history.isEmpty); XCTAssertFalse(session.snapshot().tabs.contains { $0.id == tab.id })
        XCTAssertEqual(store.writes, 0); XCTAssertEqual(notifications, 0)
        tab.close(); tab.webViewWebContentProcessDidTerminate(view); XCTAssertEqual(view.reloads, 1)
    }
}
