import AppKit
import BrowserCore
@testable import BrowserEngine
import SwiftUI
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class SidebarBehaviorTests: BackgroundUITestCase {
    private func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func host(_ c: BrowserController, width: CGFloat = 1000) -> NSWindow {
        let w = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: width, height: 820),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: BrowserWindow(controller: c)
            .browserAppearance(.light).environment(\.chromeReduceTransparencyOverride, true))
        w.setContentSize(NSSize(width: width, height: 820))
        BackgroundUIMode.show(w, key: true)
        return w
    }
    private func waitForSurface(_ width: CGFloat, in window: NSWindow) async throws {
        try await eventually("sidebar surface with width \(width)") {
            guard let content = window.contentView else { return false }
            content.layoutSubtreeIfNeeded()
            let marker = self.views(content).first { $0.identifier?.rawValue == "sidebarSurfaceGeometry" }
            return abs((marker?.bounds.width ?? 0) - width) <= 1
        }
    }
    private func sidebarKey(in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        XCTAssertTrue(window.performKeyEquivalent(with: event), "Dispatch the actual window key equivalent")
    }
    /// Inspect pixels painted by the live SwiftUI hierarchy, not an icon-store flag.
    /// The fixture's green artwork cannot be confused with the grey globe.
    private func renderedFixtureIcon(_ tab: BrowserTab, in window: NSWindow) throws -> Bool {
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        guard let marker = views(content).first(where: { $0.identifier?.rawValue == "sidebarFavicon-\(tab.id)" }) else { return false }
        let rect = marker.convert(marker.bounds, to: content)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: rect))
        content.cacheDisplay(in: rect, to: bitmap)
        var green = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.greenComponent > color.redComponent + 0.15,
                   color.greenComponent > color.blueComponent + 0.04 { green += 1 }
            }
        }
        return Double(green) / Double(bitmap.pixelsWide * bitmap.pixelsHigh) > 0.15
    }
    func testFinishedPageRendersFetchedFaviconInSidebarAndRail() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.navigate(to: URL(string: "http://127.0.0.1:18768/favicon-page")!)
        // Mount the loaded-page shell directly: a previously mounted Home
        // history row can incidentally request the icon and hide this bug.
        let w = host(c); defer { w.close() }
        try await eventually("favicon fixture navigation", timeout: 10) { tab.title == "Favicon fixture" && !tab.isLoading }
        try await eventually("fetched icon painted in the sidebar", timeout: 10) { try self.renderedFixtureIcon(tab, in: w) }
        XCTAssertNotNil(c.session.siteIcons.icon(for: tab.url, isPrivate: false))
        try sidebarKey(in: w)
        try await waitForSurface(MacBrowserLayout.railWidth, in: w)
        XCTAssertTrue(c.sidebar.rail)
        try await eventually("fetched icon painted in the rail", timeout: 10) { try self.renderedFixtureIcon(tab, in: w) }
    }
    func testSidebarFinderRevalidatesProfileScopeQueryAndTabIdentity() {
        let controller = BrowserController(testing: true)
        let other = BrowserController(testing: true)
        defer { controller.shutdown(); other.shutdown() }
        let regular = controller.session.addTab(url: URL(string: "https://match.example/regular"), select: true, load: false)
        let hidden = controller.session.addTab(url: URL(string: "https://match.example/private"), isPrivate: true, select: false, load: false)
        controller.tabSearch = "  MATCH.example "
        let regularRequest = controller.tabSearchRequest
        XCTAssertEqual(controller.tabSearchResults(regularRequest).map(\.id), [regular.id])
        XCTAssertFalse(controller.activateSidebarTab(hidden.id, request: regularRequest))
        XCTAssertFalse(controller.activateSidebarTab(regular.id, request: other.tabSearchRequest))

        controller.tabSearchPrivacyOverride = true
        let privateRequest = controller.tabSearchRequest
        XCTAssertEqual(controller.tabSearchResults(privateRequest).map(\.id), [hidden.id])
        XCTAssertFalse(controller.activateSidebarTab(regular.id, request: regularRequest))
        controller.tabSearch = "different.example"
        XCTAssertFalse(controller.activateSidebarTab(hidden.id, request: privateRequest))
        XCTAssertEqual(controller.session.selectedTabID, regular.id)

        controller.tabSearch = "match.example"
        XCTAssertTrue(controller.activateSidebarTab(hidden.id, request: privateRequest))
        controller.session.closeTab(hidden.id)
        XCTAssertFalse(controller.activateSidebarTab(hidden.id, request: privateRequest))
    }

    func testNarrowKeyEquivalentKeepsExplicitOverlayOpenWithoutPageReflow() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let w = host(c, width: 780); defer { w.close() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.navigate(to: URL(string: "http://127.0.0.1:18768/favicon-page")!)
        try await eventually("favicon fixture and document viewport", timeout: 10) {
            tab.title == "Favicon fixture" && !tab.isLoading && tab.webView.bounds.width > 0
        }
        try await waitForSurface(MacBrowserLayout.railWidth, in: w)
        XCTAssertTrue(c.sidebar.automaticRail)
        XCTAssertFalse(c.compactSidebar)
        let web = tab.webView, before = web.bounds.width
        let viewport = try await web.evaluateJavaScript("innerWidth") as? Double
        try sidebarKey(in: w)
        // Expanding under a stationary pointer outside the rail must not turn
        // an explicit command into a transient hover peek.
        c.sidebar.pointer(false); c.sidebar.panelInside = false; c.sidebar.focusInside = false
        try await pause(1500)
        XCTAssertTrue(c.sidebar.narrowOverlay, "The explicit overlay must still be visible 1.5 seconds after the key equivalent")
        let marker = try XCTUnwrap(views(w.contentView!).first { $0.identifier?.rawValue == "browserSidebarGeometry" })
        XCTAssertEqual(marker.bounds.width, MacBrowserLayout.sidebarWidth, accuracy: 1)
        XCTAssertEqual(web.bounds.width, before, accuracy: 1)
        let afterViewport = try await web.evaluateJavaScript("innerWidth") as? Double
        XCTAssertEqual(afterViewport, viewport)
        try sidebarKey(in: w)
        try await waitForSurface(MacBrowserLayout.railWidth, in: w)
        XCTAssertTrue(c.sidebar.rail); XCTAssertFalse(c.sidebar.overlay)
        // The menu sends this request; the toolbar's native button action
        // reaches the same toggle. Both must retain explicit overlay semantics.
        c.sidebarToggleRequest += 1
        try await waitForSurface(MacBrowserLayout.sidebarWidth, in: w)
        XCTAssertTrue(c.sidebar.narrowOverlay)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        try await waitForSurface(MacBrowserLayout.railWidth, in: w)
        XCTAssertTrue(c.sidebar.rail); XCTAssertFalse(c.sidebar.overlay)
        let toggle = try XCTUnwrap(views(w.contentView!).first { $0.identifier?.rawValue == "sidebarToggleGeometry" })
        let point = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            w.sendEvent(click)
        }
        try await waitForSurface(MacBrowserLayout.sidebarWidth, in: w)
        XCTAssertTrue(c.sidebar.narrowOverlay)
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 700, y: 400),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.sendEvent(outside)
        try await waitForSurface(MacBrowserLayout.railWidth, in: w)
        XCTAssertTrue(c.sidebar.rail); XCTAssertFalse(c.sidebar.overlay)
        XCTAssertEqual(web.bounds.width, before, accuracy: 1)
        XCTAssertTrue(tab.webView === web)
    }
    func testSleepingSidebarRowsHydrateOnlyTheirRegularProfileDiskCache() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("SidebarIconCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://cached-icon.example/reading")!
        let sleeping = TabRecord(title: "Cached icon", url: url), home = TabRecord()
        let profileRoot = BrowserProfile.personal.directory(in: root)
        try SessionFileStore(fileURL: profileRoot.appendingPathComponent("session.json"))
            .save(BrowserSnapshot(tabs: [home, sleeping], selectedTabID: home.id), discardPrevious: true)
        let disk = SiteIconDiskCache(directory: profileRoot.appendingPathComponent("Favicons"))
        // Draw with Core Graphics: ImageRenderer can return a blank image on headless CI runners.
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.13, green: 0.50, blue: 0.40, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let decoded = await disk.decode(png)
        let icon = try XCTUnwrap(decoded)
        await disk.write(icon, key: try XCTUnwrap(SiteIconStore.key(url, isPrivate: false)))
        let c = BrowserController(rootDirectory: root, testing: true); defer { c.shutdown() }
        c.session.siteIcons.document = { _, _ in XCTFail("Sleeping rows may read disk only"); return nil }
        let tab = try XCTUnwrap(c.session.tabs.first { $0.id == sleeping.id })
        let w = host(c); defer { w.close() }
        try await eventually("cached icon painted in the sidebar", timeout: 10) { try self.renderedFixtureIcon(tab, in: w) }
        XCTAssertFalse(tab.isInstantiated)
        try sidebarKey(in: w)
        try await waitForSurface(MacBrowserLayout.railWidth, in: w)
        try await eventually("cached icon painted in the rail", timeout: 10) { try self.renderedFixtureIcon(tab, in: w) }
        XCTAssertFalse(tab.isInstantiated)
        let privateTab = c.session.addTab(url: url, isPrivate: true, select: false, load: false)
        try await pause(350)
        XCTAssertNil(c.session.siteIcons.icon(for: url, isPrivate: true))
        XCTAssertFalse(privateTab.isInstantiated)
        let other = BrowserController(profile: BrowserProfile(name: "Separate icon cache"), rootDirectory: root, testing: true)
        defer { other.shutdown() }
        await other.session.siteIcons.loadCached(url)
        XCTAssertNil(other.session.siteIcons.icon(for: url, isPrivate: false))
    }
    func testNarrowHysteresisPreservesExplicitPreference() {
        let s = SidebarPresentation()
        s.resize(availableWidth: 796)
        XCTAssertFalse(s.rail)
        s.resize(availableWidth: 795)
        XCTAssertTrue(s.rail); XCTAssertFalse(s.preferredRail)
        for width: CGFloat in [796, 835, 806, 796] {
            s.resize(availableWidth: width); XCTAssertTrue(s.rail)
        }
        s.resize(availableWidth: 836)
        XCTAssertFalse(s.rail); XCTAssertFalse(s.preferredRail)
        s.setPreference(true); s.resize(availableWidth: 1400)
        XCTAssertTrue(s.rail); XCTAssertTrue(s.preferredRail)
    }
    func testExplicitNarrowExpansionOverlaysAndRestoresWidePreference() {
        let s = SidebarPresentation(); s.resize(availableWidth: 760)
        XCTAssertFalse(s.toggle()); XCTAssertTrue(s.narrowOverlay)
        XCTAssertEqual(s.reservation, MacBrowserLayout.railReservation)
        XCTAssertEqual(s.width, MacBrowserLayout.sidebarWidth)
        s.dismissOverlay(); XCTAssertTrue(s.rail); XCTAssertFalse(s.preferredRail)
        s.resize(availableWidth: 1000)
        XCTAssertFalse(s.rail); XCTAssertFalse(s.overlay)
    }
    func testPeekDefaultOffAndEnabledDwell() async throws {
        let s = SidebarPresentation(); s.setPreference(true)
        s.pointer(true); try await pause(300); XCTAssertFalse(s.peeking)
        s.hoverEnabled = true; s.pointer(true)
        try await pause(180); XCTAssertFalse(s.peeking)
        try await pause(110); XCTAssertTrue(s.peeking)
        XCTAssertTrue(s.preferredRail); XCTAssertEqual(s.reservation, MacBrowserLayout.railReservation)
        s.cancel()
    }
    func testPeekTravelExitAndSettingCancellation() async throws {
        let s = SidebarPresentation(); s.setPreference(true); s.hoverEnabled = true
        s.pointer(true); try await pause(150); s.pointer(true, moved: true)
        try await pause(140); XCTAssertFalse(s.peeking)
        s.pointer(false); try await pause(280); XCTAssertFalse(s.peeking)
        s.pointer(true); s.hoverEnabled = false
        try await pause(280); XCTAssertFalse(s.peeking)
        s.hoverEnabled = true; s.pointer(true); s.cancel()
        try await pause(280); XCTAssertFalse(s.peeking)
    }
    func testPeekGraceHoldRulesAndEscapeCancellation() async throws {
        let s = SidebarPresentation(); s.setPreference(true); s.hoverEnabled = true
        s.pointer(true); try await eventually("sidebar peek") { s.peeking }
        s.pointer(false); try await pause(200); XCTAssertTrue(s.peeking)
        s.menuOpen = true; try await pause(200); XCTAssertTrue(s.peeking)
        s.menuOpen = false; s.searchOpen = true; try await pause(380); XCTAssertTrue(s.peeking)
        s.searchOpen = false; s.focusInside = true; try await pause(380); XCTAssertTrue(s.peeking)
        s.focusInside = false; s.dragging = true; try await pause(380); XCTAssertTrue(s.peeking)
        s.panelInside = true; s.dragging = false; try await pause(380); XCTAssertTrue(s.peeking)
        s.panelInside = false; try await eventually("peek dismissed") { !s.peeking }
        s.pointer(true); try await pause(280); s.dismissOverlay(); XCTAssertFalse(s.peeking)
    }
    func testVoiceOverAndWebpageFullscreenSuppressAutomaticPeek() async throws {
        let s = SidebarPresentation(); s.setPreference(true); s.hoverEnabled = true; s.voiceOver = true
        s.pointer(true); try await pause(280); XCTAssertFalse(s.peeking)
        s.voiceOver = false; s.fullscreen(true); s.pointer(true)
        try await pause(280); XCTAssertFalse(s.peeking); XCTAssertEqual(s.reservation, 0)
        s.fullscreen(false); XCTAssertTrue(s.rail); XCTAssertEqual(s.reservation, MacBrowserLayout.railReservation)
        s.pointer(true); try await eventually("sidebar peek") { s.peeking }
        s.voiceOver = true; XCTAssertFalse(s.peeking); XCTAssertTrue(s.hoverEnabled)
    }
    func testDragDwellCanRevealTitlesWithoutHoverSetting() async throws {
        let s = SidebarPresentation(); s.setPreference(true); s.dragging = true
        s.pointer(true, drag: true); try await eventually("sidebar peek") { s.peeking }
        s.pointer(false); try await pause(380); XCTAssertTrue(s.peeking)
        s.dragging = false; try await eventually("peek dismissed") { !s.peeking }
    }
    func testTooltipStationaryTimingRestartAndDismiss() async throws {
        let tooltip = SidebarTooltip(), first = UUID(), second = UUID()
        tooltip.hover(id: first, text: "Full title, host.example")
        try await pause(450); XCTAssertNil(tooltip.tabID)
        tooltip.hover(id: second, text: "Second full title, duplicate.example")
        try await pause(200); XCTAssertNil(tooltip.tabID)
        try await pause(450); XCTAssertEqual(tooltip.tabID, second)
        XCTAssertEqual(tooltip.text, "Second full title, duplicate.example")
        tooltip.exit(); tooltip.hold(true); try await pause(150); XCTAssertEqual(tooltip.tabID, second)
        tooltip.hold(false); XCTAssertNil(tooltip.tabID)
        tooltip.hover(id: first, text: "Exit"); try await pause(650)
        tooltip.exit(); try await pause(150); XCTAssertNil(tooltip.tabID)
        tooltip.dismiss(); XCTAssertNil(tooltip.tabID); XCTAssertEqual(tooltip.text, "")
        tooltip.hover(id: first, text: "Cancelled"); tooltip.dismiss()
        try await pause(650); XCTAssertNil(tooltip.tabID)
    }
    func testRailFooterContainsLibraryAndSettingsWithoutCloseHitRegions() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        c.compactSidebar = true
        let w = host(c); defer { w.close() }; try await pause(350)
        let all = views(try XCTUnwrap(w.contentView))
        for title in LibrarySection.allCases.map(\.rawValue) + ["Settings"] {
            let marker = try XCTUnwrap(all.first { $0.identifier?.rawValue == "sidebarFooter-\(title)" })
            XCTAssertGreaterThanOrEqual(marker.bounds.width, 42)
            XCTAssertGreaterThanOrEqual(marker.bounds.height, 36)
        }
        XCTAssertFalse(all.contains { $0.identifier?.rawValue.hasPrefix("sidebarClose-") == true })
    }
    func testPinGridFitsFourToSixAdaptiveColumns() {
        for (width, columns) in [(220.0, 4), (256.0, 4), (300.0, 5), (360.0, 6)] {
            let available = width - 2 * MacBrowserLayout.sidebarInset
            let grid = SidebarTabs.PinGrid(availableWidth: available)
            XCTAssertEqual(grid.columns, columns)
            let expectedTileWidth = (available - CGFloat(columns - 1) * OrivMacV3.SidebarLayout.pinGap) / CGFloat(columns)
            XCTAssertEqual(grid.tileWidth, expectedTileWidth, accuracy: 0.01)
            if width >= 256 {
                XCTAssertGreaterThanOrEqual(grid.tileWidth, OrivMacV3.SidebarLayout.pinMinWidth)
            }
        }
    }

    func testNinePinsStayTilesWithOverlayAndLegacyScrollbars() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        for _ in 0..<9 { let tab = c.session.addTab(select: false, load: false); c.session.togglePinned(tab.id) }
        let w = host(c); defer { w.close() }; try await pause(350)
        let pins = c.session.orderedTabs.filter(\.isPinned)
        let content = try XCTUnwrap(w.contentView)
        let collection = try XCTUnwrap(views(content).compactMap { $0 as? SidebarTabCollection }.first)
        let scroll = try XCTUnwrap(collection.enclosingScrollView)
        scroll.autohidesScrollers = false
        for style: NSScroller.Style in [.overlay, .legacy] {
            scroll.scrollerStyle = style
            scroll.tile()
            try await pause(150)
            let all = views(content)
            let frames = try pins.map { tab in
                let marker = try XCTUnwrap(all.first { $0.identifier?.rawValue == "sidebarItem-\(tab.id)" })
                return marker.convert(marker.bounds, to: nil)
            }
            let surface = try XCTUnwrap(all.first { $0.identifier?.rawValue == "sidebarSurfaceGeometry" })
            XCTAssertEqual(surface.bounds.width, 256, accuracy: 1)
            if style == .legacy { XCTAssertLessThan(scroll.contentView.bounds.width, scroll.bounds.width) }
            let grid = SidebarTabs.PinGrid(availableWidth: scroll.contentView.bounds.width)
            XCTAssertEqual(grid.columns, 4)
            for (index, frame) in frames.enumerated() {
                XCTAssertEqual(frame.height, OrivMacV3.SidebarLayout.pinHeight, accuracy: 1)
                XCTAssertEqual(frame.width, grid.tileWidth, accuracy: 1)
                let rowStart = frames[index - index % 4]
                XCTAssertEqual(frame.midY, rowStart.midY, accuracy: 1)
                let step = grid.tileWidth + OrivMacV3.SidebarLayout.pinGap
                XCTAssertEqual(frame.minX - rowStart.minX, CGFloat(index % 4) * step, accuracy: 1)
            }
            XCTAssertEqual(frames[0].minX, frames[4].minX, accuracy: 1)
            XCTAssertEqual(frames[0].minX, frames[8].minX, accuracy: 1)
        }
        c.tabSearch = "New Tab"
        try await pause(350)
        let firstPinPath = try XCTUnwrap(collection.sidebar?.path(for: pins[0].id))
        let firstPinRow = try XCTUnwrap(collection.item(at: firstPinPath)?.view)
        XCTAssertEqual(firstPinRow.bounds.height, OrivMacV3.SidebarLayout.tabRowHeight, accuracy: 1)
        XCTAssertTrue(firstPinRow.accessibilityLabel()?.contains("New Tab") == true)
        XCTAssertNil(firstPinRow.toolTip)
        XCTAssertFalse(pins.contains(where: \.isInstantiated))
    }
    func testTransientPeekTooltipAndResizeNeverPersistOrWakeTabs() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = BrowserProfile(name: "Sidebar isolation")
        let name = try XCTUnwrap(profile.defaultsName(bundleID: Bundle.main.bundleIdentifier!))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let c = BrowserController(profile: profile, rootDirectory: root, testing: false, websiteStore: .nonPersistent())
        defer { c.shutdown() }
        c.compactSidebar = true; c.hoverSidebar = true
        try await pause(1000) // Drain session creation/migration work before the presentation-only interval.
        c.session.saveNow(discardPrevious: true)
        let before = defaults.persistentDomain(forName: name) as NSDictionary? ?? [:]
        let file = profile.directory(in: root).appendingPathComponent("session.json")
        let bytes = try Data(contentsOf: file), attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let count = c.session.tabs.filter(\.isInstantiated).count
        c.sidebar.pointer(true); try await pause(280)
        c.sidebarTooltip.hover(id: UUID(), text: "Private metadata remains in memory")
        try await pause(650); c.sidebarTooltip.dismiss(); c.sidebar.dismissOverlay()
        c.sidebar.resize(availableWidth: 760); c.sidebar.resize(availableWidth: 1400)
        XCTAssertEqual(defaults.persistentDomain(forName: name) as NSDictionary? ?? [:], before)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
        XCTAssertEqual(c.session.tabs.filter(\.isInstantiated).count, count)
        XCTAssertFalse(c.session.tabs.contains(where: \.isLoading))
    }
    func testPeekCommitUsesDeliberatePreferenceAndTooltipNeverTakesFocus() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        c.compactSidebar = true; c.hoverSidebar = true
        let w = host(c); defer { w.close() }; try await pause(350)
        let responder = w.firstResponder
        let tab = try XCTUnwrap(c.session.selectedTab)
        c.sidebarTooltip.hover(id: tab.id, text: SidebarTabs.label(tab, selected: true))
        try await pause(650); XCTAssertTrue(w.firstResponder === responder)
        c.sidebar.pointer(true); try await eventually("sidebar peek") { c.sidebar.peeking }
        c.toggleSidebar(); XCTAssertFalse(c.compactSidebar); XCTAssertFalse(c.sidebar.peeking)
        XCTAssertEqual(c.sidebar.reservation, MacBrowserLayout.expandedReservation())
    }
    func testNativeNarrowResizeAndExplicitShortcutKeepPageReservation() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let w = host(c); defer { w.close() }; try await pause(350)
        w.setContentSize(NSSize(width: 760, height: 820)); try await pause(350)
        XCTAssertTrue(c.sidebar.rail); XCTAssertFalse(c.compactSidebar)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        XCTAssertTrue(w.performKeyEquivalent(with: event)); try await pause(350)
        XCTAssertTrue(c.sidebar.narrowOverlay)
        let all = views(try XCTUnwrap(w.contentView))
        let top = try XCTUnwrap(all.first { $0.identifier?.rawValue == "browserTopBarGeometry" })
        XCTAssertEqual(top.convert(top.bounds, to: nil).minX, MacBrowserLayout.railReservation, accuracy: 1)
        w.setContentSize(NSSize(width: 1000, height: 820)); try await pause(350)
        XCTAssertFalse(c.sidebar.rail); XCTAssertFalse(c.sidebar.overlay)
    }
    func testSidebarResizeGripAdjustsPanelAndKeepsThePageInstance() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let window = host(c, width: 1150); defer { window.close() }
        try await waitForSurface(MacBrowserLayout.sidebarWidth, in: window)
        let tab = try XCTUnwrap(c.session.selectedTab)
        let web = tab.webView
        let grip = try XCTUnwrap(window.contentView.flatMap { views($0).compactMap { $0 as? SidebarResizeGrip.Grip }.first })
        for (offset, width) in [(CGFloat(-120), CGFloat(220)), (180, 360)] {
            let event: (NSEvent.EventType, CGFloat) throws -> NSEvent = { type, x in
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 300), modifierFlags: [],
                    timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            grip.mouseDown(with: try event(.leftMouseDown, 260))
            grip.mouseDragged(with: try event(.leftMouseDragged, 260 + offset))
            grip.mouseUp(with: try event(.leftMouseUp, 260 + offset))
            try await waitForSurface(width, in: window)
            XCTAssertEqual(c.sidebar.reservation, MacBrowserLayout.expandedReservation(sidebarWidth: width))
            XCTAssertTrue(tab.webView === web)
        }
    }

    func testToggleCommitsViewportOnceAndRetainsWebViewIdentity() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let w = host(c); defer { w.close() }; try await pause(350)
        let tab = try XCTUnwrap(c.session.selectedTab), web = tab.webView
        let count = c.session.tabs.filter(\.isInstantiated).count
        web.postsFrameChangedNotifications = true
        var widths: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: web, queue: .main) { _ in
            MainActor.assumeIsolated { widths.append(web.frame.width) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        XCTAssertTrue(w.performKeyEquivalent(with: event)); try await pause(350)
        XCTAssertLessThanOrEqual(Set(widths.map { Int($0.rounded()) }).count, 1, "The page must receive only the final viewport width")
        XCTAssertTrue(tab.webView === web)
        XCTAssertEqual(c.session.tabs.filter(\.isInstantiated).count, count)
        func addressFrame() throws -> NSRect {
            let view = try XCTUnwrap(views(w.contentView!).first { $0.identifier?.rawValue == "browserAddressGeometry" })
            return view.convert(view.bounds, to: nil)
        }
        let addressBefore = try addressFrame()
        c.hoverSidebar = true; widths = []
        c.sidebar.pointer(true); try await pause(500)
        XCTAssertTrue(c.sidebar.peeking); XCTAssertTrue(widths.isEmpty, "Hover overlay must never resize the page")
        XCTAssertEqual(try addressFrame(), addressBefore, "The content toolbar must also stay in place during peek")
        c.sidebar.dismissOverlay()
    }
    func testHoverSettingPersistsOnlyWhenExplicitlyChanged() {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = BrowserProfile(name: "Sidebar preference")
        let name = profile.defaultsName(bundleID: Bundle.main.bundleIdentifier!)!
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        do {
            let c = BrowserController(profile: profile, rootDirectory: root, testing: false, websiteStore: .nonPersistent())
            XCTAssertFalse(c.hoverSidebar); c.hoverSidebar = true; c.compactSidebar = true
            XCTAssertTrue(defaults.bool(forKey: "hoverSidebar")); c.shutdown()
        }
        let restored = BrowserController(profile: profile, rootDirectory: root, testing: false, websiteStore: .nonPersistent())
        defer { restored.shutdown() }
        XCTAssertTrue(restored.hoverSidebar); XCTAssertTrue(restored.compactSidebar); XCTAssertFalse(restored.sidebar.peeking)
    }
    func testNativeEscapeDismissesTooltipAndRailSearchRestoresFocus() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        c.compactSidebar = true
        let w = host(c); defer { w.close() }; try await pause(350)
        let responder = w.firstResponder, tab = try XCTUnwrap(c.session.selectedTab)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        c.sidebarTooltip.hover(id: tab.id, text: "Full title, host.example"); try await pause(650)
        XCTAssertEqual(c.sidebarTooltip.tabID, tab.id)
        NSApp.sendEvent(escape); try await pause(50); XCTAssertNil(c.sidebarTooltip.tabID)
        c.searchTabs(); try await pause(300)
        XCTAssertTrue(c.tabSearchPanel); XCTAssertTrue(c.compactSidebar)
        c.tabSearch = "host"; try await pause(150)
        NSApp.sendEvent(escape); try await pause(150)
        XCTAssertFalse(c.tabSearchPanel); XCTAssertEqual(c.tabSearch, "")
        XCTAssertTrue(w.firstResponder === responder)
    }

    func testRuntimeHitTargetsWorkWithoutDebugIdentifiers() async throws {
        let c = BrowserController(testing: true)
        defer { c.shutdown() }
        c.compactSidebar = true
        let tab = c.session.addTab(select: false, load: false)
        let w = host(c)
        defer { w.close() }

        func target(_ kind: SidebarHitTarget.Kind) -> SidebarHitTarget.TargetView? {
            w.contentView.map(views)?.compactMap { $0 as? SidebarHitTarget.TargetView }.first { $0.kind == kind && !$0.bounds.isEmpty }
        }
        func center(_ view: NSView) -> NSPoint {
            view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
        func click(at point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }

        func row() -> NSView? {
            guard let list = w.contentView.map(views)?.compactMap({ $0 as? SidebarTabCollection }).first,
                  let path = list.sidebar?.path(for: tab.id) else { return nil }
            return list.item(at: path)?.view
        }
        try await eventually("native sidebar row") { row() != nil }
        let row = try XCTUnwrap(row())
        row.identifier = nil
        let content = try XCTUnwrap(w.contentView)
        let events = try XCTUnwrap(views(content).compactMap { $0 as? SidebarWindowEvents.EventView }.first)
        XCTAssertTrue(events.requestCloseTab(at: center(row)))
        XCTAssertFalse(c.session.tabs.contains { $0.id == tab.id })

        c.searchTabs()
        try await eventually("native rail search panel") { target(.searchPanel) != nil }
        let panel = try XCTUnwrap(target(.searchPanel))
        panel.identifier = nil
        try click(at: center(panel))
        XCTAssertTrue(c.tabSearchPanel)
        try click(at: NSPoint(x: 700, y: 400))
        XCTAssertFalse(c.tabSearchPanel)
    }

    func testPeekKeepsVisibleFaviconCentresInPlace() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        for _ in 0..<3 { _ = c.session.addTab(select: false, load: false) }
        c.compactSidebar = true; c.hoverSidebar = true
        let w = host(c); defer { w.close() }; try await pause(350)
        func icons() -> [String: NSRect] {
            Dictionary(uniqueKeysWithValues: views(w.contentView!).compactMap { view in
                guard let name = view.identifier?.rawValue, name.hasPrefix("sidebarFavicon-") else { return nil }
                return (name, view.convert(view.bounds, to: nil))
            })
        }
        let before = icons(); c.sidebar.pointer(true); try await pause(500)
        XCTAssertTrue(c.sidebar.peeking)
        let after = icons()
        for (id, old) in before {
            let current = try XCTUnwrap(after[id])
            XCTAssertEqual(current.midX, old.midX, accuracy: 1)
            XCTAssertEqual(current.midY, old.midY, accuracy: 1)
        }
        c.sidebar.dismissOverlay()
    }

    func testSidebarTogglePeekAndSearchNeverAskForFaviconDiscovery() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        for index in 0..<12 {
            _ = c.session.addTab(url: URL(string: "https://cache\(index).example"), select: false, load: false)
        }
        c.session.siteIcons.document = { _, _ in
            XCTFail("Sidebar metadata presentation must never ask a document to discover or fetch favicons")
            return nil
        }
        let w = host(c); defer { w.close() }; try await pause(350)
        let instantiated = c.session.tabs.filter(\.isInstantiated).count
        c.toggleSidebar(); try await pause(350)
        c.hoverSidebar = true; c.sidebar.pointer(true); try await pause(500)
        XCTAssertTrue(c.sidebar.peeking)
        c.searchTabs(); c.tabSearch = "cache"; try await pause(250)
        c.dismissTabSearch(); c.sidebar.dismissOverlay()
        XCTAssertEqual(c.session.tabs.filter(\.isInstantiated).count, instantiated)
    }

}
