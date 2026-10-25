import BrowserCore
import BrowserEngine
import ProductivityKit
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class ContextCaptureTests: XCTestCase {
    func testCaptureRetainsSourceAndSelectionWithoutFormOrHiddenData() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        tab.navigate(to: URL(string: "http://127.0.0.1:8768/context")!)
        let deadline = Date.now.addingTimeInterval(15)
        while (tab.title != "Designing a calmer working week" || tab.isLoading) && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(tab.title, "Designing a calmer working week")
        _ = try await tab.webView.evaluateJavaScript("const r=document.createRange(); r.selectNodeContents(document.querySelector('#selected')); getSelection().removeAllRanges(); getSelection().addRange(r); true")
        let capture = try await PageCaptureService.capture(tab)
        XCTAssertTrue(capture.text.contains("Save useful research"))
        XCTAssertTrue(capture.text.contains("தமிழ்"))
        XCTAssertTrue(capture.selection.hasPrefix("Start with one clear next action"))
        XCTAssertFalse(capture.text.contains("SECRET"))
        XCTAssertFalse(capture.text.contains("Navigation clutter"))
        XCTAssertFalse(capture.text.contains("Footer clutter"))
        let store = try WorkspaceStore()
        let id = try store.save(capture, purpose: "Plan next week", kind: .selection)
        XCTAssertEqual(store.sources(for: id).first?.text, capture.selection)
        XCTAssertEqual(store.item(id)?.purpose, "Plan next week")
    }
    func testPrivateCaptureIsRejectedBeforeReadingPage() async throws {
        let tab = BrowserTab(record: TabRecord(url: URL(string: "https://example.com")), isPrivate: true, dataStore: .nonPersistent())
        defer { tab.close() }
        do { _ = try await PageCaptureService.capture(tab); XCTFail("Private content must not persist") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Private")) }
    }
    func testReminderRouteWaitsForSceneAndRetainsWindowOpeningAction() {
        let delegate = AppDelegate()
        let itemID = UUID()
        delegate.openReminder(itemID: itemID)
        let controller = BrowserController()
        var opens = 0
        delegate.connect(controller: controller) { opens += 1 }
        XCTAssertEqual(controller.selectedItemID, itemID)
        XCTAssertEqual(opens, 1)
        let secondID = UUID()
        delegate.openReminder(itemID: secondID)
        XCTAssertEqual(controller.selectedItemID, secondID)
        XCTAssertEqual(opens, 2)
    }
}
