import AppKit
import Observation
import SwiftUI
import XCTest
@testable import PersonalBrowser

@MainActor @Observable private final class CompletionState {
    var text = ""
    var editing = false
    var completion: String?
    var focus = 0
    var inlineActive = false
}
private struct CompletionFixture: View {
    @Bindable var state: CompletionState
    var body: some View {
        AddressField(text: $state.text, isEditing: $state.editing, focusRequest: state.focus,
                     submit: { true }, cancel: {}, completion: state.completion,
                     onInlineCompletionChange: { state.inlineActive = $0 }).frame(width: 500, height: 36)
    }
}
@MainActor final class AddressCompletionTests: BackgroundUITestCase {
    private func sendKey(_ code: UInt16, characters: String, window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.sendEvent(event)
    }
    func testInlineSuffixSelectionAcceptanceAndDeletionSuppression() async throws {
        let state = CompletionState()
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0,y: 0,width: 600,height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentViewController = NSHostingController(rootView: CompletionFixture(state: state))
        BackgroundUIMode.show(window)
        state.focus += 1
        try await Task.sleep(for: .milliseconds(150))
        let editor = try XCTUnwrap(window.firstResponder as? PrivacyAddressEditor)
        editor.insertText("exa", replacementRange: editor.selectedRange())
        state.completion = "example.test"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "example.test")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 9))
        XCTAssertEqual(editor.inlineCompletionRange, NSRange(location: 3, length: 9))
        XCTAssertTrue(state.inlineActive, "Tab chip state should be active while inline completion is offered")
        try sendKey(51, characters: "\u{7f}", window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "exa", "Backspace must not re-complete")
        XCTAssertEqual(state.text, "exa")
        XCTAssertNil(editor.inlineCompletionRange)
        XCTAssertFalse(state.inlineActive)
        editor.insertText("m", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "example.test")
        XCTAssertEqual(editor.inlineCompletionRange, NSRange(location: 4, length: 8))
        XCTAssertTrue(state.inlineActive)
        try sendKey(124, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.text, "example.test")
        XCTAssertEqual(editor.selectedRange().length, 0)
        XCTAssertNil(editor.inlineCompletionRange)
        XCTAssertFalse(state.inlineActive)
    }

    func testTabAcceptsInlineCompletionAndMarkedTextSuppressesHighlight() async throws {
        let state = CompletionState()
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentViewController = NSHostingController(rootView: CompletionFixture(state: state))
        BackgroundUIMode.show(window)
        state.focus += 1
        try await Task.sleep(for: .milliseconds(150))
        let editor = try XCTUnwrap(window.firstResponder as? PrivacyAddressEditor)
        editor.insertText("dev", replacementRange: editor.selectedRange())
        state.completion = "developer.apple.com"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "developer.apple.com")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 16))
        XCTAssertTrue(state.inlineActive)
        // Marked text (IME composition) must suppress inline completion highlight.
        editor.setMarkedText("d", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(editor.inlineCompletionRange)
        XCTAssertFalse(state.inlineActive)
        editor.unmarkText()
        editor.string = ""
        editor.insertText("dev", replacementRange: NSRange(location: 0, length: 0))
        state.completion = "developer.apple.com"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "developer.apple.com")
        try sendKey(48, characters: "\t", window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.text, "developer.apple.com")
        XCTAssertEqual(editor.selectedRange().length, 0)
        XCTAssertFalse(state.inlineActive)
    }
}
