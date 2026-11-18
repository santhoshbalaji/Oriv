import AppKit
import BrowserCore
@testable import BrowserEngine
import SwiftUI
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class SidebarGlassTests: BackgroundUITestCase {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func nodes(_ element: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 24, let node = element as? any NSAccessibilityProtocol else { return [] }
        return [node] + (node.accessibilityChildren() ?? []).flatMap { nodes($0, depth: depth + 1) }
    }
    private func window(_ controller: BrowserController, solid: Bool = false) -> NSWindow {
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BrowserWindow(controller: controller)
            .browserAppearance(.light).environment(\.chromeReduceTransparencyOverride, solid))
        BackgroundUIMode.show(window, key: true)
        return window
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    func testTitleAndHostSearchIncludesPinsAndPrivateWithoutOpeningWebViews() throws {
        let title = BrowserTab(record: TabRecord(title: "Field Guide", url: URL(string: "https://notes.example/story"), isPinned: true))
        let host = BrowserTab(record: TabRecord(title: "Reading", url: URL(string: "https://field.example/book")))
        let privateTab = BrowserTab(record: TabRecord(title: "Private field", url: URL(string: "https://private.example")), isPrivate: true)
        defer { [title, host, privateTab].forEach { $0.close() } }
        XCTAssertEqual(SidebarTabs.filtered([title, host, privateTab], query: " FiELd ").map(\.id), [title.id, host.id, privateTab.id])
        XCTAssertEqual(SidebarTabs.filtered([title, host], query: "notes.example").map(\.id), [title.id])
        XCTAssertTrue(SidebarTabs.filtered([title, host], query: "absent").isEmpty)
        XCTAssertEqual(SidebarTabs.filtered([title, host], query: "  ").count, 2)
        XCTAssertFalse([title, host, privateTab].contains(where: \.isInstantiated))
    }
    func testDropReordersPinsAndExplicitlyPinsUnpinsButRejectsOtherPrivacyAndOwners() throws {
        let controller = BrowserController(testing: true); defer { controller.shutdown() }
        let s = controller.session, first = try XCTUnwrap(controller.session.selectedTab)
        let second = s.addTab(load: false), third = s.addTab(load: false), privateTab = s.addTab(isPrivate: true, load: false)
        func payload(_ tab: BrowserTab) -> [SidebarTabTransfer] { [SidebarTabTransfer(id: tab.id, owner: controller.sidebarDragID)] }
        XCTAssertTrue(SidebarTabs.drop(payload(third), on: .tab(first.id), controller: controller))
        XCTAssertEqual(s.orderedTabs.map(\.id), [third.id, first.id, second.id, privateTab.id])
        XCTAssertTrue(SidebarTabs.drop(payload(second), on: .pinned(true), controller: controller))
        XCTAssertEqual(s.orderedTabs.first?.id, second.id)
        XCTAssertFalse(SidebarTabs.drop(payload(first), on: .tab(second.id), controller: controller))
        XCTAssertTrue(SidebarTabs.drop(payload(third), on: .pinned(true), controller: controller))
        XCTAssertEqual(s.orderedTabs.prefix(2).map(\.id), [second.id, third.id])
        XCTAssertTrue(SidebarTabs.drop(payload(third), on: .tab(second.id), controller: controller))
        XCTAssertEqual(s.orderedTabs.prefix(2).map(\.id), [third.id, second.id])
        XCTAssertFalse(SidebarTabs.drop(payload(privateTab), on: .pinned(true), controller: controller))
        XCTAssertFalse(SidebarTabs.drop(payload(first), on: .tab(privateTab.id), controller: controller))
        XCTAssertFalse(SidebarTabs.drop([SidebarTabTransfer(id: first.id, owner: UUID())], on: .pinned(true), controller: controller))
        XCTAssertTrue(SidebarTabs.drop(payload(second), on: .pinned(false), controller: controller))
        XCTAssertFalse(second.isPinned)
        XCTAssertEqual(s.orderedTabs.map(\.id), [third.id, first.id, second.id, privateTab.id])
    }
    func testContextMenuCommandsUseExistingSessionAndCloseConfirmationPaths() throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTab), second = c.session.addTab(load: false)
        SidebarTabs.perform(.pin, tab: second, controller: c)
        XCTAssertTrue(second.isPinned)
        SidebarTabs.perform(.pin, tab: second, controller: c)
        SidebarTabs.perform(.moveUp, tab: second, controller: c)
        XCTAssertEqual(c.session.orderedTabs.map(\.id), [second.id, first.id])
        SidebarTabs.perform(.moveDown, tab: second, controller: c)
        XCTAssertEqual(c.session.orderedTabs.map(\.id), [first.id, second.id])
        SidebarTabs.perform(.media, tab: second, controller: c); XCTAssertTrue(second.mediaSuspended)
        SidebarTabs.perform(.media, tab: second, controller: c); XCTAssertFalse(second.mediaSuspended)
        SidebarTabs.perform(.duplicate, tab: second, controller: c); XCTAssertEqual(c.session.tabs.count, 3)
        SidebarTabs.perform(.newPrivate, tab: second, controller: c)
        XCTAssertTrue(try XCTUnwrap(c.session.selectedTab).isPrivate)
        SidebarTabs.perform(.pin, tab: c.session.selectedTab!, controller: c); XCTAssertFalse(c.session.selectedTab!.isPinned)
        second.recordFieldEdit()
        XCTAssertTrue(c.session.requiresCloseConfirmation(second.id))
        SidebarTabs.perform(.close, tab: first, controller: c)
        XCTAssertFalse(c.session.tabs.contains { $0.id == first.id })
    }
    func testAccessibilityLabelsIncludeTitleHostSelectionPrivacyPinAndAudio() throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let tab = c.session.addTab(url: URL(string: "https://audio.example"), select: false, load: false)
        c.session.togglePinned(tab.id); tab.recordAudio(frame: "one", audible: true)
        let label = SidebarTabs.label(tab, selected: true)
        for text in ["audio.example", "Selected", "Pinned", "Playing audio"] { XCTAssertTrue(label.contains(text)) }
        tab.toggleMediaSuspension()
        XCTAssertTrue(SidebarTabs.label(tab, selected: false).contains("Media paused"))
        let privateTab = c.session.addTab(isPrivate: true, load: false)
        XCTAssertTrue(SidebarTabs.label(privateTab, selected: false).contains("Private"))
    }
    func testGridAndRailArrowOrderReachesRowsWithoutSkippingThem() throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTab), second = c.session.addTab(select: false, load: false)
        let regular = c.session.addTab(select: false, load: false), privateTab = c.session.addTab(isPrivate: true, select: false, load: false)
        c.session.togglePinned(first.id); c.session.togglePinned(second.id)
        let tabs = c.session.orderedTabs
        XCTAssertEqual(SidebarTabs.keyboardTarget(from: second.id, key: .downArrow, tabs: tabs, rail: false)?.id, regular.id)
        XCTAssertEqual(SidebarTabs.keyboardTarget(from: first.id, key: .rightArrow, tabs: tabs, rail: false)?.id, second.id)
        XCTAssertEqual(SidebarTabs.keyboardTarget(from: second.id, key: .upArrow, tabs: tabs, rail: false)?.id, second.id)
        XCTAssertEqual(SidebarTabs.keyboardTarget(from: regular.id, key: .upArrow, tabs: tabs, rail: false)?.id, second.id)
        XCTAssertEqual(SidebarTabs.keyboardTarget(from: regular.id, key: .downArrow, tabs: tabs, rail: false)?.id, privateTab.id)
        XCTAssertEqual(SidebarTabs.keyboardTarget(from: first.id, key: .downArrow, tabs: tabs, rail: true)?.id, second.id)
    }
    func testNativeArrowAndReturnEventsNavigateFromSearchThroughPinsAndRows() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTab), second = c.session.addTab(select: false, load: false)
        let regular = c.session.addTab(select: false, load: false)
        c.session.togglePinned(first.id); c.session.togglePinned(second.id)
        let w = window(c); defer { w.close() }; try await settle()
        c.searchTabs(); try await settle()
        func key(_ code: UInt16, _ text: String) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
        }
        try key(125, "\u{f701}"); try await settle() // Search -> first pin focus.
        try key(36, "\r"); try await settle(); XCTAssertEqual(c.session.selectedTabID, first.id)
        try key(124, "\u{f703}"); try await settle(); XCTAssertEqual(c.session.selectedTabID, second.id)
        try key(125, "\u{f701}"); try await settle(); XCTAssertEqual(c.session.selectedTabID, regular.id)
    }
    func testNativeArrowNavigationScrollsThroughSixtyLazyRowsAndRail() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        for _ in 1..<60 { _ = c.session.addTab(select: false, load: false) }
        let tabs = c.session.orderedTabs
        let w = window(c); defer { w.close() }; try await settle()
        c.searchTabs(); try await settle()
        func key(_ code: UInt16, _ text: String) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
        }
        try key(125, "\u{f701}"); try await settle()
        for index in 1..<60 {
            try key(125, "\u{f701}")
            try await Task.sleep(for: .milliseconds(35))
            guard c.session.selectedTabID == tabs[index].id else { XCTFail("Expanded arrow focus lost at lazy row \(index)"); return }
        }
        let toggle = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        XCTAssertTrue(w.performKeyEquivalent(with: toggle)); try await settle()
        XCTAssertTrue(c.compactSidebar)
        try key(125, "\u{f701}"); try await settle() // Toggle -> selected rail tab.
        for index in stride(from: 58, through: 0, by: -1) {
            try key(126, "\u{f700}")
            try await Task.sleep(for: .milliseconds(35))
            guard c.session.selectedTabID == tabs[index].id else { XCTFail("Rail arrow focus lost at lazy row \(index)"); return }
        }
    }
    func testAudioEventsAggregateFramesAndResetWithNavigation() throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.recordAudio(frame: "main", audible: true); tab.recordAudio(frame: "child", audible: true)
        tab.recordAudio(frame: "main", audible: false); XCTAssertTrue(tab.isPlayingAudio)
        tab.recordAudio(frame: "child", audible: false); XCTAssertFalse(tab.isPlayingAudio)
        tab.recordAudio(frame: "main", audible: true)
        tab.webView(tab.webView, didCommit: nil); XCTAssertFalse(tab.isPlayingAudio)
    }
    func testNativeRailToggleRetainsIconsLabelsAndSelection() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let selected = c.session.selectedTabID
        let w = window(c, solid: true); defer { w.close() }
        try await settle()
        for rail in [true, false] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
            XCTAssertTrue(w.performKeyEquivalent(with: event)); try await settle()
            XCTAssertEqual(c.compactSidebar, rail); XCTAssertEqual(c.session.selectedTabID, selected)
            let marker = try XCTUnwrap(w.contentView.flatMap { views($0).first { $0.identifier?.rawValue == "browserSidebarGeometry" } })
            XCTAssertEqual(marker.bounds.width, rail ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth, accuracy: 1)
        }
    }
    func testSearchFocusExpandsRailEscapeClearsAndSelectionClearsHiddenFilter() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTab), second = c.session.addTab(url: URL(string: "https://search.example"), select: false, load: false)
        let w = window(c); defer { w.close() }; try await settle()
        c.compactSidebar = true; c.searchTabs(); try await settle()
        XCTAssertFalse(c.compactSidebar)
        // A styled SwiftUI prompt need not be an NSTextField.placeholderString.
        // Verify the actual focused editor and its search binding instead.
        _ = try XCTUnwrap(w.firstResponder as? NSTextView)
        c.tabSearch = "search.example"; try await settle()
        XCTAssertEqual((w.firstResponder as? NSTextView)?.string, "search.example")
        XCTAssertEqual(SidebarTabs.filtered(c.session.orderedTabs, query: c.tabSearch).map(\.id), [second.id])
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape); try await settle(); XCTAssertEqual(c.tabSearch, "")
        c.tabSearch = "absent"; c.session.selectTab(second.id); try await settle(); XCTAssertEqual(c.tabSearch, "")
        c.session.selectTab(first.id)
    }
    func testNativeAXOrderAndCloseActionRemainAvailableWithoutHover() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTab)
        _ = c.session.addTab(select: false, load: false)
        let w = window(c, solid: true); defer { w.close() }; try await settle()
        let all = nodes(w)
        try XCTSkipIf(BackgroundUIMode.isEnabled && !all.contains { $0.accessibilityIdentifier() == "sidebarToggle" }, "Foreground-only VoiceOver tree: SwiftUI exposes no sidebar AX descendants in this off-screen accessory window. Model labels and native shortcut tests still run.")
        let labels = all.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains("Search tabs"))
        XCTAssertTrue(labels.contains("Pinned, 0 tabs")); XCTAssertTrue(labels.contains("Tabs, 2 tabs"))
        XCTAssertTrue(labels.contains("Close New Tab"), "Hidden glyph must retain a native AX close control")
        let row = try XCTUnwrap(all.first { $0.accessibilityLabel() == SidebarTabs.label(first, selected: true) })
        XCTAssertEqual(row.accessibilityRole(), .button)
        let searchIndex = try XCTUnwrap(labels.firstIndex(of: "Search tabs"))
        let tabIndex = try XCTUnwrap(labels.firstIndex(of: SidebarTabs.label(first, selected: true)))
        let newIndex = try XCTUnwrap(labels.firstIndex(of: "New Tab"))
        XCTAssertLessThan(searchIndex, tabIndex); XCTAssertLessThan(tabIndex, newIndex)
    }
    func testNativeToggleReorderAndSearchBudgetsAtTwelveFiftyAndHundredTabs() async throws {
        for count in [12, 50, 100] {
            let c = BrowserController(testing: true)
            for index in 1..<count { _ = c.session.addTab(url: URL(string: "https://site\(index).example"), select: false, load: false) }
            let w = window(c, solid: false)
            try await settle()
            var toggles: [Double] = [], reorders: [Double] = [], searches: [Double] = []
            for index in 0..<24 {
                var start = CACurrentMediaTime()
                c.compactSidebar.toggle(); w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded()
                toggles.append((CACurrentMediaTime() - start) * 1000)
                start = CACurrentMediaTime()
                let tabs = c.session.orderedTabs
                c.session.moveTab(tabs.last!.id, to: tabs.first!.id)
                w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded()
                reorders.append((CACurrentMediaTime() - start) * 1000)
                start = CACurrentMediaTime()
                c.tabSearch = index.isMultiple(of: 2) ? "site9" : ""
                w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded()
                searches.append((CACurrentMediaTime() - start) * 1000)
                try await Task.sleep(for: .milliseconds(10))
            }
            func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }
            print("SIDEBAR_INTERACTION tabs=\(count) toggle_p95_ms=\(p95(toggles)) reorder_p95_ms=\(p95(reorders)) search_p95_ms=\(p95(searches)) native_layout_only=true")
            XCTAssertEqual(c.session.tabs.count, count)
            w.contentView = nil; w.close(); c.shutdown()
        }
    }
    func testHundredTabNativeScrollLayoutBudgetWithGlassAndSolid() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = (0..<100).map { TabRecord(title: "Tab \($0)", url: URL(string: "https://site\($0).example"), isPinned: $0 < 10) }
        try SessionFileStore(fileURL: BrowserProfile.personal.directory(in: root).appendingPathComponent("session.json"))
            .save(BrowserSnapshot(tabs: records, selectedTabID: records[10].id, legacyBookmarksImported: true))
        let c = BrowserController(rootDirectory: root, testing: true); defer { c.shutdown() }
        // Sidebar-only host: the exact same 100 sleeping metadata records and no page loads.
        for solid in [true, false] {
            let w = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 276, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: BrowserSidebar(controller: c).browserAppearance(.light)
                .background { Color.clear.modifier(MacSidebarGlass()) }.environment(\.chromeReduceTransparencyOverride, solid))
            BackgroundUIMode.show(w); try await settle()
            let scroll = try XCTUnwrap(w.contentView.flatMap { views($0).compactMap { $0 as? NSScrollView }.first })
            let clip = scroll.contentView
            var samples: [Double] = []
            for frame in 0..<180 {
                let start = CACurrentMediaTime()
                let maximum = max(1, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height)
                clip.scroll(to: NSPoint(x: 0, y: maximum * Double(frame % 90) / 89))
                scroll.reflectScrolledClipView(clip)
                w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded()
                samples.append((CACurrentMediaTime() - start) * 1000)
                try await Task.sleep(for: .milliseconds(2))
            }
            let sorted = samples.sorted(), p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            print("SIDEBAR_SCROLL tabs=100 solid=\(solid) samples=\(samples.count) p50_ms=\(sorted[sorted.count / 2]) p95_ms=\(p95) max_ms=\(sorted.last!) over16ms=\(samples.filter { $0 > 16.67 }.count) native_layout_only=true")
            XCTAssertLessThan(p95, 16.67, "Off-screen native scroll/layout CPU must fit a 60 Hz frame budget")
            XCTAssertFalse(c.session.tabs.contains(where: \.isInstantiated), "Rows/search must never wake sleeping WebViews")
            w.contentView = nil; w.close()
        }
        for count in [12, 50, 100] {
            let tabs = Array(c.session.orderedTabs.prefix(count))
            let start = CACurrentMediaTime()
            for _ in 0..<100 { _ = SidebarTabs.filtered(tabs, query: "site9") }
            print("SIDEBAR_SEARCH tabs=\(count) mean_ms=\((CACurrentMediaTime() - start) * 10)")
        }
    }
}
