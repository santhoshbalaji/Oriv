import AppKit
import BrowserCore
@testable import BrowserEngine
import SwiftUI
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class BrowserShortcutTests: BackgroundUITestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func window(_ controller: BrowserController) -> NSWindow {
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BrowserWindow(controller: controller).browserAppearance(.t3Code))
        BackgroundUIMode.show(window)
        return window
    }
    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags, characters: String, window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.sendEvent(event)
    }
    func testControlTabRealEventsWithWebContentAndAddressEditorFocusWrapInSidebarOrder() async throws {
        let controller = BrowserController(testing: true); defer { controller.shutdown() }
        let session = controller.session
        let first = try XCTUnwrap(session.selectedTab)
        first.webView.loadHTMLString("<input id='edit' autofocus value='Page editor'>", baseURL: URL(string: "https://shortcut.test"))
        let second = session.addTab(load: false), third = session.addTab(load: false)
        session.togglePinned(third.id)
        session.selectTab(first.id)
        let window = window(controller); defer { window.close() }
        for _ in 0..<200 {
            if (try? await first.webView.evaluateJavaScript("document.querySelector('#edit') !== null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(window.makeFirstResponder(first.webView))
        _ = try await first.webView.evaluateJavaScript("document.querySelector('#edit').focus(); true")
        try key(48, flags: .control, characters: "\t", window: window)
        XCTAssertEqual(session.selectedTabID, second.id)
        try key(48, flags: .control, characters: "\t", window: window)
        XCTAssertEqual(session.selectedTabID, third.id, "Wrap follows pinned-first sidebar order")
        controller.focusAddress()
        try await Task.sleep(for: .milliseconds(150))
        let field = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? FocusAwareAddressField }.first })
        XCTAssertNotNil(field.currentEditor())
        try key(48, flags: [.control, .shift], characters: "\u{19}", window: window)
        XCTAssertEqual(session.selectedTabID, second.id)
        try key(48, flags: [.control, .shift], characters: "\u{19}", window: window)
        XCTAssertEqual(session.selectedTabID, first.id)
        // Complete the focus/direction matrix: previous in web content, next in
        // the address editor, in addition to the two paths above.
        XCTAssertTrue(window.makeFirstResponder(first.webView))
        _ = try await first.webView.evaluateJavaScript("document.querySelector('#edit').focus(); true")
        try key(48, flags: [.control, .shift], characters: "\u{19}", window: window)
        XCTAssertEqual(session.selectedTabID, third.id)
        session.selectTab(first.id)
        controller.focusAddress()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(field.currentEditor())
        try key(48, flags: .control, characters: "\t", window: window)
        XCTAssertEqual(session.selectedTabID, second.id)
    }
    func testControlTabRoutesSheetItemsButNotOtherWindows() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        defer { session.shutdown() }
        let first = try XCTUnwrap(session.selectedTabID), second = session.addTab(load: false).id
        let parent = BackgroundUIMode.Window(contentRect: NSRect(x: 0,y: 0,width: 700,height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; defer { parent.close() }
        parent.contentViewController = NSHostingController(rootView: BrowserKeyRouter(session: session, overviewVisible: true))
        BackgroundUIMode.show(parent)
        let sheet = BackgroundUIMode.Window(contentRect: NSRect(x: 0,y: 0,width: 500,height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        parent.beginSheet(sheet, completionHandler: { _ in }); defer { parent.endSheet(sheet); sheet.close() }
        BackgroundUIMode.checkFrontmost()
        try key(48, flags: .control, characters: "\t", window: sheet)
        XCTAssertEqual(session.selectedTabID, first)
        try key(48, flags: [.control, .shift], characters: "\u{19}", window: sheet)
        XCTAssertEqual(session.selectedTabID, second)
    }
    func testFileMenuPrivateShortcutsAndTabShortcutsAreUnique() throws {
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let file = try XCTUnwrap(menu.items.first { $0.title == "File" }?.submenu)
        let modifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let bindings: [(String, String, NSEvent.ModifierFlags)] = [
            ("New Tab", "t", [.command]),
            ("Reopen Closed Tab", "t", [.command, .shift]),
            ("New Private Tab", "n", [.command, .shift]),
            ("New Private Window", "n", [.command, .shift, .option])
        ]
        for (title, key, expected) in bindings {
            let matches = items(menu).filter {
                $0.keyEquivalent.lowercased() == key && $0.keyEquivalentModifierMask.intersection(modifiers) == expected
            }
            XCTAssertEqual(matches.map(\.title), [title])
            XCTAssertTrue(file.items.contains { $0 === matches.first })
        }
    }

    func testPrivateWindowContextsKeepTheirOwnTabsAndDiscardOnClose() throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let regular = profiles.controller
        regular.session.settings.privateTabIsolation.isEnabled = false
        let first = profiles.createPrivateWindow(), second = profiles.createPrivateWindow()
        let firstWindow = try XCTUnwrap(profiles.privateWindows[first])
        let secondWindow = try XCTUnwrap(profiles.privateWindows[second])
        let original = try XCTUnwrap(firstWindow.session.selectedTab)
        let store = try XCTUnwrap(original.websiteDataStore)
        firstWindow.newTab() // Same action as the focused window’s Command-T menu item.
        XCTAssertEqual(firstWindow.session.tabs.count, 2)
        XCTAssertTrue(firstWindow.session.tabs.allSatisfy { $0.isPrivate && $0.websiteDataStore === store })
        XCTAssertEqual(secondWindow.session.tabs.count, 1)
        XCTAssertFalse(secondWindow.session.selectedTab?.websiteDataStore === store)
        XCTAssertTrue(regular.session.tabs.allSatisfy { !$0.isPrivate })
        XCTAssertNil(profiles.externalPrivate)

        profiles.endPrivateWindow(first)
        XCTAssertNil(profiles.privateWindows[first])
        XCTAssertNil(original.websiteDataStore)
        XCTAssertTrue(firstWindow.session.tabs.isEmpty)
        XCTAssertNil(firstWindow.session.selectedTabID)
        XCTAssertTrue(firstWindow.session.snapshot().tabs.isEmpty)
        XCTAssertFalse(firstWindow.session.canReopenTab)
        XCTAssertTrue(profiles.privateWindows[second] === secondWindow)
        XCTAssertEqual(secondWindow.session.tabs.count, 1)
    }

    func testReloadMenuEquivalentsAreUniqueAndReaderIsUnbound() throws {
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let all = items(try XCTUnwrap(NSApp.mainMenu))
        let reloads = all.filter { $0.keyEquivalent.lowercased() == "r" }
        let modifiers = reloads.map { $0.keyEquivalentModifierMask.intersection([.command, .shift, .control, .option]).rawValue }
        XCTAssertEqual(Set(modifiers).count, modifiers.count)
        XCTAssertTrue(modifiers.contains(NSEvent.ModifierFlags([.command, .shift]).rawValue))
        XCTAssertTrue(modifiers.contains(NSEvent.ModifierFlags([.command, .option]).rawValue))
        let reader = try XCTUnwrap(all.first { $0.title == "Read Page Text" })
        XCTAssertTrue(reader.keyEquivalent.isEmpty)
    }
    func testTabSearchMenuHasOneNonconflictingShiftCommandA() throws {
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let matches = items(try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.keyEquivalent.lowercased() == "a" && $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [.command, .shift]
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.title, "Search Tabs…")
    }
    func testCommandShiftRRealEventReloadsOriginFromAddressFocus() async throws {
        let controller = BrowserController(testing: true); defer { controller.shutdown() }
        let tab = try XCTUnwrap(controller.session.selectedTab)
        let spy = ReloadOriginWebView(frame: .zero, configuration: WKWebViewConfiguration())
        tab.createWebView = { _ in spy }
        tab.navigate(to: URL(string: "https://reload.test")!)
        let window = window(controller); defer { window.close() }
        controller.focusAddress(); try await Task.sleep(for: .milliseconds(200))
        try key(15, flags: [.command, .shift], characters: "r", window: window)
        XCTAssertEqual(spy.originReloads, 1)
        XCTAssertTrue(window.makeFirstResponder(spy))
        try key(15, flags: [.command, .shift], characters: "r", window: window)
        XCTAssertEqual(spy.originReloads, 2)
        XCTAssertEqual(spy.ordinaryReloads, 0)
        XCTAssertNil(controller.readerCapture)
    }
}

@MainActor private final class ReloadOriginWebView: WKWebView {
    var originReloads = 0, ordinaryReloads = 0
    override func load(_ request: URLRequest) -> WKNavigation? { nil }
    override func reloadFromOrigin() -> WKNavigation? { originReloads += 1; return nil }
    override func reload() -> WKNavigation? { ordinaryReloads += 1; return nil }
}
