import BrowserCore
import BrowserEngine
import SwiftUI
import UIKit
import XCTest
@testable import OrivMobile

@MainActor final class MobileSuggestionTests: XCTestCase {
    func testNativeCompletionCoordinatorSuppressesDeletionAndClear() {
        let parent = MobileAddressField(text: .constant("exa"), editing: .constant(true), submit: {})
        let coordinator = parent.makeCoordinator()
        let field = MobilePrivacyAddressField()
        XCTAssertTrue(coordinator.textField(field, shouldChangeCharactersIn: NSRange(location: 3, length: 9), replacementString: ""))
        XCTAssertTrue(coordinator.suppressCompletion)
        XCTAssertTrue(coordinator.textField(field, shouldChangeCharactersIn: NSRange(location: 3, length: 0), replacementString: "m"))
        XCTAssertFalse(coordinator.suppressCompletion)
        XCTAssertTrue(coordinator.textFieldShouldClear(field)); XCTAssertTrue(coordinator.suppressCompletion)
        field.hasInlineCompletion = false
        XCTAssertFalse(field.keyCommands?.contains { $0.input == "\t" } == true)
        field.hasInlineCompletion = true
        XCTAssertTrue(field.keyCommands?.contains { $0.input == "\t" } == true)
    }
    func testSharedRowsGroupSwitchBookmarkHistoryAndSearchWithKeyboardSelection() async throws {
        let session = BrowserSession(dataStore: .nonPersistent(), settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        session.settings.searchEngine = .google
        let tab = session.addTab(url: URL(string: "https://example.test/open")!, load: false)
        _ = session.importBookmarks([Bookmark(title: "Example saved", url: URL(string: "https://example.test/saved")!)])
        let model = AddressSuggestions()
        await model.update("exa", session: session, isPrivate: false)
        XCTAssertEqual(model.rows.map(\.source), [.tab, .bookmark, .search])
        XCTAssertEqual(model.rows.first?.tabID, tab.id)
        XCTAssertEqual(model.rows.last?.url, session.settings.searchEngine.searchURL("exa"))
        XCTAssertEqual(model.completion, "example.test")
        model.move(1); XCTAssertEqual(model.selected, 0)
        model.move(1); XCTAssertEqual(model.selected, 1)
        model.move(-1); XCTAssertEqual(model.selected, 0)
        await model.update("", session: session, isPrivate: false)
        XCTAssertTrue(model.rows.isEmpty); XCTAssertNil(model.completion)
    }
}
