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
        XCTAssertEqual(tab.title, "Data navigation fixture")
        try await body(session, tab)
    }

    private func waitUntil(_ ready: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !ready() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(ready(), "Expected navigation or download did not complete", file: file, line: line)
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
