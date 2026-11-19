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
        _ = try XCTUnwrap(condition() ? true : nil, message)
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

    private func focusIndicators(in window: NSWindow) -> [String] {
        window.contentView.map { views($0).compactMap { $0.identifier?.rawValue }.filter { $0.contains("FocusIndicator") } } ?? []
    }

    /// App-owned, off-display opaque layout evidence; never capture a display.
    private func capture(_ name: String, in window: NSWindow) throws {
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum Shortcut: String, CaseIterable { case collapse, search, newTab, cycle }

    @MainActor private final class ShortcutActions: NSObject {
        let controller: BrowserController
        init(_ controller: BrowserController) { self.controller = controller }
        @objc func search() { controller.searchTabs() }
        @objc func newTab() { controller.newTab() }
    }

    private func checkShortcut(_ shortcut: Shortcut) async throws {
        try XCTSkipIf(NSApp.isFullKeyboardAccessEnabled, "Pointer-modality rendering requires Full Keyboard Access off")
        for appearance in [BrowserAppearance.light, .dark] {
            let c = BrowserController(testing: true); defer { c.shutdown() }
            let first = try XCTUnwrap(c.session.selectedTab)
            c.session.togglePinned(first.id)
            let clicked = c.session.addTab(select: false, load: false)
            let next = c.session.addTab(select: false, load: false)
            let w = host(c, appearance: appearance); defer { w.close() }
            // This hosted window has no app scene. Route its scene commands to
            // this ephemeral controller, without BrowserCommands.openWindow.
            let actions = ShortcutActions(c), menu = NSMenu()
            let group = NSMenuItem(); group.submenu = NSMenu(); menu.addItem(group)
            for (title, action, equivalent, modifiers) in [
                ("Search Tabs", #selector(ShortcutActions.search), "a", NSEvent.ModifierFlags([.command, .shift])),
                ("New Tab", #selector(ShortcutActions.newTab), "t", NSEvent.ModifierFlags.command)
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: equivalent)
                item.keyEquivalentModifierMask = modifiers; item.target = actions
                group.submenu?.addItem(item)
            }
            let previousMenu = NSApp.mainMenu
            NSApp.mainMenu = menu
            defer { NSApp.mainMenu = previousMenu }
            try await wait("Rows did not mount") { self.marker("sidebarItem-\(clicked.id)", in: w) != nil }
            // Let the initial address-focus request finish before clicking.
            try await focusSearch(c, in: w)
            try click("sidebarItem-\(clicked.id)", in: w)
            try await wait("Click did not select the row") { c.session.selectedTabID == clicked.id }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(focusIndicators(in: w).isEmpty)
            let event: NSEvent
            switch shortcut {
            case .collapse: event = try keyEvent(1, "s", modifiers: [.option, .command], in: w)
            case .search: event = try keyEvent(0, "a", modifiers: [.shift, .command], in: w)
            case .newTab: event = try keyEvent(17, "t", modifiers: .command, in: w)
            case .cycle: event = try keyEvent(48, "\t", modifiers: .control, in: w)
            }
            NSApp.sendEvent(event)
            switch shortcut {
            case .collapse:
                if !c.sidebar.rail { XCTAssertTrue(w.performKeyEquivalent(with: event)) }
                try await wait("Collapse lost its toggle handoff") { c.sidebar.rail && self.marker("sidebarToggleKeyboardFocus", in: w) != nil }
            case .search:
                if c.tabSearchFocusRequest == 1 { XCTAssertTrue(menu.performKeyEquivalent(with: event)) }
                try await wait("Search shortcut did not acquire its editor") {
                    self.searchEditing(in: w)
                }
                let editor = try XCTUnwrap(w.firstResponder as? NSTextView)
                XCTAssertTrue(editor.isEditable)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0), "Search retains its insertion caret")
            case .newTab:
                if c.session.tabs.count == 3 { XCTAssertTrue(menu.performKeyEquivalent(with: event)) }
                try await wait("New Tab did not focus the address editor") {
                    w.contentView.map { self.views($0).contains { ($0 as? FocusAwareAddressField)?.currentEditor() != nil } } == true
                }
            case .cycle:
                try await wait("Control-Tab did not cycle selection") { c.session.selectedTabID == next.id }
            }
            try await Task.sleep(for: .milliseconds(200))
            try capture("focus-\(shortcut.rawValue)-shortcut-\(appearance.rawValue)", in: w)
            XCTAssertTrue(focusIndicators(in: w).isEmpty, "Shortcut exposed focus cues: \(focusIndicators(in: w))")
            XCTAssertNotNil(marker("sidebarSelection-\(c.session.selectedTabID!)", in: w), "Selection highlight must remain")
            if shortcut == .newTab {
                // New Tab deliberately owns the address editor. Restore sidebar
                // search ownership without navigation before testing its arrow.
                c.searchTabs()
                try await wait("Search did not reacquire its editor") {
                    self.searchEditing(in: w)
                }
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertTrue(focusIndicators(in: w).isEmpty)
            }
            let expected = shortcut == .collapse ? clicked.id : shortcut == .cycle ? next.id : first.id
            try key(125, "\u{f701}", in: w)
            try await wait("First Down arrow lost navigation after \(shortcut.rawValue)") {
                self.marker("sidebarFocusIndicator-\(expected)", in: w) != nil
            }
            try capture("focus-\(shortcut.rawValue)-down-\(appearance.rawValue)", in: w)
            if shortcut == .cycle { XCTAssertEqual(c.session.selectedTabID, next.id) }
            if shortcut == .search {
                // The arrow moved focus out of the editor. Restoring its focus
                // binding after navigation must use normal keyboard rendering.
                c.searchTabs()
                try await wait("Restored search focus lost keyboard rendering") {
                    self.marker("sidebarSearchFocusIndicator", in: w) != nil
                }
                try capture("focus-search-restored-\(appearance.rawValue)", in: w)
            }
        }
    }

    func testPointerThenCollapseShortcutDefersRingUntilDownArrow() async throws { try await checkShortcut(.collapse) }
    func testPointerThenSearchShortcutDefersRingUntilDownArrow() async throws { try await checkShortcut(.search) }
    func testPointerThenNewTabShortcutDefersRingUntilDownArrow() async throws { try await checkShortcut(.newTab) }
    func testPointerThenControlTabDefersRingUntilDownArrow() async throws { try await checkShortcut(.cycle) }

    private func pointerEvent(_ type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testOnlyUnmodifiedNavigationEntersKeyboardModality() throws {
        let input = ChromeFocusState(fullKeyboardAccessEnabled: { false })
        for code: UInt16 in [48, 123, 124, 125, 126] {
            for modifiers: NSEvent.ModifierFlags in [[], .shift, .function, [.shift, .function], .capsLock] {
                input.receive(try pointerEvent())
                input.receive(try keyEvent(code, "", modifiers: modifiers))
                XCTAssertTrue(input.showsFocus, "Navigation key \(code), modifiers \(modifiers)")
            }
            for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, [.command, .shift], [.option, .shift], [.control, .shift]] {
                input.receive(try pointerEvent())
                input.receive(try keyEvent(code, "", modifiers: modifiers))
                XCTAssertFalse(input.showsFocus, "Modified navigation must remain a shortcut")
            }
        }
        for (code, text): (UInt16, String) in [(0, "a"), (49, " "), (36, "\r"), (76, "\u{3}"), (122, "\u{f704}"), (90, "\u{f717}")] {
            input.receive(try pointerEvent())
            input.receive(try keyEvent(code, text))
            XCTAssertFalse(input.showsFocus, "Typing, activation and function keys cannot start navigation")
            input.receive(try keyEvent(125, "\u{f701}"))
            input.receive(try keyEvent(code, text))
            XCTAssertTrue(input.showsFocus, "Other keys preserve established navigation")
        }
        for (code, text, modifiers): (UInt16, String, NSEvent.ModifierFlags) in [
            (1, "s", [.command, .option]), (0, "a", [.command, .shift]), (17, "t", .command), (48, "\t", .control)
        ] {
            input.receive(try keyEvent(125, "\u{f701}"))
            input.receive(try keyEvent(code, text, modifiers: modifiers))
            XCTAssertFalse(input.showsFocus, "Shortcut handoffs must defer decoration until navigation")
        }
    }

    func testEveryMouseButtonResetsKeyboardModality() throws {
        let input = ChromeFocusState(fullKeyboardAccessEnabled: { false })
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            input.receive(try keyEvent(48, "\t")); XCTAssertTrue(input.showsFocus)
            input.receive(try pointerEvent(type)); XCTAssertFalse(input.showsFocus)
        }
    }

    func testFullKeyboardAccessKeepsKeyboardCuesIncludingShortcuts() throws {
        let input = ChromeFocusState(fullKeyboardAccessEnabled: { true })
        XCTAssertTrue(input.showsFocus)
        for (code, text, modifiers): (UInt16, String, NSEvent.ModifierFlags) in [
            (1, "s", [.command, .option]), (0, "a", [.command, .shift]), (17, "t", .command),
            (48, "\t", .control), (122, "\u{f704}", []), (49, " ", [])
        ] {
            input.receive(try pointerEvent()); XCTAssertFalse(input.showsFocus)
            input.receive(try keyEvent(code, text, modifiers: modifiers)); XCTAssertTrue(input.showsFocus)
        }
    }

    func testConsumedControlTabUpdatesModalityBeforeSidebarMonitor() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        _ = c.session.addTab(select: false, load: false)
        let w = host(c); defer { w.close() }
        try await wait("Key router did not mount") {
            w.contentView.map { self.views($0).contains { $0 is BrowserKeyRouter.RoutingView } } == true
        }
        let router = try XCTUnwrap(w.contentView.flatMap { views($0).compactMap { $0 as? BrowserKeyRouter.RoutingView }.first })
        let input = ChromeFocusState(fullKeyboardAccessEnabled: { false })
        router.input = input
        input.receive(try keyEvent(125, "\u{f701}", in: w))
        XCTAssertTrue(input.showsFocus)
        XCTAssertTrue(router.route(try keyEvent(48, "\t", modifiers: .control, in: w)))
        XCTAssertFalse(input.showsFocus, "Consumed events cannot depend on another local monitor")
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
