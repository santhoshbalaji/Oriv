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
                            appearance: BrowserAppearance = .t3Code, key: Bool = true) -> NSWindow {
        let root = BrowserWindow(controller: controller, profiles: profiles)
            .browserAppearance(appearance)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight).dynamicTypeSize(largestText ? .accessibility5 : .large)
        let host = NSHostingController(rootView: root)
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 60, y: 60, width: width, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: width, height: 600))
        BackgroundUIMode.show(window, key: key, activate: key && BackgroundUIMode.foregroundAllowed)
        return window
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func marker(_ name: String, in window: NSWindow) -> NSView? {
        window.contentView.flatMap { descendants($0).first { $0.identifier?.rawValue == name } }
    }
    private func markers(_ name: String, in window: NSWindow) -> [NSView] {
        window.contentView.map { descendants($0).filter { $0.identifier?.rawValue == name } } ?? []
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
    func testProfileDotsKeepFooterFramesAndMirrorWithoutAppearingInPrivateOrRail() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let controller = profiles.controller
        let window = makeWindow(controller, profiles: profiles, largestText: false, key: false)
        defer { window.close() }
        let footer = ["sidebarFooterGeometry", "sidebarFooter-Settings"] + LibrarySection.allCases.map { "sidebarFooter-\($0.rawValue)" }
        try await eventually("one-profile footer") { footer.allSatisfy { self.geometry($0, in: window) != nil } }
        let baseline = try footer.map { try frame($0, in: window) }
        XCTAssertNil(marker("sidebarProfileDotsGeometry", in: window))
        for name in ["Work", "Reading"] { try profiles.create(name: name, color: .ocean, symbol: .work) }
        try await eventually("three profile dots") { self.marker("sidebarProfileDot-2", in: window) != nil }
        let dots = try frame("sidebarProfileDotsGeometry", in: window)
        XCTAssertEqual(dots.height, OrivTarget.macMinimum.height, accuracy: 1)
        XCTAssertEqual(dots.minY, try frame("sidebarFooterGeometry", in: window).maxY, accuracy: 1)
        for (name, old) in zip(footer, baseline) {
            let new = try frame(name, in: window)
            XCTAssertEqual(new.minX, old.minX, accuracy: 1, name)
            XCTAssertEqual(new.minY, old.minY, accuracy: 1, name)
            XCTAssertEqual(new.width, old.width, accuracy: 1, name)
            XCTAssertEqual(new.height, old.height, accuracy: 1, name)
            XCTAssertGreaterThanOrEqual(new.width, OrivTarget.macMinimum.width, name)
            XCTAssertGreaterThanOrEqual(new.height, OrivTarget.macMinimum.height, name)
        }
        XCTAssertLessThan(try frame("sidebarProfileDot-0", in: window).midX, try frame("sidebarProfileDot-2", in: window).midX)
        let rtl = makeWindow(controller, profiles: profiles, rtl: true, largestText: false, key: false)
        defer { rtl.close() }
        try await eventually("RTL profile dots") { self.marker("sidebarProfileDot-2", in: rtl) != nil }
        XCTAssertGreaterThan(try frame("sidebarProfileDot-0", in: rtl).midX, try frame("sidebarProfileDot-2", in: rtl).midX)

        controller.compactSidebar = true
        try await eventually("profile dots removed in rail") { self.marker("sidebarProfileDotsGeometry", in: window) == nil }
        let privateID = profiles.createPrivateWindow()
        let privateController = try XCTUnwrap(profiles.privateWindows[privateID])
        let privateWindow = makeWindow(privateController, key: false)
        defer { privateWindow.close() }
        try await eventually("private footer") { self.marker("sidebarFooterGeometry", in: privateWindow) != nil }
        XCTAssertNil(marker("sidebarProfileDotsGeometry", in: privateWindow))
        // The external scene supplies the same profile-less controller type
        // together with the regular registry. Model that wiring without opening
        // a second SwiftUI scene or delivering a real URL.
        let externalWindow = makeWindow(privateController, profiles: profiles, key: false)
        defer { externalWindow.close() }
        try await eventually("external private footer") { self.marker("sidebarFooterGeometry", in: externalWindow) != nil }
        XCTAssertNil(marker("sidebarProfileDotsGeometry", in: externalWindow))
    }

    private func waitForSidebar(_ window: NSWindow, rail: Bool, overlay: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let reserved = rail ? MacBrowserLayout.railReservation : MacBrowserLayout.expandedReservation()
        let expectedWidth = overlay ? MacBrowserLayout.sidebarWidth : (rail ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth)
        try await eventually("sidebar and toolbar geometry", file: file, line: line) {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let surface = self.geometry("sidebarSurfaceGeometry", in: window),
                  let toolbar = self.geometry("browserTopBarGeometry", in: window) else { return false }
            return abs(surface.width - expectedWidth) <= 1
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
        let contentFrame = content.convert(content.bounds, to: nil)
        let inset = MacBrowserLayout.windowInset
        let expectedReservation = collapsed ? MacBrowserLayout.railReservation : MacBrowserLayout.expandedReservation()
        let top = try XCTUnwrap(marker("browserTopBarGeometry", in: window), file: file, line: line)
        let topFrame = top.convert(top.bounds, to: nil)
        XCTAssertEqual(topFrame.minX, expectedReservation, accuracy: 1, file: file, line: line)
        XCTAssertEqual(topFrame.maxX, contentFrame.maxX - inset, accuracy: 1, file: file, line: line)
        XCTAssertEqual(topFrame.maxY, contentFrame.maxY - inset, accuracy: 1, file: file, line: line)
        XCTAssertEqual(topFrame.height, MacBrowserLayout.headerHeight, accuracy: 1, file: file, line: line)
        let card = try XCTUnwrap(marker("browserPageCardGeometry", in: window), file: file, line: line)
        let cardFrame = card.convert(card.bounds, to: nil)
        XCTAssertEqual(cardFrame.minX, expectedReservation, accuracy: 1, file: file, line: line)
        XCTAssertEqual(cardFrame.maxX, contentFrame.maxX - inset, accuracy: 1, file: file, line: line)
        XCTAssertEqual(cardFrame.minY, inset, accuracy: 1, file: file, line: line)
        XCTAssertEqual(cardFrame.maxY, contentFrame.maxY - inset, accuracy: 1, file: file, line: line)
        do {
            // Measure the floating v3 sidebar card surface.
            let sidebar = try XCTUnwrap(marker("sidebarSurfaceGeometry", in: window), file: file, line: line)
            let rect = sidebar.convert(sidebar.bounds, to: nil)
            XCTAssertEqual(rect.minX, inset, accuracy: 1, file: file, line: line)
            XCTAssertEqual(rect.minY, inset, accuracy: 1, file: file, line: line)
            XCTAssertEqual(rect.width, overlay ? MacBrowserLayout.sidebarWidth : (collapsed ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth), accuracy: 1, file: file, line: line)
            XCTAssertEqual(rect.height, content.bounds.height - 2 * inset, accuracy: 1, file: file, line: line)
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
        let expectedGrid = SidebarTabs.PinGrid(availableWidth: row.width)
        XCTAssertEqual(expectedGrid.columns, 4)
        XCTAssertEqual(tiles.first?.minX, row.minX)
        XCTAssertEqual(tiles.last?.maxX ?? 0, row.maxX, accuracy: 1)
        for (index, tile) in tiles.enumerated() {
            XCTAssertEqual(tile.minY, tiles[0].minY)
            XCTAssertEqual(tile.height, OrivMacV3.SidebarLayout.pinHeight, accuracy: 1)
            XCTAssertEqual(tile.width, expectedGrid.tileWidth, accuracy: 1)
            let step = expectedGrid.tileWidth + OrivMacV3.SidebarLayout.pinGap
            XCTAssertEqual(tile.minX - row.minX, CGFloat(index) * step, accuracy: 1)
        }
        let gap = NSPoint(x: (tiles[0].maxX + tiles[1].minX) / 2, y: tiles[0].midY)
        let pins = session.orderedTabs.filter(\.isPinned)
        let target = list.sidebar?.dropTarget(at: gap)
        XCTAssertTrue(target == .between(pins[0].id, after: true) || target == .between(pins[1].id, after: false))
        let active = try XCTUnwrap(session.selectedTabID)
        let selection = try frame("sidebarSelection-\(active)", in: window)
        let favicon = try frame("sidebarFavicon-\(active)", in: window)
        XCTAssertEqual(favicon.width, OrivMacV3.SidebarLayout.pinIconSize, accuracy: 1)
        XCTAssertEqual(selection.midX, favicon.midX, accuracy: 1)
        XCTAssertEqual(selection.midY, favicon.midY, accuracy: 1)
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

    func testPinnedHoverCloseMirrorsAcrossSelectedTileInRTL() async throws {
        for rtl in [false, true] {
            let controller = BrowserController(testing: true)
            defer { controller.shutdown() }
            let tab = controller.session.addTab(load: false)
            controller.session.togglePinned(tab.id)
            let window = makeWindow(controller, rtl: rtl, largestText: false, appearance: .light, key: false)
            defer { window.close() }
            let closeName = "sidebarClose-\(tab.id)"
            let selectionName = "sidebarSelection-\(tab.id)"
            try await eventually("selected pin pill") { self.marker(selectionName, in: window) != nil }
            XCTAssertNil(marker(closeName, in: window))
            let content = try XCTUnwrap(window.contentView)
            let list = try XCTUnwrap(descendants(content).compactMap { $0 as? SidebarTabCollection }.first)
            let data = try XCTUnwrap(list.sidebar)
            data.setHovered(try XCTUnwrap(data.path(for: tab.id)))
            try await eventually("pinned close target on hover") { self.marker(closeName, in: window) != nil }
            let close = try frame(closeName, in: window)
            let selection = try frame(selectionName, in: window)
            let icon = try frame("sidebarFavicon-\(tab.id)", in: window)
            XCTAssertEqual(close.width, OrivMacV3.SidebarLayout.pinCloseWidth, accuracy: 1)
            XCTAssertEqual(close.height, OrivMacV3.SidebarLayout.pinCloseHeight, accuracy: 1)
            XCTAssertEqual(selection.midX, icon.midX, accuracy: 1)
            XCTAssertEqual(selection.midY, icon.midY, accuracy: 1)
            if rtl { XCTAssertLessThan(close.midX, icon.midX) }
            else { XCTAssertGreaterThan(close.midX, icon.midX) }
            let path = try XCTUnwrap(data.path(for: tab.id))
            let row = try XCTUnwrap(list.item(at: path)?.view)
            XCTAssertEqual(row.toolTip, tab.displayTitle)
            XCTAssertTrue(row.accessibilityLabel()?.contains(tab.displayTitle) == true)
            XCTAssertTrue(row.accessibilityLabel()?.contains("Selected") == true)
            XCTAssertEqual(row.accessibilityValue() as? String, "Pinned, 1 of 1")
            XCTAssertFalse(list.interact(at: NSPoint(x: icon.midX, y: icon.midY)))
            XCTAssertTrue(list.interact(at: NSPoint(x: close.midX, y: close.midY)))
            XCTAssertFalse(controller.session.tabs.contains { $0.id == tab.id })
        }
    }

    func testAttachedSidebarAndRailAtMinimumAndAfterResize() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let window = makeWindow(profiles.controller, profiles: profiles, width: 760); defer { window.close() }
        try await eventually("sidebar fixture state") { (self.marker("browserSidebarGeometry", in: window)?.bounds.height ?? 0) > 500 && profiles.controller.sidebar.rail }
        try await waitForSidebar(window, rail: true)
        try checkGeometry(window, collapsed: true)
        window.setContentSize(NSSize(width: 1280, height: 820))
        try await waitForSidebar(window, rail: false)
        try checkGeometry(window, collapsed: false)
    }
    func testExpandedAndNarrowOverlayKeepInternalInsetsOnFlushSurface() async throws {
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
            XCTAssertEqual(row.height, OrivMacV3.SidebarLayout.tabRowHeight, accuracy: 1)
            XCTAssertEqual(icon.width, OrivMacV3.SidebarLayout.tabFaviconSize, accuracy: 1)
            XCTAssertEqual(icon.minX - row.minX, OrivMacV3.SidebarLayout.tabRowPaddingHorizontal, accuracy: 1)
            XCTAssertEqual(try frame("sidebarSection-Tabs", in: window).minX, icon.minX, accuracy: 1)
            let toolbar = try frame("browserTopBarGeometry", in: window)
            XCTAssertEqual(surface.minX, MacBrowserLayout.windowInset, accuracy: 1)
            XCTAssertEqual(surface.minY, MacBrowserLayout.windowInset, accuracy: 1)
            XCTAssertEqual(toolbar.minX, controller.sidebar.reservation, accuracy: 1)
            if controller.sidebar.narrowOverlay {
                XCTAssertGreaterThan(surface.maxX, toolbar.minX)
            } else {
                XCTAssertEqual(toolbar.minX - surface.maxX, MacBrowserLayout.sidebarCardGap, accuracy: 1)
            }
            XCTAssertEqual(surface.maxY, toolbar.maxY, accuracy: 1)
            XCTAssertEqual(try frame("sidebarSearchGeometry", in: window).height, OrivMacV3.SidebarLayout.searchHeight, accuracy: 1)
            let footer = try frame("sidebarFooterGeometry", in: window)
            XCTAssertEqual(footer.height, OrivMacV3.SidebarLayout.footerHeight, accuracy: 1)
            let footerTitles = LibrarySection.allCases.map(\.rawValue) + ["Settings"]
            let footerButtons = try footerTitles.map { try frame("sidebarFooter-\($0)", in: window) }
            for (title, button) in zip(footerTitles, footerButtons) {
                XCTAssertTrue(footer.contains(button), title)
                XCTAssertGreaterThanOrEqual(button.width, OrivMacV3.SidebarLayout.footerButtonSize, title)
                XCTAssertEqual(button.height, OrivMacV3.SidebarLayout.footerButtonSize, accuracy: 1, title)
            }
            for (left, right) in zip(footerButtons, footerButtons.dropFirst()) {
                XCTAssertLessThanOrEqual(left.maxX, right.minX)
            }
            XCTAssertEqual(footer.minY - surface.minY, MacBrowserLayout.sidebarInset, accuracy: 1)
            // Q4: With few tabs, New Tab sits inline directly under the last tab row (6 pt gap).
            let newTab = try frame("sidebarNewTabGeometry", in: window)
            XCTAssertEqual(newTab.height, OrivMacV3.SidebarLayout.newTabHeight, accuracy: 1)
            XCTAssertEqual(row.minY - newTab.maxY, OrivMacV3.SidebarLayout.newTabTopMargin, accuracy: 1.5)
            XCTAssertGreaterThan(newTab.minY, footer.maxY)
            XCTAssertEqual(try frame("sidebarTitlebarGeometry", in: window).height, MacBrowserLayout.sidebarTitlebarHeight, accuracy: 1)
            XCTAssertEqual(surface.maxY - (try frame("sidebarProfileGeometry", in: window)).maxY, MacBrowserLayout.sidebarTitlebarHeight, accuracy: 1)
            XCTAssertEqual(surface.maxY - (try frame("sidebarToggleGeometry", in: window)).midY, MacBrowserLayout.sidebarTitlebarHeight / 2, accuracy: 1)
            XCTAssertEqual((try frame("sidebarToggleGeometry", in: window)).midY, toolbar.midY, accuracy: 1)
        }
    }

    func testRailUsesMinimumWidthAndInsetGlass() async throws {
        let controller = BrowserController(testing: true); defer { controller.shutdown() }
        controller.compactSidebar = true
        let window = makeWindow(controller, largestText: false); defer { window.close() }
        try await eventually("window chrome attachment") {
            self.marker("browserSidebarGeometry", in: window) != nil
        }
        let chrome = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? BrowserWindowChrome.WindowChromeView }.first })
        for fullscreen in [false, true] {
            chrome.simulatesFullscreenLayout = fullscreen; chrome.configure()
            let expectedTopInset = fullscreen ? MacBrowserLayout.railFullscreenTopInset : MacBrowserLayout.sidebarTitlebarHeight
            try await eventually("rail toggle position") {
                guard let surface = self.geometry("sidebarSurfaceGeometry", in: window),
                      let toggle = self.geometry("sidebarToggleGeometry", in: window) else { return false }
                return abs(surface.maxY - toggle.maxY - expectedTopInset) <= 1
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
            XCTAssertEqual(surface.maxY - toggle.maxY, expectedTopInset, accuracy: 1)
            XCTAssertEqual(try frame("sidebarFooter-Settings", in: window).minY - surface.minY, OrivSpacing.small, accuracy: 1)
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
        XCTAssertEqual(surface.maxY - profile.maxY, OrivSpacing.xs, accuracy: 1)
        XCTAssertEqual(surface.maxY - toggle.maxY, OrivSpacing.xs, accuracy: 1)
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
        try await waitForTitlebar(window, height: MacBrowserLayout.sidebarTitlebarHeight)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(try frame("sidebarTitlebarGeometry", in: window).height, MacBrowserLayout.sidebarTitlebarHeight, accuracy: 1)
    }

    func testProfileNameAlignsWithoutRedundantCountAndStaysClearOfSearchAndToggle() async throws {
        for appearance in [BrowserAppearance.light, .dark] {
            let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
            for _ in 0..<2 { _ = profiles.controller.session.addTab(select: false, load: false) }
            let window = makeWindow(profiles.controller, profiles: profiles, largestText: false, appearance: appearance)
            defer { window.close() }
            try await waitForTitlebar(window, height: MacBrowserLayout.sidebarTitlebarHeight)
            let chrome = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? BrowserWindowChrome.WindowChromeView }.first })
            for fullscreen in [false, true] {
                chrome.simulatesFullscreenLayout = fullscreen; chrome.configure()
                try await waitForTitlebar(window, height: fullscreen ? 0 : MacBrowserLayout.sidebarTitlebarHeight)
                let profile = try frame("sidebarProfileGeometry", in: window)
                let name = try frame("sidebarProfileNameGeometry", in: window)
                let search = try frame("sidebarSearchGeometry", in: window)
                let toggle = try frame("sidebarToggleGeometry", in: window)
                XCTAssertEqual(profile.minX, MacBrowserLayout.windowInset + MacBrowserLayout.sidebarInset, accuracy: 1)
                XCTAssertEqual(profile.height, OrivMacV3.SidebarLayout.profileHeight, accuracy: 1)
                XCTAssertNil(marker("sidebarProfileCountGeometry", in: window), "Phase 4 removes redundant tab count next to profile name")
                XCTAssertTrue(profile.contains(name))
                XCTAssertEqual(profile.minY - search.maxY, OrivMacV3.SidebarLayout.profileBottomMargin, accuracy: 1)
                XCTAssertFalse(profile.intersects(toggle)); XCTAssertFalse(search.intersects(toggle))
            }
        }
    }

    func testNewTabSitsInlineBelowLastTabAndSticksOnOverflow() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        _ = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        let controller = profiles.controller
        let window = makeWindow(controller, profiles: profiles, largestText: false, appearance: .light, key: false)
        defer { window.close() }
        try await waitForSidebar(window, rail: false)
        let firstTab = try XCTUnwrap(controller.session.orderedTabs.last)
        try await eventually("inline new tab directly below last tab") {
            guard let row = self.geometry("sidebarItem-\(firstTab.id)", in: window),
                  let newTab = self.geometry("sidebarNewTabGeometry", in: window) else { return false }
            return abs((row.minY - newTab.maxY) - OrivMacV3.SidebarLayout.newTabTopMargin) <= 1.5
        }
        let dots = try frame("sidebarProfileDotsGeometry", in: window)
        let inlineNewTab = try frame("sidebarNewTabGeometry", in: window)
        XCTAssertGreaterThan(inlineNewTab.minY, dots.maxY + 40, "Inline New Tab should sit below the last tab, not pinned to the bottom")

        // Overflow the tab list: New Tab must stick to the bottom of the tab area directly above profile dots.
        for index in 0..<24 {
            _ = controller.session.addTab(url: URL(string: "https://overflow\(index).example"), select: false, load: false)
        }
        try await eventually("sticky new tab above profile dots on overflow") {
            guard let sticky = self.geometry("sidebarNewTabGeometry", in: window),
                  let dots = self.geometry("sidebarProfileDotsGeometry", in: window) else { return false }
            return abs((sticky.minY - dots.maxY) - MacBrowserLayout.sidebarFooterGap) <= 1.5
        }
        let stickyNewTab = try frame("sidebarNewTabGeometry", in: window)
        XCTAssertEqual(stickyNewTab.height, OrivMacV3.SidebarLayout.newTabHeight, accuracy: 1)
        XCTAssertEqual(stickyNewTab.minY - dots.maxY, MacBrowserLayout.sidebarFooterGap, accuracy: 1.5)
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
                (self.marker("sidebarSurfaceGeometry", in: window)?.bounds.width ?? 0) ==
                        (rail ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth)
            }
            let sidebar = try frame("sidebarSurfaceGeometry", in: window)
            let newTab = try frame("sidebarNewTabGeometry", in: window)
            let toolbar = try frame("browserTopBarGeometry", in: window)
            XCTAssertTrue(sidebar.contains(newTab))
            XCTAssertFalse(toolbar.intersects(newTab))
            for name in ["browserPrivacyGeometry", "browserPageMenuGeometry"] {
                XCTAssertTrue(toolbar.contains(try frame(name, in: window)))
            }
            let address = try frame("browserAddressGeometry", in: window)
            let card = try frame("browserPageCardGeometry", in: window)
            let expectedWidth = OrivMacV3.StartLayout.columnWidth(for: card.width)
            XCTAssertEqual(address.width, expectedWidth, accuracy: 1)
            XCTAssertEqual(address.height, OrivMacV3.StartLayout.bigFieldSize.height, accuracy: 1)
            XCTAssertEqual(address.midX, toolbar.midX, accuracy: 1)
            XCTAssertLessThan(address.maxY, toolbar.minY, "Start page renders the address field in-page below the toolbar")
        }
    }

    func testStartPageAddressFieldFollowsItsSlotBelowTopBars() async throws {
        let controller = BrowserController(testing: true)
        try controller.session.applyContinuity(bookmarks: [Bookmark(title: "Example", url: URL(string: "https://example.com")!, createdAt: .now)], history: [])
        let window = makeWindow(controller, width: 1280, largestText: false)
        window.setContentSize(NSSize(width: 1280, height: 860))
        defer { window.close(); controller.shutdown() }
        func gap() async throws -> CGFloat {
            try await eventually("start page address and bookmarks") {
                self.marker("homeBookmarks", in: window) != nil && self.marker("browserAddressGeometry", in: window) != nil
            }
            let address = try frame("browserAddressGeometry", in: window)
            let bookmarks = try frame("homeBookmarks", in: window)
            XCTAssertEqual(address.height, OrivMacV3.StartLayout.bigFieldSize.height, accuracy: 1)
            return bookmarks.maxY - address.minY
        }
        let plain = try await gap()
        controller.profileUI.showFind = true
        try await eventually("find bar shown") { self.marker("browserFindBarGeometry", in: window) != nil }
        try await Task.sleep(for: .milliseconds(400))
        // AppKit's y axis points up: the field keeps its place relative to the page content.
        let withFindBar = try await gap()
        XCTAssertEqual(withFindBar, plain, accuracy: 1, "The start-page field stays in its slot when a bar pushes the page down")
    }

    func testStartPageResponsiveBreakpointsWrapBookmarksAndCollapseCards() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionFileStore(fileURL: BrowserProfile.personal.directory(in: root).appendingPathComponent("session.json"))
        let now = Date()
        let bookmarks = (1...8).map { i in
            Bookmark(title: "Site \(i)", url: URL(string: "https://site\(i).example")!, createdAt: now.addingTimeInterval(Double(i)))
        }
        let history = (1...6).map { i in
            HistoryEntry(title: "Frequent \(i)", url: URL(string: "https://freq\(i).example")!, visitedAt: now, visitCount: 5)
        }
        try store.save(BrowserSnapshot(bookmarks: bookmarks, history: history, legacyBookmarksImported: true))
        let controller = BrowserController(rootDirectory: root, testing: true)
        let window = makeWindow(controller, width: 1280, largestText: false)
        window.setContentSize(NSSize(width: 1280, height: 860))
        defer { window.close(); controller.shutdown() }
        try await eventually("start page tiles mounted") {
            self.markers("homeBookmarks-tile", in: window).count == 8
                && self.markers("homeFrequent-tile", in: window).count == 6
        }
        // Wide card (>= 772 pt): 8 bookmarks in 1 row, 6 frequent sites in 2 columns (3 rows).
        let wideBookmarkYs = Set(markers("homeBookmarks-tile", in: window).map { Int($0.convert($0.bounds, to: nil).midY.rounded()) })
        let wideFrequentXs = Set(markers("homeFrequent-tile", in: window).map { Int($0.convert($0.bounds, to: nil).minX.rounded()) })
        XCTAssertEqual(wideBookmarkYs.count, 1, "8 bookmarks stay in a single row when card >= 772 pt")
        XCTAssertEqual(wideFrequentXs.count, 2, "Frequently Visited uses 2 columns when card >= 600 pt")

        // Narrow card (< 772 pt, >= 600 pt): bookmarks wrap to 4 × 2, Frequently Visited stays 2 columns.
        window.setContentSize(NSSize(width: 980, height: 860))
        try await eventually("bookmarks wrapped to 2 rows") {
            guard let card = self.marker("browserPageCardGeometry", in: window) else { return false }
            let ys = Set(self.markers("homeBookmarks-tile", in: window).map { Int($0.convert($0.bounds, to: nil).midY.rounded()) })
            return card.bounds.width < OrivMacV3.StartLayout.bookmarkWrapCardWidth
                && card.bounds.width >= OrivMacV3.StartLayout.frequentCollapseCardWidth
                && ys.count == 2
        }
        let midFrequentXs = Set(markers("homeFrequent-tile", in: window).map { Int($0.convert($0.bounds, to: nil).minX.rounded()) })
        XCTAssertEqual(midFrequentXs.count, 2, "Frequently Visited stays 2 columns above 600 pt card width")

        // Extra-narrow card (< 600 pt): Frequently Visited collapses to 1 column.
        window.setContentSize(NSSize(width: 820, height: 860))
        try await eventually("frequent card collapsed to 1 column") {
            guard let card = self.marker("browserPageCardGeometry", in: window) else { return false }
            let xs = Set(self.markers("homeFrequent-tile", in: window).map { Int($0.convert($0.bounds, to: nil).minX.rounded()) })
            return card.bounds.width < OrivMacV3.StartLayout.frequentCollapseCardWidth && xs.count == 1
        }

        // Private start page card shows on private tab and hides regular tiles.
        controller.newTab(isPrivate: true)
        try await eventually("private start card mounted") {
            self.marker("homePrivateCard", in: window) != nil
                && self.marker("homeBookmarks", in: window) == nil
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

    func testSitePrivacyPopoverFitsShortContent() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let controller = profiles.controller
        let window = makeWindow(controller, profiles: profiles)
        defer { window.close() }

        controller.profileUI.showProtection = true
        try await eventually("Site Privacy fits settings for an empty tab") {
            NSApp.windows.contains {
                $0 !== window && $0.isVisible && $0.frame.height < 360 &&
                    self.marker("sitePrivacyPanelGeometry", in: $0) != nil
            }
        }
    }

    func testPrivacyShieldOpensRealPopover() async throws {
        let profiles = BrowserProfiles(testing: true); defer { profiles.shutdown() }
        let controller = profiles.controller
        let tab = try XCTUnwrap(controller.session.selectedTab)
        tab.webView.loadHTMLString("<body>Popover focus fixture</body>", baseURL: URL(string: "https://fixture.example"))
        try await eventually("Local page loaded") { tab.url != nil && !tab.webView.isLoading }
        let window = makeWindow(controller, profiles: profiles, width: 1250, largestText: false)
        defer { window.close() }
        try await eventually("Browser controls mounted") { self.marker("browserSiteInformationGeometry", in: window) != nil }
        func click(_ identifier: String) throws {
            let anchor = try XCTUnwrap(marker(identifier, in: window))
            let point = anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        }

        func sendKey(_ code: UInt16, _ characters: String, to window: NSWindow, flags: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
        }

        let field = try XCTUnwrap(address(in: window))
        print("POPOVER_FOCUS fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled) parentKey=\(window.isKeyWindow)")
        for (panel, isPresented, show) in [
            ("sitePrivacyPanelGeometry", { controller.profileUI.showProtection }, { try click("browserPrivacyGeometry") }),
            ("siteInformationPanelGeometry", { controller.profileUI.showSiteInfo }, { controller.profileUI.showSiteInfo = true }),
            ("passwordsGuidePanelGeometry", { controller.profileUI.showPasswords }, { controller.passwordsGuideRequest += 1 }),
        ] {
            controller.focusAddress()
            try await eventually("Address editor focused before opening \(panel)") { field.currentEditor() != nil }
            let parentWasKey = window.isKeyWindow
            try show()
            try await eventually("\(panel) was presented") {
                NSApp.windows.contains { $0.isVisible && self.marker(panel, in: $0) != nil }
            }
            let popover = try XCTUnwrap(NSApp.windows.first { $0.isVisible && marker(panel, in: $0) != nil })
            XCTAssertFalse(popover === window)
            XCTAssertTrue(popover.canBecomeKey)
            // An inactive accessory process can be denied key-window status.
            // Send window-numbered events to the real popover either way.
            if parentWasKey { XCTAssertTrue(popover.isKeyWindow) }
            let first = try XCTUnwrap(popover.firstResponder as? NSView)
            try sendKey(48, "\t", to: popover)
            let next = try XCTUnwrap(popover.firstResponder as? NSView)
            if panel != "passwordsGuidePanelGeometry" { XCTAssertFalse(next === first) }
            try sendKey(48, "\u{19}", to: popover, flags: .shift)
            XCTAssertTrue(popover.firstResponder === first)
            try sendKey(48, "\u{19}", to: popover, flags: .shift)
            try sendKey(48, "\t", to: popover)
            XCTAssertTrue(popover.firstResponder === first, "The key-view loop must wrap within \(panel)")
            if parentWasKey { XCTAssertTrue(NSApp.keyWindow === popover) }

            try sendKey(53, "\u{1b}", to: popover)
            try await eventually("Escape dismissed \(panel)") { !popover.isVisible && !isPresented() }
            try await eventually("Closing \(panel) restored the address editor") {
                field.currentEditor() != nil && (!parentWasKey || window.isKeyWindow)
            }
        }
        let audit = BackgroundUIMode.audit()
        XCTAssertEqual(audit.onscreenWindowViolations, 0)
        XCTAssertEqual(audit.activationViolations, 0)
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
            let toolbar = try frame("browserTopBarGeometry", in: window)
            for (i, type) in types.enumerated() {
                let button = try XCTUnwrap(window.standardWindowButton(type))
                XCTAssertTrue(button.superview === parents[i])
                let frame = button.convert(button.bounds, to: nil)
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(button.window === window && window.isVisible)
                XCTAssertEqual(frame.minX, (collapsed ? MacBrowserLayout.railLightsInset : MacBrowserLayout.lightsInset) + CGFloat(i) * MacBrowserLayout.lightsSpacing, accuracy: 1)
                XCTAssertEqual(window.contentView!.bounds.maxY - frame.midY, MacBrowserLayout.lightsCenterY, accuracy: 1)
                XCTAssertEqual(frame.midY, toolbar.midY, accuracy: 1)
                XCTAssertGreaterThanOrEqual(frame.minX, MacBrowserLayout.windowInset)
                XCTAssertLessThanOrEqual(frame.maxX, MacBrowserLayout.windowInset + (collapsed ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth))
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
            let reservation = rail ? MacBrowserLayout.railReservation : MacBrowserLayout.expandedReservation()
            try await eventually("RTL sidebar and toolbar positions") {
                window.contentView?.layoutSubtreeIfNeeded()
                return abs((self.geometry("sidebarSurfaceGeometry", in: window)?.minX ?? 0) - (1040 - MacBrowserLayout.windowInset - width)) < 1
                    && abs((self.geometry("browserTopBarGeometry", in: window)?.maxX ?? 0) - (1040 - reservation)) < 1
                    && self.marker("sidebarFavicon-\(tab.id)", in: window) != nil
            }
            let sidebar = try frame("sidebarSurfaceGeometry", in: window)
            let row = try frame("sidebarItem-\(tab.id)", in: window)
            let icon = try frame("sidebarFavicon-\(tab.id)", in: window)
            let field = try XCTUnwrap(address(in: window))
            let card = try frame("browserPageCardGeometry", in: window)
            let topBar = try frame("browserTopBarGeometry", in: window)
            let addressCapsule = try frame("browserAddressGeometry", in: window)
            let fieldRect = field.convert(field.bounds, to: nil)
            XCTAssertTrue(sidebar.contains(row))
            XCTAssertTrue(row.contains(icon))
            XCTAssertTrue(card.contains(addressCapsule), "Start-page address capsule sits inside the RTL page card")
            XCTAssertTrue(addressCapsule.contains(fieldRect), "Start-page address field sits inside its capsule")
            XCTAssertEqual(addressCapsule.midX, topBar.midX, accuracy: 1, "Start-page address capsule stays centered in the RTL page card")
            XCTAssertLessThanOrEqual(addressCapsule.maxY, topBar.minY, "Start-page address capsule renders below the RTL toolbar")
            if rail {
                XCTAssertEqual(icon.midX, row.midX, accuracy: 1)
            } else {
                XCTAssertEqual(row.maxX - icon.maxX, MacBrowserLayout.sidebarRowInset, accuracy: 1)
            }
            for (index, button) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                let view = try XCTUnwrap(window.standardWindowButton(button))
                let rect = view.convert(view.bounds, to: nil)
                XCTAssertEqual(window.contentView!.bounds.maxX - rect.maxX,
                    (rail ? MacBrowserLayout.railLightsInset : MacBrowserLayout.lightsInset) + CGFloat(index) * MacBrowserLayout.lightsSpacing,
                    accuracy: 1)
            }
        }
        tab.webView.loadHTMLString("<body>Page direction fixture</body>",
            baseURL: URL(string: "http://127.0.0.1:18768/rtl-page"))
        try await eventually("LTR document displayed in RTL chrome") {
            tab.hasRenderedContent && tab.webView.window === window && !tab.isLoading
        }
        let loadedField = try XCTUnwrap(address(in: window))
        try await eventually("Loaded page address field moves into RTL toolbar") {
            guard let bar = self.geometry("browserTopBarGeometry", in: window) else { return false }
            return bar.contains(loadedField.convert(loadedField.bounds, to: nil))
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
        XCTAssertEqual(window.contentView!.bounds.maxY - button.convert(button.bounds, to: nil).midY, MacBrowserLayout.lightsCenterY, accuracy: 1)
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

    func testSidebarLoadingRingSpinsNormallyAndStaysStaticUnderReduceMotion() async throws {
        XCTAssertTrue(SidebarLoadingRing.animatesRotation(reduceMotion: false))
        XCTAssertFalse(SidebarLoadingRing.animatesRotation(reduceMotion: true))

        for reduceMotion in [false, true] {
            let controller = BrowserController(testing: true); defer { controller.shutdown() }
            let tab = try XCTUnwrap(controller.session.selectedTab)
            let capture = SidebarCaptureState(loading: tab.id)
            let root = BrowserWindow(controller: controller)
                .browserAppearance(.light)
                .environment(\.sidebarCaptureState, capture)
                .environment(\.sidebarCaptureReduceMotion, reduceMotion)
            let host = NSHostingController(rootView: root)
            let window = BackgroundUIMode.Window(contentRect: NSRect(x: 60, y: 60, width: 1000, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1000, height: 600))
            BackgroundUIMode.show(window, key: false, activate: false)
            defer { window.close() }

            let expectedMarker = reduceMotion ? "sidebarLoadingRingStatic" : "sidebarLoadingRingSpinning"
            let unexpectedMarker = reduceMotion ? "sidebarLoadingRingSpinning" : "sidebarLoadingRingStatic"
            try await eventually("sidebar loading indicator (reduceMotion=\(reduceMotion))") {
                self.marker("sidebarFavicon-\(tab.id)", in: window) != nil
                    && self.marker("sidebarItem-\(tab.id)", in: window) != nil
                    && self.marker(expectedMarker, in: window) != nil
            }
            XCTAssertNil(marker(unexpectedMarker, in: window),
                         "Loading indicator rotation state must match reduceMotion=\(reduceMotion)")
            let row = try frame("sidebarItem-\(tab.id)", in: window)
            XCTAssertEqual(row.height, OrivMacV3.SidebarLayout.tabRowHeight, accuracy: 1,
                           "Loading tab row must keep 34 pt height")
            let favicon = try frame("sidebarFavicon-\(tab.id)", in: window)
            XCTAssertEqual(favicon.width, OrivMacV3.SidebarLayout.tabFaviconSize, accuracy: 1)
            XCTAssertEqual(favicon.height, OrivMacV3.SidebarLayout.tabFaviconSize, accuracy: 1)
        }
    }

}
