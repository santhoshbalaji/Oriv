import AppKit
import BrowserEngine
import SwiftUI
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class SidebarLayoutTests: BackgroundUITestCase {
    private func makeWindow(_ controller: BrowserController, profiles: BrowserProfiles? = nil,
                            width: CGFloat = 1000, rtl: Bool = false, largestText: Bool = true,
                            appearance: BrowserAppearance = .t3Code) -> NSWindow {
        let root = BrowserWindow(controller: controller, profiles: profiles)
            .browserAppearance(appearance)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight).dynamicTypeSize(largestText ? .accessibility5 : .large)
        let host = NSHostingController(rootView: root)
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 60, y: 60, width: width, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: width, height: 600))
        BackgroundUIMode.show(window, key: true, activate: BackgroundUIMode.foregroundAllowed)
        return window
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func marker(_ name: String, in window: NSWindow) -> NSView? {
        window.contentView.flatMap { descendants($0).first { $0.identifier?.rawValue == name } }
    }
    private func address(in window: NSWindow) -> NSTextField? {
        window.contentView.flatMap { descendants($0).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "addressField" } }
    }
    private func frame(_ name: String, in window: NSWindow) throws -> NSRect {
        let view = try XCTUnwrap(marker(name, in: window), name)
        return view.convert(view.bounds, to: nil)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(50)) }
        XCTFail("Sidebar layout did not settle")
    }
    private func checkGeometry(_ window: NSWindow, collapsed: Bool, overlay: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(window.contentView, file: file, line: line)
        let top = try XCTUnwrap(marker("browserTopBarGeometry", in: window), file: file, line: line)
        let topFrame = top.convert(top.bounds, to: nil)
        XCTAssertEqual(topFrame.minX, collapsed ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth, accuracy: 1, file: file, line: line)
        XCTAssertEqual(topFrame.maxX, content.convert(content.bounds, to: nil).maxX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(topFrame.maxY, content.convert(content.bounds, to: nil).maxY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(topFrame.height, MacBrowserLayout.headerHeight, accuracy: 1, file: file, line: line)
        do {
            // Measure the actual material, not its formerly padded wrapper.
            let sidebar = try XCTUnwrap(marker("sidebarSurfaceGeometry", in: window), file: file, line: line)
            let rect = sidebar.convert(sidebar.bounds, to: nil)
            XCTAssertEqual(rect.minX, 0, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(rect.minY, 0, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(rect.width, overlay ? MacBrowserLayout.sidebarWidth : (collapsed ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth), accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(rect.height, content.bounds.height, accuracy: 0.5, file: file, line: line)
        }
    }
    func testAttachedSidebarAndRailAtMinimumAndAfterResize() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles, width: 760); defer { window.close() }
        try await wait { (self.marker("browserSidebarGeometry", in: window)?.bounds.height ?? 0) > 500 && profiles.controller.sidebar.rail }
        try checkGeometry(window, collapsed: true)
        window.setContentSize(NSSize(width: 1280, height: 820))
        try await Task.sleep(for: .milliseconds(200))
        try checkGeometry(window, collapsed: false)
    }
    func testExpandedAndNarrowOverlayUseEightPointGuttersAndFivePointFooterGap() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let controller = profiles.controller
        let window = makeWindow(controller, profiles: profiles, largestText: false); defer { window.close() }
        for width: CGFloat in [1000, 780] {
            window.setContentSize(NSSize(width: width, height: 600))
            try await Task.sleep(for: .milliseconds(300))
            controller.compactSidebar = false
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(controller.sidebar.narrowOverlay, width == 780)
            let surface = try frame("sidebarSurfaceGeometry", in: window)
            let tab = try XCTUnwrap(controller.session.selectedTabID)
            let rowView = try XCTUnwrap(window.contentView.flatMap {
                descendants($0).first { $0.identifier?.rawValue == "sidebarItem-\(tab)" }
            })
            let scroll = try XCTUnwrap(rowView.enclosingScrollView)
            let scrollerGutter = scroll.bounds.width - scroll.contentView.bounds.width
            for name in ["sidebarSearchGeometry", "sidebarItem-\(tab)", "sidebarSelection-\(tab)", "sidebarNewTabGeometry", "sidebarFooterGeometry"] {
                let rect = try frame(name, in: window)
                let gutter = name.hasPrefix("sidebarItem-") || name.hasPrefix("sidebarSelection-") ? scrollerGutter : 0
                XCTAssertEqual(rect.minX - surface.minX, 8, accuracy: 0.5, name)
                XCTAssertEqual(surface.maxX - rect.maxX, 8 + gutter, accuracy: 0.5, name)
            }
            let row = try frame("sidebarItem-\(tab)", in: window)
            let icon = try frame("sidebarFavicon-\(tab)", in: window)
            XCTAssertEqual(row.height, 36, accuracy: 0.5)
            XCTAssertEqual(icon.minX - row.minX, 8, accuracy: 0.5)
            XCTAssertEqual(try frame("sidebarSection-Tabs", in: window).minX, icon.minX, accuracy: 0.5)
            let footer = try frame("sidebarFooterGeometry", in: window)
            XCTAssertEqual(footer.minY - surface.minY, 8, accuracy: 0.5)
            XCTAssertEqual(try frame("sidebarNewTabGeometry", in: window).minY - footer.maxY, 5, accuracy: 0.5)
            XCTAssertEqual(try frame("sidebarTitlebarGeometry", in: window).height, 32, accuracy: 0.5)
            XCTAssertEqual(surface.maxY - (try frame("sidebarProfileGeometry", in: window)).maxY, 40, accuracy: 0.5)
            XCTAssertEqual(surface.maxY - (try frame("sidebarToggleGeometry", in: window)).midY, 16, accuracy: 0.5)
        }
    }

    func testRailUsesMinimumWidthAndNoOuterTopOrBottomInsets() async throws {
        let controller = BrowserController(testing: true); defer { controller.shutdown() }
        controller.compactSidebar = true
        let window = makeWindow(controller, largestText: false); defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let chrome = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? BrowserWindowChrome.WindowChromeView }.first })
        for fullscreen in [false, true] {
            chrome.simulatesFullscreenLayout = fullscreen; chrome.configure()
            try await Task.sleep(for: .milliseconds(300))
            let surface = try frame("sidebarSurfaceGeometry", in: window)
            let tab = try XCTUnwrap(controller.session.selectedTabID)
            for name in ["sidebarToggleGeometry", "sidebarSearchGeometry", "sidebarNewTabGeometry", "sidebarItem-\(tab)", "sidebarFooter-Settings"] {
                let rect = try frame(name, in: window)
                XCTAssertEqual(rect.midX, surface.midX, accuracy: 0.5, name)
                XCTAssertEqual(rect.width, 42, accuracy: 0.5, name)
                XCTAssertEqual(rect.height, 36, accuracy: 0.5, name)
            }
            let toggle = try frame("sidebarToggleGeometry", in: window)
            XCTAssertEqual(surface.maxY - toggle.maxY, fullscreen ? 0 : 32, accuracy: 0.5)
            XCTAssertEqual(try frame("sidebarFooter-Settings", in: window).minY - surface.minY, 0, accuracy: 0.5)
        }
    }

    func testFullscreenProfileSharesToggleLineWithoutRevealRelayout() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles, largestText: false); defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let chrome = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? BrowserWindowChrome.WindowChromeView }.first })
        chrome.simulatesFullscreenLayout = true; chrome.configure()
        try await Task.sleep(for: .milliseconds(300))
        let surface = try frame("sidebarSurfaceGeometry", in: window)
        let profile = try frame("sidebarProfileGeometry", in: window)
        let toggle = try frame("sidebarToggleGeometry", in: window)
        XCTAssertEqual(try frame("sidebarTitlebarGeometry", in: window).height, 0, accuracy: 0.5)
        XCTAssertEqual(surface.maxY - profile.maxY, 8, accuracy: 0.5)
        XCTAssertEqual(surface.maxY - toggle.maxY, 8, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(toggle.minX - profile.maxX, 8)
        // Visibility represents the two reveal states without a system Space
        // transition. Native host painting still needs foreground acceptance.
        for hidden in [true, false, true] {
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = hidden }
            chrome.configure()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try frame("sidebarProfileGeometry", in: window), profile)
            XCTAssertEqual(try frame("sidebarToggleGeometry", in: window), toggle)
            XCTAssertFalse(window.titlebarAppearsTransparent, "The revealed system titlebar must cover underlying chrome")
            XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty, "No extra reveal height is reserved")
        }
        chrome.simulatesFullscreenLayout = false; chrome.configure()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(try frame("sidebarTitlebarGeometry", in: window).height, 32, accuracy: 0.5)
    }

    func testProfileNameAndCountAlignAndStayClearOfSearchAndToggle() async throws {
        for appearance in [BrowserAppearance.light, .dark] {
            let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
            for _ in 0..<2 { _ = profiles.controller.session.addTab(select: false, load: false) }
            let window = makeWindow(profiles.controller, profiles: profiles, largestText: false, appearance: appearance)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            let chrome = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? BrowserWindowChrome.WindowChromeView }.first })
            for fullscreen in [false, true] {
                chrome.simulatesFullscreenLayout = fullscreen; chrome.configure()
                try await Task.sleep(for: .milliseconds(300))
                let profile = try frame("sidebarProfileGeometry", in: window)
                let name = try frame("sidebarProfileNameGeometry", in: window)
                let count = try frame("sidebarProfileCountGeometry", in: window)
                let search = try frame("sidebarSearchGeometry", in: window)
                let toggle = try frame("sidebarToggleGeometry", in: window)
                XCTAssertEqual(profile.minX, 8, accuracy: 0.5)
                XCTAssertEqual(profile.height, 44, accuracy: 0.5)
                XCTAssertEqual(name.minX, count.minX, accuracy: 0.5)
                XCTAssertTrue(profile.contains(name)); XCTAssertTrue(profile.contains(count))
                XCTAssertGreaterThanOrEqual(profile.minY - search.maxY, 8)
                XCTAssertFalse(profile.intersects(toggle)); XCTAssertFalse(search.intersects(toggle))
            }
        }
    }
    func testPrivacyShieldAndAddressFitDefaultAndMinimumWithSidebar() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let controller = profiles.controller, tab = try XCTUnwrap(controller.session.selectedTab)
        let window = makeWindow(controller, profiles: profiles, width: 1250); defer { window.close() }
        controller.navigate("http://127.0.0.1:18768/privacy?utm_source=integration&keep=1")
        for _ in 0..<800 {
            if tab.title == "Privacy fixture" && !tab.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(tab.title, "Privacy fixture")
        XCTAssertEqual(tab.url?.query, "keep=1")
        let trackerBlocked = try await tab.webView.evaluateJavaScript("window.shippingTrackerBlocked === true") as? Bool
        XCTAssertEqual(trackerBlocked, true)
        controller.downloads.items.append(DownloadItem())
        for width: CGFloat in [1250, 760, 800] {
            window.setContentSize(NSSize(width: width, height: 600))
            for collapsed in [false, true] {
                controller.compactSidebar = collapsed
                try await Task.sleep(for: .milliseconds(400))
                try checkGeometry(window, collapsed: controller.sidebar.reservesRail, overlay: controller.sidebar.overlay)
                let header = try XCTUnwrap(marker("browserTopBarGeometry", in: window))
                let address = try XCTUnwrap(marker("browserAddressGeometry", in: window))
                let shield = try XCTUnwrap(marker("browserPrivacyGeometry", in: window))
                let addressRect = address.convert(address.bounds, to: header)
                let shieldRect = shield.convert(shield.bounds, to: header)
                XCTAssertGreaterThanOrEqual(addressRect.width, 230)
                XCTAssertTrue(header.bounds.contains(addressRect))
                XCTAssertTrue(header.bounds.contains(shieldRect))
                XCTAssertLessThanOrEqual(addressRect.maxX, shieldRect.minX)
                XCTAssertNotNil(marker("browserPrivacyGeometry", in: window))
            }
        }
        controller.compactSidebar = false
        try await Task.sleep(for: .milliseconds(400))
        controller.session.settings.privacy.setEnabled(true, .cookieBanners)
        tab.reload()
        var bannerDisplay: String?
        for _ in 0..<800 {
            bannerDisplay = try? await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#onetrust-banner-sdk')).display") as? String
            if !tab.isLoading && bannerDisplay == "none" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(bannerDisplay, "none")
        let audit = BackgroundUIMode.audit()
        XCTAssertEqual(audit.onscreenWindowViolations, 0)
    }
    func testPrivacyShieldOpensRealPopover() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles, width: 1250); defer { window.close() }
        try await wait { self.marker("browserPrivacyGeometry", in: window) != nil }
        if #unavailable(macOS 27) {
            try XCTSkipIf(BackgroundUIMode.isEnabled && !window.isKeyWindow,
                "Foreground-dependent popover check on macOS < 27: background/accessory mode is enabled and AppKit refused the key window.")
        }
        let shield = try XCTUnwrap(marker("browserPrivacyGeometry", in: window))
        let point = shield.convert(NSPoint(x: shield.bounds.midX, y: shield.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await wait {
            NSApp.windows.contains { self.marker("sitePrivacyPanelGeometry", in: $0) != nil }
        }
        XCTAssertTrue(NSApp.windows.contains { window in
            marker("sitePrivacyPanelGeometry", in: window) != nil
        }, "Shield must open the privacy controls in the integrated shell")
        let audit = BackgroundUIMode.audit()
        XCTAssertEqual(audit.onscreenWindowViolations, 0)
    }
    func testRealWindowButtonsStayInTheirParentsAndAlignInBothStates() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles); defer { window.close() }
        let other = BackgroundUIMode.Window(); other.isReleasedWhenClosed = false; defer { other.close() }
        let otherFrame = other.standardWindowButton(.closeButton)?.frame
        try await Task.sleep(for: .milliseconds(350))
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let parents = types.map { window.standardWindowButton($0)?.superview }
        for collapsed in [false, true, false] {
            profiles.controller.compactSidebar = collapsed
            try await Task.sleep(for: .milliseconds(400))
            try checkGeometry(window, collapsed: collapsed)
            for (i, type) in types.enumerated() {
                let button = try XCTUnwrap(window.standardWindowButton(type))
                XCTAssertTrue(button.superview === parents[i])
                let frame = button.convert(button.bounds, to: nil)
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(button.window === window && window.isVisible)
                XCTAssertEqual(frame.minX, (collapsed ? 1 : MacBrowserLayout.lightsInset) + CGFloat(i) * MacBrowserLayout.lightsSpacing, accuracy: 1)
                XCTAssertEqual(window.contentView!.bounds.maxY - frame.midY, MacBrowserLayout.sidebarTitlebarHeight / 2, accuracy: 1)
                XCTAssertLessThanOrEqual(frame.maxX, collapsed ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth)
                XCTAssertTrue(button.superview!.bounds.contains(button.frame), "Native hit testing must include the entire button")
            }
        }
        XCTAssertEqual(other.standardWindowButton(.closeButton)?.frame, otherFrame)
    }
    func testTogglePreservesSelectedTabAddressAndNativeFieldIdentity() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles); defer { window.close() }
        try await wait { self.address(in: window) != nil }
        let field = try XCTUnwrap(address(in: window))
        let id = profiles.controller.session.selectedTabID
        let request = profiles.controller.addressFocusRequest
        for collapsed in [true, false, true] {
            profiles.controller.compactSidebar = collapsed
            try await Task.sleep(for: .milliseconds(400))
            try checkGeometry(window, collapsed: collapsed)
            XCTAssertTrue(address(in: window) === field)
            XCTAssertEqual(profiles.controller.session.selectedTabID, id)
            XCTAssertEqual(profiles.controller.addressFocusRequest, request)
        }
    }
    func testActualBrowserScrollAndCollapseDoNotReplayCommandL() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let controller = profiles.controller, tab = try XCTUnwrap(profiles.controller.session.selectedTab)
        let url = "https://docs.example.com/full/address?q=sidebar#focus"
        tab.webView.loadHTMLString("<body style='margin:0;background:white;height:4000px'>Focus fixture</body>", baseURL: URL(string: url))
        try await wait { !tab.webView.isLoading && tab.url != nil }
        let window = makeWindow(controller, profiles: profiles); defer { window.close() }
        try await wait { self.address(in: window) != nil }
        let field = try XCTUnwrap(address(in: window))
        try await wait { abs(tab.webView.obscuredContentInsets.top - MacBrowserLayout.headerHeight) < 1 }
        XCTAssertEqual(tab.webView.obscuredContentInsets.top, MacBrowserLayout.headerHeight, accuracy: 1)
        window.makeFirstResponder(tab.webView)
        try await wait { field.currentEditor() == nil }
        controller.focusAddress()
        try await wait { field.currentEditor()?.string == url }
        XCTAssertEqual(field.currentEditor()?.selectedRange, NSRange(location: 0, length: (url as NSString).length))
        window.makeFirstResponder(tab.webView)
        try await wait { field.currentEditor() == nil }
        for collapsed in [false, true, false] {
            controller.compactSidebar = collapsed
            for y in [100, 0, 400, 0] {
                _ = try await tab.webView.evaluateJavaScript("window.scrollTo(0,\(y))")
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertTrue(address(in: window) === field)
                XCTAssertNil(field.currentEditor())
                XCTAssertEqual(field.stringValue, "docs.example.com")
            }
        }
        controller.focusAddress()
        try await wait { field.currentEditor()?.string == url }
    }
    func testRightToLeftLargestTextRetainsPhysicalLeftSidebar() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles, width: 760, rtl: true); defer { window.close() }
        try await Task.sleep(for: .milliseconds(350))
        try checkGeometry(window, collapsed: true)
        let field = try XCTUnwrap(address(in: window))
        XCTAssertGreaterThan(field.bounds.width, 40)
        XCTAssertTrue(window.contentView!.bounds.contains(field.convert(field.bounds, to: window.contentView)))
    }
    func testFullscreenOpenCollapsedAndReturnedGeometry() async throws {
        try XCTSkipUnless(BackgroundUIMode.foregroundAllowed, BackgroundUIMode.foregroundOnlyReason)
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles); defer { window.close() }
        window.collectionBehavior.insert(.fullScreenPrimary)
        try await Task.sleep(for: .milliseconds(400))
        window.toggleFullScreen(nil)
        try await wait { window.styleMask.contains(.fullScreen) }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNil(window.toolbar, "No separately hosted toolbar may cover the content colour band")
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(type))
            XCTAssertTrue(button.window !== window || button.isHiddenOrHasHiddenAncestor, "Resting fullscreen window controls belong to the system reveal host")
        }
        try checkGeometry(window, collapsed: false)
        profiles.controller.compactSidebar = true
        try await Task.sleep(for: .milliseconds(400))
        try checkGeometry(window, collapsed: true)
        window.toggleFullScreen(nil)
        try await wait { !window.styleMask.contains(.fullScreen) }
        try await Task.sleep(for: .milliseconds(800))
        try checkGeometry(window, collapsed: true)
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertEqual(window.contentView!.bounds.maxY - button.convert(button.bounds, to: nil).midY, MacBrowserLayout.sidebarTitlebarHeight / 2, accuracy: 1)
    }
    func testExternalPrivateWindowUsesSameLayout() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        profiles.handleIncomingURL(URL(string: "https://fixture.example/external")!, sourceName: "Example App")
        let controller = try XCTUnwrap(profiles.externalPrivate)
        let window = makeWindow(controller, profiles: profiles, width: 760); defer { window.close() }
        try await Task.sleep(for: .milliseconds(350))
        try checkGeometry(window, collapsed: true)
        controller.compactSidebar = true
        try await Task.sleep(for: .milliseconds(400))
        try checkGeometry(window, collapsed: true)
    }
    func testSidebarToggleKeyboardShortcutUsesOneSurvivingControl() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles); defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        for collapsed in [true, false] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s",
                isARepeat: false, keyCode: 1))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            try await wait { profiles.controller.compactSidebar == collapsed }
            try await Task.sleep(for: .milliseconds(400))
            try checkGeometry(window, collapsed: collapsed)
        }
    }

    func testWindowAccessibilityOrderStartsWithRealWindowButtons() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles); defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        let order = try XCTUnwrap(window.accessibilityChildrenInNavigationOrder())
        let buttons = [window.accessibilityCloseButton(), window.accessibilityMinimizeButton(), window.accessibilityZoomButton()].compactMap { $0 as AnyObject? }
        XCTAssertEqual(order.count, window.accessibilityChildren()?.count)
        XCTAssertGreaterThan(order.count, 3)
        for index in 0..<3 { XCTAssertTrue((order[index] as AnyObject) === buttons[index]) }
    }

    func testCollapsingFocusedSidebarSearchDoesNotFocusAddress() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let controller = profiles.controller
        let tab = try XCTUnwrap(controller.session.selectedTab)
        tab.webView.loadHTMLString("<body>Sidebar focus fixture</body>", baseURL: URL(string: "https://fixture.example/sidebar-focus"))
        try await wait { tab.url != nil && !tab.webView.isLoading }
        for _ in 0..<8 { _ = controller.session.addTab(url: nil, select: false, load: false) }
        let window = makeWindow(controller, profiles: profiles); defer { window.close() }
        try XCTSkipIf(BackgroundUIMode.isEnabled && !window.isKeyWindow,
            "System keyboard-focus handoff needs a key window; inactive accessory mode refused it. ORIV_FOREGROUND_UI=1 requires orchestrator approval.")
        try await Task.sleep(for: .milliseconds(400))
        let search = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "tabSearchField" || $0.placeholderString == "Search tabs" } })
        let field = try XCTUnwrap(address(in: window))
        window.makeFirstResponder(search)
        try await wait { search.currentEditor() != nil }
        let context = MacBrowserWindowContext(); context.window = window
        XCTAssertTrue(context.sidebarContainsFocus, "Native search focus must be detectable before collapse")
        let request = controller.addressFocusRequest
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s",
            isARepeat: false, keyCode: 1))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        try await Task.sleep(for: .milliseconds(500))
        try checkGeometry(window, collapsed: true)
        XCTAssertNil(field.currentEditor(), "Removing sidebar focus must select the surviving toggle, not the address")
        XCTAssertEqual(controller.addressFocusRequest, request)
        XCTAssertTrue(window.firstResponder is NSView)
    }

    func testFullscreenLayoutGeometryWithoutAWindowServerTransition() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles); defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let chrome = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? BrowserWindowChrome.WindowChromeView }.first })
        chrome.simulatesFullscreenLayout = true
        chrome.configure()
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = true }
        for collapsed in [false, true] {
            profiles.controller.compactSidebar = collapsed
            try await Task.sleep(for: .milliseconds(400))
            try checkGeometry(window, collapsed: collapsed)
            XCTAssertFalse(window.styleMask.contains(.fullScreen), "This is a background geometry fixture, not a system fullscreen transition")
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                XCTAssertTrue(window.standardWindowButton(type)?.isHidden == true)
            }
        }
        // Return the simulated system-owned controls to the real windowed path.
        chrome.simulatesFullscreenLayout = false
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = false }
        chrome.configure()
        try await Task.sleep(for: .milliseconds(300))
        try checkGeometry(window, collapsed: true)
        let returned = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertFalse(returned.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(returned.convert(returned.bounds, to: nil).minX, 1, accuracy: 1)
        if BackgroundUIMode.isEnabled {
            XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        }
    }

}
