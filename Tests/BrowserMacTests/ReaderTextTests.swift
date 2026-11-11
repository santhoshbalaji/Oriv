import BrowserCore
import BrowserEngine
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class ReaderTextTests: BackgroundUITestCase {
    func testReaderRetainsTextAndSelectionWithoutFormOrHiddenData() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        tab.navigate(to: URL(string: "http://127.0.0.1:8768/context")!)
        let deadline = Date.now.addingTimeInterval(15)
        while (tab.title != "Designing a calmer working week" || tab.isLoading) && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(tab.title, "Designing a calmer working week")
        _ = try await tab.webView.evaluateJavaScript("const r=document.createRange(); r.selectNodeContents(document.querySelector('#selected')); getSelection().removeAllRanges(); getSelection().addRange(r); true")
        let capture = try await PageCaptureService.readerText(tab)
        XCTAssertTrue(capture.text.contains("Save useful research"))
        XCTAssertTrue(capture.text.contains("தமிழ்"))
        XCTAssertTrue(capture.selection.hasPrefix("Start with one clear next action"))
        XCTAssertFalse(capture.text.contains("SECRET"))
        XCTAssertFalse(capture.text.contains("Navigation clutter"))
        XCTAssertFalse(capture.text.contains("Footer clutter"))
    }
}
