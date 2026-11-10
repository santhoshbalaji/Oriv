import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class BrowserChromeTests: XCTestCase {
    func testThemeColorIgnoredAndBodyChangesDetachFromPreviousTab() async throws {
        let first = makeWebView(), second = makeWebView()
        let firstWindow = samplingWindow(first), secondWindow = samplingWindow(second)
        defer { firstWindow.close(); secondWindow.close() }
        let chrome = PageChrome()
        first.loadHTMLString("<meta name='theme-color' content='#ffffff'><body style='background:white'>Light</body>", baseURL: nil)
        second.loadHTMLString("<meta name='theme-color' content='#111111'><body style='background:#111111'>Dark</body>", baseURL: nil)
        try await wait { first.themeColor != nil && second.themeColor != nil }
        chrome.observe(first)
        try await wait { !chrome.isDark }
        XCTAssertFalse(chrome.isDark)
        _ = try await first.evaluateJavaScript("document.querySelector('meta').content = '#111111';document.body.style.background='#111111'")
        try await wait { chrome.isDark }
        chrome.observe(second)
        try await wait { chrome.isDark }
        _ = try await first.evaluateJavaScript("document.querySelector('meta').content = '#ffffff';document.body.style.background='#ffffff'")
        try await wait { (first.themeColor?.usingColorSpace(.sRGB)?.redComponent ?? 0) > 0.99 }
        XCTAssertTrue(chrome.isDark, "A background tab must not recolor the displayed chrome")
        chrome.observe(nil)
        XCTAssertTrue(chrome.isDark, "Start page resets to T3 chrome")
    }

    func testPageWithoutThemeColorTracksComputedBodyBackground() async throws {
        let view = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(view); defer { window.close() }
        view.loadHTMLString("<body style='background:#ffffff'>Fallback</body>", baseURL: nil)
        try await wait { !view.isLoading && view.url != nil }
        chrome.observe(view)
        try await wait { !chrome.isDark }
        _ = try await view.evaluateJavaScript("document.body.style.background = '#111111'")
        try await wait { chrome.isDark }
    }

    func testThemeIgnoredAndMidtoneUsesHighContrastForeground() async throws {
        let web = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(web); defer { window.close() }
        web.loadHTMLString("<meta name='theme-color' content='#ffffff'><body style='background:#1f6f5c'>Body</body>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        chrome.observe(web)
        try await wait { chrome.sampleCount > 0 }
        let color = try XCTUnwrap(NSColor(chrome.color).usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 31.0 / 255, accuracy: 0.002)
        XCTAssertEqual(color.greenComponent, 111.0 / 255, accuracy: 0.002)
        XCTAssertTrue(chrome.isDark)
        XCTAssertGreaterThanOrEqual(1.05 / (chrome.luminance + 0.05), 4.5)
        XCTAssertEqual(chrome.contrasting(chrome.color), chrome.foreground)
        _ = try await web.evaluateJavaScript("document.querySelector('meta').content='#000000';document.body.style.background='#808080'")
        try await wait { !chrome.isDark }
        XCTAssertGreaterThanOrEqual((chrome.luminance + 0.05) / 0.05, 4.5)
    }

    func testComputedBackgroundFallbackAndCanvasWithoutColour() async throws {
        let web = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(web); defer { window.close() }
        web.loadHTMLString("<body style='background:#1f6f5c'>Computed fallback</body>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        web.underPageBackgroundColor = .clear
        chrome.observe(web)
        try await wait { chrome.sampleCount > 0 }
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

    func testPrivatePageAlwaysUsesCanvasDespiteLiveEdgeChanges() async throws {
        let web = makeWebView(), chrome = PageChrome()
        web.loadHTMLString("<meta name='theme-color' content='#ffffff'><body>Private</body>", baseURL: nil)
        try await wait { web.themeColor != nil }
        chrome.observe(web, isPrivate: true)
        XCTAssertEqual(chrome.luminance, 0)
        _ = try await web.evaluateJavaScript("document.body.style.background='#ffffff';document.body.innerHTML=\"<header style='position:fixed;inset:0;background:red'></header>\"")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(chrome.luminance, 0)
        XCTAssertTrue(chrome.isDark)
        XCTAssertEqual(chrome.sampleCount, 0)
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

    func testFixedHeaderBeatsWhiteCanvasAndUpdatesAfterSPAMutation() async throws {
        let web = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(web); defer { window.close() }
        web.loadHTMLString("<style>body{margin:0;background:white}header{position:fixed;top:0;width:100%;height:100px;background:#6600cc}</style><header>Header</header><main>Content</main>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        chrome.observe(web)
        try await wait { chrome.sampleCount > 0 }
        XCTAssertEqual(chrome.sampledTop?.red ?? -1, 0.4, accuracy: 0.01)
        XCTAssertTrue(chrome.isDark)
        _ = try await web.evaluateJavaScript("history.pushState({}, '', '#next');document.querySelector('header').style.background='#ffffff'")
        try await wait { !chrome.isDark }
        XCTAssertEqual(chrome.sampledTop?.red ?? -1, 1, accuracy: 0.01)
        chrome.observe(nil)
    }

    func testStickyBecomesPinnedOnlyAfterScroll() async throws {
        let web = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(web); defer { window.close() }
        web.loadHTMLString("<style>body{margin:0;height:3000px;background:white}header{position:sticky;top:0;height:100px;background:#6600cc}</style><div style='height:180px'>Intro</div><header>Header</header>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        chrome.observe(web)
        try await wait { chrome.sampleCount > 0 }
        XCTAssertNil(chrome.sampledTop)
        XCTAssertFalse(chrome.isDark)
        _ = try await web.evaluateJavaScript("window.scrollTo(0,300)")
        try await wait { chrome.hasScrolled && chrome.sampledTop != nil }
        XCTAssertEqual(chrome.sampledTop?.blue ?? -1, 0.8, accuracy: 0.01)
        _ = try await web.evaluateJavaScript("window.scrollTo(0,0)")
        try await wait { !chrome.hasScrolled && chrome.sampledTop == nil }
        XCTAssertFalse(chrome.isDark)
        chrome.observe(nil)
    }

    func testNonFixedHeaderFallsBackToBodyAndTransparentStickyFallsThrough() async throws {
        let web = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(web); defer { window.close() }
        web.loadHTMLString("<style>body{margin:0;background:white}header{height:100px;background:#6600cc}</style><header>Header</header>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        chrome.observe(web)
        try await wait { chrome.sampleCount > 0 }
        XCTAssertNil(chrome.sampledTop)
        XCTAssertFalse(chrome.isDark)
        let before = chrome.sampleCount
        _ = try await web.evaluateJavaScript("document.querySelector('header').style.cssText='position:sticky;top:0;background:transparent';document.body.style.background='#1f6f5c'")
        try await wait { chrome.sampleCount > before }
        XCTAssertNil(chrome.sampledTop)
        XCTAssertEqual(NSColor(chrome.color).usingColorSpace(.sRGB)!.greenComponent, 111.0/255, accuracy: 0.002)
    }

    func testTranslucentHeaderClampsButDimmingOverlayComposites() async throws {
        let web = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(web); defer { window.close() }
        web.loadHTMLString("<style>body{margin:0;background:white}header{position:fixed;inset:0 0 auto;height:80px;background:rgba(22,22,23,.8)}</style><header>Apple-like header</header>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        chrome.observe(web)
        try await wait { chrome.sampleCount > 0 }
        XCTAssertEqual(NSColor(chrome.color).usingColorSpace(.sRGB)!.redComponent, 22.0/255, accuracy: 0.002)
        _ = try await web.evaluateJavaScript("const overlay=document.createElement('div');overlay.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.25);z-index:10';document.body.append(overlay)")
        try await wait { !chrome.isDark }
        XCTAssertEqual(NSColor(chrome.color).usingColorSpace(.sRGB)!.redComponent, 0.75, accuracy: 0.005)
        // A full-viewport dimmer must composite even at alpha >= .75.
        _ = try await web.evaluateJavaScript("document.body.lastElementChild.style.background='rgba(0,0,0,.8)'")
        try await wait { chrome.isDark }
        XCTAssertEqual(NSColor(chrome.color).usingColorSpace(.sRGB)!.redComponent, 0.2, accuracy: 0.005)
    }

    func testTransparentStickyRevealsFixedLayerAndResizeInvalidates() async throws {
        let web = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(web); defer { window.close() }
        web.loadHTMLString("<style>body{margin:0;background:white}aside{position:fixed;inset:0 0 auto;height:100px;background:#6600cc}header{position:sticky;top:0;height:100px;background:transparent}</style><aside></aside><header>Transparent</header>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        chrome.observe(web)
        try await wait { chrome.sampledTop != nil }
        XCTAssertTrue(chrome.isDark)
        let before = chrome.sampleCount
        _ = try await web.evaluateJavaScript("document.querySelector('aside').style.width='100px';window.dispatchEvent(new Event('resize'))")
        try await wait { chrome.sampleCount > before }
        XCTAssertNil(chrome.sampledTop, "A narrow fixed widget must not tint the full toolbar")
        XCTAssertFalse(chrome.isDark)
    }

    func testAppearanceChangesAndHtmlFallback() async throws {
        let web = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(web); defer { window.close() }
        web.appearance = NSAppearance(named: .aqua)
        web.loadHTMLString("<style>html{background:white}body{background:transparent}@media(prefers-color-scheme:dark){html{background:#111111}}</style><body>Appearance</body>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        chrome.observe(web)
        try await wait { chrome.sampleCount > 0 }
        XCTAssertFalse(chrome.isDark)
        web.appearance = NSAppearance(named: .darkAqua)
        try await wait { chrome.isDark }
        XCTAssertEqual(NSColor(chrome.color).usingColorSpace(.sRGB)!.redComponent, 17.0/255, accuracy: 0.002)
    }

    func testNativeInsetDoesNotSkipShortHeaderAndUnloadedPrivateTabResets() async throws {
        let web = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(web); defer { window.close() }
        web.obscuredContentInsets = NSEdgeInsets(top: 62, left: 0, bottom: 0, right: 0)
        web.loadHTMLString("<style>body{margin:0;background:white}header{position:sticky;top:0;height:44px;background:#6600cc}</style><header>Short header</header>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        chrome.observe(web)
        try await wait { chrome.sampleCount > 0 }
        XCTAssertEqual(chrome.sampledTop?.blue ?? -1, 0.8, accuracy: 0.002)
        chrome.observe(makeWebView(), isPrivate: true)
        XCTAssertEqual(chrome.luminance, 0)
        XCTAssertTrue(chrome.isDark)
    }

    func testScrollSamplingIsDebouncedAndDetached() async throws {
        let web = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(web); defer { window.close() }
        web.loadHTMLString("<style>body{margin:0;height:3000px;background:#6600cc}</style>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        chrome.observe(web)
        try await wait { chrome.sampleCount > 0 }
        let initial = chrome.sampleCount
        for _ in 0..<30 { chrome.requestSample() }
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertLessThanOrEqual(chrome.sampleCount - initial, 2)
        chrome.observe(nil)
        let detached = chrome.sampleCount
        _ = try await web.evaluateJavaScript("document.body.style.background='white';window.scrollTo(0,300)")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(chrome.sampleCount, detached)
        XCTAssertFalse(chrome.hasScrolled)
    }

    func testScrolledContentBackdropCrossesTopAndStickyBoundaryAtomically() async throws {
        let web = makeWebView(), chrome = PageChrome()
        let window = samplingWindow(web); defer { window.close() }
        web.loadHTMLString("<style>body{margin:0;background:white;height:4000px}header{margin-top:200px;position:sticky;top:0;height:80px;background:#6600cc}</style><header>Sticky later</header>", baseURL: nil)
        try await wait { !web.isLoading && web.url != nil }
        chrome.observe(web)
        try await wait { chrome.sampleCount > 0 }
        XCTAssertFalse(chrome.showsContentUnderChrome)
        _ = try await web.evaluateJavaScript("window.scrollTo(0,100)")
        try await wait { chrome.showsContentUnderChrome }
        XCTAssertNil(chrome.sampledTop)
        _ = try await web.evaluateJavaScript("window.scrollTo(0,300)")
        try await wait { chrome.hasScrolled && chrome.sampledTop != nil }
        XCTAssertFalse(chrome.showsContentUnderChrome)
        XCTAssertEqual(chrome.sampledTop?.blue ?? -1, 0.8, accuracy: 0.002)
        _ = try await web.evaluateJavaScript("document.querySelector('header').style.position='static';window.scrollTo(0,400)")
        try await wait { chrome.showsContentUnderChrome }
        _ = try await web.evaluateJavaScript("window.scrollTo(0,0)")
        try await wait { !chrome.hasScrolled }
        XCTAssertFalse(chrome.showsContentUnderChrome)
        XCTAssertFalse(chrome.isDark, "Returning to the top restores the white canvas in the same update")
        chrome.observe(web, isPrivate: true)
        _ = try await web.evaluateJavaScript("window.scrollTo(0,300)")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(chrome.showsContentUnderChrome)
    }

    private func samplingWindow(_ web: WKWebView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        return window
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    }
    private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Chrome observation did not settle", file: file, line: line)
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
