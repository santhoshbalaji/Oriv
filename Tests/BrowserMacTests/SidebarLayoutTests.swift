import AppKit
import BrowserCore
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
        try XCTUnwrap(geometry(name, in: window), name)
    }
    private func geometry(_ name: String, in window: NSWindow) -> NSRect? {
        marker(name, in: window).map { $0.convert($0.bounds, to: nil) }
    }
    private func waitForSidebar(_ window: NSWindow, rail: Bool, overlay: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let reserved = rail ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth
        try await eventually("sidebar and toolbar geometry", file: file, line: line) {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let surface = self.geometry("sidebarSurfaceGeometry", in: window),
                  let toolbar = self.geometry("browserTopBarGeometry", in: window) else { return false }
            return abs(surface.width - (overlay ? MacBrowserLayout.sidebarWidth : reserved)) <= 1
                && abs(toolbar.minX - reserved) <= 1
        }
    }
    private func waitForTitlebar(_ window: NSWindow, height: CGFloat) async throws {
        try await eventually("sidebar titlebar height \(height)") {
            window.contentView?.layoutSubtreeIfNeeded()
            return abs((self.marker("sidebarTitlebarGeometry", in: window)?.bounds.height ?? -1) - height) <= 1
        }
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
            XCTAssertEqual(rect.minX, 0, accuracy: 1, file: file, line: line)
            XCTAssertEqual(rect.minY, 0, accuracy: 1, file: file, line: line)
            XCTAssertEqual(rect.width, overlay ? MacBrowserLayout.sidebarWidth : (collapsed ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth), accuracy: 1, file: file, line: line)
            XCTAssertEqual(rect.height, content.bounds.height, accuracy: 1, file: file, line: line)
        }
    }
    func testFourPinnedTilesAlignWithRegularRowAt256Points() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let session = profiles.controller.session
        for _ in 0..<4 { session.togglePinned(session.addTab(load: false).id) }
        // The last pinned tile is selected. Use the opaque capture path to
        // retain the actual AppKit grid and SwiftUI tile fill offscreen.
        let window = makeWindow(profiles.controller, profiles: profiles, largestText: false, appearance: .light)
        defer { window.close() }
        try await waitForSidebar(window, rail: false)
        let content = try XCTUnwrap(window.contentView)
        let list = try XCTUnwrap(descendants(content).compactMap { $0 as? SidebarTabCollection }.first)
        let layout = try XCTUnwrap(list.collectionViewLayout)
        let tiles = try (0..<4).map { try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))).frame }
        let row = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1))).frame
        XCTAssertEqual(tiles.first?.minX, row.minX)
        XCTAssertEqual(tiles.last?.maxX, row.maxX)
        XCTAssertTrue(tiles.allSatisfy { $0.minY == tiles[0].minY && $0.width == 54 })
        let surface = try XCTUnwrap(marker("sidebarSurfaceGeometry", in: window))
        let rect = surface.convert(surface.bounds, to: content)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: rect))
        content.cacheDisplay(in: rect, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "mac-sidebar-256-aligned-pins"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAttachedSidebarAndRailAtMinimumAndAfterResize() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles, width: 760); defer { window.close() }
        try await eventually("sidebar fixture state") { (self.marker("browserSidebarGeometry", in: window)?.bounds.height ?? 0) > 500 && profiles.controller.sidebar.rail }
        try checkGeometry(window, collapsed: true)
        window.setContentSize(NSSize(width: 1280, height: 820))
        try await waitForSidebar(window, rail: false)
        try checkGeometry(window, collapsed: false)
    }
    func testExpandedAndNarrowOverlayUseEightPointGuttersAndFivePointFooterGap() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let controller = profiles.controller
        let window = makeWindow(controller, profiles: profiles, largestText: false); defer { window.close() }
        for width: CGFloat in [1000, 780] {
            window.setContentSize(NSSize(width: width, height: 600))
            try await eventually("window width updates the sidebar layout") {
                controller.sidebar.automaticRail == (width == 780)
            }
            controller.compactSidebar = false
            try await waitForSidebar(window, rail: width == 780, overlay: width == 780)
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
                XCTAssertEqual(rect.minX - surface.minX, 8, accuracy: 1, name)
                XCTAssertEqual(surface.maxX - rect.maxX, 8 + gutter, accuracy: 1, name)
            }
            let row = try frame("sidebarItem-\(tab)", in: window)
            let icon = try frame("sidebarFavicon-\(tab)", in: window)
            XCTAssertEqual(row.height, 36, accuracy: 1)
            XCTAssertEqual(icon.minX - row.minX, 8, accuracy: 1)
            XCTAssertEqual(try frame("sidebarSection-Tabs", in: window).minX, icon.minX, accuracy: 1)
            let footer = try frame("sidebarFooterGeometry", in: window)
            let footerTitles = LibrarySection.allCases.map(\.rawValue) + ["Settings"]
            let footerButtons = try footerTitles.map { try frame("sidebarFooter-\($0)", in: window) }
            for (title, button) in zip(footerTitles, footerButtons) {
                XCTAssertTrue(footer.contains(button), title)
                XCTAssertEqual(button.width, 32, accuracy: 1, title)
                XCTAssertEqual(button.height, 32, accuracy: 1, title)
            }
            for (left, right) in zip(footerButtons, footerButtons.dropFirst()) {
                XCTAssertLessThanOrEqual(left.maxX, right.minX)
            }
            XCTAssertEqual(footer.minY - surface.minY, 8, accuracy: 1)
            XCTAssertEqual(try frame("sidebarNewTabGeometry", in: window).minY - footer.maxY, 5, accuracy: 1)
            XCTAssertEqual(try frame("sidebarTitlebarGeometry", in: window).height, 32, accuracy: 1)
            XCTAssertEqual(surface.maxY - (try frame("sidebarProfileGeometry", in: window)).maxY, 40, accuracy: 1)
            XCTAssertEqual(surface.maxY - (try frame("sidebarToggleGeometry", in: window)).midY, 16, accuracy: 1)
        }
    }

    func testRailUsesMinimumWidthAndNoOuterTopOrBottomInsets() async throws {
        let controller = BrowserController(testing: true); defer { controller.shutdown() }
        controller.compactSidebar = true
        let window = makeWindow(controller, largestText: false); defer { window.close() }
        try await eventually("window chrome attachment") {
            self.marker("browserSidebarGeometry", in: window) != nil
        }
        let chrome = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? BrowserWindowChrome.WindowChromeView }.first })
        for fullscreen in [false, true] {
            chrome.simulatesFullscreenLayout = fullscreen; chrome.configure()
            try await eventually("rail toggle position") {
                guard let surface = self.geometry("sidebarSurfaceGeometry", in: window),
                      let toggle = self.geometry("sidebarToggleGeometry", in: window) else { return false }
                return abs(surface.maxY - toggle.maxY - (fullscreen ? 0 : 32)) <= 1
            }
            let surface = try frame("sidebarSurfaceGeometry", in: window)
            let tab = try XCTUnwrap(controller.session.selectedTabID)
            for name in ["sidebarToggleGeometry", "sidebarSearchGeometry", "sidebarNewTabGeometry", "sidebarItem-\(tab)", "sidebarFooter-Settings"] {
                let rect = try frame(name, in: window)
                XCTAssertEqual(rect.midX, surface.midX, accuracy: 1, name)
                XCTAssertEqual(rect.width, 42, accuracy: 1, name)
                XCTAssertEqual(rect.height, 36, accuracy: 1, name)
            }
            let toggle = try frame("sidebarToggleGeometry", in: window)
            XCTAssertEqual(surface.maxY - toggle.maxY, fullscreen ? 0 : 32, accuracy: 1)
            XCTAssertEqual(try frame("sidebarFooter-Settings", in: window).minY - surface.minY, 0, accuracy: 1)
        }
    }

    func testFullscreenProfileSharesToggleLineWithoutRevealRelayout() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles, largestText: false); defer { window.close() }
        try await eventually("window chrome attachment") {
            self.marker("browserSidebarGeometry", in: window) != nil
        }
        let chrome = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? BrowserWindowChrome.WindowChromeView }.first })
        chrome.simulatesFullscreenLayout = true; chrome.configure()
        try await waitForTitlebar(window, height: 0)
        let surface = try frame("sidebarSurfaceGeometry", in: window)
        let profile = try frame("sidebarProfileGeometry", in: window)
        let toggle = try frame("sidebarToggleGeometry", in: window)
        XCTAssertEqual(try frame("sidebarTitlebarGeometry", in: window).height, 0, accuracy: 1)
        XCTAssertEqual(surface.maxY - profile.maxY, 8, accuracy: 1)
        XCTAssertEqual(surface.maxY - toggle.maxY, 8, accuracy: 1)
        XCTAssertGreaterThanOrEqual(toggle.minX - profile.maxX, 8 - 1)
        // Visibility represents the two reveal states without a system Space
        // transition. Native host painting still needs foreground acceptance.
        for hidden in [true, false, true] {
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = hidden }
            chrome.configure()
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(try frame("sidebarProfileGeometry", in: window), profile)
            XCTAssertEqual(try frame("sidebarToggleGeometry", in: window), toggle)
            XCTAssertFalse(window.titlebarAppearsTransparent, "The revealed system titlebar must cover underlying chrome")
            XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty, "No extra reveal height is reserved")
        }
        chrome.simulatesFullscreenLayout = false; chrome.configure()
        try await waitForTitlebar(window, height: 32)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(try frame("sidebarTitlebarGeometry", in: window).height, 32, accuracy: 1)
    }

    func testProfileNameAndCountAlignAndStayClearOfSearchAndToggle() async throws {
        for appearance in [BrowserAppearance.light, .dark] {
            let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
            for _ in 0..<2 { _ = profiles.controller.session.addTab(select: false, load: false) }
            let window = makeWindow(profiles.controller, profiles: profiles, largestText: false, appearance: appearance)
            defer { window.close() }
            try await waitForTitlebar(window, height: 32)
            let chrome = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? BrowserWindowChrome.WindowChromeView }.first })
            for fullscreen in [false, true] {
                chrome.simulatesFullscreenLayout = fullscreen; chrome.configure()
                try await waitForTitlebar(window, height: fullscreen ? 0 : 32)
                let profile = try frame("sidebarProfileGeometry", in: window)
                let name = try frame("sidebarProfileNameGeometry", in: window)
                let count = try frame("sidebarProfileCountGeometry", in: window)
                let search = try frame("sidebarSearchGeometry", in: window)
                let toggle = try frame("sidebarToggleGeometry", in: window)
                XCTAssertEqual(profile.minX, 8, accuracy: 1)
                XCTAssertEqual(profile.height, 44, accuracy: 1)
                XCTAssertEqual(name.minX, count.minX, accuracy: 1)
                XCTAssertTrue(profile.contains(name)); XCTAssertTrue(profile.contains(count))
                XCTAssertGreaterThanOrEqual(profile.minY - search.maxY, 8 - 1)
                XCTAssertFalse(profile.intersects(toggle)); XCTAssertFalse(search.intersects(toggle))
            }
        }
    }
    func testPrivacyShieldAndAddressFitDefaultAndMinimumWithSidebar() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let controller = profiles.controller, tab = try XCTUnwrap(controller.session.selectedTab)
        let window = makeWindow(controller, profiles: profiles, width: 1250); defer { window.close() }
        controller.navigate("http://127.0.0.1:18768/privacy?utm_source=integration&keep=1")
        try await eventually("privacy fixture navigation", timeout: 40) {
            tab.title == "Privacy fixture" && !tab.isLoading
        }
        XCTAssertEqual(tab.url?.query, "keep=1")
        let trackerBlocked = try await tab.webView.evaluateJavaScript("window.shippingTrackerBlocked === true") as? Bool
        XCTAssertEqual(trackerBlocked, true)
        controller.downloads.items.append(DownloadItem())
        for width: CGFloat in [1250, 760, 800] {
            window.setContentSize(NSSize(width: width, height: 600))
            for collapsed in [false, true] {
                try await eventually("sidebar acknowledges resized window") { controller.sidebar.automaticRail == (width != 1250) }
                controller.compactSidebar = collapsed
                try await waitForSidebar(window, rail: controller.sidebar.reservesRail, overlay: controller.sidebar.overlay)
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
        try await waitForSidebar(window, rail: controller.sidebar.reservesRail, overlay: controller.sidebar.overlay)
        controller.session.settings.privacy.setCookieBannerMode(.hide)
        tab.reload()
        try await eventually("cookie banner protection", timeout: 40) {
            guard !tab.isLoading else { return false }
            let display = try? await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#onetrust-banner-sdk')).display") as? String
            return display == "none"
        }
        let audit = BackgroundUIMode.audit()
        XCTAssertEqual(audit.onscreenWindowViolations, 0)
    }
    func testSidebarKeepsNewTabAndToolbarReclaimsItsWidth() async throws {
        let controller = BrowserController(testing: true)
        let window = makeWindow(controller, width: 1050, largestText: false)
        defer { window.close(); controller.shutdown() }
        for rail in [false, true] {
            controller.compactSidebar = rail
            try await eventually("sidebar fixture state") {
                self.marker("browserOverviewGeometry", in: window) != nil &&
                    (self.marker("sidebarSurfaceGeometry", in: window)?.bounds.width ?? 0) ==
                        (rail ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth)
            }
            let sidebar = try frame("sidebarSurfaceGeometry", in: window)
            let newTab = try frame("sidebarNewTabGeometry", in: window)
            let toolbar = try frame("browserTopBarGeometry", in: window)
            XCTAssertTrue(sidebar.contains(newTab))
            XCTAssertFalse(toolbar.intersects(newTab))
            for name in ["browserPrivacyGeometry", "browserOverviewGeometry", "browserPageMenuGeometry"] {
                XCTAssertTrue(toolbar.contains(try frame(name, in: window)))
            }
            XCTAssertGreaterThan(try frame("browserAddressGeometry", in: window).width, rail ? 600 : 570)
        }
    }

    func testStartPageRendersRegularTilesAndHidesThemInPrivateAndAfterClear() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionFileStore(fileURL: BrowserProfile.personal.directory(in: root).appendingPathComponent("session.json"))
        let bookmark = Bookmark(title: "Saved fixture", url: URL(string: "https://saved.example")!)
        let history = HistoryEntry(title: "Frequent fixture", url: URL(string: "https://frequent.example")!, visitCount: 5)
        try store.save(BrowserSnapshot(bookmarks: [bookmark], history: [history], legacyBookmarksImported: true))
        let controller = BrowserController(rootDirectory: root, testing: true)
        let regular = try XCTUnwrap(controller.session.selectedTab)
        let window = makeWindow(controller, largestText: false)
        defer { window.close(); controller.shutdown() }
        try await eventually("sidebar fixture state") { self.marker("homeBookmarks", in: window) != nil && self.marker("homeFrequent", in: window) != nil }
        XCTAssertFalse(regular.isInstantiated)
        controller.newTab(isPrivate: true)
        try await eventually("sidebar fixture state") { self.marker("homeBookmarks", in: window) == nil && self.marker("homeFrequent", in: window) == nil }
        controller.session.selectTab(regular.id)
        try await eventually("sidebar fixture state") { self.marker("homeFrequent", in: window) != nil }
        controller.session.clearHistory()
        try await eventually("sidebar fixture state") { self.marker("homeBookmarks", in: window) != nil && self.marker("homeFrequent", in: window) == nil }
    }

    func testPrivacyShieldOpensRealPopover() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles, width: 1250); defer { window.close() }
        try await eventually("sidebar fixture state") { self.marker("browserPrivacyGeometry", in: window) != nil }
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
        try await eventually("sidebar fixture state") {
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
        try await waitForSidebar(window, rail: false)
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let parents = types.map { window.standardWindowButton($0)?.superview }
        for collapsed in [false, true, false] {
            profiles.controller.compactSidebar = collapsed
            try await waitForSidebar(window, rail: collapsed)
            try await eventually("native traffic-light frames") {
                types.enumerated().allSatisfy { index, type in
                    guard let button = window.standardWindowButton(type) else { return false }
                    let inset = collapsed ? MacBrowserLayout.railLightsInset : MacBrowserLayout.lightsInset
                    return abs(button.convert(button.bounds, to: nil).minX - inset - CGFloat(index) * MacBrowserLayout.lightsSpacing) < 1
                }
            }
            try checkGeometry(window, collapsed: collapsed)
            for (i, type) in types.enumerated() {
                let button = try XCTUnwrap(window.standardWindowButton(type))
                XCTAssertTrue(button.superview === parents[i])
                let frame = button.convert(button.bounds, to: nil)
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(button.window === window && window.isVisible)
                XCTAssertEqual(frame.minX, (collapsed ? MacBrowserLayout.railLightsInset : MacBrowserLayout.lightsInset) + CGFloat(i) * MacBrowserLayout.lightsSpacing, accuracy: 1)
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
        try await eventually("sidebar fixture state") { self.address(in: window) != nil }
        let field = try XCTUnwrap(address(in: window))
        let id = profiles.controller.session.selectedTabID
        let request = profiles.controller.addressFocusRequest
        for collapsed in [true, false, true] {
            profiles.controller.compactSidebar = collapsed
            try await waitForSidebar(window, rail: collapsed)
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
        try await eventually("sidebar fixture state") { !tab.webView.isLoading && tab.url != nil }
        let window = makeWindow(controller, profiles: profiles); defer { window.close() }
        try await eventually("sidebar fixture state") { self.address(in: window) != nil }
        let field = try XCTUnwrap(address(in: window))
        try await eventually("sidebar fixture state") { abs(tab.webView.obscuredContentInsets.top - MacBrowserLayout.headerHeight) < 1 }
        XCTAssertEqual(tab.webView.obscuredContentInsets.top, MacBrowserLayout.headerHeight, accuracy: 1)
        window.makeFirstResponder(tab.webView)
        try await eventually("sidebar fixture state") { field.currentEditor() == nil }
        controller.focusAddress()
        try await eventually("sidebar fixture state") { field.currentEditor()?.string == url }
        XCTAssertEqual(field.currentEditor()?.selectedRange, NSRange(location: 0, length: (url as NSString).length))
        window.makeFirstResponder(tab.webView)
        try await eventually("sidebar fixture state") { field.currentEditor() == nil }
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
        try await eventually("sidebar fixture state") { field.currentEditor()?.string == url }
    }
    func testRightToLeftMirrorsSidebarRailRowsAndNativeLights() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let controller = profiles.controller
        let window = makeWindow(controller, profiles: profiles, width: 1040, rtl: true); defer { window.close() }
        let tab = try XCTUnwrap(controller.session.selectedTab)
        for rail in [false, true] {
            controller.compactSidebar = rail
            let width = rail ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth
            try await eventually("RTL sidebar and toolbar positions") {
                window.contentView?.layoutSubtreeIfNeeded()
                return abs((self.geometry("sidebarSurfaceGeometry", in: window)?.minX ?? 0) - (1040 - width)) < 1
                    && abs((self.geometry("browserTopBarGeometry", in: window)?.maxX ?? 0) - (1040 - width)) < 1
                    && self.marker("sidebarFavicon-\(tab.id)", in: window) != nil
            }
            let sidebar = try frame("sidebarSurfaceGeometry", in: window)
            let row = try frame("sidebarItem-\(tab.id)", in: window)
            let icon = try frame("sidebarFavicon-\(tab.id)", in: window)
            let field = try XCTUnwrap(address(in: window))
            XCTAssertTrue(sidebar.contains(row))
            XCTAssertTrue(row.contains(icon))
            XCTAssertTrue((try frame("browserTopBarGeometry", in: window)).contains(field.convert(field.bounds, to: nil)))
            if rail {
                XCTAssertEqual(icon.midX, row.midX, accuracy: 1)
            } else {
                XCTAssertEqual(row.maxX - icon.maxX, MacBrowserLayout.sidebarRowInset, accuracy: 1)
            }
            for (index, button) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                let view = try XCTUnwrap(window.standardWindowButton(button))
                let rect = view.convert(view.bounds, to: nil)
                XCTAssertEqual(sidebar.maxX - rect.maxX,
                    (rail ? MacBrowserLayout.railLightsInset : MacBrowserLayout.lightsInset) + CGFloat(index) * MacBrowserLayout.lightsSpacing,
                    accuracy: 1)
            }
        }
        tab.webView.loadHTMLString("<body>Page direction fixture</body>",
            baseURL: URL(string: "http://127.0.0.1:18768/rtl-page"))
        try await eventually("LTR document displayed in RTL chrome") {
            tab.hasRenderedContent && tab.webView.window === window && !tab.isLoading
        }
        let result = try await tab.webView.evaluateJavaScript("getComputedStyle(document.documentElement).direction")
        XCTAssertEqual(result as? String, "ltr")
    }
    func testFullscreenOpenCollapsedAndReturnedGeometry() async throws {
        try XCTSkipUnless(BackgroundUIMode.foregroundAllowed, BackgroundUIMode.foregroundOnlyReason)
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles); defer { window.close() }
        window.collectionBehavior.insert(.fullScreenPrimary)
        try await Task.sleep(for: .milliseconds(400))
        window.toggleFullScreen(nil)
        try await eventually("sidebar fixture state") { window.styleMask.contains(.fullScreen) }
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
        try await eventually("sidebar fixture state") { !window.styleMask.contains(.fullScreen) }
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
        try await waitForSidebar(window, rail: true)
        try checkGeometry(window, collapsed: true)
        controller.compactSidebar = true
        try await waitForSidebar(window, rail: true)
        try checkGeometry(window, collapsed: true)
    }
    func testSidebarToggleKeyboardShortcutUsesOneSurvivingControl() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles); defer { window.close() }
        try await waitForSidebar(window, rail: false)
        for collapsed in [true, false] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s",
                isARepeat: false, keyCode: 1))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            try await eventually("sidebar fixture state") { profiles.controller.compactSidebar == collapsed }
            try await waitForSidebar(window, rail: collapsed)
            try checkGeometry(window, collapsed: collapsed)
        }
    }

    func testWindowAccessibilityOrderStartsWithRealWindowButtons() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles); defer { window.close() }
        try await eventually("native accessibility navigation order") {
            window.accessibilityChildrenInNavigationOrder()?.count ?? 0 > 3
        }
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
        try await eventually("sidebar fixture state") { tab.url != nil && !tab.webView.isLoading }
        for _ in 0..<8 { _ = controller.session.addTab(url: nil, select: false, load: false) }
        let window = makeWindow(controller, profiles: profiles); defer { window.close() }
        try XCTSkipIf(BackgroundUIMode.isEnabled && !window.isKeyWindow,
            "System keyboard-focus handoff needs a key window; inactive accessory mode refused it. ORIV_FOREGROUND_UI=1 requires orchestrator approval.")
        func searchField() -> NSTextField? {
            window.contentView.flatMap {
                descendants($0).compactMap { $0 as? NSTextField }.first {
                    $0.accessibilityIdentifier() == "tabSearchField" || $0.placeholderString == "Search tabs"
                }
            }
        }
        try await eventually("native focus fields") { searchField() != nil && self.address(in: window) != nil }
        let search = try XCTUnwrap(searchField())
        let field = try XCTUnwrap(address(in: window))
        window.makeFirstResponder(search)
        try await eventually("sidebar fixture state") { search.currentEditor() != nil }
        let context = MacBrowserWindowContext(); context.window = window
        XCTAssertTrue(context.sidebarContainsFocus, "Native search focus must be detectable before collapse")
        let request = controller.addressFocusRequest
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s",
            isARepeat: false, keyCode: 1))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        try await waitForSidebar(window, rail: true)
        try checkGeometry(window, collapsed: true)
        XCTAssertNil(field.currentEditor(), "Removing sidebar focus must select the surviving toggle, not the address")
        XCTAssertEqual(controller.addressFocusRequest, request)
        XCTAssertTrue(window.firstResponder is NSView)
    }

    func testFullscreenLayoutGeometryWithoutAWindowServerTransition() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles); defer { window.close() }
        try await eventually("window chrome attachment") {
            self.marker("browserSidebarGeometry", in: window) != nil
        }
        let chrome = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? BrowserWindowChrome.WindowChromeView }.first })
        chrome.simulatesFullscreenLayout = true
        chrome.configure()
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = true }
        for collapsed in [false, true] {
            profiles.controller.compactSidebar = collapsed
            try await waitForSidebar(window, rail: collapsed)
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
        try await eventually("windowed title bar restored") { window.titlebarAppearsTransparent }
        try checkGeometry(window, collapsed: true)
        let returned = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertFalse(returned.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(returned.convert(returned.bounds, to: nil).minX, MacBrowserLayout.railLightsInset, accuracy: 1)
        if BackgroundUIMode.isEnabled {
            XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        }
    }

}
