import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class BrowserChromeTests: XCTestCase {
    func testThemeColorTracksLiveChangesAndStopsObservingPreviousTab() async throws {
        let first = makeWebView(), second = makeWebView()
        let chrome = PageChrome()
        first.loadHTMLString("<meta name='theme-color' content='#ffffff'><body style='background:white'>Light</body>", baseURL: nil)
        second.loadHTMLString("<meta name='theme-color' content='#111111'><body style='background:#111111'>Dark</body>", baseURL: nil)
        try await wait { first.themeColor != nil && second.themeColor != nil }
        chrome.observe(first)
        XCTAssertFalse(chrome.isDark)
        _ = try await first.evaluateJavaScript("document.querySelector('meta').content = '#111111'")
        try await wait { chrome.isDark }
        chrome.observe(second)
        _ = try await first.evaluateJavaScript("document.querySelector('meta').content = '#ffffff'")
        try await wait { (first.themeColor?.usingColorSpace(.sRGB)?.redComponent ?? 0) > 0.99 }
        XCTAssertTrue(chrome.isDark, "A background tab must not recolor the displayed chrome")
        chrome.observe(nil)
        XCTAssertTrue(chrome.isDark, "Start page resets to T3 chrome")
    }

    func testPageWithoutThemeColorUsesUnderPageBackground() async throws {
        let view = makeWebView(), chrome = PageChrome()
        view.loadHTMLString("<body style='background:#ffffff'>Fallback</body>", baseURL: nil)
        try await wait { !view.isLoading && view.url != nil }
        chrome.observe(view)
        try await wait { !chrome.isDark }
        _ = try await view.evaluateJavaScript("document.body.style.background = '#111111'")
        try await wait { chrome.isDark }
    }

    func testThemeWinsOverBackgroundAndMidtoneUsesHighContrastForeground() async throws {
        let web = makeWebView(), chrome = PageChrome()
        web.loadHTMLString("<meta name='theme-color' content='#1f6f5c'><body style='background:#ffffff'>Theme</body>", baseURL: nil)
        try await wait { web.themeColor != nil }
        chrome.observe(web)
        let color = try XCTUnwrap(NSColor(chrome.color).usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 31.0 / 255, accuracy: 0.002)
        XCTAssertEqual(color.greenComponent, 111.0 / 255, accuracy: 0.002)
        XCTAssertTrue(chrome.isDark)
        XCTAssertGreaterThanOrEqual(1.05 / (chrome.luminance + 0.05), 4.5)
        XCTAssertEqual(chrome.contrasting(chrome.color), chrome.foreground)
        _ = try await web.evaluateJavaScript("document.querySelector('meta').content = '#808080'")
        try await wait { !chrome.isDark }
        XCTAssertGreaterThanOrEqual((chrome.luminance + 0.05) / 0.05, 4.5)
    }

    func testComputedBackgroundFallbackAndCanvasWithoutColour() async throws {
        let web = makeWebView(), chrome = PageChrome()
        web.loadHTMLString("<body style='background:#1f6f5c'>Computed fallback</body>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        web.underPageBackgroundColor = .clear
        chrome.observe(web)
        try await wait { chrome.luminance > 0.05 }
        let color = try XCTUnwrap(NSColor(chrome.color).usingColorSpace(.sRGB))
        XCTAssertEqual(color.greenComponent, 111.0 / 255, accuracy: 0.002)
        chrome.observe(nil)
        XCTAssertEqual(chrome.luminance, 0)
        chrome.observe(makeWebView())
        XCTAssertEqual(chrome.luminance, 0, "An unloaded page must not supply the default WebKit background")
    }

    func testScrollEdgeAppearsOnlyAfterScrollingAndDetachesFromOldTab() async throws {
        let web = makeWebView(), next = makeWebView(), chrome = PageChrome()
        web.loadHTMLString("<body style='height:3000px;background:white'>Scroll</body>", baseURL: nil)
        next.loadHTMLString("<body style='height:3000px'>Next</body>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil && !next.isLoading && next.url != nil }
        chrome.observe(web)
        XCTAssertFalse(chrome.hasScrolled)
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 300)")
        try await wait { chrome.hasScrolled }
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 0)")
        try await wait { !chrome.hasScrolled }
        chrome.observe(next)
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 300)")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(chrome.hasScrolled)
    }

    func testPrivatePageAlwaysUsesCanvasDespiteLiveThemeChanges() async throws {
        let web = makeWebView(), chrome = PageChrome()
        web.loadHTMLString("<meta name='theme-color' content='#ffffff'><body>Private</body>", baseURL: nil)
        try await wait { web.themeColor != nil }
        chrome.observe(web, isPrivate: true)
        XCTAssertEqual(chrome.luminance, 0)
        _ = try await web.evaluateJavaScript("document.querySelector('meta').content = '#1f6f5c'")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(chrome.luminance, 0)
        XCTAssertTrue(chrome.isDark)
    }

    func testTransparentTitlebarHasNoDividerAndRemainsWindowLocal() {
        let window = NSWindow(), other = NSWindow()
        window.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer { window.close(); other.close() }
        let otherColor = other.backgroundColor
        let bridge = BrowserTitlebar.TitlebarView()
        bridge.color = .white
        bridge.reduceMotion = true
        window.contentView!.addSubview(bridge)
        bridge.configure()
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertEqual(window.backgroundColor, .white)
        XCTAssertEqual(other.backgroundColor, otherColor)
    }

    func testTitlebarColourAnimationAndReduceMotionCancellation() async throws {
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let bridge = BrowserTitlebar.TitlebarView()
        bridge.color = .white
        bridge.reduceMotion = true
        window.contentView!.addSubview(bridge)
        bridge.configure()
        bridge.color = .black
        bridge.reduceMotion = false
        bridge.configure()
        try await Task.sleep(for: .milliseconds(70))
        let middle = try XCTUnwrap(window.backgroundColor.usingColorSpace(.sRGB)).redComponent
        XCTAssertGreaterThan(middle, 0)
        XCTAssertLessThan(middle, 1)
        bridge.reduceMotion = true
        bridge.configure()
        XCTAssertEqual(window.backgroundColor, .black)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(window.backgroundColor, .black, "Reduce Motion cancels an in-flight colour animation")
    }

    func testWebKitExtendsUnderToolbarWithMeasuredInsets() {
        let web = makeWebView()
        let host = WebViewHost(webView: web)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.toolbar = NSToolbar(identifier: "ChromeInsetTest")
        window.contentView!.addSubview(host)
        host.frame = window.contentLayoutRect
        host.layout()
        XCTAssertGreaterThan(web.obscuredContentInsets.top, 0)
        XCTAssertEqual(web.bounds.height, host.bounds.height + web.obscuredContentInsets.top, accuracy: 1)
        XCTAssertEqual(web.obscuredContentInsets.bottom, 0)
        XCTAssertTrue(host.clipsToBounds, "WebKit must never paint over the native toolbar")
    }

    func testAddressShowsHostAndSelectsCompleteURLOnFocus() async throws {
        let address = "https://docs.example.com/designing-calm-interfaces?q=glass#details"
        let state = AddressTestState(text: address)
        let hosting = NSHostingController(rootView: AddressTestView(state: state).browserAppearance(.t3Code))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        window.makeFirstResponder(nil)
        func addressField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.accessibilityIdentifier() == "addressField" { return field }
            return view.subviews.lazy.compactMap { addressField(in: $0) }.first
        }
        try await wait { addressField(in: window.contentView!.superview!)?.stringValue == "docs.example.com" }
        let field = try XCTUnwrap(addressField(in: window.contentView!.superview!))
        XCTAssertEqual(field.alignment, .center)
        // Direct responder entry is shared by mouse focus and the Command-L request.
        window.makeFirstResponder(field)
        try await wait { field.currentEditor()?.string == address }
        try await wait { field.currentEditor()?.selectedRange == NSRange(location: 0, length: (address as NSString).length) }
        window.makeFirstResponder(nil)
        try await wait { field.stringValue == "docs.example.com" }
        state.focusRequest += 1
        try await wait { field.currentEditor()?.string == address }
        try await wait { field.currentEditor()?.selectedRange == NSRange(location: 0, length: (address as NSString).length) }
        XCTAssertEqual(state.text, address, "Focusing must not replace the URL with its display host")
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    }
    private func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Chrome observation did not settle")
    }
}

@MainActor @Observable private final class AddressTestState {
    var text: String
    var editing = false
    var focusRequest = 0
    init(text: String) { self.text = text }
}

private struct AddressTestView: View {
    @Bindable var state: AddressTestState
    var body: some View {
        AddressField(text: $state.text, isEditing: $state.editing, displayText: "docs.example.com",
                     focusRequest: state.focusRequest, submit: { true }, cancel: {})
            .frame(width: 500, height: 32)
    }
}
