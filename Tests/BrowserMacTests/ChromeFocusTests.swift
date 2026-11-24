import AppKit
import BrowserEngine
import SwiftUI
import XCTest
@testable import PersonalBrowser

@MainActor final class ChromeFocusTests: BackgroundUITestCase {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func marker(_ name: String, in window: NSWindow) -> NSView? {
        window.contentView.flatMap { views($0).first { $0.identifier?.rawValue == name } }
    }
    private func host(_ controller: BrowserController, appearance: BrowserAppearance = .light) -> NSWindow {
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BrowserWindow(controller: controller)
            .browserAppearance(appearance).environment(\.chromeReduceTransparencyOverride, true)
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

    func testNativeDragDelegatesReorderAndPinThroughThePasteboard() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let pinned = try XCTUnwrap(c.session.selectedTab)
        c.session.togglePinned(pinned.id)
        let first = c.session.addTab(select: false, load: false)
        let second = c.session.addTab(select: false, load: false)
        let w = host(c); defer { w.close() }
        try await wait("Collection did not mount") { self.collection(in: w)?.sidebar?.path(for: second.id) != nil }
        let list = try XCTUnwrap(collection(in: w))
        let data = try XCTUnwrap(list.sidebar)
        let source = try XCTUnwrap(data.path(for: second.id))
        let destination = try XCTUnwrap(data.path(for: first.id))
        let item = try XCTUnwrap(data.collectionView(list, pasteboardWriterForItemAt: source))
        let info = DragFixture(source: list)
        XCTAssertTrue(info.draggingPasteboard.writeObjects([item]))
        list.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(list.layoutAttributesForItem(at: destination))
        info.move(to: row.frame, verticalFraction: 0.25)
        var proposed = destination as NSIndexPath
        var operation = NSCollectionView.DropOperation.before
        XCTAssertEqual(data.collectionView(list, validateDrop: info, proposedIndexPath: &proposed, dropOperation: &operation), .move)
        XCTAssertEqual(operation, .on)
        XCTAssertTrue(data.collectionView(list, acceptDrop: info, indexPath: destination, dropOperation: operation))
        XCTAssertEqual(c.session.orderedTabs.map(\.id), [pinned.id, second.id, first.id])

        let pinSection = try XCTUnwrap(data.path(for: pinned.id)).section
        let header = try XCTUnwrap(list.layoutAttributesForSupplementaryElement(ofKind: NSCollectionView.elementKindSectionHeader,
                                                                                at: IndexPath(item: 0, section: pinSection)))
        info.move(to: header.frame)
        XCTAssertEqual(data.collectionView(list, validateDrop: info, proposedIndexPath: &proposed, dropOperation: &operation), .move)
        XCTAssertEqual(operation, .before)
        XCTAssertTrue(data.collectionView(list, acceptDrop: info, indexPath: proposed as IndexPath, dropOperation: operation))
        XCTAssertTrue(second.isPinned)
        XCTAssertTrue(data.menu(for: second).items.contains { $0.title == "Unpin Tab" })
    }

    func testNarrowOverlayKeepsNativeLightsAboveInsetSurface() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let w = host(c); defer { w.close() }
        w.setContentSize(NSSize(width: 780, height: 760))
        try await wait("Narrow rail did not mount") {
            guard c.sidebar.rail, let surface = self.marker("sidebarSurfaceGeometry", in: w),
                  let toggle = self.marker("sidebarToggleGeometry", in: w) else { return false }
            return surface.bounds.width == MacBrowserLayout.railWidth &&
                toggle.convert(toggle.bounds, to: nil).maxX <= MacBrowserLayout.railWidth + MacBrowserLayout.panelInset
        }
        try click("sidebarToggleGeometry", in: w)
        try await wait("Explicit overlay did not open") { c.sidebar.narrowOverlay }
        try await Task.sleep(for: .milliseconds(200))
        let surface = try XCTUnwrap(marker("sidebarSurfaceGeometry", in: w))
        let inset = MacBrowserLayout.panelInset
        XCTAssertEqual(surface.convert(surface.bounds, to: nil),
                       NSRect(x: inset, y: inset, width: MacBrowserLayout.sidebarWidth, height: w.contentView!.bounds.height - 2 * inset))
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            let button = try XCTUnwrap(w.standardWindowButton(type))
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            let rect = button.convert(button.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(rect.minX, 8 - 1)
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
    func move(to rect: NSRect, verticalFraction: CGFloat = 0.5) {
        draggingLocation = source.convert(NSPoint(x: rect.midX, y: rect.minY + rect.height * verticalFraction), to: nil)
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
