import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI
import XCTest
@testable import PersonalBrowser

@MainActor final class ChromeFocusTests: BackgroundUITestCase {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func marker(_ name: String, in window: NSWindow) -> NSView? {
        window.contentView.flatMap { views($0).first { $0.identifier?.rawValue == name } }
    }
    private func host(_ controller: BrowserController, appearance: BrowserAppearance = .light, rtl: Bool = false, reduceMotion: Bool = true) -> NSWindow {
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BrowserWindow(controller: controller)
            .browserAppearance(appearance).environment(\.chromeReduceTransparencyOverride, true)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .environment(\.sidebarCaptureReduceMotion, reduceMotion))
        window.setContentSize(NSSize(width: 1000, height: 760))
        BackgroundUIMode.show(window)
        return window
    }
    private func wait(_ message: String, condition: @MainActor () -> Bool) async throws {
        try await eventually(message, poll: .milliseconds(20), condition)
    }
    private func keyEvent(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
    private func key(_ code: UInt16, _ text: String, in window: NSWindow) throws {
        NSApp.sendEvent(try keyEvent(code, text, in: window))
    }
    private func searchEditing(in window: NSWindow) -> Bool {
        window.firstResponder is NSTextView && window.contentView.map {
            !views($0).contains { ($0 as? FocusAwareAddressField)?.currentEditor() != nil }
        } == true
    }
    private func focusSearch(_ controller: BrowserController, in window: NSWindow) async throws {
        func addressEditing() -> Bool {
            window.contentView.map { views($0).contains { ($0 as? FocusAwareAddressField)?.currentEditor() != nil } } == true
        }
        try await wait("Initial address focus did not settle") { addressEditing() }
        controller.searchTabs()
        try await wait("Search did not acquire the field editor") { window.firstResponder is NSTextView && !addressEditing() }
    }
    private func click(_ name: String, in window: NSWindow) throws {
        let target = try XCTUnwrap(marker(name, in: window), name)
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        try click(point, in: window)
    }

    private func click(_ point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    private func collection(in window: NSWindow) -> SidebarTabCollection? {
        window.contentView.flatMap { views($0).compactMap { $0 as? SidebarTabCollection }.first }
    }

    func testSearchHandsFocusToNativeCollectionAndTabLeavesIt() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let w = host(c); defer { w.close() }
        try await focusSearch(c, in: w)
        try key(125, "\u{f701}", in: w)
        let list = try XCTUnwrap(collection(in: w))
        try await wait("Search did not transfer to the AppKit list") { w.firstResponder === list }
        XCTAssertEqual(list.sidebar?.selectedID, c.session.selectedTabID)
        let path = try XCTUnwrap(list.selectionIndexPaths.first)
        let row = try XCTUnwrap(list.item(at: path)?.view)
        XCTAssertFalse(row.focusRingMaskBounds.isEmpty)
        try key(48, "\t", in: w)
        try await wait("Tab did not advance beyond the collection") { w.firstResponder !== list }
        XCTAssertTrue(row.focusRingMaskBounds.isEmpty)
    }

    func testTabAndArrowDrawFocusRingUntilClickOrShortcut() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let next = c.session.addTab(select: false, load: false)
        let w = host(c, appearance: .dark); defer { w.close() }
        try await focusSearch(c, in: w)
        let list = try XCTUnwrap(collection(in: w))
        try key(48, "\t", in: w)
        try await wait("Tab did not enter the native collection") { w.firstResponder === list }
        let firstPath = try XCTUnwrap(list.selectionIndexPaths.first)
        let firstRow = try XCTUnwrap(list.item(at: firstPath)?.view)
        XCTAssertFalse(firstRow.focusRingMaskBounds.isEmpty)

        list.keyDown(with: try keyEvent(125, "\u{f701}", in: w))
        XCTAssertEqual(list.sidebar?.selectedID, next.id)
        XCTAssertNotEqual(c.session.selectedTabID, next.id)
        XCTAssertTrue(firstRow.accessibilityLabel()?.contains("Selected") == true)
        XCTAssertTrue(firstRow.focusRingMaskBounds.isEmpty)
        let path = try XCTUnwrap(list.selectionIndexPaths.first)
        let row = try XCTUnwrap(list.item(at: path)?.view)
        XCTAssertFalse(row.focusRingMaskBounds.isEmpty)
        XCTAssertFalse(row.accessibilityLabel()?.contains("Selected") == true)

        func capture(_ name: String) throws -> Data {
            let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return png
        }

        let keyboard = try capture("Sidebar row after keyboard navigation")
        try click("sidebarItem-\(next.id)", in: w)
        XCTAssertTrue(w.firstResponder === list)
        XCTAssertEqual(c.session.selectedTabID, next.id)
        XCTAssertTrue(row.focusRingMaskBounds.isEmpty)
        XCTAssertNotEqual(keyboard, try capture("Sidebar row after click"))

        // Re-enter keyboard mode, then use the window router's consumed shortcut.
        list.keyDown(with: try keyEvent(125, "\u{f701}", in: w))
        XCTAssertFalse(row.focusRingMaskBounds.isEmpty)
        NSApp.sendEvent(try keyEvent(48, "\t", modifiers: .control, in: w))
        XCTAssertEqual(c.session.selectedTabID, list.sidebar?.tab(at: firstPath)?.id)
        XCTAssertTrue(firstRow.focusRingMaskBounds.isEmpty)
        XCTAssertTrue(row.focusRingMaskBounds.isEmpty)
    }

    func testRevealingFirstRowsIncludesTheirSectionHeadings() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTab)
        c.session.togglePinned(first.id)
        var pins = [first]
        for _ in 0..<4 {
            let pin = c.session.addTab(select: false, load: false)
            c.session.togglePinned(pin.id)
            pins.append(pin)
        }
        let regular = (0..<40).map { _ in c.session.addTab(select: false, load: false) }
        let last = try XCTUnwrap(regular.last)
        let w = host(c); defer { w.close() }
        try await wait("Collection did not mount") { self.collection(in: w)?.sidebar?.path(for: last.id) != nil }
        let list = try XCTUnwrap(collection(in: w))
        let data = try XCTUnwrap(list.sidebar)

        func revealFromBottom(_ tab: BrowserTab) async throws -> NSRect {
            c.session.selectNumberedTab(9)
            try await wait("Last tab was not revealed") { data.selectedID == last.id && list.visibleRect.minY > 200 }
            let number = try XCTUnwrap(c.session.orderedTabs.firstIndex { $0.id == tab.id }) + 1
            c.session.selectNumberedTab(number)
            try await wait("Numbered tab was not selected") { data.selectedID == tab.id }
            let path = try XCTUnwrap(data.path(for: tab.id))
            let header = try XCTUnwrap(list.layoutAttributesForSupplementaryElement(ofKind: NSCollectionView.elementKindSectionHeader,
                                                                                     at: IndexPath(item: 0, section: path.section)))
            let row = try XCTUnwrap(list.layoutAttributesForItem(at: path))
            XCTAssertTrue(list.visibleRect.contains(row.frame.union(header.frame)))
            return header.frame
        }

        _ = try await revealFromBottom(first)
        XCTAssertEqual(list.visibleRect.minY, 0, accuracy: 1)
        let firstRowLast = try XCTUnwrap(c.session.orderedTabs.dropFirst(2).first)
        _ = try await revealFromBottom(firstRowLast)
        XCTAssertEqual(list.visibleRect.minY, 0, accuracy: 1)
        let tabs = try await revealFromBottom(try XCTUnwrap(regular.first))
        XCTAssertEqual(list.visibleRect.minY, tabs.minY, accuracy: 1)

        for pin in pins { c.session.togglePinned(pin.id) }
        let firstUnpinned = try XCTUnwrap(c.session.orderedTabs.first)
        _ = try await revealFromBottom(firstUnpinned)
        XCTAssertEqual(list.visibleRect.minY, 0, accuracy: 1)
    }

    func testArrowsLeaveTabsSleepingUntilExplicitActivation() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let original = try XCTUnwrap(c.session.selectedTab)
        let tabs = (1...5).map { index in
            c.session.addTab(url: URL(string: "https://sleeping-\(index).example"), select: false, load: false)
        }
        let w = host(c); defer { w.close() }
        try await focusSearch(c, in: w)
        try key(125, "\u{f701}", in: w)
        let list = try XCTUnwrap(collection(in: w))
        try await wait("Collection did not gain focus") { w.firstResponder === list }
        for tab in tabs {
            list.keyDown(with: try keyEvent(125, "\u{f701}", in: w))
            XCTAssertEqual(list.sidebar?.selectedID, tab.id)
            XCTAssertEqual(c.session.selectedTabID, original.id)
            XCTAssertTrue(tabs.allSatisfy { !$0.isInstantiated })
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(c.session.selectedTabID, original.id)
        XCTAssertTrue(tabs.allSatisfy { !$0.isInstantiated })
        list.keyDown(with: try keyEvent(49, " ", in: w))
        XCTAssertEqual(c.session.selectedTabID, tabs.last?.id)
        XCTAssertTrue(tabs.last?.isInstantiated == true)
        XCTAssertTrue(tabs.dropLast().allSatisfy { !$0.isInstantiated })
    }

    func testReturnCommitsHighlightAfterReturningToSidebar() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let original = try XCTUnwrap(c.session.selectedTab)
        let sleeping = c.session.addTab(url: URL(string: "https://sleeping.example"), select: false, load: false)
        let w = host(c); defer { w.close() }
        try await focusSearch(c, in: w)
        try key(125, "\u{f701}", in: w)
        let list = try XCTUnwrap(collection(in: w))
        try await wait("Search did not transfer to the AppKit list") { w.firstResponder === list }
        list.keyDown(with: try keyEvent(125, "\u{f701}", in: w))
        XCTAssertEqual(list.sidebar?.selectedID, sleeping.id)
        XCTAssertTrue(w.makeFirstResponder(nil))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(c.session.selectedTabID, original.id)
        XCTAssertFalse(sleeping.isInstantiated)
        list.focusTab(original.id)
        list.keyDown(with: try keyEvent(125, "\u{f701}", in: w))
        list.keyDown(with: try keyEvent(36, "\r", in: w))
        XCTAssertEqual(c.session.selectedTabID, sleeping.id)
        XCTAssertTrue(sleeping.isInstantiated)
    }

    func testLegacyScrollbarLeavesFullRailAndNativeRowsExposeActions() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        for _ in 0..<40 { _ = c.session.addTab(select: false, load: false) }
        c.compactSidebar = true
        let w = host(c); defer { w.close() }
        func layoutMatches(_ width: CGFloat, showsScrollbar: Bool) -> Bool {
            w.contentView?.layoutSubtreeIfNeeded()
            return marker("sidebarSurfaceGeometry", in: w)?.bounds.width == width &&
                collection(in: w)?.enclosingScrollView?.hasVerticalScroller == showsScrollbar
        }
        try await wait("Rail did not mount") { layoutMatches(MacBrowserLayout.railWidth, showsScrollbar: false) }
        c.compactSidebar = false
        try await wait("Expanded scroller did not mount") {
            layoutMatches(MacBrowserLayout.sidebarWidth, showsScrollbar: true)
        }
        let expandedScroll = try XCTUnwrap(collection(in: w)?.enclosingScrollView)
        expandedScroll.scrollerStyle = .legacy
        expandedScroll.tile()
        XCTAssertEqual(expandedScroll.scrollerStyle, .legacy)
        c.compactSidebar = true
        try await wait("Rail kept legacy scrollbar space") {
            layoutMatches(MacBrowserLayout.railWidth, showsScrollbar: false)
        }
        let list = try XCTUnwrap(collection(in: w))
        let scroll = try XCTUnwrap(list.enclosingScrollView)
        scroll.tile()
        XCTAssertEqual(scroll.contentView.bounds.width, MacBrowserLayout.railWidth, accuracy: 1)
        XCTAssertFalse(scroll.hasVerticalScroller)
        let path = try XCTUnwrap(list.selectionIndexPaths.first)
        let row = try XCTUnwrap(list.item(at: path)?.view)
        XCTAssertEqual(row.bounds.width, 42, accuracy: 1)
        XCTAssertEqual(row.accessibilityRole(), .row)
        XCTAssertTrue(row.isAccessibilitySelected())
        XCTAssertTrue(row.accessibilityCustomActions()?.contains { $0.name == "Close Tab" } == true)
        XCTAssertNotNil(list.accessibilityRole())
    }

    func testNativeDragPinsInGridGapsReordersAndUnpinsAtEveryWidth() async throws {
        for rtl in [false, true] {
            let c = BrowserController(testing: true); defer { c.shutdown() }
            let regular = try XCTUnwrap(c.session.selectedTab)
            let candidate = c.session.addTab(select: false, load: false)
            let pins = (0..<7).map { _ in
                let tab = c.session.addTab(select: false, load: false)
                c.session.togglePinned(tab.id)
                return tab
            }
            let w = host(c, rtl: rtl); defer { w.close() }
            try await wait("Collection did not mount") { self.collection(in: w)?.sidebar?.path(for: candidate.id) != nil }
            let list = try XCTUnwrap(collection(in: w))
            let data = try XCTUnwrap(list.sidebar)
            for width: CGFloat in [220, 256, 360] {
                c.sidebar.setExpandedWidth(width)
                try await wait("Sidebar width \(width)") {
                    w.contentView?.layoutSubtreeIfNeeded()
                    return self.marker("sidebarSurfaceGeometry", in: w)?.bounds.width == width
                }
                let first = try itemFrame(pins[0].id, in: list)
                let second = try itemFrame(pins[1].id, in: list)
                let gap = NSPoint(x: (first.midX + second.midX) / 2, y: first.midY)
                try await drag(candidate.id, in: list) { gap }
                XCTAssertEqual(c.session.orderedTabs.filter(\.isPinned).map(\.id),
                               [pins[0].id, candidate.id] + pins.dropFirst().map(\.id))
                try await wait("Pin order did not update") { data.path(for: candidate.id)?.item == 1 }

                try await drag(candidate.id, in: list) {
                    let last = try self.itemFrame(pins[6].id, in: list)
                    return NSPoint(x: rtl ? last.minX : last.maxX, y: last.maxY + OrivLayout.sidebarPinGap / 2)
                }
                XCTAssertEqual(c.session.orderedTabs.filter(\.isPinned).last?.id, candidate.id)
                try await wait("Pinned reorder did not update") { data.path(for: candidate.id)?.item == pins.count }

                try await drag(candidate.id, in: list) {
                    let row = try self.itemFrame(regular.id, in: list)
                    return NSPoint(x: row.midX, y: row.minY + row.height / 4)
                }
                XCTAssertFalse(candidate.isPinned)
                XCTAssertEqual(c.session.orderedTabs.filter { !$0.isPinned }.map(\.id), [candidate.id, regular.id])
                try await wait("Unpin did not update") { data.path(for: candidate.id)?.section == 1 }
            }
        }
    }

    func testNativeDragPinAndUnpinWithEmptySectionsInExpandedSidebarAndRail() async throws {
        for rail in [false, true] {
            let c = BrowserController(testing: true); defer { c.shutdown() }
            c.compactSidebar = rail
            let tab = try XCTUnwrap(c.session.selectedTab)
            let w = host(c); defer { w.close() }
            try await wait("Collection did not mount") { self.collection(in: w)?.sidebar?.path(for: tab.id) != nil }
            let list = try XCTUnwrap(collection(in: w))
            for pinning in [true, false] {
                try await drag(tab.id, in: list) {
                    // An empty pin section is first; an empty Tabs section follows the only pin.
                    let path = IndexPath(item: 0, section: pinning ? 0 : 1)
                    let header = try XCTUnwrap(list.layoutAttributesForSupplementaryElement(
                        ofKind: NSCollectionView.elementKindSectionHeader, at: path))
                    return NSPoint(x: header.frame.midX, y: header.frame.midY)
                }
                XCTAssertEqual(tab.isPinned, pinning)
                let emptySection = pinning ? 1 : 0
                XCTAssertEqual(list.numberOfItems(inSection: emptySection), 0)
                XCTAssertNil(list.layoutAttributesForSupplementaryElement(
                    ofKind: NSCollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: emptySection)))
            }

            let other = c.session.addTab(select: false, load: false)
            c.session.togglePinned(other.id)
            try await wait("Single pin did not mount") { list.sidebar?.path(for: other.id)?.section == 0 }
            try await drag(tab.id, in: list) {
                let pin = try self.itemFrame(other.id, in: list)
                return NSPoint(x: pin.minX + pin.width / 4, y: pin.minY + pin.height / 4)
            }
            XCTAssertEqual(c.session.orderedTabs.filter(\.isPinned).map(\.id), [tab.id, other.id])
            try await drag(tab.id, in: list) {
                let pin = try self.itemFrame(other.id, in: list)
                return rail ? NSPoint(x: pin.midX, y: pin.midY + 4) : NSPoint(x: pin.midX + 4, y: pin.midY)
            }
            XCTAssertEqual(c.session.orderedTabs.filter(\.isPinned).map(\.id), [other.id, tab.id])
        }
    }

    func testNativeDragRejectsForeignOwnerAndCrossPrivacyTiles() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let pin = try XCTUnwrap(c.session.selectedTab)
        c.session.togglePinned(pin.id)
        let privateTab = c.session.addTab(isPrivate: true, select: false, load: false)
        let w = host(c); defer { w.close() }
        try await wait("Private tab did not mount") { self.collection(in: w)?.sidebar?.path(for: privateTab.id) != nil }
        let list = try XCTUnwrap(collection(in: w))
        try await drag(privateTab.id, in: list, accepted: false) {
            let frame = try self.itemFrame(pin.id, in: list)
            return NSPoint(x: frame.midX, y: frame.midY)
        }
        try await drag(privateTab.id, in: list, accepted: false, owner: UUID()) {
            let header = try XCTUnwrap(list.layoutAttributesForSupplementaryElement(
                ofKind: NSCollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 0)))
            return NSPoint(x: header.frame.midX, y: header.frame.midY)
        }
        XCTAssertFalse(privateTab.isPinned)
    }

    func testSixTabDragCancelsAndDropsWithAndWithoutPins() async throws {
        let restoreDefaults = setFramePacingPreference(false)
        defer { restoreDefaults() }
        let enabledByEnvironment = ProcessInfo.processInfo.environment["ORIV_SIDEBAR_DRAG_FRAMES"] == "1"
        let output = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        for withPins in [false, true] {
            let c = BrowserController(testing: true); defer { c.shutdown() }
            let source = try XCTUnwrap(c.session.selectedTab)
            let peers = (0..<5).map { _ in c.session.addTab(select: false, load: false) }
            if withPins { c.session.togglePinned(peers[0].id) }
            let w = host(c, reduceMotion: false); defer { w.close() }
            try await wait("Six-tab drag fixture did not mount") { self.collection(in: w)?.sidebar?.path(for: peers[4].id) != nil }
            let list = try XCTUnwrap(collection(in: w))
            let file = output.appendingPathComponent(UUID().uuidString)
            list.dragFramePacingTestOutput = file
            let destination = try itemFrame(peers[4].id, in: list)
            try await exerciseDrag(source.id, in: list, cancel: true) {
                let frame = try self.itemFrame(peers[4].id, in: list)
                return NSPoint(x: frame.midX, y: frame.maxY - 2)
            }
            XCTAssertEqual(try itemFrame(peers[4].id, in: list), destination)
            XCTAssertEqual(c.session.orderedTabs.count, 6)
            try await exerciseDrag(source.id, in: list, cancel: false) {
                let frame = try self.itemFrame(peers[4].id, in: list)
                return NSPoint(x: frame.midX, y: frame.maxY - 2)
            }
            XCTAssertEqual(c.session.orderedTabs.last?.id, source.id)
            if enabledByEnvironment {
                try await wait("Frame pacing did not record both six-tab drags") {
                    (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").count == 2
                }
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    private func setFramePacingPreference(_ enabled: Bool) -> () -> Void {
        let defaults = UserDefaults.standard
        let domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var updated = domain
        updated["SidebarDragFramePacing"] = enabled
        defaults.setVolatileDomain(updated, forName: UserDefaults.argumentDomain)
        return { defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain) }
    }

    func testFramePacingReportsCancellationAndDropFromEverySidebarSectionAndTheRail() async throws {
        struct Report: Decodable {
            struct Stats: Decodable { let count: Int }
            struct Work: Decodable {
                let phase: String
                let durationMS: Double
            }
            let total: Stats
            let phases: [String: Stats]
            let mainThreadWork: [String: [Work]]
        }
        let restoreDefaults = setFramePacingPreference(true)
        defer { restoreDefaults() }

        let output = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        for (rail, pinned, isPrivate) in [(false, false, false), (false, true, false), (false, false, true), (true, false, false)] {
            let c = BrowserController(profile: isPrivate ? nil : .personal, testing: true)
            defer { c.shutdown() }
            c.compactSidebar = rail
            let source = try XCTUnwrap(c.session.selectedTab)
            if pinned { c.session.togglePinned(source.id) }
            XCTAssertEqual(c.session.orderedTabs.map(\.id), [source.id])
            XCTAssertEqual(source.isPrivate, isPrivate)
            let w = host(c, reduceMotion: false); defer { w.close() }
            try await wait("Single-tab sidebar did not mount") { self.collection(in: w)?.sidebar?.path(for: source.id) != nil }
            let list = try XCTUnwrap(collection(in: w))
            let file = output.appendingPathComponent(UUID().uuidString)
            list.dragFramePacingTestOutput = file
            let target = IndexPath(item: 0, section: pinned ? 1 : 0)
            for cancel in [true, false] {
                try await exerciseDrag(source.id, in: list, cancel: cancel) {
                    let header = try XCTUnwrap(list.layoutAttributesForSupplementaryElement(
                        ofKind: NSCollectionView.elementKindSectionHeader, at: target))
                    return NSPoint(x: header.frame.midX, y: header.frame.midY)
                }
                XCTAssertEqual(source.isPinned, cancel ? pinned : !pinned)
                XCTAssertEqual(source.isPrivate, isPrivate)
            }
            try await wait("Frame pacing did not write both JSON lines") {
                (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").count == 2
            }
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            let attachment = XCTAttachment(data: Data(lines.joined(separator: "\n").utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "sidebar-drag-pacing-rail-\(rail)-pinned-\(pinned)-private-\(isPrivate)"
            attachment.lifetime = .keepAlways
            add(attachment)
            for (index, line) in lines.enumerated() {
                let report = try JSONDecoder().decode(Report.self, from: Data(line.utf8))
                XCTAssertEqual(report.total.count, report.phases.values.reduce(0) { $0 + $1.count })
                XCTAssertEqual(report.mainThreadWork["dragBegin"]?.count, 1)
                XCTAssertEqual(report.mainThreadWork["dragSetup"]?.count, 1)
                if index == 1 {
                    let commit = try XCTUnwrap(report.mainThreadWork["dropCommit"]?.first)
                    XCTAssertEqual(commit.phase, "publish")
                    XCTAssertEqual(report.mainThreadWork["dropRelease"]?.count, 1)
                    XCTAssertGreaterThanOrEqual(commit.durationMS, 0)
                }
            }
        }
    }

    func testSidebarRejectsStaleCollectionIndexPaths() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let w = host(c); defer { w.close() }
        try await wait("Sidebar did not mount") { self.collection(in: w)?.sidebar != nil }
        let list = try XCTUnwrap(collection(in: w))
        let data = try XCTUnwrap(list.sidebar)
        let obsolete = IndexPath(item: 0, section: list.numberOfSections)
        XCTAssertEqual(data.collectionView(list, numberOfItemsInSection: obsolete.section), 0)
        XCTAssertNil(list.collectionViewLayout?.layoutAttributesForItem(at: obsolete))
        XCTAssertNil(list.collectionViewLayout?.layoutAttributesForSupplementaryView(
            ofKind: NSCollectionView.elementKindSectionHeader, at: obsolete))
    }

    private func exerciseDrag(_ id: UUID, in list: SidebarTabCollection, cancel: Bool,
                              at point: () throws -> NSPoint) async throws {
        let data = try XCTUnwrap(list.sidebar)
        let source = try XCTUnwrap(data.path(for: id))
        let info = try makeDrag(id, in: list)
        data.beginDrag(at: source)
        defer { data.endDrag() }
        // AppKit can enter the destination before the queued activation runs.
        list.layoutSubtreeIfNeeded()
        info.move(to: NSPoint(x: list.bounds.midX, y: -1))
        XCTAssertEqual(list.draggingEntered(info), [])
        XCTAssertTrue(data.controller?.sidebar.dragging == true)
        XCTAssertEqual(data.path(for: id), source, "AppKit retains the source index path when the drop headings appear")
        info.move(to: try point())
        XCTAssertEqual(list.draggingUpdated(info), .move)
        list.layoutSubtreeIfNeeded()
        XCTAssertNotNil(list.insertionMarkerFrame)
        let layout = try XCTUnwrap(list.collectionViewLayout)
        for attributes in layout.layoutAttributesForElements(in: NSRect(origin: .zero, size: layout.collectionViewContentSize)) {
            let path = try XCTUnwrap(attributes.indexPath)
            XCTAssertTrue((0..<list.numberOfSections).contains(path.section))
            if attributes.representedElementCategory == .item, (0..<list.numberOfSections).contains(path.section) {
                XCTAssertTrue((0..<list.numberOfItems(inSection: path.section)).contains(path.item))
            }
        }
        if cancel {
            list.draggingExited(info)
            data.endDrag()
        } else {
            XCTAssertTrue(list.prepareForDragOperation(info))
            XCTAssertTrue(list.performDragOperation(info))
            list.concludeDragOperation(info)
            try await wait("Drop did not publish") { data.controller?.sidebar.dragging == false }
        }
        XCTAssertFalse(data.controller?.sidebar.dragging == true)
        XCTAssertNil(list.insertionMarkerFrame)
    }

    func testDragReflowsBothWaysAndRestoresLayoutOnCancellation() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let candidate = try XCTUnwrap(c.session.selectedTab)
        c.sidebar.setExpandedWidth(220)
        let pins = (0..<4).map { _ in c.session.addTab(select: false, load: false) }
        for pin in pins { c.session.togglePinned(pin.id) }
        let peer = c.session.addTab(select: false, load: false)
        let window = host(c, reduceMotion: false); defer { window.close() }
        try await wait("Drag fixture did not lay out") { self.collection(in: window)?.sidebar?.path(for: peer.id) != nil }
        let list = try XCTUnwrap(collection(in: window))
        let data = try XCTUnwrap(list.sidebar)
        let pin = pins[0]

        func capture(_ name: String) throws {
            let bitmap = try XCTUnwrap(list.bitmapImageRepForCachingDisplay(in: list.visibleRect))
            list.cacheDisplay(in: list.visibleRect, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "sidebar-drag-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        try capture("01-before-pin")
        let pinFrame = try itemFrame(pin.id, in: list)
        let source = try XCTUnwrap(data.path(for: candidate.id))
        let sourceItem = try XCTUnwrap(list.item(at: source))
        let artwork = try XCTUnwrap(sourceItem.draggingImageComponents.first)
        XCTAssertEqual(artwork.frame.size, try itemFrame(candidate.id, in: list).size)
        XCTAssertTrue(artwork === sourceItem.draggingImageComponents.first)
        let peerPinItem = try XCTUnwrap(list.item(at: XCTUnwrap(data.path(for: pin.id))))
        let intoPins = try makeDrag(candidate.id, in: list)
        data.beginDrag(at: source)
        defer { data.endDrag() }
        try await wait("Pin drag did not begin") { c.sidebar.dragging }
        let lastPin = try itemFrame(pins[3].id, in: list)
        intoPins.move(to: NSPoint(x: lastPin.maxX - 2, y: lastPin.midY))
        XCTAssertEqual(list.draggingEntered(intoPins), .move)
        list.layoutSubtreeIfNeeded()
        let wrappedGap = try XCTUnwrap(list.insertionMarkerFrame)
        let preview = try XCTUnwrap(intoPins.draggingItem)
        XCTAssertEqual(preview.draggingFrame.size, lastPin.size)
        let previewImage = try XCTUnwrap(preview.imageComponentsProvider?().first?.contents) as! CGImage
        let renderCount = list.dragImageRenderCount
        XCTAssertGreaterThan(wrappedGap.minY, lastPin.maxY)
        intoPins.move(to: NSPoint(x: wrappedGap.midX, y: wrappedGap.midY))
        XCTAssertEqual(list.draggingUpdated(intoPins), .move)
        list.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.insertionMarkerFrame, wrappedGap)

        intoPins.move(to: NSPoint(x: pinFrame.minX + 4, y: pinFrame.midY))
        XCTAssertEqual(list.draggingUpdated(intoPins), .move)
        list.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try itemFrame(pin.id, in: list).minX, pinFrame.minX)
        XCTAssertEqual(list.insertionMarkerFrame, pinFrame)
        let reflow = try XCTUnwrap(peerPinItem.view.layer?.animation(forKey: "sidebarReflow") as? CAKeyframeAnimation)
        XCTAssertTrue(reflow.isAdditive)
        XCTAssertFalse(candidate.isPinned)
        try capture("02-pin-gap")
        try await Task.sleep(for: .milliseconds(100))
        try capture("03-pin-reflow")
        XCTAssertTrue(list.prepareForDragOperation(intoPins))
        XCTAssertTrue(intoPins.animatesToDestination)
        XCTAssertTrue(list.performDragOperation(intoPins))
        let landingFrame = try XCTUnwrap(list.insertionMarkerFrame)
        let landing = try XCTUnwrap(intoPins.draggingItem)
        XCTAssertEqual(landing.draggingFrame, landingFrame)
        let contents = try XCTUnwrap(landing.imageComponentsProvider?().first?.contents)
        XCTAssertTrue(previewImage === contents as! CGImage)
        XCTAssertEqual(list.dragImageRenderCount, renderCount, "Slot updates and release must reuse the preview bitmap")
        let bitmap = NSBitmapImageRep(cgImage: contents as! CGImage)
        XCTAssertGreaterThan(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0, 0)
        list.concludeDragOperation(intoPins)
        try await wait("Drop did not publish") { !c.sidebar.dragging }
        XCTAssertEqual(list.layoutAttributesForItem(at: try XCTUnwrap(data.path(for: candidate.id)))?.alpha, 1)
        XCTAssertNil(sourceItem.view.layer?.animation(forKey: "sidebarLanding"))
        data.endDrag()
        try await wait("Pinned position did not mount") { data.path(for: candidate.id)?.section == 0 }
        XCTAssertTrue(candidate.isPinned)
        XCTAssertTrue(sourceItem === list.item(at: try XCTUnwrap(data.path(for: candidate.id))))
        XCTAssertTrue(peerPinItem === list.item(at: try XCTUnwrap(data.path(for: pin.id))))
        try capture("04-pin-landed")

        let row = try itemFrame(peer.id, in: list)
        let fromPins = try makeDrag(candidate.id, in: list)
        data.beginDrag(at: try XCTUnwrap(data.path(for: candidate.id)))
        try await wait("Unpin drag did not begin") { c.sidebar.dragging }
        fromPins.move(to: NSPoint(x: row.midX, y: row.minY + 4))
        XCTAssertEqual(list.draggingEntered(fromPins), .move)
        list.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(try itemFrame(peer.id, in: list), row)
        XCTAssertNotNil(list.insertionMarkerFrame)
        try capture("05-unpin-reflow")
        list.draggingExited(fromPins)
        list.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.layoutAttributesForItem(at: try XCTUnwrap(data.path(for: candidate.id)))?.alpha, 0)
        XCTAssertEqual(fromPins.draggingItem?.draggingFrame.size, pinFrame.size)
        data.endDrag() // Same cleanup as AppKit ending the session after Escape.
        XCTAssertNil(list.insertionMarkerFrame)
        XCTAssertEqual(try itemFrame(peer.id, in: list), row)
        XCTAssertTrue(candidate.isPinned)
        try capture("06-cancel-return")

        try await drag(candidate.id, in: list) { NSPoint(x: row.midX, y: row.minY + 4) }
        try await wait("Unpinned position did not mount") { data.path(for: candidate.id)?.section == 1 }
        XCTAssertFalse(candidate.isPinned)
        try capture("07-unpin-landed")
    }

    func testSidebarDragFrameSequences() async throws {
        struct Item: Encodable {
            let id: UUID
            let frame: CGRect
            let target: CGRect
            let alpha: Float
            let hasPresentation: Bool
        }
        struct Frame: Encodable {
            let timestamp: Double
            let stage: String
            let items: [Item]
            let preview: CGRect?
            let pointer: CGPoint?
            let gap: CGRect?
            let landing: CGRect?
            let scroll: CGFloat
        }
        enum Scenario: String, CaseIterable {
            case reorderTabs, pin, unpinLastPin, reorderPins, rail, edgeScrollCancel
        }
        let restoreDefaults = setFramePacingPreference(true)
        defer { restoreDefaults() }
        let pacingDirectory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pacingDirectory) }
        let screen = try XCTUnwrap(NSScreen.main)
        for scenario in Scenario.allCases {
            let c = BrowserController(testing: true)
            defer { c.shutdown() }
            c.compactSidebar = scenario == .rail
            let source = try XCTUnwrap(c.session.selectedTab)
            let peers = (0..<(scenario == .edgeScrollCancel ? 33 : 5)).map { _ in c.session.addTab(select: false, load: false) }
            if scenario == .unpinLastPin || scenario == .reorderPins { c.session.togglePinned(source.id) }
            if scenario == .pin || scenario == .reorderPins { peers.prefix(3).forEach { c.session.togglePinned($0.id) } }
            let window = host(c, reduceMotion: false)
            defer { window.close() }
            try await wait("Frame sequence fixture did not mount") {
                self.collection(in: window)?.sidebar?.path(for: peers[4].id) != nil
            }
            let list = try XCTUnwrap(collection(in: window))
            let pacingFile = pacingDirectory.appendingPathComponent("\(scenario.rawValue).jsonl")
            list.dragFramePacingTestOutput = pacingFile
            let data = try XCTUnwrap(list.sidebar)
            let path = try XCTUnwrap(data.path(for: source.id))
            let info = try makeDrag(source.id, in: list)
            let preview = try XCTUnwrap(info.draggingItem)
            let original = preview.draggingFrame
            let originalOrder = c.session.orderedTabs.map(\.id)
            let originalPin = source.isPinned
            let first = try itemFrame(peers[0].id, in: list)
            let last = try itemFrame(peers[scenario == .reorderPins || scenario == .pin ? 2 : 4].id, in: list)
            let renderCount = list.dragImageRenderCount
            var samples: [Frame] = []
            var stage = "before"
            var gap: CGRect?
            var frozenRelayouts = 0
            let frameClock = SidebarDragTestDisplayLink()
            let displayLink = screen.displayLink(target: frameClock, selector: #selector(SidebarDragTestDisplayLink.tick(_:)))
            defer {
                displayLink.invalidate()
                data.endDrag()
            }

            func move(to point: CGPoint, entering: Bool = false, accepted: Bool = true) {
                let oldPointer = list.convert(info.draggingLocation, from: nil)
                preview.draggingFrame = preview.draggingFrame.offsetBy(dx: point.x - oldPointer.x, dy: point.y - oldPointer.y)
                let before = preview.draggingFrame
                info.move(to: point)
                let operation = entering ? list.draggingEntered(info) : list.draggingUpdated(info)
                XCTAssertEqual(operation, accepted ? .move : [], scenario.rawValue)
                if !accepted { XCTAssertEqual(preview.draggingFrame.size, before.size) }
                XCTAssertEqual(preview.draggingFrame.midX, before.midX, accuracy: 0.01, scenario.rawValue)
                XCTAssertEqual(preview.draggingFrame.midY, before.midY, accuracy: 0.01, scenario.rawValue)
                if accepted { list.layoutSubtreeIfNeeded() }
            }

            info.move(to: CGPoint(x: original.midX, y: original.midY))
            frameClock.onFrame = { timestamp, elapsed in
                if stage == "before", elapsed >= 0.035 {
                    stage = "tracking"
                    data.beginDrag(at: path)
                    let target: CGPoint
                    switch scenario {
                    case .pin: target = CGPoint(x: first.minX + 2, y: first.midY)
                    case .reorderPins: target = CGPoint(x: first.maxX - 2, y: first.midY)
                    case .edgeScrollCancel: target = CGPoint(x: list.bounds.midX, y: list.visibleRect.maxY - 2)
                    default: target = CGPoint(x: first.midX, y: first.maxY - 2)
                    }
                    move(to: target, entering: true)
                }
                if stage == "tracking", elapsed >= 0.075, scenario != .edgeScrollCancel {
                    stage = "retargeted"
                    let target = scenario == .pin || scenario == .reorderPins
                        ? CGPoint(x: last.maxX - 2, y: last.midY)
                        : CGPoint(x: last.midX, y: last.maxY - 2)
                    if scenario == .pin {
                        move(to: CGPoint(x: -1, y: first.midY), accepted: false)
                    }
                    move(to: target)
                }
                if elapsed >= 0.24, stage == "retargeted" {
                    stage = "settling"
                    XCTAssertTrue(list.prepareForDragOperation(info), scenario.rawValue)
                    gap = list.insertionMarkerFrame
                    XCTAssertTrue(list.performDragOperation(info), scenario.rawValue)
                    XCTAssertEqual(preview.draggingFrame, gap, scenario.rawValue)
                    frozenRelayouts = list.dragRelayoutCount
                }
                if elapsed >= 0.39, stage == "settling" {
                    stage = "handoff"
                    XCTAssertEqual(source.isPinned, originalPin)
                    XCTAssertEqual(c.session.orderedTabs.map(\.id), originalOrder)
                    XCTAssertEqual(list.dragRelayoutCount, frozenRelayouts)
                    list.concludeDragOperation(info)
                    XCTAssertEqual(list.dragLandingFrame, gap)
                }
                if elapsed >= 0.30, scenario == .edgeScrollCancel, stage == "tracking" {
                    stage = "cancelled"
                    list.draggingExited(info)
                    data.endDrag()
                }
                if stage == "handoff", !c.sidebar.dragging { stage = "landed" }
                let items = list.visibleItems().compactMap { item -> Item? in
                    guard let id = item.view.identifier?.rawValue.split(separator: "-", maxSplits: 1).last.flatMap({ UUID(uuidString: String($0)) }),
                          let layer = item.view.layer else { return nil }
                    let presentation = layer.presentation()
                    return Item(id: id, frame: presentation?.frame ?? layer.frame, target: layer.frame,
                                alpha: presentation?.opacity ?? layer.opacity, hasPresentation: presentation != nil)
                }
                let image = ["tracking", "retargeted", "settling"].contains(stage) ? preview.draggingFrame : nil
                let pointer = image == nil ? nil : list.convert(info.draggingLocation, from: nil)
                samples.append(Frame(timestamp: timestamp, stage: stage, items: items, preview: image, pointer: pointer,
                                     gap: list.insertionMarkerFrame, landing: list.dragLandingFrame,
                                     scroll: list.visibleRect.minY))
            }
            displayLink.add(to: .main, forMode: .common)
            try await wait("Display link did not complete \(scenario.rawValue)") { frameClock.elapsed >= 0.66 }
            displayLink.invalidate()
            let work = try await attachDragWork(from: pacingFile, name: scenario.rawValue)
            if scenario != .edgeScrollCancel {
                assertDropBudget(work, scenario: scenario.rawValue)
            }

            let attachment = try XCTAttachment(data: JSONEncoder().encode(samples), uniformTypeIdentifier: "public.json")
            attachment.name = "sidebar-drag-frames-\(scenario.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let tracking = samples.filter { ["tracking", "retargeted", "settling"].contains($0.stage) }
            // Locally a 120 Hz display link yields well over 12 tracking frames in 0.66 s.
            // Hosted runners drop to a handful under load, like the time budgets below.
            XCTAssertGreaterThan(tracking.count, Self.isHostedCI ? 4 : 12, scenario.rawValue)
            XCTAssertTrue(tracking.dropFirst(2).contains { $0.items.contains(where: \.hasPresentation) }, scenario.rawValue)
            for frame in tracking.dropFirst(2) {
                for item in frame.items {
                    XCTAssertEqual(item.alpha, item.id == source.id ? 0 : 1, accuracy: 0.02, scenario.rawValue)
                }
            }

            // Check the actual samples for each target on both axes. Allow a
            // pixel of rounding and the maximum slope of the monotone cubic.
            var distances: [UUID: (target: CGRect, x: CGFloat, y: CGFloat)] = [:]
            var observedMotion = false
            for (before, after) in zip(samples, samples.dropFirst()) {
                let previous = Dictionary(uniqueKeysWithValues: before.items.map { ($0.id, $0) })
                let dt = after.timestamp - before.timestamp
                for item in after.items where item.id != source.id {
                    guard let old = previous[item.id], old.alpha > 0.99, item.alpha > 0.99 else { continue }
                    let previousDistance = distances[item.id]
                    let sameTarget = old.target == item.target
                    let x = abs(item.target.midX - old.frame.midX)
                    let y = abs(item.target.midY - old.frame.midY)
                    let dx = sameTarget && previousDistance?.target == item.target ? (previousDistance?.x ?? x) : x
                    let dy = sameTarget && previousDistance?.target == item.target ? (previousDistance?.y ?? y) : y
                    distances[item.id] = (item.target, dx, dy)
                    // An interval that spans a retarget moved toward the old target until
                    // the new one landed, so bound only that interval by the farther target.
                    let boundX = sameTarget ? dx : max(dx, abs(old.target.midX - old.frame.midX))
                    let boundY = sameTarget ? dy : max(dy, abs(old.target.midY - old.frame.midY))
                    let step = min(1, 3 * (dt + 1 / Double(screen.maximumFramesPerSecond)) / SidebarReflowMotion.duration)
                    // Hosted runners deliver frames irregularly, so the per-frame
                    // slope bound is a local check; overshoot is checked everywhere.
                    if !Self.isHostedCI {
                        XCTAssertLessThanOrEqual(abs(item.frame.midX - old.frame.midX), boundX * step + 1.5, scenario.rawValue)
                        XCTAssertLessThanOrEqual(abs(item.frame.midY - old.frame.midY), boundY * step + 1.5, scenario.rawValue)
                    }
                    if sameTarget {
                        XCTAssertLessThanOrEqual(abs(item.target.midX - item.frame.midX), x + 1.5, scenario.rawValue)
                        XCTAssertLessThanOrEqual(abs(item.target.midY - item.frame.midY), y + 1.5, scenario.rawValue)
                    }
                    observedMotion = observedMotion || (item.frame != item.target && abs(item.frame.midY - item.target.midY) > 1)
                        || abs(item.frame.midX - item.target.midX) > 1
                }
            }
            XCTAssertTrue(observedMotion, "No in-flight presentation motion in \(scenario.rawValue)")
            for frame in tracking where frame.stage != "settling" && scenario != .edgeScrollCancel {
                let image = try XCTUnwrap(frame.preview)
                let pointer = try XCTUnwrap(frame.pointer)
                XCTAssertEqual(image.midX, pointer.x, accuracy: 0.01, scenario.rawValue)
                XCTAssertEqual(image.midY, pointer.y, accuracy: 0.01, scenario.rawValue)
            }
            let previewSizes = [original.size] + tracking.compactMap { $0.preview?.size }
            let morphs = zip(previewSizes, previewSizes.dropFirst()).filter { $0 != $1 }.count
            XCTAssertEqual(morphs, scenario == .pin || scenario == .unpinLastPin ? 1 : 0, scenario.rawValue)
            XCTAssertEqual(list.dragImageRenderCount, renderCount, "The drag must use both prewarmed images")
            XCTAssertNil(list.insertionMarkerFrame)
            XCTAssertFalse(c.sidebar.dragging)
            if scenario == .edgeScrollCancel {
                XCTAssertGreaterThan(samples.last?.scroll ?? 0, 14)
                XCTAssertEqual(c.session.orderedTabs.map(\.id), originalOrder)
                XCTAssertEqual(try itemFrame(source.id, in: list), original)
            } else {
                let landing = try XCTUnwrap(gap)
                XCTAssertEqual(try itemFrame(source.id, in: list), landing, "The final item must stay where the image landed")
                XCTAssertEqual(list.dragRelayoutCount, frozenRelayouts, "Model publication must not replay the gap")
                let landed = samples.filter { $0.stage == "landed" }.compactMap { frame in frame.items.first { $0.id == source.id } }
                XCTAssertGreaterThan(landed.count, 2)
                // The first display callback after publication can still observe
                // the previous CA transaction, which contains the landing image.
                for item in landed.dropFirst() {
                    XCTAssertEqual(item.alpha, 1, accuracy: 0.02, scenario.rawValue)
                    XCTAssertEqual(item.frame.midY, item.target.midY, accuracy: 0.5)
                    XCTAssertEqual(item.frame.midX, item.target.midX, accuracy: 0.5)
                }
            }
        }
    }

    private struct DragWork: Decodable {
        struct Sample: Decodable {
            let phase: String
            let durationMS: Double
        }
        let mainThreadWork: [String: [Sample]]
    }

    private func attachDragWork(from file: URL, name: String) async throws -> DragWork {
        try await wait("Missing drag timings for \(name)") {
            (try? String(contentsOf: file, encoding: .utf8))?.hasSuffix("\n") == true
        }
        let data = try Data(contentsOf: file)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "sidebar-drag-work-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let work = try JSONDecoder().decode(DragWork.self, from: data)
        for (kind, samples) in work.mainThreadWork.sorted(by: { $0.key < $1.key }) {
            let durations = samples.map(\.durationMS).sorted()
            print("SIDEBAR_DRAG_WORK \(name) \(kind) n=\(durations.count) p95_ms=\(durations[Int(ceil(Double(durations.count) * 0.95)) - 1]) max_ms=\(durations.last!)")
        }
        return work
    }

    private static let isHostedCI = ["CI", "GITHUB_ACTIONS"].contains {
        ["1", "true", "yes"].contains(ProcessInfo.processInfo.environment[$0, default: ""].lowercased())
    }

    private func assertDropBudget(_ work: DragWork, scenario: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(work.mainThreadWork["dropCommit"]?.count, 1, scenario, file: file, line: line)
        // Absolute time budgets are enforced locally only; hosted runners are slower and noisier.
        guard !Self.isHostedCI else { return }
        for kind in ["dropCommit", "sidebarRepresentable", "collectionLayout", "hostingLayout"] {
            let slices = (work.mainThreadWork[kind] ?? []).filter { $0.phase == "publish" }
            for slice in slices {
                XCTAssertLessThanOrEqual(slice.durationMS, 4, "\(scenario) \(kind)", file: file, line: line)
            }
        }
    }

    func testSidebarDropPersistsWithDebouncedSaveAndImmediateQuit() async throws {
        for terminating in [false, true] {
            let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionFileStore(fileURL: BrowserProfile.personal.directory(in: root).appendingPathComponent("session.json"))
            let records = (0..<100).map { TabRecord(title: "Tab \($0)", isPinned: $0 == 0) }
            try store.save(BrowserSnapshot(tabs: records, selectedTabID: records[0].id))
            let controller = BrowserController(rootDirectory: root, testing: true)
            defer { controller.shutdown() }
            let privateTab = controller.session.addTab(isPrivate: true, select: false, load: false)
            let window = host(controller)
            defer { window.close() }
            let source = records[0].id
            let anchor = records[5].id
            try await wait("Persisted sidebar fixture did not mount") {
                self.collection(in: window)?.sidebar?.path(for: anchor) != nil
            }
            let list = try XCTUnwrap(collection(in: window))
            let data = try XCTUnwrap(list.sidebar)
            let info = try makeDrag(source, in: list)
            data.beginDrag(at: try XCTUnwrap(data.path(for: source)))
            defer { data.endDrag() }
            try await wait("Persistence drag did not begin") { controller.sidebar.dragging }
            let row = try itemFrame(anchor, in: list)
            info.move(to: CGPoint(x: row.midX, y: row.maxY - 2))
            XCTAssertEqual(list.draggingEntered(info), .move)
            XCTAssertTrue(list.prepareForDragOperation(info))
            XCTAssertTrue(list.performDragOperation(info))

            var expected = records.map(\.id)
            expected.insert(expected.removeFirst(), at: 5)
            if terminating {
                // Exercise the real quit save barrier before AppKit even concludes.
                XCTAssertEqual(controller.session.tabs.first?.id, source)
                controller.saveSession(terminating: true)
            } else {
                list.concludeDragOperation(info)
                try await wait("Drop did not save via the debounce") {
                    (try? store.load().snapshot?.tabs.map(\.id)) == expected
                }
            }
            let saved = try XCTUnwrap(store.load().snapshot)
            XCTAssertEqual(saved.tabs.map(\.id), expected)
            XCTAssertFalse(saved.tabs.contains(where: \.isPinned))
            XCTAssertEqual(saved.selectedTabID, source)
            XCTAssertFalse(saved.tabs.contains { $0.id == privateTab.id })
            let restored = BrowserController(rootDirectory: root, testing: true)
            defer { restored.shutdown() }
            XCTAssertEqual(restored.session.orderedTabs.map(\.id), expected)
        }
    }

    func testSidebarReflowRetargetStartsAtCurrentPositionAndDoesNotOvershoot() {
        let initial = SidebarReflowMotion(start: .zero, end: CGPoint(x: 49, y: 36), velocity: .zero, begin: 1)
        let crossing = initial.sample(at: 1.05)
        let reverse = SidebarReflowMotion(start: crossing.position, end: .zero, velocity: crossing.velocity, begin: 1.05)
        XCTAssertEqual(reverse.sample(at: 1.05).position, crossing.position)
        XCTAssertEqual(reverse.sample(at: 1.05).velocity, .zero)
        XCTAssertLessThan(reverse.sample(at: 1.06).position.x, crossing.position.x)
        XCTAssertLessThan(reverse.sample(at: 1.15).position.x, crossing.position.x)
        XCTAssertEqual(reverse.sample(at: 1.25).position, .zero)
        XCTAssertEqual(reverse.sample(at: 1.25).velocity, .zero)
        let closeTarget = CGPoint(x: crossing.position.x + 1, y: crossing.position.y)
        let nearby = SidebarReflowMotion(start: crossing.position, end: closeTarget, velocity: crossing.velocity, begin: 1.05)
        var previous = crossing.position.x
        for frame in 1...18 {
            let x = nearby.sample(at: 1.05 + Double(frame) / 120).position.x
            XCTAssertGreaterThanOrEqual(x, previous)
            XCTAssertLessThanOrEqual(x, closeTarget.x)
            previous = x
        }
    }

    func testTabDragStartMoveAndEdgeScrollWithOneHundredTabs() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let candidate = try XCTUnwrap(c.session.selectedTab)
        for index in 0..<99 {
            let other = c.session.addTab(select: false, load: false)
            if index < 4 { c.session.togglePinned(other.id) }
        }
        let window = host(c, reduceMotion: false); defer { window.close() }
        try await wait("100-tab drag fixture did not lay out") {
            self.collection(in: window)?.sidebar?.path(for: candidate.id) != nil
        }
        let list = try XCTUnwrap(collection(in: window))
        let data = try XCTUnwrap(list.sidebar)
        let source = try XCTUnwrap(data.path(for: candidate.id))
        let firstPin = try XCTUnwrap(c.session.orderedTabs.first)
        let pin = try itemFrame(firstPin.id, in: list)
        let row = try itemFrame(candidate.id, in: list)
        let targets = [NSPoint(x: pin.minX + 4, y: pin.midY), NSPoint(x: row.midX, y: row.maxY + row.height)]
        var starts: [Double] = []
        var moves: [Int: [Double]] = [:]
        var updates: [Double] = []
        let clock = ContinuousClock()
        for trial in 0..<24 {
            let info = try makeDrag(candidate.id, in: list)
            let start = ProcessInfo.processInfo.systemUptime
            let sourceItem = try XCTUnwrap(list.item(at: source))
            _ = sourceItem.draggingImageComponents
            data.beginDrag(at: source)
            starts.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            defer { data.endDrag() }
            try await wait("Timing drag did not begin") { c.sidebar.dragging }
            info.move(to: NSPoint(x: list.bounds.midX, y: -1))
            XCTAssertEqual(list.draggingEntered(info), [])
            let hz = trial.isMultiple(of: 2) ? 120 : 60
            let interval = Duration.seconds(1 / Double(hz))
            var next = clock.now
            for target in Array(repeating: targets, count: 3).joined() {
                info.move(to: target)
                let move = ProcessInfo.processInfo.systemUptime
                XCTAssertEqual(list.draggingUpdated(info), .move)
                updates.append((ProcessInfo.processInfo.systemUptime - move) * 1_000)
                list.layoutSubtreeIfNeeded()
                moves[hz, default: []].append((ProcessInfo.processInfo.systemUptime - move) * 1_000)
                next += interval
                try await clock.sleep(until: next)
            }
        }

        let restoreDefaults = setFramePacingPreference(true)
        defer { restoreDefaults() }
        let pacingDirectory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pacingDirectory) }
        let pacingFile = pacingDirectory.appendingPathComponent("unpin-100.jsonl")
        list.dragFramePacingTestOutput = pacingFile
        let info = try makeDrag(firstPin.id, in: list)
        data.beginDrag(at: try XCTUnwrap(data.path(for: firstPin.id)))
        defer { data.endDrag() }
        try await wait("Unpin drag did not begin") { c.sidebar.dragging }
        info.move(to: NSPoint(x: row.midX, y: row.midY))
        XCTAssertEqual(list.draggingEntered(info), .move)
        let interval = Duration.seconds(1.0 / 120)
        var next = clock.now
        for index in 0..<32 {
            info.move(to: NSPoint(x: row.midX, y: row.midY + CGFloat(index % 3) * row.height))
            XCTAssertEqual(list.draggingUpdated(info), .move)
            next += interval
            try await clock.sleep(until: next)
        }
        let top = list.visibleRect.minY
        info.move(to: NSPoint(x: list.bounds.midX, y: list.visibleRect.maxY - 2))
        XCTAssertEqual(list.draggingUpdated(info), .move)
        try await wait("Stationary pointer did not scroll the collection") { list.visibleRect.minY > top + 14 }
        list.draggingExited(info)
        list.layoutSubtreeIfNeeded()
        let stopped = list.visibleRect.minY
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(list.visibleRect.minY, stopped, accuracy: 1)
        XCTAssertNil(list.insertionMarkerFrame)
        data.endDrag()
        let unpin = try await attachDragWork(from: pacingFile, name: "unpin-100")
        XCTAssertGreaterThanOrEqual(unpin.mainThreadWork["draggingUpdated"]?.count ?? 0, 32)
        XCTAssertFalse(unpin.mainThreadWork["edgeScroll"]?.isEmpty ?? true)

        func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] }
        let move60 = try XCTUnwrap(moves[60])
        let move120 = try XCTUnwrap(moves[120])
        for (label, values) in [("start", starts), ("update", updates), ("move60", move60), ("move120", move120)] {
            let p50 = values.sorted()[values.count / 2]
            print("TAB_DRAG \(label) n=\(values.count) p50_ms=\(p50) p95_ms=\(p95(values)) max_ms=\(values.max() ?? 0) offscreen=true")
        }
        if !["CI", "GITHUB_ACTIONS"].contains(where: { ProcessInfo.processInfo.environment[$0] == "true" }) {
            XCTAssertLessThanOrEqual(p95(starts), 5)
            XCTAssertLessThanOrEqual(p95(updates), 0.5)
            XCTAssertLessThanOrEqual(p95(move60), 16.67)
            XCTAssertLessThanOrEqual(p95(move120), 8.33)
        }
    }

    func testUnchangedGapSkipsRelayoutAndReorderPreservesArtworkInExpandedAndRail() async throws {
        for rail in [false, true] {
            let c = BrowserController(testing: true); defer { c.shutdown() }
            c.compactSidebar = rail
            let source = try XCTUnwrap(c.session.selectedTab)
            let first = c.session.addTab(select: false, load: false)
            let second = c.session.addTab(select: false, load: false)
            let w = host(c, reduceMotion: true); defer { w.close() }
            try await wait("Drag fixture did not mount") { self.collection(in: w)?.sidebar?.path(for: second.id) != nil }
            let list = try XCTUnwrap(collection(in: w))
            let data = try XCTUnwrap(list.sidebar)
            let info = try makeDrag(source.id, in: list)
            data.beginDrag(at: try XCTUnwrap(data.path(for: source.id)))
            defer { data.endDrag() }
            try await wait("Drag tracking did not begin") { c.sidebar.dragging }

            let firstPath = try XCTUnwrap(data.path(for: first.id))
            let firstItem = try XCTUnwrap(list.item(at: firstPath))
            let above = try itemFrame(first.id, in: list)
            let below = try itemFrame(second.id, in: list)
            let afterFirst = NSPoint(x: above.midX, y: above.midY + 2)
            let beforeSecond = NSPoint(x: below.midX, y: below.midY - 2)
            let beforeFirst = NSPoint(x: above.midX, y: above.midY - 2)

            let initialCount = list.dragRelayoutCount
            info.move(to: beforeFirst)
            XCTAssertEqual(list.draggingEntered(info), .move)
            info.move(to: afterFirst)
            XCTAssertEqual(list.draggingUpdated(info), .move)
            XCTAssertEqual(list.dragRelayoutCount, initialCount, "Pointer callbacks must not force layout")
            list.layoutSubtreeIfNeeded()
            XCTAssertEqual(list.dragRelayoutCount, initialCount + 1, "Apply only the latest request per layout pass")
            let gap = try XCTUnwrap(list.insertionMarkerFrame)
            let artworkCount = list.dragArtworkRefreshCount
            let imageCount = list.dragImageRenderCount

            for index in 0..<1_024 {
                info.move(to: index.isMultiple(of: 2) ? beforeSecond : afterFirst)
                XCTAssertEqual(list.draggingUpdated(info), .move)
                list.layoutSubtreeIfNeeded()
            }
            XCTAssertEqual(list.dragRelayoutCount, initialCount + 1, "Equivalent slots must not allocate new layout attributes")
            XCTAssertEqual(list.dragArtworkRefreshCount, artworkCount, "Pointer movement must not reset hosting roots")
            XCTAssertEqual(list.dragImageRenderCount, imageCount, "Equivalent slots must not redraw the drag image")
            XCTAssertEqual(list.insertionMarkerFrame, gap)
            XCTAssertEqual(c.session.orderedTabs.map(\.id), [source.id, first.id, second.id])
            XCTAssertTrue(list.prepareForDragOperation(info))
            XCTAssertFalse(info.animatesToDestination)
            XCTAssertTrue(list.performDragOperation(info))
            list.concludeDragOperation(info)
            try await wait("Drop did not publish") { !c.sidebar.dragging }
            XCTAssertEqual(c.session.orderedTabs.map(\.id), [first.id, source.id, second.id])
            XCTAssertTrue(firstItem === list.item(at: try XCTUnwrap(data.path(for: first.id))))
            XCTAssertNil(firstItem.view.layer?.animation(forKey: "sidebarReflow"))
        }
    }

    private func makeDrag(_ id: UUID, in list: SidebarTabCollection) throws -> DragFixture {
        let data = try XCTUnwrap(list.sidebar)
        let source = try XCTUnwrap(data.path(for: id))
        list.warmDragImages(at: source)
        let writer = try XCTUnwrap(data.collectionView(list, pasteboardWriterForItemAt: source))
        let info = DragFixture(source: list)
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.draggingFrame = try itemFrame(id, in: list)
        if let components = list.item(at: source)?.draggingImageComponents {
            item.imageComponentsProvider = { components }
        }
        info.draggingItem = item
        XCTAssertTrue(info.draggingPasteboard.writeObjects([writer]))
        return info
    }

    private func itemFrame(_ id: UUID, in list: SidebarTabCollection) throws -> NSRect {
        let path = try XCTUnwrap(list.sidebar?.path(for: id))
        return try XCTUnwrap(list.layoutAttributesForItem(at: path)).frame
    }

    private func drag(_ id: UUID, in list: SidebarTabCollection, accepted: Bool = true, owner: UUID? = nil,
                      at point: () throws -> NSPoint) async throws {
        let data = try XCTUnwrap(list.sidebar)
        let source = try XCTUnwrap(data.path(for: id))
        let info = try makeDrag(id, in: list)
        if let owner {
            let payload = try JSONEncoder().encode(SidebarTabTransfer(id: id, owner: owner))
            XCTAssertTrue(info.draggingPasteboard.setData(payload, forType: SidebarCollectionData.pasteboardType))
        }
        data.beginDrag(at: source)
        defer { data.endDrag() }
        try await wait("Drag targets did not appear") { data.controller?.sidebar.dragging == true }
        list.layoutSubtreeIfNeeded()
        // Send AppKit's destination callbacks to the collection in the offscreen window.
        info.move(to: NSPoint(x: list.bounds.midX, y: -1))
        XCTAssertEqual(list.draggingEntered(info), [])
        info.move(to: try point())
        XCTAssertEqual(list.draggingUpdated(info), accepted ? .move : [])
        list.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.insertionMarkerFrame != nil, accepted)
        XCTAssertEqual(list.prepareForDragOperation(info), accepted)
        XCTAssertEqual(list.performDragOperation(info), accepted)
        if accepted {
            list.concludeDragOperation(info)
            try await wait("Drop did not publish") { data.controller?.sidebar.dragging == false }
        }
        XCTAssertNil(list.insertionMarkerFrame)
    }

    func testStartPageAddressMovesInOneFrameAndClosingEndsEditing() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18768/morph/article"))
        tab.webView.loadHTMLString("<body>Morph fixture</body>", baseURL: url)
        try await wait("Morph fixture did not load") { tab.url == url && !tab.webView.isLoading }
        let w = host(c, reduceMotion: false); defer { w.close() }
        var field: FocusAwareAddressField? {
            w.contentView.flatMap { views($0).compactMap { $0 as? FocusAwareAddressField }.first }
        }
        try await wait("Address capsule did not mount") { field != nil && self.marker("browserAddressGeometry", in: w) != nil }
        XCTAssertEqual(field?.focusRingType, NSFocusRingType.none, "The capsule draws its own focus halo; AppKit's ring would box the text")
        func capsule() -> NSRect {
            w.contentView?.layoutSubtreeIfNeeded()
            return self.marker("browserAddressGeometry", in: w).map { $0.convert($0.bounds, to: nil) } ?? .zero
        }
        /// Samples the capsule until it rests, so each frame can be checked for travel direction.
        func travel(from origin: NSRect, _ action: () -> Void) async throws -> [NSRect] {
            action()
            var frames: [NSRect] = [origin, capsule()]
            var still = 0
            let start = Date()
            // The tab switch renders a frame or two later: wait for the first change.
            while frames.last == origin, Date().timeIntervalSince(start) < 1 {
                try await Task.sleep(for: .milliseconds(4))
                frames.append(capsule())
            }
            while still < 8, Date().timeIntervalSince(start) < 2 {
                try await Task.sleep(for: .milliseconds(8))
                let frame = capsule()
                still = frame == frames.last ? still + 1 : 0
                frames.append(frame)
            }
            return frames
        }
        func assertMonotonic(_ frames: [NSRect], _ label: String) {
            guard let first = frames.first, let last = frames.last else { return XCTFail("\(label): no frames") }
            // The capsule moves home in a single frame: a main-thread-driven travel stuttered
            // under real pages, so any in-between position is a regression.
            let positions = frames.reduce(into: [CGFloat]()) { if $0.last != $1.minY { $0.append($1.minY) } }
            XCTAssertLessThanOrEqual(positions.count, 2, "\(label) passed through in-between positions: \(positions)")
            let down = last.minY < first.minY
            for (previous, next) in zip(frames, frames.dropFirst()) {
                // Window coordinates: travelling down the card lowers minY. A slot correction
                // applied without animation shows up as a step against the direction of travel.
                let step = next.minY - previous.minY
                XCTAssertLessThanOrEqual(down ? step : -step, 0.5, "\(label) moved against its travel: \(previous) -> \(next)")
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        let toolbar = capsule()

        let opening = try await travel(from: toolbar) { c.newTab() }
        assertMonotonic(opening, "Opening a new tab")
        let start = try XCTUnwrap(opening.last)
        XCTAssertEqual(start.height, OrivMacV3.StartLayout.bigFieldSize.height, accuracy: 1)
        XCTAssertLessThan(start.minY, toolbar.minY - 100, "The field settles in the start page slot")

        let closing = c.session.selectedTabID
        try await wait("New tab did not focus the address") { field?.currentEditor() != nil }
        let closingID = try XCTUnwrap(closing)
        let returning = try await travel(from: capsule()) { c.session.closeTab(closingID) }
        assertMonotonic(returning, "Closing the new tab")
        let back = try XCTUnwrap(returning.last)
        XCTAssertEqual(back.minY, toolbar.minY, accuracy: 1, "The field returns to the toolbar")
        XCTAssertNil(field?.currentEditor(), "Closing the new tab ends address editing")
        XCTAssertEqual(field?.stringValue, URLDisplay.site(url), "The toolbar shows the compact site, not a selected URL")

        let reopening = try await travel(from: capsule()) { c.newTab() }
        assertMonotonic(reopening, "Reopening a new tab")
        XCTAssertEqual(try XCTUnwrap(reopening.last).minY, start.minY, accuracy: 1)
    }

    func testTabSwitchCoverAlignsTheSnapshotWithThePageBelowTheToolbar() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTab)
        let page = "<html><body style='margin:0;background:#00f'><div style='height:24px;background:#f00'></div><div style='height:3000px'></div></body></html>"
        let firstURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18768/cover/first"))
        first.webView.loadHTMLString(page, baseURL: firstURL)
        let w = host(c); defer { w.close() }
        try await wait("First page did not paint") { first.url == firstURL && first.hasRenderedContent && !first.webView.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        let inset = first.webView.obscuredContentInsets.top
        XCTAssertGreaterThan(inset, 0, "The page scrolls under the floating toolbar")

        let second = c.session.addTab(url: nil, select: true, load: false)
        second.webView.loadHTMLString(page, baseURL: URL(string: "http://127.0.0.1:18768/cover/second"))
        try await wait("Leaving the first tab did not store its snapshot") { first.switchSnapshot != nil }
        XCTAssertEqual(try XCTUnwrap(first.switchSnapshot).topInset, inset, accuracy: 0.5)

        c.session.selectTab(first.id)
        w.contentView?.layoutSubtreeIfNeeded()
        let cover = try XCTUnwrap(w.contentView.flatMap { views($0).compactMap { $0 as? TabSwitchCover }.first { !$0.isHidden && $0.containsSnapshot } },
                                  "Returning to the tab shows its snapshot cover")
        let rep = try XCTUnwrap(cover.bitmapImageRepForCachingDisplay(in: cover.bounds))
        cover.cacheDisplay(in: cover.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / cover.bounds.height
        let redTop = (0..<Int(cover.bounds.height)).first { y in
            guard let color = rep.colorAt(x: Int(40 * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.sRGB) else { return false }
            return color.redComponent > 0.8 && color.blueComponent < 0.3
        }
        // The live page draws its top at the obscured inset; the cover must match it.
        XCTAssertEqual(CGFloat(try XCTUnwrap(redTop, "The snapshot's red band is visible")), inset, accuracy: 2,
                       "The snapshot sits where the live page draws, not a toolbar higher")
    }

    func testAddressCapsulePaddingSelectsFullURLAndSiteInfoKeepsItsAction() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18768/full/address?q=focus#section"))
        tab.webView.loadHTMLString("<body>Address fixture</body>", baseURL: url)
        try await wait("Address fixture did not load") { tab.url == url && !tab.webView.isLoading }
        let w = host(c); defer { w.close() }
        var field: FocusAwareAddressField? {
            w.contentView.flatMap { views($0).compactMap { $0 as? FocusAwareAddressField }.first }
        }
        try await wait("Address capsule did not mount") { field != nil && self.marker("browserSiteInformationGeometry", in: w) != nil }
        let address = try XCTUnwrap(field)
        let capsule = try XCTUnwrap(marker("browserAddressGeometry", in: w))
        for fraction in [0.004, 0.78] {
            w.makeFirstResponder(nil)
            func clickPoint() -> NSPoint {
                capsule.convert(NSPoint(x: capsule.bounds.width * fraction, y: capsule.bounds.midY), to: nil)
            }
            try await wait("Compact address layout did not restore the padding at \(fraction)") {
                w.contentView?.layoutSubtreeIfNeeded()
                return address.currentEditor() == nil && address.stringValue == URLDisplay.site(url)
                    && !address.convert(address.bounds, to: nil).contains(clickPoint())
            }
            try click(clickPoint(), in: w)
            let selection = NSRange(location: 0, length: url.absoluteString.utf16.count)
            try await wait("Capsule click did not select the URL at \(fraction)") {
                address.currentEditor()?.string == url.absoluteString && address.currentEditor()?.selectedRange == selection
            }
        }
        w.makeFirstResponder(nil)
        let focusRequest = c.addressFocusRequest
        let reload = XCTNSNotificationExpectation(name: BrowserTab.navigationStarted, object: tab.webView)
        // While focused the trailing slot shows Clear; Reload returns once the blur lands.
        try await wait("Reload did not return after the address lost focus") { self.marker("browserReloadGeometry", in: w) != nil }
        // The capsule springs back from its focused size; click once the reload slot stops moving.
        var lastReloadFrame: NSRect?
        var stablePolls = 0
        try await wait("Reload did not settle after the address lost focus") {
            w.contentView?.layoutSubtreeIfNeeded()
            guard let reloadMarker = self.marker("browserReloadGeometry", in: w) else { lastReloadFrame = nil; return false }
            let frame = reloadMarker.convert(reloadMarker.bounds, to: nil)
            stablePolls = frame == lastReloadFrame ? stablePolls + 1 : 0
            lastReloadFrame = frame
            // Five unchanged 20 ms polls: the focus spring has finished.
            return stablePolls >= 5 && !address.convert(address.bounds, to: nil).intersects(frame)
        }
        try click("browserReloadGeometry", in: w)
        await fulfillment(of: [reload], timeout: 5)
        XCTAssertEqual(c.addressFocusRequest, focusRequest)
        XCTAssertNil(address.currentEditor())

        try click("browserSiteInformationGeometry", in: w)
        try await wait("Site info did not open") { c.profileUI.showSiteInfo }
        XCTAssertNil(address.currentEditor())

        _ = c.session.addTab(isPrivate: true, load: false)
        try await wait("Private pill did not mount") {
            self.marker("privateAddressPillGeometry", in: w) != nil && !c.profileUI.showSiteInfo
        }
        w.makeFirstResponder(nil)
        let privateFocusRequest = c.addressFocusRequest
        try click("privateAddressPillGeometry", in: w)
        XCTAssertEqual(c.addressFocusRequest, privateFocusRequest, "The Private badge keeps its own hit region")
        XCTAssertNil(address.currentEditor())
        try click("startPageEngineChipGeometry", in: w)
        try await wait("Clicking the private big field engine chip did not focus the address field") { address.currentEditor() != nil }

        _ = c.session.addTab(isPrivate: false, load: false)
        try await wait("Regular start-page search icon did not mount") {
            self.marker("browserAddressSearchIconGeometry", in: w) != nil
        }
        w.makeFirstResponder(nil)
        try click("browserAddressSearchIconGeometry", in: w)
        try await wait("The search icon did not focus the address field") { address.currentEditor() != nil }
    }

    func testAddressChromeSharesBaselineAndAttachesSuggestionsInEveryAppearance() async throws {
        for appearance: BrowserAppearance in [.light, .dark, .t3Code] {
            let c = BrowserController(testing: true); defer { c.shutdown() }
            let tab = try XCTUnwrap(c.session.selectedTab)
            let url = try XCTUnwrap(URL(string: "http://docs.research-and-development.example/full/address?q=focus#section"))
            tab.webView.loadHTMLString("<body>Address layout fixture</body>", baseURL: url)
            try await wait("Address fixture did not load") { tab.url == url && !tab.isLoading }
            let w = host(c, appearance: appearance); defer { w.close() }
            func frame(_ name: String) throws -> NSRect {
                let view = try XCTUnwrap(marker(name, in: w), name)
                return view.convert(view.bounds, to: nil)
            }
            func capture(_ suffix: String) throws {
                let content = try XCTUnwrap(w.contentView)
                let top = try frame("browserTopBarGeometry")
                let windowBounds = NSRect(x: 0, y: top.maxY - 174, width: content.bounds.width, height: 174)
                let bounds = content.convert(windowBounds, from: nil)
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: bounds))
                content.cacheDisplay(in: bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                               uniformTypeIdentifier: "public.png")
                attachment.name = "address-\(appearance.rawValue.lowercased())-\(suffix)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }

            try await wait("Chrome did not mount") { self.marker("browserReloadGeometry", in: w) != nil }
            let capsule = try frame("browserAddressGeometry")
            XCTAssertEqual(capsule.height, OrivMacV3.ToolbarLayout.addressRestHeight, accuracy: 1)
            XCTAssertEqual(try frame("browserNavGroupGeometry").height, OrivMacV3.ToolbarLayout.groupHeight, accuracy: 1)
            XCTAssertEqual(try frame("browserActionsGroupGeometry").height, OrivMacV3.ToolbarLayout.groupHeight, accuracy: 1)
            XCTAssertEqual(try frame("browserTopBarGeometry").height, OrivMacV3.ToolbarLayout.overlayHeight, accuracy: 1)
            for name in ["sidebarToggleGeometry", "browserNavGroupGeometry", "browserActionsGroupGeometry",
                         "browserSiteInformationGeometry", "browserReloadGeometry",
                         "browserPrivacyGeometry", "browserPageMenuGeometry"] {
                XCTAssertEqual(try frame(name).midY, capsule.midY, accuracy: 1, name)
            }
            let field = try XCTUnwrap(w.contentView.flatMap { views($0).compactMap { $0 as? FocusAwareAddressField }.first })
            XCTAssertEqual(field.stringValue, URLDisplay.site(url))
            let fieldFrame = field.convert(field.bounds, to: nil)
            XCTAssertEqual(fieldFrame.midX, capsule.midX, accuracy: 1.5, "Compact host stays optically centered even with Not secure cue")
            try capture("compact")

            tab.zoomIn()
            try await wait("Zoom control did not appear") { self.marker("browserZoomGeometry", in: w) != nil }
            XCTAssertEqual(try frame("browserZoomGeometry").midY, capsule.midY, accuracy: 1)
            XCTAssertEqual(try frame("browserAddressGeometry"), capsule)
            let navBeforeFocus = try frame("browserNavGroupGeometry")
            let actionsBeforeFocus = try frame("browserActionsGroupGeometry")
            c.focusAddress()
            try await wait("Editing selection, expanded capsule, scrim, or attached suggestions did not mount") {
                guard field.currentEditor()?.selectedRange == NSRange(location: 0, length: url.absoluteString.utf16.count),
                      self.marker("browserAddressSuggestionsGeometry", in: w) != nil,
                      self.marker("browserAddressScrimGeometry", in: w) != nil,
                      self.marker("browserAddressClearGeometry", in: w) != nil,
                      let current = self.marker("browserAddressGeometry", in: w) else { return false }
                let rect = current.convert(current.bounds, to: nil)
                return rect.width > capsule.width + 1
                    && abs(rect.height - OrivMacV3.ToolbarLayout.addressFocusHeight) <= 1
            }
            let focusedCapsule = try frame("browserAddressGeometry")
            XCTAssertGreaterThan(focusedCapsule.width, capsule.width, "Focused capsule expands toward 576 pt")
            XCTAssertLessThanOrEqual(focusedCapsule.width, OrivMacV3.ToolbarLayout.addressFocusWidth + 1)
            XCTAssertEqual(focusedCapsule.height, OrivMacV3.ToolbarLayout.addressFocusHeight, accuracy: 1)
            XCTAssertEqual(focusedCapsule.midX, capsule.midX, accuracy: 1, "Focused expansion stays centered")
            XCTAssertEqual(focusedCapsule.midY, capsule.midY, accuracy: 1, "Focused expansion keeps toolbar baseline")
            XCTAssertEqual(try frame("browserNavGroupGeometry"), navBeforeFocus, "Focused expansion must not move leading toolbar pill")
            XCTAssertEqual(try frame("browserActionsGroupGeometry"), actionsBeforeFocus, "Focused expansion must not move trailing toolbar pill")
            XCTAssertNotNil(marker("browserAddressSearchIconGeometry", in: w), "Focused capsule replaces connection cue with search icon")
            XCTAssertNil(marker("browserSiteInformationGeometry", in: w))
            let panel = try frame("browserAddressSuggestionsGeometry")
            XCTAssertEqual(panel.minX, focusedCapsule.minX, accuracy: 1)
            XCTAssertEqual(panel.width, focusedCapsule.width, accuracy: 1)
            XCTAssertEqual(focusedCapsule.minY - panel.maxY, OrivMacV3.ToolbarLayout.suggestionsTopGap, accuracy: 1)
            try capture("editing-suggestions-zoom")

            // At wider window width, the focused capsule reaches its full 576 × 36 ideal dimensions.
            w.setContentSize(NSSize(width: 1280, height: 760))
            try await wait("Wide focused capsule did not reach 576 pt") {
                guard let current = self.marker("browserAddressGeometry", in: w) else { return false }
                let rect = current.convert(current.bounds, to: nil)
                return abs(rect.width - OrivMacV3.ToolbarLayout.addressFocusWidth) <= 1
            }
            let wideFocusedCapsule = try frame("browserAddressGeometry")
            let widePanel = try frame("browserAddressSuggestionsGeometry")
            XCTAssertEqual(wideFocusedCapsule.width, OrivMacV3.ToolbarLayout.addressFocusWidth, accuracy: 1)
            XCTAssertEqual(wideFocusedCapsule.height, OrivMacV3.ToolbarLayout.addressFocusHeight, accuracy: 1)
            XCTAssertEqual(widePanel.width, OrivMacV3.ToolbarLayout.addressFocusWidth, accuracy: 1)
            XCTAssertEqual(wideFocusedCapsule.minY - widePanel.maxY, OrivMacV3.ToolbarLayout.suggestionsTopGap, accuracy: 1)
            w.setContentSize(NSSize(width: 1000, height: 760))

            // Clicking the scrim below the popover dismisses focus, suggestions, and scrim.
            let scrimView = try XCTUnwrap(marker("browserAddressScrimGeometry", in: w))
            let scrimRect = scrimView.convert(scrimView.bounds, to: nil)
            try click(NSPoint(x: scrimRect.minX + 24, y: scrimRect.minY + 24), in: w)
            try await wait("Clicking the scrim did not dismiss address editing and suggestions") {
                field.currentEditor() == nil
                    && self.marker("browserAddressSuggestionsGeometry", in: w) == nil
                    && self.marker("browserAddressScrimGeometry", in: w) == nil
            }

            // Re-focus and verify the clear button clears the address while keeping focus.
            c.focusAddress()
            try await wait("Clear button did not reappear after refocusing") {
                self.marker("browserAddressClearGeometry", in: w) != nil
            }
            try click("browserAddressClearGeometry", in: w)
            try await wait("Clear button did not clear the address while keeping focus") {
                c.profileUI.address.isEmpty && field.currentEditor() != nil
                    && self.marker("browserAddressSuggestionsGeometry", in: w) == nil
                    && self.marker("browserAddressScrimGeometry", in: w) == nil
            }

            _ = c.session.addTab(isPrivate: true, load: false)
            try await wait("Private address did not mount") {
                guard self.marker("privateAddressPillGeometry", in: w) != nil,
                      self.marker("browserAddressPlaceholderGeometry", in: w) != nil,
                      let current = self.marker("browserAddressGeometry", in: w) else { return false }
                return abs(current.bounds.height - OrivMacV3.StartLayout.bigFieldSize.height) <= 1
            }
            let privateStartCapsule = try frame("browserAddressGeometry")
            XCTAssertEqual(privateStartCapsule.height, OrivMacV3.StartLayout.bigFieldSize.height, accuracy: 1)
            XCTAssertEqual(try frame("privateAddressPillGeometry").midY, privateStartCapsule.midY, accuracy: 1)
            let content = try XCTUnwrap(w.contentView)
            let hint = content.convert(try frame("browserAddressPlaceholderGeometry"), from: nil)
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: hint))
            content.cacheDisplay(in: hint, to: bitmap)
            func luminance(_ color: NSColor) -> Double {
                guard let color = color.usingColorSpace(.sRGB) else { return 0 }
                func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
                return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) +
                    0.0722 * linear(color.blueComponent)
            }
            let back = luminance(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)))
            var contrast = 1.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y) {
                        let ink = luminance(color)
                        contrast = max(contrast, (max(back, ink) + 0.05) / (min(back, ink) + 0.05))
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(contrast, 4.5, "Rendered placeholder contrast in \(appearance.rawValue)")
            print("ADDRESS_PLACEHOLDER appearance=\(appearance.rawValue) contrast=\(contrast)")
            try capture("private-empty")
        }
    }

    func testNarrowOverlayKeepsNativeLightsAboveFlushSurface() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let w = host(c); defer { w.close() }
        w.setContentSize(NSSize(width: 780, height: 760))
        let inset = MacBrowserLayout.windowInset
        try await wait("Narrow rail did not mount") {
            guard c.sidebar.rail, let surface = self.marker("sidebarSurfaceGeometry", in: w),
                  let toggle = self.marker("sidebarToggleGeometry", in: w) else { return false }
            return surface.bounds.width == MacBrowserLayout.railWidth &&
                toggle.convert(toggle.bounds, to: nil).maxX <= inset + MacBrowserLayout.railWidth
        }
        try click("sidebarToggleGeometry", in: w)
        try await wait("Explicit overlay did not open") { c.sidebar.narrowOverlay }
        try await Task.sleep(for: .milliseconds(200))
        let surface = try XCTUnwrap(marker("sidebarSurfaceGeometry", in: w))
        XCTAssertEqual(surface.convert(surface.bounds, to: nil),
                       NSRect(x: inset, y: inset, width: MacBrowserLayout.sidebarWidth, height: w.contentView!.bounds.height - 2 * inset))
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            let button = try XCTUnwrap(w.standardWindowButton(type))
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            let rect = button.convert(button.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(rect.minX, inset)
            XCTAssertLessThanOrEqual(rect.maxX, inset + MacBrowserLayout.railWidth)
            XCTAssertEqual(rect.minX, MacBrowserLayout.railLightsInset + CGFloat(index) * MacBrowserLayout.lightsSpacing, accuracy: 1)
            XCTAssertEqual(w.contentView!.bounds.maxY - rect.midY, MacBrowserLayout.lightsCenterY, accuracy: 1)
        }
    }

    func testToolbarProgressLineFitsInsideCapsuleAndPrivacyDotTracksProtections() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        let url = try XCTUnwrap(URL(string: "https://docs.example.com/progress"))
        tab.webView.loadHTMLString("<body style='height:2000px'>Progress fixture</body>", baseURL: url)
        try await wait("Fixture did not load") { tab.url == url && !tab.webView.isLoading }
        let w = host(c, appearance: .dark, reduceMotion: true); defer { w.close() }
        try await wait("Toolbar capsules did not mount") {
            self.marker("browserAddressGeometry", in: w) != nil
                && self.marker("browserPrivacyActiveDotGeometry", in: w) != nil
        }
        // Verify empirically whether WKWebView hosts an NSScrollView reachable by SwiftUI scrollEdgeEffectStyle.
        let webScrollViews = views(tab.webView).compactMap { $0 as? NSScrollView }
        XCTAssertTrue(webScrollViews.isEmpty && tab.webView.enclosingScrollView == nil,
                      "Documented macOS 26 behavior: WKWebView does not expose an NSScrollView to SwiftUI .scrollEdgeEffectStyle")

        // Turning off all protections for the site removes the active green shield dot.
        c.session.adBlocker.setException(true, for: url, isPrivate: false)
        for layer in PrivacyLayer.allCases { c.session.settings.privacy.setException(true, layer, for: url, isPrivate: false) }
        try await wait("Shield active dot did not hide when protections disabled") {
            self.marker("browserPrivacyActiveDotGeometry", in: w) == nil
        }

        // Start a navigation against the delayed local fixture and verify the 2 pt progress line sits inside the address capsule.
        c.navigate("http://127.0.0.1:18768/tab-switch?delay=2")
        try await wait("Address progress line did not mount") {
            self.marker("browserAddressProgressGeometry", in: w) != nil
        }
        let capsule = try XCTUnwrap(marker("browserAddressGeometry", in: w))
        let progress = try XCTUnwrap(marker("browserAddressProgressGeometry", in: w))
        let capsuleFrame = capsule.convert(capsule.bounds, to: nil)
        let progressFrame = progress.convert(progress.bounds, to: nil)
        XCTAssertTrue(capsuleFrame.insetBy(dx: -1, dy: -1).contains(progressFrame))

        // Under Reduce Motion, finishing load hides the progress bar immediately without fading.
        tab.stop()
        try await wait("Address progress line did not hide on completion") {
            self.marker("browserAddressProgressGeometry", in: w) == nil
        }
    }

    func testSingleAddressFieldPersistsAcrossStartPageAndWebNavigation() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let startTab = try XCTUnwrap(c.session.selectedTab)
        let now = Date()
        try c.session.applyContinuity(
            bookmarks: [
                Bookmark(title: "Apple Developer", url: URL(string: "https://developer.apple.com/documentation/")!, createdAt: now),
            ],
            history: [
                HistoryEntry(title: "MDN Web Docs", url: URL(string: "https://developer.mozilla.org/en-US/")!, visitedAt: now),
            ]
        )
        let w = host(c, appearance: .light); defer { w.close() }
        w.setContentSize(NSSize(width: 1280, height: 820))
        func allAddressFields() -> [FocusAwareAddressField] {
            w.contentView.map { views($0).compactMap { $0 as? FocusAwareAddressField } } ?? []
        }
        func frame(_ name: String) throws -> NSRect {
            let view = try XCTUnwrap(marker(name, in: w), name)
            return view.convert(view.bounds, to: nil)
        }

        // 1. Start page renders the single 724 × 52 in-page big field with 16 pt font and engine chip.
        try await wait("Start page big field did not mount") {
            guard allAddressFields().count == 1,
                  let current = self.marker("browserAddressGeometry", in: w),
                  self.marker("startPageEngineChipGeometry", in: w) != nil else { return false }
            let rect = current.convert(current.bounds, to: nil)
            return abs(rect.width - OrivMacV3.StartLayout.columnWidth) <= 1
                && abs(rect.height - OrivMacV3.StartLayout.bigFieldSize.height) <= 1
        }
        let fieldOnStart = try XCTUnwrap(allAddressFields().first)
        XCTAssertEqual(allAddressFields().count, 1)
        XCTAssertEqual(fieldOnStart.font?.pointSize ?? 0, 16, accuracy: 0.5)
        let startFieldFrame = try frame("browserAddressGeometry")
        let topBarFrame = try frame("browserTopBarGeometry")
        XCTAssertLessThan(startFieldFrame.maxY, topBarFrame.minY, "Big field sits in-page below the toolbar")

        // 2. Typing on the start page attaches suggestions (matching 724 pt width) and scrim below the big field.
        c.focusAddress()
        try await wait("Start page field editor did not focus") { fieldOnStart.currentEditor() != nil }
        let editor = try XCTUnwrap(fieldOnStart.currentEditor() as? NSTextView)
        editor.insertText("dev", replacementRange: editor.selectedRange())
        try await wait("Start page suggestions did not attach") {
            self.marker("browserAddressSuggestionsGeometry", in: w) != nil
                && self.marker("browserAddressScrimGeometry", in: w) != nil
        }
        let startSuggestionsFrame = try frame("browserAddressSuggestionsGeometry")
        XCTAssertEqual(startSuggestionsFrame.width, startFieldFrame.width, accuracy: 1)
        XCTAssertEqual(startFieldFrame.minY - startSuggestionsFrame.maxY, OrivMacV3.ToolbarLayout.suggestionsTopGap, accuracy: 1)

        // 3. Navigating to a web page moves the EXACT same NSTextField instance into the toolbar capsule.
        let webURL = try XCTUnwrap(URL(string: "https://docs.example.com/start-transition"))
        startTab.webView.loadHTMLString("<body>Loaded page</body>", baseURL: webURL)
        try await wait("Toolbar address capsule did not mount after navigation") {
            guard !startTab.webView.isLoading, startTab.url == webURL,
                  let current = self.marker("browserAddressGeometry", in: w) else { return false }
            let rect = current.convert(current.bounds, to: nil)
            return abs(rect.height - OrivMacV3.ToolbarLayout.addressRestHeight) <= 1
                || abs(rect.height - OrivMacV3.ToolbarLayout.addressFocusHeight) <= 1
        }
        let fieldsOnWeb = allAddressFields()
        XCTAssertEqual(fieldsOnWeb.count, 1, "Must keep strictly one AddressField on web page")
        XCTAssertTrue(fieldsOnWeb.first === fieldOnStart, "NSTextField instance must be identical on web page")
        w.makeFirstResponder(nil)
        try await wait("Toolbar capsule did not settle to rest state") {
            guard let current = self.marker("browserAddressGeometry", in: w) else { return false }
            return abs(current.bounds.height - OrivMacV3.ToolbarLayout.addressRestHeight) <= 1
                && abs(current.bounds.width - OrivMacV3.ToolbarLayout.addressRestWidth) <= 1
        }
        XCTAssertEqual(fieldOnStart.font?.pointSize ?? 0, 13, accuracy: 0.5)

        // 4. Returning to a start page moves the EXACT same NSTextField instance back to the 724 × 52 big field.
        c.newTab(isPrivate: false)
        try await wait("Start page big field did not return on new tab") {
            guard let current = self.marker("browserAddressGeometry", in: w),
                  self.marker("startPageEngineChipGeometry", in: w) != nil else { return false }
            let rect = current.convert(current.bounds, to: nil)
            return abs(rect.width - OrivMacV3.StartLayout.columnWidth) <= 1
                && abs(rect.height - OrivMacV3.StartLayout.bigFieldSize.height) <= 1
        }
        let fieldsBackOnStart = allAddressFields()
        XCTAssertEqual(fieldsBackOnStart.count, 1, "Must keep strictly one AddressField back on start page")
        XCTAssertTrue(fieldsBackOnStart.first === fieldOnStart, "NSTextField instance must be identical back on start page")
        XCTAssertEqual(fieldOnStart.font?.pointSize ?? 0, 16, accuracy: 0.5)
    }

    func testAddressMorphUsesReducedMotionAndPreservesAddressFieldIdentityAcrossStartPageTransitions() async throws {
        // Motion tokens must drop springs/spins/shimmers under Reduce Motion to nil or <= 0.15 s fades.
        XCTAssertEqual(OrivMacV3.Motion.addressMorph(reduceMotion: false), OrivMacV3.Motion.addressMorph)
        XCTAssertEqual(OrivMacV3.Motion.addressMorph(reduceMotion: true), OrivMacV3.Motion.addressMorphReduced)
        XCTAssertEqual(OrivMacV3.Motion.addressMorphGeometry(reduceMotion: false), OrivMacV3.Motion.addressMorph)
        XCTAssertNil(OrivMacV3.Motion.addressMorphGeometry(reduceMotion: true),
                     "Reduce Motion must snap address morph geometry without travel")
        XCTAssertLessThanOrEqual(OrivMacV3.Motion.reducedDuration, 0.15)
        XCTAssertLessThanOrEqual(OrivMacV3.Motion.popoverReducedDuration, 0.15)
        XCTAssertLessThanOrEqual(OrivMacV3.Motion.caFadeDuration(reduceMotion: true), 0.15)
        XCTAssertNil(OrivMacV3.Motion.addressFocus(reduceMotion: true))
        XCTAssertNil(OrivMacV3.Motion.quick(reduceMotion: true))
        XCTAssertNil(OrivMacV3.Motion.standardGeometry(reduceMotion: true))
        XCTAssertNil(OrivMacV3.Motion.progressShimmer(reduceMotion: true))
        XCTAssertNil(OrivMacV3.Motion.tabLoading(reduceMotion: true))
        XCTAssertEqual(OrivMacV3.Motion.tabLoading(reduceMotion: false), OrivMacV3.Motion.tabLoading)

        for reduceMotion in [false, true] {
            let c = BrowserController(testing: true); defer { c.shutdown() }
            let startTab = try XCTUnwrap(c.session.selectedTab)
            let w = host(c, appearance: .light, reduceMotion: reduceMotion); defer { w.close() }
            w.setContentSize(NSSize(width: 1280, height: 820))
            func allAddressFields() -> [FocusAwareAddressField] {
                w.contentView.map { views($0).compactMap { $0 as? FocusAwareAddressField } } ?? []
            }

            try await wait("Start page big field did not mount (reduceMotion=\(reduceMotion))") {
                guard allAddressFields().count == 1,
                      let current = self.marker("browserAddressGeometry", in: w) else { return false }
                let rect = current.convert(current.bounds, to: nil)
                return abs(rect.width - OrivMacV3.StartLayout.columnWidth) <= 1
                    && abs(rect.height - OrivMacV3.StartLayout.bigFieldSize.height) <= 1
            }
            let originalField = try XCTUnwrap(allAddressFields().first)

            // Type in the start page field before transitioning to a web page; the field must survive.
            c.focusAddress()
            try await wait("Start field editor did not activate (reduceMotion=\(reduceMotion))") {
                originalField.currentEditor() != nil
            }
            let editor = try XCTUnwrap(originalField.currentEditor() as? NSTextView)
            editor.insertText("example.org", replacementRange: editor.selectedRange())
            XCTAssertEqual(c.profileUI.address, "example.org")

            let webURL = try XCTUnwrap(URL(string: "https://docs.example.com/morph-check"))
            startTab.webView.loadHTMLString("<body>Morph target</body>", baseURL: webURL)
            try await wait("Toolbar address capsule did not settle on web page (reduceMotion=\(reduceMotion))") {
                guard !startTab.webView.isLoading, startTab.url == webURL,
                      let current = self.marker("browserAddressGeometry", in: w) else { return false }
                let rect = current.convert(current.bounds, to: nil)
                return abs(rect.height - OrivMacV3.ToolbarLayout.addressRestHeight) <= 1
                    || abs(rect.height - OrivMacV3.ToolbarLayout.addressFocusHeight) <= 1
            }
            XCTAssertEqual(allAddressFields().count, 1)
            XCTAssertTrue(allAddressFields().first === originalField,
                          "NSTextField instance must survive start->page transition (reduceMotion=\(reduceMotion))")
            XCTAssertEqual(c.profileUI.address, "example.org",
                           "Typed address text must survive while focused across start->page transition")

            // Return to a start page (new tab) and confirm the exact same NSTextField returns to the big-field slot.
            c.newTab(isPrivate: false)
            try await wait("Start page big field did not return (reduceMotion=\(reduceMotion))") {
                guard let current = self.marker("browserAddressGeometry", in: w),
                      self.marker("startPageEngineChipGeometry", in: w) != nil else { return false }
                let rect = current.convert(current.bounds, to: nil)
                return abs(rect.width - OrivMacV3.StartLayout.columnWidth) <= 1
                    && abs(rect.height - OrivMacV3.StartLayout.bigFieldSize.height) <= 1
            }
            XCTAssertEqual(allAddressFields().count, 1)
            XCTAssertTrue(allAddressFields().first === originalField,
                          "NSTextField instance must survive page->start transition (reduceMotion=\(reduceMotion))")
        }
    }
}


@MainActor private final class SidebarDragTestDisplayLink: NSObject {
    private var start: CFTimeInterval?
    private(set) var elapsed: CFTimeInterval = 0
    var onFrame: ((CFTimeInterval, CFTimeInterval) -> Void)?

    @objc func tick(_ link: CADisplayLink) {
        if start == nil { start = link.timestamp }
        elapsed = link.timestamp - (start ?? link.timestamp)
        onFrame?(link.timestamp, elapsed)
    }
}

@MainActor private final class DragFixture: NSObject, NSDraggingInfo {
    let source: SidebarTabCollection
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingLocation = NSPoint.zero
    var draggingItem: NSDraggingItem?
    var draggingDestinationWindow: NSWindow? { source.window }
    let draggingSourceOperationMask = NSDragOperation.move
    var draggingSource: Any? { source }
    let draggingSequenceNumber = 1
    var draggedImageLocation: NSPoint { draggingLocation }
    let draggedImage: NSImage? = nil
    var draggingFormation = NSDraggingFormation.none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight = NSSpringLoadingHighlight.none

    init(source: SidebarTabCollection) { self.source = source }
    func move(to point: NSPoint) {
        draggingLocation = source.convert(point, to: nil)
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard let draggingItem else { return }
        var stop = ObjCBool(false)
        block(draggingItem, 0, &stop)
    }
    func resetSpringLoading() {}
}



@MainActor final class WebKeyFallthroughTests: BackgroundUITestCase {
    /// Records key presses that reach the window unclaimed, where AppKit plays its alert sound.
    final class RecordingWindow: BackgroundUIMode.Window {
        var unhandled: [String] = []
        override func noResponder(for eventSelector: Selector) {
            unhandled.append(NSStringFromSelector(eventSelector))
            super.noResponder(for: eventSelector)
        }
    }

    func testPageKeysThePageDidNotCancelDoNotBeep() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let w = RecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: BrowserWindow(controller: c).browserAppearance(.dark))
        w.setContentSize(NSSize(width: 1100, height: 760))
        BackgroundUIMode.show(w)
        defer { w.close() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        // Like YouTube's shortcuts outside the player: the page reacts but does not cancel.
        tab.webView.loadHTMLString("<html><body><script>window.keys=[];document.addEventListener('keydown',e=>keys.push(e.key));</script><p>Short page</p></body></html>",
                                   baseURL: URL(string: "http://127.0.0.1:18768/keys"))
        try await eventually("page loaded", timeout: 10) { !tab.webView.isLoading && tab.url != nil }
        try await Task.sleep(for: .milliseconds(300))
        let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        for (code, characters) in [(UInt16(124), right), (UInt16(37), "l")] {
            w.makeFirstResponder(tab.webView)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                w.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
            }
        }
        try await eventually("page received both keys") {
            let keys = (try? await tab.webView.evaluateJavaScript("keys.join(',')")) as? String
            return keys == "ArrowRight,l"
        }
        XCTAssertFalse(w.unhandled.contains("keyDown:"), "Page keys must not fall through to the alert sound: \(w.unhandled)")
    }
}


@MainActor final class ClosedTabMediaTests: BackgroundUITestCase {
    func testClosingATabStopsItsMediaEvenIfTheViewIsStillHeld() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let w = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: BrowserWindow(controller: c).browserAppearance(.dark))
        w.setContentSize(NSSize(width: 1100, height: 760))
        BackgroundUIMode.show(w)
        defer { w.close() }
        let media = c.session.addTab(url: nil, select: true, load: false)
        // A muted, looping video drawn from a canvas: it plays without a user gesture.
        media.webView.loadHTMLString("""
            <html><body><canvas id=c width=64 height=64></canvas><video id=v muted playsinline></video><script>
            const canvas = document.getElementById('c'), g = canvas.getContext('2d'); let n = 0;
            setInterval(() => { g.fillStyle = `hsl(${n++ % 360},80%,50%)`; g.fillRect(0, 0, 64, 64); }, 30);
            const v = document.getElementById('v'); v.srcObject = canvas.captureStream(30); v.play();
            </script></body></html>
            """, baseURL: URL(string: "http://127.0.0.1:18768/closed-media"))
        try await eventually("media page", timeout: 10) { media.url != nil && !media.webView.isLoading }
        let view = media.webView // An outside holder, like a fullscreen or PiP window.
        try await eventually("video playing", timeout: 10) {
            ((try? await view.evaluateJavaScript("!document.getElementById('v').paused")) as? Bool) == true
        }
        c.requestCloseTab(media.id)
        try await eventually("closed tab's video paused", timeout: 5) {
            ((try? await view.evaluateJavaScript("document.getElementById('v').paused")) as? Bool) == true
        }
        let state = await view.requestMediaPlaybackState()
        XCTAssertNotEqual(state, .playing, "A closed tab must not keep playing")
    }
}
