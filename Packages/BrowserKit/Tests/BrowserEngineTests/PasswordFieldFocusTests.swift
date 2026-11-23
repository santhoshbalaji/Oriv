#if os(macOS)
import WebKit
import XCTest
@testable import BrowserEngine

@MainActor final class PasswordFieldFocusTests: XCTestCase {
    func testClassificationAndNativeGlyphInBothStores() async throws {
        for isPrivate in [false, true] {
            let tab = BrowserTab(isPrivate: isPrivate, dataStore: .nonPersistent())
            defer { tab.close() }
            let webView = tab.webView
            webView.loadHTMLString("""
                <form>
                <input id="login" type="email" autocomplete="email">
                <input id="current" type="password">
                <input id="new" type="password" autocomplete="section-test new-password">
                <input id="otp" inputmode="numeric" autocomplete="one-time-code">
                <input id="name" autocomplete="family-name">
                <input id="readonly" type="password" readonly>
                </form>
                """, baseURL: URL(string: "http://localhost"))
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(10)
            while (try? await webView.evaluateJavaScript("!!document.querySelector('#login')")) as? Bool != true,
                  clock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }

            let pageWorldGlyph = try await webView.evaluateJavaScript("'autofillButtonType' in HTMLInputElement.prototype")
            XCTAssertEqual(pageWorldGlyph as? Bool, false, "Only the isolated world may control the glyph")
            let supported = try await webView.callAsyncJavaScript(
                "return 'autofillButtonType' in HTMLInputElement.prototype;",
                arguments: [:], contentWorld: PasswordFieldFocus.world) as? Bool == true
            for (id, expected) in [
                ("login", PasswordFieldFocus.Kind.username), ("current", .password),
                ("new", .newPassword), ("otp", .otp), ("name", nil), ("readonly", nil)
            ] {
                let glyph = try await webView.callAsyncJavaScript("""
                    document.getElementById(id).focus();
                    return document.activeElement?.autofillButtonType === "credentials";
                    """, arguments: ["id": id], contentWorld: PasswordFieldFocus.world)
                let focusDeadline = clock.now + .seconds(3)
                while tab.passwordFields.kind != expected, clock.now < focusDeadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                let shouldShowGlyph = supported && expected?.supportsPasswordFill == true
                XCTAssertEqual(tab.passwordFields.kind, expected, id)
                XCTAssertEqual(tab.passwordFields.showsGlyph, shouldShowGlyph, id)
                XCTAssertEqual(glyph as? Bool, shouldShowGlyph, id)
            }
            let oldGlyph = try await webView.callAsyncJavaScript(
                "return document.getElementById('current').autofillButtonType === 'credentials';",
                arguments: [:], contentWorld: PasswordFieldFocus.world)
            XCTAssertEqual(oldGlyph as? Bool, false, "Blur removes the glyph")
            print("PASSWORDS_GLYPH supported=\(supported) privateTab=\(isPrivate)")
        }
    }
}
#endif
