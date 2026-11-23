import AppKit
import BrowserEngine
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class ApplePasswordsTests: BackgroundUITestCase {
    private final class RecordingPicker: PasswordPickerRequesting {
        weak var requestedView: WKWebView?

        func requestPicker(in webView: WKWebView) async -> Bool {
            requestedView = webView
            return true
        }
    }

    private func mount(_ webView: WKWebView) -> NSWindow {
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        BackgroundUIMode.show(window, key: true)
        return window
    }

    private func focusPassword(in tab: BrowserTab, window: NSWindow) async throws {
        let webView = tab.webView
        tab.navigate(to: try XCTUnwrap(URL(string: "http://127.0.0.1:8768/login")))
        try await waitForFixtureCondition("local login fixture", timeout: 15) {
            tab.title == "AutoFill check" && !tab.isLoading
        }
        XCTAssertTrue(window.makeFirstResponder(webView))
        let focused = try await webView.evaluateJavaScript("""
            const input = document.querySelector('input[type=password]');
            input.focus();
            document.activeElement === input;
            """)
        XCTAssertEqual(focused as? Bool, true)
        try await waitForFixtureCondition("classified password", timeout: 5) {
            tab.passwordFields.kind == .password
        }
    }

    func testFindsOnlyAnEnabledPasswordsActionInTheContextMenuAutoFillSubmenu() throws {
        let root = NSMenu()
        root.autoenablesItems = false
        let action = #selector(NSResponder.showContextMenuForSelection(_:))
        let paste = root.addItem(withTitle: "Paste", action: action, keyEquivalent: "")
        let decoy = root.addItem(withTitle: "Passwords…", action: action, keyEquivalent: "")
        root.addItem(.separator())
        XCTAssertNil(ApplePasswords.passwordsItem(in: root))

        let autoFill = root.addItem(withTitle: "AutoFill", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        autoFill.submenu = submenu
        for title in ["Contact…", "Passwords…", "Credit Card…"] {
            submenu.addItem(withTitle: title, action: action, keyEquivalent: "")
        }
        let passwords = try XCTUnwrap(submenu.item(withTitle: decoy.title))
        XCTAssertTrue(ApplePasswords.passwordsItem(in: root) === passwords)
        XCTAssertFalse(ApplePasswords.passwordsItem(in: root) === paste)
        passwords.isEnabled = false
        XCTAssertNil(ApplePasswords.passwordsItem(in: root))
        passwords.isEnabled = true
        passwords.isHidden = true
        XCTAssertNil(ApplePasswords.passwordsItem(in: root))
        passwords.isHidden = false
        passwords.title = "Passwords..."
        autoFill.title = "Localized AutoFill"
        autoFill.identifier = NSUserInterfaceItemIdentifier("_NSMenuItemAutoFillIdentifier")
        XCTAssertTrue(ApplePasswords.passwordsItem(in: root) === passwords)
        autoFill.isHidden = true
        XCTAssertNil(ApplePasswords.passwordsItem(in: root))
    }

    func testRequestsPickerOnlyForTheSelectedFocusedField() async throws {
        try XCTSkipUnless(BackgroundUIMode.isEnabled, "Passwords tests run off-screen only")
        let controller = BrowserController(testing: true)
        defer { controller.shutdown() }
        let tab = controller.session.addTab(isPrivate: true, load: false)
        XCTAssertTrue(tab.webView is PasswordContextWebView)
        let window = mount(tab.webView)
        defer { tab.close(); window.close() }
        try await focusPassword(in: tab, window: window)

        let picker = RecordingPicker()
        let requested = await ApplePasswords.requestFill(in: tab, window: window, picker: picker) { true }
        XCTAssertTrue(requested)
        XCTAssertTrue(picker.requestedView === tab.webView)

        let requestedInBackground = await ApplePasswords.requestFill(in: tab, window: window, picker: AppKitPasswordPicker()) { true }
        XCTAssertFalse(requestedInBackground)

        picker.requestedView = nil
        let requestedAfterTabChange = await ApplePasswords.requestFill(in: tab, window: window, picker: picker) { false }
        XCTAssertFalse(requestedAfterTabChange)
        XCTAssertNil(picker.requestedView)

        _ = try await tab.webView.evaluateJavaScript("document.querySelector('input[type=password]').remove()")
        let requestedAfterRemoval = await ApplePasswords.requestFill(in: tab, window: window, picker: picker) { true }
        XCTAssertFalse(requestedAfterRemoval)
        XCTAssertNil(picker.requestedView)
    }
}
