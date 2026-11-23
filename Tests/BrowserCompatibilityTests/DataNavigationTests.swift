import BrowserCore
import BrowserEngine
import WebKit
import XCTest
#if os(macOS)
@testable import PersonalBrowser
#else
@testable import OrivMobile
#endif

@MainActor final class DataNavigationTests: XCTestCase {
    private let fixture = URL(string: "http://127.0.0.1:8768/data-navigation")!
    private let dataAddress = "data:text/html,%3Ctitle%3EData%20destination%3C/title%3E"

    private func withFixture(_ body: (BrowserSession, BrowserTab) async throws -> Void) async throws {
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil),
                                     settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let tab = session.addTab(configuration: configuration, load: false)
        #if os(macOS)
        let delegate = MacWebUIDelegate(session: session, tab: tab)
        #else
        let delegate = MobileWebDelegate(session: session, tab: tab)
        #endif
        tab.webView.uiDelegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        let detach = try mountWebFixture(tab)
        defer { detach() }
        try await waitForWebFixture(tab, at: fixture) { tab.navigate(to: fixture) }
        try await body(session, tab)
    }

    private func waitUntil(_ ready: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitForFixtureCondition("data navigation or download", timeout: 30, file: file, line: line, ready)
    }

    func testRefusedAddressPreservesRetryDestination() async throws {
        let session = BrowserSession(dataStore: .nonPersistent(), settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        let detach = try mountWebFixture(tab)
        defer { detach() }
        let refused = try XCTUnwrap(URL(string: "http://127.0.0.1:9/unreachable"))
        for attempt in 0..<2 {
            if attempt == 0 { tab.navigate(to: refused) }
            else { tab.reload() }
            try await waitForFixtureCondition("refused address error", timeout: 10) { tab.errorMessage != nil && !tab.isLoading }
            XCTAssertEqual(tab.url, refused)
            XCTAssertFalse(tab.isLoading)
            XCTAssertNil(tab.httpWarningURL)
        }
    }

    func testFrequentHomeDestinationsExcludeBookmarksAndPrivateSessions() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionFileStore(fileURL: root.appendingPathComponent("session.json"))
        let bookmarked = URL(string: "https://bookmarked.example")!
        let frequent = URL(string: "https://frequent.example")!
        try store.save(BrowserSnapshot(bookmarks: [Bookmark(title: "Saved", url: bookmarked)], history: [
            HistoryEntry(title: "Saved", url: bookmarked, visitCount: 9),
            HistoryEntry(title: "Frequent", url: frequent, visitCount: 3),
            HistoryEntry(title: "Frequent page", url: URL(string: "https://www.frequent.example/?tab=2")!, visitCount: 2),
            HistoryEntry(title: "Other", url: URL(string: "https://other.example/a")!, visitCount: 1)
        ]))
        let session = BrowserSession(store: store, dataStore: .nonPersistent(), settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        let tiles = await session.frequentHistory(excluding: [bookmarked], isPrivate: false)
        // Pages of one site collapse into its most visited page.
        XCTAssertEqual(tiles.map(\.url), [frequent, URL(string: "https://other.example/a")!])
        let privateTiles = await session.frequentHistory(excluding: [], isPrivate: true)
        XCTAssertTrue(privateTiles.isEmpty)
        let external = BrowserSession(store: store, dataStore: .nonPersistent(), settings: BrowserSettings(defaults: nil), externalPrivate: true)
        defer { external.shutdown() }
        let externalTiles = await external.frequentHistory(excluding: [], isPrivate: false)
        XCTAssertTrue(externalTiles.isEmpty)
        XCTAssertFalse(session.tabs.contains(where: \.isInstantiated))
        session.clearHistory()
        let clearedTiles = await session.frequentHistory(excluding: [], isPrivate: false)
        XCTAssertTrue(clearedTiles.isEmpty)
        XCTAssertEqual(session.bookmarks.map(\.url), [bookmarked])
    }

    func testContentCannotReplaceTopFrameWithDataDocument() async throws {
        let attempts = [
            ("script", "location = document.querySelector('#link').href"),
            ("link", "document.querySelector('#link').click()"),
            ("form", "document.querySelector('#form').submit()"),
            ("meta-refresh", """
            const meta = document.createElement('meta');
            meta.httpEquiv = 'refresh';
            meta.content = '0;url=' + document.querySelector('#link').href;
            document.head.append(meta);
            """)
        ]
        for (name, script) in attempts {
            try await withFixture { _, tab in
                _ = try await tab.webView.evaluateJavaScript("(() => { \(script); return true; })()")
                // No commit callback is expected for a blocked attempt. Give WebKit a
                // bounded observation window, including the zero-delay refresh timer.
                let deadline = ContinuousClock.now + .milliseconds(750)
                while tab.webView.backForwardList.currentItem?.url == fixture && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                let committed = tab.webView.backForwardList.currentItem?.url
                let documentURL = try await tab.webView.evaluateJavaScript("location.href") as? String
                print("data-navigation \(name): committed \(committed?.scheme ?? "none"), \(tab.title)")
                XCTAssertEqual(committed, fixture, name)
                XCTAssertEqual(documentURL, fixture.absoluteString, name)
                XCTAssertEqual(tab.title, "Data navigation fixture", name)
            }
        }
    }

    func testWindowOpenCannotCommitDataDocument() async throws {
        try await withFixture { session, tab in
            let initialTabs = session.tabs.map(\.id)
            _ = try await tab.webView.evaluateJavaScript("""
                const link = document.querySelector('#link');
                window.open(link.href);
                link.target = '_blank';
                link.click();
                void 0;
                """)
            let deadline = ContinuousClock.now + .milliseconds(750)
            while session.tabs.map(\.id) == initialTabs && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(session.tabs.map(\.id), initialTabs)
            XCTAssertEqual(tab.webView.url, fixture)
        }
    }

    func testDataIframeImageAndDownloadStillWork() async throws {
        try await withFixture { _, tab in
            let embedded = try await tab.webView.evaluateJavaScript("""
                window.dataIframeLoaded === true && document.querySelector('#image').naturalWidth === 1
                """) as? Bool
            XCTAssertEqual(embedded, true)
            let sink = DataDownloadSink()
            defer { try? FileManager.default.removeItem(at: sink.destination) }
            tab.onDownload = { $0.delegate = sink }
            _ = try await tab.webView.evaluateJavaScript("document.querySelector('#download').click()")
            try await waitUntil { sink.finished }
            XCTAssertNil(sink.error)
            XCTAssertEqual(try String(contentsOf: sink.destination, encoding: .utf8), "fixture-download")
            XCTAssertEqual(tab.webView.url, fixture)
        }
    }

    func testAddressSubmissionCanOpenDataDocument() async throws {
        try await withFixture { session, tab in
            try session.navigate(dataAddress)
            try await waitUntil { tab.title == "Data destination" && !tab.isLoading }
            XCTAssertEqual(tab.webView.url?.absoluteString, dataAddress)
            XCTAssertNil(tab.record.url)
            session.toggleBookmark()
            let saved = try XCTUnwrap(session.snapshot().bookmarks.first)
            XCTAssertEqual(saved.url.absoluteString, dataAddress)
            session.openSavedPage(saved.url, inNewTab: true)
            let reopened = try XCTUnwrap(session.selectedTab)
            XCTAssertNotEqual(reopened.id, tab.id)
            let detach = try mountWebFixture(reopened)
            defer { detach() }
            try await waitUntil { reopened.title == "Data destination" && !reopened.isLoading }
        }
    }
}

@MainActor private final class DataDownloadSink: NSObject, WKDownloadDelegate {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var finished = false
    var error: Error?

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        completionHandler(destination)
    }
    func downloadDidFinish(_ download: WKDownload) { finished = true }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        self.error = error
        finished = true
    }
}
