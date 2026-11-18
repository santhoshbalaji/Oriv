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
}
private struct CompletionFixture: View {
    @Bindable var state: CompletionState
    var body: some View {
        AddressField(text: $state.text, isEditing: $state.editing, focusRequest: state.focus,
                     submit: { true }, cancel: {}, completion: state.completion).frame(width: 500, height: 32)
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
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("exa", replacementRange: editor.selectedRange())
        state.completion = "example.test"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "example.test")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 9))
        try sendKey(51, characters: "\u{7f}", window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "exa", "Backspace must not re-complete")
        XCTAssertEqual(state.text, "exa")
        editor.insertText("m", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "example.test")
        try sendKey(124, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.text, "example.test")
        XCTAssertEqual(editor.selectedRange().length, 0)
    }
}
