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
    private func host(_ controller: BrowserController, appearance: BrowserAppearance = .light, rtl: Bool = false) -> NSWindow {
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BrowserWindow(controller: controller)
            .browserAppearance(appearance).environment(\.chromeReduceTransparencyOverride, true)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .environment(\.sidebarCaptureReduceMotion, true))
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
                try await wait("Completed drag did not collapse its empty section") { list.numberOfSections == 1 }
            }

            let other = c.session.addTab(select: false, load: false)
            c.session.togglePinned(other.id)
            try await wait("Single pin did not mount") { list.sidebar?.path(for: other.id)?.section == 0 && list.numberOfSections == 2 }
            try await drag(tab.id, in: list) {
                let pin = try self.itemFrame(other.id, in: list)
                return NSPoint(x: pin.minX + pin.width / 4, y: pin.minY + pin.height / 4)
            }
            XCTAssertEqual(c.session.orderedTabs.filter(\.isPinned).map(\.id), [tab.id, other.id])
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

    private func itemFrame(_ id: UUID, in list: SidebarTabCollection) throws -> NSRect {
        let path = try XCTUnwrap(list.sidebar?.path(for: id))
        return try XCTUnwrap(list.layoutAttributesForItem(at: path)).frame
    }

    private func drag(_ id: UUID, in list: SidebarTabCollection, accepted: Bool = true, owner: UUID? = nil,
                      at point: () throws -> NSPoint) async throws {
        let data = try XCTUnwrap(list.sidebar)
        let source = try XCTUnwrap(data.path(for: id))
        let writer = try XCTUnwrap(data.collectionView(list, pasteboardWriterForItemAt: source))
        let info = DragFixture(source: list)
        XCTAssertTrue(info.draggingPasteboard.writeObjects([writer]))
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
        XCTAssertEqual(list.insertionMarkerFrame != nil, accepted)
        XCTAssertEqual(list.prepareForDragOperation(info), accepted)
        XCTAssertEqual(list.performDragOperation(info), accepted)
        XCTAssertNil(list.insertionMarkerFrame)
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
                let bounds = NSRect(x: 0, y: top.maxY - 174, width: content.bounds.width, height: 174)
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
            XCTAssertEqual(capsule.height, OrivLayout.controlHeight, accuracy: 1)
            for name in ["sidebarToggleGeometry", "browserSiteInformationGeometry", "browserReloadGeometry",
                         "browserPrivacyGeometry", "browserPageMenuGeometry"] {
                XCTAssertEqual(try frame(name).midY, capsule.midY, accuracy: 1, name)
            }
            let field = try XCTUnwrap(w.contentView.flatMap { views($0).compactMap { $0 as? FocusAwareAddressField }.first })
            XCTAssertEqual(field.stringValue, URLDisplay.site(url))
            try capture("compact")

            tab.zoomIn()
            try await wait("Zoom control did not appear") { self.marker("browserZoomGeometry", in: w) != nil }
            XCTAssertEqual(try frame("browserZoomGeometry").midY, capsule.midY, accuracy: 1)
            XCTAssertEqual(try frame("browserAddressGeometry"), capsule)
            c.focusAddress()
            try await wait("Editing selection or attached suggestions did not mount") {
                field.currentEditor()?.selectedRange == NSRange(location: 0, length: url.absoluteString.utf16.count)
                    && self.marker("browserAddressSuggestionsGeometry", in: w) != nil
            }
            let panel = try frame("browserAddressSuggestionsGeometry")
            XCTAssertEqual(panel.minX, capsule.minX, accuracy: 1)
            XCTAssertEqual(panel.width, capsule.width, accuracy: 1)
            XCTAssertEqual(capsule.minY - panel.maxY, OrivSpacing.xxs, accuracy: 1)
            XCTAssertEqual(try frame("browserAddressGeometry"), capsule)
            try capture("editing-suggestions-zoom")

            _ = c.session.addTab(isPrivate: true, load: false)
            try await wait("Private address did not mount") { self.marker("privateAddressPillGeometry", in: w) != nil }
            XCTAssertEqual(try frame("privateAddressPillGeometry").midY, capsule.midY, accuracy: 1)
            try capture("private-empty")
        }
    }

    func testNarrowOverlayKeepsNativeLightsAboveFlushSurface() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let w = host(c); defer { w.close() }
        w.setContentSize(NSSize(width: 780, height: 760))
        try await wait("Narrow rail did not mount") {
            guard c.sidebar.rail, let surface = self.marker("sidebarSurfaceGeometry", in: w),
                  let toggle = self.marker("sidebarToggleGeometry", in: w) else { return false }
            return surface.bounds.width == MacBrowserLayout.railWidth &&
                toggle.convert(toggle.bounds, to: nil).maxX <= MacBrowserLayout.railWidth
        }
        try click("sidebarToggleGeometry", in: w)
        try await wait("Explicit overlay did not open") { c.sidebar.narrowOverlay }
        try await Task.sleep(for: .milliseconds(200))
        let surface = try XCTUnwrap(marker("sidebarSurfaceGeometry", in: w))
        XCTAssertEqual(surface.convert(surface.bounds, to: nil),
                       NSRect(origin: .zero, size: NSSize(width: MacBrowserLayout.sidebarWidth, height: w.contentView!.bounds.height)))
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            let button = try XCTUnwrap(w.standardWindowButton(type))
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            let rect = button.convert(button.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertLessThanOrEqual(rect.maxX, MacBrowserLayout.railWidth)
            XCTAssertEqual(rect.minX, MacBrowserLayout.railLightsInset + CGFloat(index) * 20, accuracy: 1)
            XCTAssertEqual(w.contentView!.bounds.maxY - rect.midY, MacBrowserLayout.headerHeight / 2, accuracy: 1)
        }
    }
}


@MainActor private final class DragFixture: NSObject, NSDraggingInfo {
    let source: SidebarTabCollection
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingLocation = NSPoint.zero
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
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
