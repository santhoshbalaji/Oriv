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
    private func wait(_ message: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), message)
    }
    private func key(_ code: UInt16, _ text: String, in window: NSWindow) throws {
        NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
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
    /// Catch a native blue rectangle even if our custom indicator is absent.
    private func assertNoBlueRing(_ name: String, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(window.contentView), target = try XCTUnwrap(marker(name, in: window))
        let rect = target.convert(target.bounds, to: content).insetBy(dx: -4, dy: -4)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: rect))
        content.cacheDisplay(in: rect, to: bitmap)
        var blue = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   c.blueComponent > 0.4, c.blueComponent > c.redComponent + 0.12,
                   c.blueComponent > c.greenComponent + 0.06 { blue += 1 }
            }
        }
        XCTAssertEqual(blue, 0, "Mouse input must not leave the system blue focus rectangle", file: file, line: line)
    }

    func testMouseClickToggleHidesKeyboardCueInLightAndDark() async throws {
        for appearance in [BrowserAppearance.light, .dark] {
            let c = BrowserController(testing: true); defer { c.shutdown() }
            let w = host(c, appearance: appearance); defer { w.close() }
            try await wait("Address did not mount") { self.marker("sidebarToggleGeometry", in: w) != nil }
            try await focusSearch(c, in: w)
            try key(125, "\u{f701}", in: w)
            let id = try XCTUnwrap(c.session.selectedTabID)
            try await wait("Arrow navigation must draw a rounded row cue") { self.marker("sidebarFocusIndicator-\(id)", in: w) != nil }
            try click("sidebarToggleGeometry", in: w)
            try await wait("Toggle click did not collapse") { c.sidebar.rail }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertNil(marker("sidebarToggleFocusIndicator", in: w))
            XCTAssertNil(marker("sidebarFocusIndicator-\(id)", in: w))
            try assertNoBlueRing("sidebarToggleGeometry", in: w)
        }
    }

    func testMouseClickRowRemovesFocusCueButKeepsSelectionInLightAndDark() async throws {
        for appearance in [BrowserAppearance.light, .dark] {
            let c = BrowserController(testing: true); defer { c.shutdown() }
            let first = try XCTUnwrap(c.session.selectedTabID)
            let second = c.session.addTab(select: false, load: false)
            let w = host(c, appearance: appearance); defer { w.close() }
            try await wait("Rows did not mount") { self.marker("sidebarItem-\(second.id)", in: w) != nil }
            try await focusSearch(c, in: w)
            try key(125, "\u{f701}", in: w)
            try await wait("Keyboard cue missing") { self.marker("sidebarFocusIndicator-\(first)", in: w) != nil }
            try click("sidebarItem-\(second.id)", in: w)
            try await wait("Row click must select the destination") { c.session.selectedTabID == second.id }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNil(marker("sidebarFocusIndicator-\(first)", in: w))
            XCTAssertNil(marker("sidebarFocusIndicator-\(second.id)", in: w))
            XCTAssertNotNil(marker("sidebarSelection-\(second.id)", in: w))
            try assertNoBlueRing("sidebarItem-\(second.id)", in: w)
        }
    }

    func testKeyboardFocusAndSelectedFocusUseSameRowBounds() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTabID)
        let second = c.session.addTab(select: true, load: false)
        let w = host(c); defer { w.close() }
        try await wait("Search did not mount") { self.marker("sidebarToggleGeometry", in: w) != nil }
        try await focusSearch(c, in: w)
        try key(125, "\u{f701}", in: w)
        try await wait("Keyboard focus must be visible on an unselected row") { self.marker("sidebarFocusIndicator-\(first)", in: w) != nil }
        XCTAssertEqual(c.session.selectedTabID, second.id)
        try key(125, "\u{f701}", in: w)
        try await wait("Arrow navigation must select and focus the next row") { self.marker("sidebarFocusIndicator-\(second.id)", in: w) != nil }
        XCTAssertEqual(c.session.selectedTabID, second.id)
        let ring = try XCTUnwrap(marker("sidebarFocusIndicator-\(second.id)", in: w))
        let selected = try XCTUnwrap(marker("sidebarSelection-\(second.id)", in: w))
        XCTAssertEqual(ring.convert(ring.bounds, to: nil), selected.convert(selected.bounds, to: nil))
        XCTAssertNil(marker("sidebarFocusIndicator-\(first)", in: w))
    }

    func testNarrowOverlayKeepsNativeLightsAboveAttachedSurface() async throws {
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
        XCTAssertEqual(surface.convert(surface.bounds, to: nil), NSRect(x: 0, y: 0, width: MacBrowserLayout.sidebarWidth, height: w.contentView!.bounds.height))
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(w.standardWindowButton(type))
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            let rect = button.convert(button.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertLessThanOrEqual(rect.maxX, MacBrowserLayout.railWidth)
            XCTAssertEqual(w.contentView!.bounds.maxY - rect.midY, MacBrowserLayout.sidebarTitlebarHeight / 2, accuracy: 1)
        }
    }
}
