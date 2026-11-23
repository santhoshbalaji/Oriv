import AppKit
import BrowserEngine
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class ApplePasswordsTests: BackgroundUITestCase {
    private struct MissingMenuPicker: PasswordPickerRequesting {
        let menu: NSMenu

        func requestPicker(in webView: WKWebView) -> Bool {
            ApplePasswords.enabledPasswordsItem(in: menu) != nil
        }
    }

    private final class RecordingPicker: PasswordPickerRequesting {
        weak var requestedView: WKWebView?

        func requestPicker(in webView: WKWebView) -> Bool {
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

    func testProbeAutoFillMenuInBackground() async throws {
        try XCTSkipUnless(BackgroundUIMode.isEnabled, "Passwords probes run off-screen only")
        let tab = BrowserTab(isPrivate: true)
        let window = mount(tab.webView)
        defer { tab.close(); window.close() }
        try await focusPassword(in: tab, window: window)

        // Inventory only. Do not resolve or dispatch any AppKit action.
        let submenu = ApplePasswords.autoFillSubmenu(in: NSApp.mainMenu)
        for item in submenu?.items ?? [] {
            print("PASSWORDS_PROBE title=\(item.title.debugDescription) enabled=\(item.isEnabled)")
        }
        let passwords = submenu.flatMap { ApplePasswords.passwordsItem(in: $0) }
        print("PASSWORDS_PROBE AutoFill exists=\(submenu != nil) Passwords… exists=\(passwords != nil) enabled=\(passwords?.isEnabled == true)")
    }

    func testRequestsPickerAndFallsBackWithMissingMenuItem() async throws {
        try XCTSkipUnless(BackgroundUIMode.isEnabled, "Passwords tests run off-screen only")
        let tab = BrowserTab(dataStore: .nonPersistent())
        let window = mount(tab.webView)
        defer { tab.close(); window.close() }
        try await focusPassword(in: tab, window: window)

        let picker = RecordingPicker()
        let requested = await ApplePasswords.requestFill(in: tab, window: window, picker: picker) { true }
        XCTAssertTrue(requested)
        XCTAssertTrue(picker.requestedView === tab.webView)

        let root = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu()
        root.addItem(edit)
        let autoFill = NSMenuItem(title: "AutoFill", action: nil, keyEquivalent: "")
        autoFill.submenu = NSMenu()
        edit.submenu?.addItem(autoFill)
        let missing = MissingMenuPicker(menu: root)
        let requestedWithMissingItem = await ApplePasswords.requestFill(in: tab, window: window, picker: missing) { true }
        XCTAssertFalse(requestedWithMissingItem)

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
