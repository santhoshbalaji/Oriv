import AppKit
import BrowserCore
@testable import BrowserEngine
import Observation
import SwiftUI
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class SidebarGlassTests: BackgroundUITestCase {
    private final class FocusTestWindow: BackgroundUIMode.Window {
        // Exercise 1x window/SwiftUI geometry without changing any display.
        var scale: CGFloat?
        override var backingScaleFactor: CGFloat { scale ?? super.backingScaleFactor }
    }
    func testStoredSidebarGlassLevelsKeepTheirLabelsAndBackingOrder() {
        let levels = ["Balanced", "High", "Solid"].compactMap(SidebarGlassOpacity.init(rawValue:))
        XCTAssertEqual(levels, [.balanced, .high, .solid])
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let styles = levels.map { SidebarChromaticStyle(level: $0, environment: environment) }
            XCTAssertEqual(styles.map(\.backingOpacity), [0.65, 0.86, 1])
            XCTAssertEqual(styles.first?.guardOpacity, 0.65)
            XCTAssertEqual(styles.map(\.selectionOpacity), [0.43, 0.43, 1])
            XCTAssertEqual(styles.map(\.opaque), [false, false, true])
        }
    }

    func testChromaticSelectionUsesOpaquePillForAccessibility() {
        var environment = EnvironmentValues()
        environment.sidebarCaptureContrast = .standard
        XCTAssertFalse(SidebarChromaticStyle(environment: environment).opaque)

        environment.chromeReduceTransparencyOverride = true
        XCTAssertTrue(SidebarChromaticStyle(environment: environment).opaque)

        environment.chromeReduceTransparencyOverride = false
        environment.sidebarCaptureContrast = .increased
        let style = SidebarChromaticStyle(environment: environment)
        XCTAssertTrue(style.opaque)
        XCTAssertTrue(style.increased)
    }

    func testSidebarColorReadsOnlyRecognizedPreferences() {
        XCTAssertEqual(SidebarColor.saved(nil), .graphite)
        XCTAssertEqual(SidebarColor.saved("future-color"), .graphite)
        for choice in SidebarColor.allCases {
            XCTAssertEqual(SidebarColor.saved(choice.rawValue), choice)
        }
    }

    func testSidebarColorFollowsProfileRebindingAndProfileColorEdits() throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let first = profiles.controller
        XCTAssertEqual(first.sidebarColor, .graphite)
        first.sidebarColor = .rose
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        try profiles.select(work.id)
        let second = profiles.controller
        XCTAssertEqual(second.sidebarColor, .graphite)
        second.sidebarColor = .profile
        let ocean = Theme.SidebarChromaticTokens.resolve(second.sidebarColor, profile: second.sidebarProfileColor(in: profiles),
                                                       dark: false, black: false)
        try profiles.update(work.id, name: work.name, color: .fern, symbol: work.symbol)
        let fern = Theme.SidebarChromaticTokens.resolve(second.sidebarColor, profile: second.sidebarProfileColor(in: profiles),
                                                       dark: false, black: false)
        XCTAssertNotEqual(ocean, fern)
        try profiles.select(BrowserProfile.personalID)
        XCTAssertTrue(profiles.controller === first)
        XCTAssertEqual(profiles.controller.sidebarColor, .rose)
        try profiles.select(work.id)
        XCTAssertTrue(profiles.controller === second)
        XCTAssertEqual(profiles.controller.sidebarColor, .profile)
        XCTAssertEqual(profiles.controller.sidebarProfileColor(in: profiles), .fern)
    }

    func testSidebarColorKeepsItsChoiceThroughT3CodeAppearance() {
        let controller = BrowserController(testing: true)
        defer { controller.shutdown() }
        controller.sidebarColor = .mint
        let profile = controller.sidebarProfileColor(in: nil)
        controller.appearance = .t3Code
        let black = Theme.SidebarChromaticTokens.resolve(controller.sidebarColor, profile: profile,
                                                         dark: true, black: controller.appearance.theme.isT3Code)
        XCTAssertEqual(black.top, 0x0A0A0A)
        XCTAssertEqual(controller.sidebarColor, .mint)
        controller.appearance = .system
        let restored = Theme.SidebarChromaticTokens.resolve(controller.sidebarColor, profile: profile,
                                                            dark: true, black: controller.appearance.theme.isT3Code)
        XCTAssertEqual(restored, Theme.SidebarChromaticTokens.resolve(.mint, profile: profile, dark: true, black: false))
        XCTAssertNotEqual(restored, black)
    }

    func testProfilelessPrivateWindowsUseGraphite() throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        profiles.controller.appearance = .light
        profiles.controller.sidebarColor = .lavender
        let privateID = profiles.createPrivateWindow()
        let privateWindow = try XCTUnwrap(profiles.privateWindows[privateID])
        profiles.openExternalLinksPrivately = true
        profiles.handleIncomingURL(try XCTUnwrap(URL(string: "https://example.test")))
        let external = try XCTUnwrap(profiles.externalPrivate)
        for context in [privateWindow, external] {
            context.sidebarColor = .butter
            XCTAssertEqual(context.sidebarColor, .graphite)
            XCTAssertNil(context.sidebarProfileColor(in: profiles))
            XCTAssertEqual(Theme.SidebarChromaticTokens.resolve(.butter, profile: context.sidebarProfileColor(in: profiles),
                                                               dark: false, black: false),
                           Theme.SidebarChromaticTokens.resolve(.graphite, profile: nil, dark: false, black: false))
        }
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func nodes(_ element: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 24, let node = element as? any NSAccessibilityProtocol else { return [] }
        return [node] + (node.accessibilityChildren() ?? []).flatMap { nodes($0, depth: depth + 1) }
    }
    private func window(_ controller: BrowserController, solid: Bool = false, reduceMotion: Bool? = nil,
                        appearance: BrowserAppearance = .light, size: NSSize = NSSize(width: 1000, height: 760),
                        displayScale: CGFloat? = nil) -> NSWindow {
        let window = FocusTestWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.scale = displayScale
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BrowserWindow(controller: controller)
            .browserAppearance(appearance).environment(\.chromeReduceTransparencyOverride, solid)
            .environment(\.sidebarCaptureReduceMotion, reduceMotion)
            .transformEnvironment(\.displayScale) { if let displayScale { $0 = displayScale } })
        window.setContentSize(size)
        BackgroundUIMode.show(window, key: true)
        return window
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    private func waitUntil(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                           condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !condition() {
            for window in NSApp.windows {
                guard let content = window.contentView else { continue }
                for view in views(content) {
                    if let scroll = view as? NSScrollView {
                        print("SIDEBAR_FOCUS_FAILURE viewport=\(scroll.contentView.bounds) document=\(String(describing: scroll.documentView?.bounds)) scrollerStyle=\(scroll.scrollerStyle.rawValue) verticalScroller=\(scroll.hasVerticalScroller) responder=\(String(describing: window.firstResponder))")
                    }
                    if let name = view.identifier?.rawValue, name.hasPrefix("sidebarKeyboardFocus-") || name.hasPrefix("sidebarSelection-") {
                        print("SIDEBAR_FOCUS_FAILURE \(name) frame=\(view.convert(view.bounds, to: view.enclosingScrollView?.contentView))")
                    }
                }
            }
        }
        _ = try XCTUnwrap(condition() ? true : nil, message, file: file, line: line)
    }

    private func hasVisibleKeyboardFocus(_ id: UUID, in window: NSWindow) -> Bool {
        guard let list = window.firstResponder as? SidebarTabCollection,
              list.sidebar?.selectedID == id,
              let path = list.sidebar?.path(for: id),
              let frame = list.layoutAttributesForItem(at: path)?.frame else { return false }
        return list.visibleRect.insetBy(dx: -1, dy: -1).contains(frame)
    }

    private func checkFocusedRailViewport(_ id: UUID, in window: NSWindow,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let marker = try XCTUnwrap(window.contentView.flatMap { views($0).first {
            $0.identifier?.rawValue == "sidebarItem-\(id)"
        } }, file: file, line: line)
        let scroll = try XCTUnwrap(marker.enclosingScrollView, file: file, line: line)
        let frame = marker.convert(marker.bounds, to: scroll.contentView)
        print("SIDEBAR_RAIL_VIEWPORT viewport=\(scroll.contentView.bounds) focusedRow=\(frame) scrollerStyle=\(scroll.scrollerStyle.rawValue) verticalScroller=\(scroll.hasVerticalScroller)")
        XCTAssertEqual(scroll.contentView.bounds.width, MacBrowserLayout.railWidth, accuracy: 1,
                       "A scrollbar gutter must not clip rail rows or their focus rings", file: file, line: line)
        XCTAssertEqual(frame.minX, MacBrowserLayout.railInset, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.width, MacBrowserLayout.railItemWidth, accuracy: 1, file: file, line: line)
    }

    private func toggleSidebar(in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        XCTAssertTrue(window.performKeyEquivalent(with: event), "Use the live sidebar shortcut action")
    }

    private func checkRail(_ controller: BrowserController, in window: NSWindow, settled: Bool = true,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let all = views(try XCTUnwrap(window.contentView, file: file, line: line))
        func frame(_ name: String) throws -> NSRect {
            let marker = try XCTUnwrap(all.first { $0.identifier?.rawValue == name }, name, file: file, line: line)
            return marker.convert(marker.bounds, to: nil)
        }
        let sidebar = try frame("browserSidebarGeometry")
        if settled { XCTAssertEqual(sidebar.width, MacBrowserLayout.railWidth, accuracy: 1, file: file, line: line) }
        XCTAssertFalse(all.contains { $0.identifier?.rawValue.hasPrefix("sidebarClose-") == true },
                       "A rail must not retain expanded close buttons", file: file, line: line)
        for tab in controller.session.orderedTabs {
            let icon = try frame("sidebarFavicon-\(tab.id)")
            let item = try frame("sidebarItem-\(tab.id)")
            XCTAssertEqual(icon.midX, sidebar.midX, accuracy: 1, "Favicon \(tab.id)", file: file, line: line)
            XCTAssertEqual(item.width, 42, accuracy: 1, file: file, line: line)
            XCTAssertEqual(item.height, 36, accuracy: 1, file: file, line: line)
            if tab.id == controller.session.selectedTabID {
                let highlight = try frame("sidebarSelection-\(tab.id)")
                XCTAssertEqual(highlight.midX, sidebar.midX, accuracy: 1, file: file, line: line)
                XCTAssertEqual(highlight.midX, icon.midX, accuracy: 1, file: file, line: line)
                XCTAssertEqual(highlight.midY, icon.midY, accuracy: 1, file: file, line: line)
                XCTAssertTrue(highlight.contains(icon), "Selection must surround the favicon", file: file, line: line)
            }
        }
    }

    private func checkLiveRailToggle(reduceMotion: Bool) async throws {
        let controller = BrowserController(testing: true); defer { controller.shutdown() }
        for _ in 1..<4 { _ = controller.session.addTab(select: false, load: false) }
        let selected = controller.session.orderedTabs[1].id
        controller.session.selectTab(selected)
        let window = window(controller, solid: true, reduceMotion: reduceMotion, appearance: .dark); defer { window.close() }
        window.setContentSize(NSSize(width: 1000, height: 760))
        try await settle()
        for _ in 0..<2 {
            XCTAssertFalse(controller.compactSidebar)
            try toggleSidebar(in: window)
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(40))
                try checkRail(controller, in: window, settled: false)
            }
            try await settle() // Also check after the live 220 ms collapse animation.
            XCTAssertTrue(controller.compactSidebar)
            XCTAssertEqual(controller.session.selectedTabID, selected)
            try checkRail(controller, in: window)
            try toggleSidebar(in: window)
            try await settle()
            XCTAssertFalse(controller.compactSidebar)
            let all = views(try XCTUnwrap(window.contentView))
            XCTAssertEqual(all.filter { $0.identifier?.rawValue.hasPrefix("sidebarClose-") == true }.count, 4)
        }
    }

    func testLiveShortcutRailGeometryWithAnimation() async throws { try await checkLiveRailToggle(reduceMotion: false) }
    func testLiveShortcutRailGeometryWithReduceMotion() async throws { try await checkLiveRailToggle(reduceMotion: true) }

    private func checkRestoredRail(reduceMotion: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = BrowserProfile(name: "Rail regression")
        let defaultsName = try XCTUnwrap(profile.defaultsName(bundleID: Bundle.main.bundleIdentifier!))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
        var selected: UUID?
        do {
            let controller = BrowserController(profile: profile, rootDirectory: root, testing: false, websiteStore: .nonPersistent())
            defer { controller.shutdown() }
            for _ in 1..<4 { _ = controller.session.addTab(select: false, load: false) }
            selected = controller.session.orderedTabs[1].id
            controller.session.selectTab(selected!)
            let window = window(controller, solid: true, reduceMotion: reduceMotion, appearance: .dark); defer { window.close() }
            window.setContentSize(NSSize(width: 1000, height: 760))
            try await settle()
            XCTAssertFalse(controller.compactSidebar)
            try toggleSidebar(in: window)
            try await settle()
            try checkRail(controller, in: window)
            XCTAssertTrue(defaults.bool(forKey: "compactSidebar"))
            controller.session.saveNow(discardPrevious: true)
        }
        let restored = BrowserController(profile: profile, rootDirectory: root, testing: false, websiteStore: .nonPersistent())
        defer { restored.shutdown() }
        XCTAssertTrue(restored.compactSidebar)
        XCTAssertEqual(restored.session.selectedTabID, selected)
        XCTAssertEqual(restored.session.tabs.count, 4)
        let window = window(restored, solid: true, reduceMotion: reduceMotion, appearance: .dark); defer { window.close() }
        window.setContentSize(NSSize(width: 1000, height: 760))
        try await settle()
        try checkRail(restored, in: window)
    }

    func testLiveShortcutRailPersistsAcrossRelaunchWithAnimation() async throws { try await checkRestoredRail(reduceMotion: false) }
    func testLiveShortcutRailPersistsAcrossRelaunchWithReduceMotion() async throws { try await checkRestoredRail(reduceMotion: true) }

    func testDecodedFaviconAdaptsToPanelAndActiveBacking() async throws {
        let cache = SiteIconDiskCache(directory: nil)
        func backing(_ range: ClosedRange<Double>) -> FaviconBacking {
            FaviconBacking(luminance: range, lightCushion: 0.95, darkCushion: 0.01)
        }
        let dark = backing(0.02...0.12)
        let light = backing(0.65...0.90)
        let nearBlue = backing(0.05...0.16)
        func glyph(_ color: NSColor) async throws -> SiteIcon {
            let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 20, height: 20)).fill()
                return true
            }
            let decoded = await cache.decode(try XCTUnwrap(image.tiffRepresentation))
            return try XCTUnwrap(decoded)
        }
        for color in [NSColor.black, .white] {
            let icon = try await glyph(color)
            XCTAssertEqual(icon.analysis.kind, .transparentGlyph)
            XCTAssertEqual(icon.treatment(on: dark), .ink)
            XCTAssertEqual(icon.treatment(on: light), .ink)
        }
        let blue = try await glyph(NSColor(srgbRed: 0.1, green: 0.32, blue: 0.80, alpha: 1))
        XCTAssertEqual(blue.treatment(on: nearBlue), .cushion(light: true))
        XCTAssertEqual(blue.treatment(on: light), .bare)
        XCTAssertEqual(blue.treatment(on: nearBlue), .cushion(light: true))

        let opaque = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.black.setFill(); NSBezierPath(rect: rect).fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 8, dy: 8)).fill()
            return true
        }
        let decoded = await cache.decode(try XCTUnwrap(opaque.tiffRepresentation))
        let icon = try XCTUnwrap(decoded)
        XCTAssertEqual(icon.analysis.kind, .fullBleed)
        XCTAssertEqual(icon.treatment(on: light), .fullBleed(hairline: false))
        XCTAssertEqual(icon.treatment(on: backing(0.01...0.05)), .fullBleed(hairline: true))
    }

    func testRestoredPageReceivesInitialFocusInsteadOfChrome() async throws {
        let controller = BrowserController(testing: true); defer { controller.shutdown() }
        let tab = try XCTUnwrap(controller.session.selectedTab)
        tab.webView.loadHTMLString("<title>Initial page focus</title><body>Page</body>", baseURL: URL(string: "https://focus.example"))
        for _ in 0..<100 {
            if tab.webView.title == "Initial page focus", !tab.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let window = window(controller, solid: true); defer { window.close() }
        try await settle()
        XCTAssertTrue(window.initialFirstResponder === tab.webView)
        XCTAssertTrue(window.firstResponder === tab.webView, "Restored-page launch must not focus the sidebar toggle")
    }

    func testTitleAndHostSearchIncludesPinsAndPrivateWithoutOpeningWebViews() throws {
        let title = BrowserTab(record: TabRecord(title: "Field Guide", url: URL(string: "https://notes.example/story"), isPinned: true))
        let host = BrowserTab(record: TabRecord(title: "Reading", url: URL(string: "https://field.example/book")))
        let privateTab = BrowserTab(record: TabRecord(title: "Private field", url: URL(string: "https://private.example")), isPrivate: true)
        defer { [title, host, privateTab].forEach { $0.close() } }
        let tabs = [title, host, privateTab]
        func matching(_ text: String, isPrivate: Bool = false) -> [UUID] {
            let query = SidebarTabQuery(text: text, isPrivate: isPrivate)
            return tabs.filter { query.matches($0) }.map(\.id)
        }
        XCTAssertEqual(matching(" FiELd "), [title.id, host.id])
        XCTAssertEqual(matching("field", isPrivate: true), [privateTab.id])
        XCTAssertEqual(matching("notes.example"), [title.id])
        XCTAssertTrue(matching("absent").isEmpty)
        XCTAssertEqual(matching("  ").count, 2)
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
        XCTAssertTrue(SidebarTabs.drop(payload(privateTab), on: .pinned(true, isPrivate: true), controller: controller))
        XCTAssertEqual(s.orderedTabs[2].id, privateTab.id)
        XCTAssertFalse(s.snapshot().tabs.contains { $0.id == privateTab.id })
        XCTAssertFalse(SidebarTabs.drop(payload(privateTab), on: .between(second.id, after: true), controller: controller))
        XCTAssertFalse(SidebarTabs.drop(payload(privateTab), on: .pinned(false), controller: controller))
        XCTAssertTrue(SidebarTabs.drop(payload(privateTab), on: .pinned(false, isPrivate: true), controller: controller))
        XCTAssertFalse(privateTab.isPinned)
        XCTAssertFalse(SidebarTabs.drop([SidebarTabTransfer(id: first.id, owner: UUID())], on: .pinned(true), controller: controller))
        XCTAssertTrue(SidebarTabs.drop(payload(second), on: .pinned(false), controller: controller))
        XCTAssertFalse(second.isPinned)
        XCTAssertEqual(s.orderedTabs.map(\.id), [third.id, first.id, second.id, privateTab.id])
    }
    func testDuplicateTitleRowsShowHostsOnlyWhileBothMatch() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = TabRecord()
        let first = TabRecord(title: "Project", url: URL(string: "https://alpha.research-and-development.example"))
        let second = TabRecord(title: "Project", url: URL(string: "https://beta.research-and-development.example"))
        let unique = TabRecord(title: "Reference", url: URL(string: "https://reference.example"))
        try SessionFileStore(fileURL: BrowserProfile.personal.directory(in: root).appendingPathComponent("session.json"))
            .save(BrowserSnapshot(tabs: [home, first, second, unique], selectedTabID: home.id, legacyBookmarksImported: true))
        let c = BrowserController(rootDirectory: root, testing: true)
        let w = window(c, solid: true)
        defer { w.contentView = nil; w.close(); c.shutdown() }
        func marker(_ name: String, _ id: UUID) -> NSView? {
            w.contentView.flatMap { views($0).first { $0.identifier?.rawValue == "\(name)-\(id)" } }
        }
        try await waitUntil("Both duplicate hosts are rendered") {
            marker("sidebarHost", first.id) != nil && marker("sidebarHost", second.id) != nil
        }
        XCTAssertNil(marker("sidebarHost", unique.id))
        for record in [first, second, unique] {
            let row = try XCTUnwrap(marker("sidebarItem", record.id))
            XCTAssertEqual(row.bounds.height, OrivLayout.tabRowHeight, accuracy: 1)
            XCTAssertEqual(row.accessibilityLabel()?.contains(record.url!.host!), true)
            if record.id != unique.id {
                let host = try XCTUnwrap(marker("sidebarHost", record.id))
                let close = try XCTUnwrap(marker("sidebarClose", record.id))
                let hostFrame = host.convert(host.bounds, to: row)
                let closeFrame = close.convert(close.bounds, to: row)
                XCTAssertGreaterThan(hostFrame.width, 100)
                XCTAssertTrue(row.bounds.contains(hostFrame))
                XCTAssertTrue(row.bounds.contains(closeFrame))
                XCTAssertLessThanOrEqual(hostFrame.maxX, closeFrame.minX)
            }
        }
        let list = try XCTUnwrap(w.contentView.flatMap { views($0).compactMap { $0 as? SidebarTabCollection }.first })
        c.tabSearch = "beta.research"
        try await waitUntil("The native list contains only the matching result") {
            list.sidebar?.path(for: first.id) == nil && list.sidebar?.path(for: second.id) != nil
        }
        let path = try XCTUnwrap(list.sidebar?.path(for: second.id))
        list.sidebar?.revealItem(at: path)
        try await waitUntil("A single remaining match drops the subtitle") {
            guard let row = list.item(at: path)?.view else { return false }
            return row.accessibilityLabel()?.contains("beta.research") == true &&
                !self.views(row).contains { $0.identifier?.rawValue == "sidebarHost-\(second.id)" }
        }
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
        let privateTab = try XCTUnwrap(c.session.selectedTab)
        SidebarTabs.perform(.pin, tab: privateTab, controller: c)
        XCTAssertTrue(privateTab.isPinned)
        let menu = SidebarCollectionData().menu(for: privateTab).items.map(\.title)
        for command in ["Unpin Tab", "Move Up", "Move Down", "Close Tab"] { XCTAssertTrue(menu.contains(command)) }
        SidebarTabs.perform(.pin, tab: privateTab, controller: c)
        XCTAssertFalse(privateTab.isPinned)
        second.recordFieldEdit()
        XCTAssertTrue(c.session.requiresCloseConfirmation(second.id))
        SidebarTabs.perform(.close, tab: first, controller: c)
        XCTAssertFalse(c.session.tabs.contains { $0.id == first.id })
    }
    func testNativePageMenuReloadAndMuteTargetTheClickedTab() async throws {
        let c = BrowserController(testing: true)
        let home = try XCTUnwrap(c.session.selectedTab)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:8768/quality"))
        let tab = c.session.addTab(url: url, select: false, load: false)
        tab.activate()
        let w = window(c, solid: true)
        defer { w.contentView = nil; w.close(); c.shutdown() }
        try await waitUntil("The fixture finishes loading") {
            tab.webView.url == url && !tab.isLoading &&
                w.contentView.map { self.views($0).contains { $0 is SidebarTabCollection } } == true
        }
        let list = try XCTUnwrap(w.contentView.flatMap { views($0).compactMap { $0 as? SidebarTabCollection }.first })
        let data = try XCTUnwrap(list.sidebar)
        func invoke(_ title: String) throws {
            let menu = data.menu(for: tab)
            let item = try XCTUnwrap(menu.item(withTitle: title))
            menu.performActionForItem(at: menu.index(of: item))
        }
        for title in ["Reload", "Copy Link", "Mute Tab"] {
            XCTAssertNil(data.menu(for: home).item(withTitle: title))
            XCTAssertNotNil(data.menu(for: tab).item(withTitle: title))
        }
        let revision = tab.documentRevision
        try invoke("Reload")
        try await waitUntil("Reload starts a new navigation on the clicked tab") {
            tab.documentRevision > revision && !tab.isLoading
        }
        _ = try await tab.webView.evaluateJavaScript("""
            for (const [id, muted] of [['normalMedia', false], ['siteMuted', true]]) {
                const video = document.createElement('video');
                video.id = id; video.muted = muted;
                document.body.append(video); video.dispatchEvent(new Event('volumechange'));
            }
            """)
        func expectMute(_ expected: Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                let result = try await tab.webView.evaluateJavaScript(
                    "document.getElementById('normalMedia').muted === \(expected) && document.getElementById('siteMuted').muted"
                )
                if result as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            XCTFail("Media state did not follow the clicked tab’s mute command")
        }
        try invoke("Mute Tab")
        XCTAssertTrue(tab.isAudioMuted)
        try await expectMute(true)
        XCTAssertTrue(SidebarTabs.label(tab, selected: false).contains("Muted"))
        XCTAssertFalse(tab.mediaSuspended)
        try invoke("Unmute Tab")
        try await expectMute(false)
        XCTAssertEqual(c.session.selectedTabID, home.id)
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
    func testNativeArrowAndReturnEventsNavigateFromSearchThroughPinsAndRows() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTab), second = c.session.addTab(select: false, load: false)
        let regular = c.session.addTab(select: false, load: false)
        c.session.togglePinned(first.id); c.session.togglePinned(second.id)
        let w = window(c); defer { w.close() }; try await settle()
        c.searchTabs(); try await settle()
        func key(_ code: UInt16, _ text: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            if let list = w.firstResponder as? SidebarTabCollection { list.keyDown(with: event) }
            else { NSApp.sendEvent(event) }
        }
        try key(125, "\u{f701}"); try await settle() // Search -> first pin focus.
        try key(36, "\r"); try await settle(); XCTAssertEqual(c.session.selectedTabID, first.id)
        try key(124, "\u{f703}"); try await settle()
        XCTAssertEqual(c.session.selectedTabID, first.id)
        XCTAssertTrue(hasVisibleKeyboardFocus(second.id, in: w))
        try key(49, " "); XCTAssertEqual(c.session.selectedTabID, second.id)
        try key(119, "\u{f72b}"); try await settle()
        XCTAssertEqual(c.session.selectedTabID, second.id)
        XCTAssertTrue(hasVisibleKeyboardFocus(regular.id, in: w))
        try key(36, "\r"); XCTAssertEqual(c.session.selectedTabID, regular.id)
    }
    func testNativeArrowNavigationScrollsThroughSixtyRowsAndRail() async throws {
        try await checkNativeArrowNavigation(size: NSSize(width: 1000, height: 760))
    }

    func testNativeArrowNavigationInShortWindowsAtOnePointScale() async throws {
        for height in [520.0, 521.0, 600.0] {
            try await checkNativeArrowNavigation(size: NSSize(width: 840, height: height), displayScale: 1)
        }
    }

    private func checkNativeArrowNavigation(size: NSSize, displayScale: CGFloat? = nil) async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        for _ in 1..<60 { _ = c.session.addTab(select: false, load: false) }
        let tabs = c.session.orderedTabs
        let w = window(c, size: size, displayScale: displayScale)
        defer { w.contentViewController = nil; w.close() }
        print("SIDEBAR_FOCUS_ENV size=\(size) displayScale=\(String(describing: displayScale)) backingScale=\(w.backingScaleFactor) preferredScrollerStyle=\(NSScroller.preferredScrollerStyle.rawValue) CI=\(ProcessInfo.processInfo.environment["CI", default: ""])")
        try await waitUntil("Initial address field did not acquire its editor") {
            w.contentView.map { self.views($0).contains { ($0 as? FocusAwareAddressField)?.currentEditor() != nil } } == true
        }
        c.searchTabs()
        try await waitUntil("Search field did not acquire its editor") {
            w.firstResponder is NSTextView && w.contentView.map {
                let all = self.views($0)
                return !all.contains { ($0 as? FocusAwareAddressField)?.currentEditor() != nil } &&
                    all.contains { ($0 as? SidebarTabCollection)?.sidebar?.isSearching == true }
            } == true
        }
        func key(_ code: UInt16, _ text: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            if let list = w.firstResponder as? SidebarTabCollection { list.keyDown(with: event) }
            else { NSApp.sendEvent(event) }
        }
        try key(125, "\u{f701}")
        try await waitUntil("Search did not hand focus to the first row") { self.hasVisibleKeyboardFocus(tabs[0].id, in: w) }
        for index in 1..<60 {
            try key(125, "\u{f701}")
            try await waitUntil("Expanded arrow focus lost at row \(index)") {
                self.hasVisibleKeyboardFocus(tabs[index].id, in: w)
            }
        }
        try await waitUntil("Rebuilding the list after search lost the last highlighted row") {
            let list = w.firstResponder as? SidebarTabCollection
            return list?.sidebar?.isSearching == false && self.hasVisibleKeyboardFocus(tabs[59].id, in: w)
        }
        XCTAssertEqual(c.session.selectedTabID, tabs.first?.id)
        try key(36, "\r")
        try await waitUntil("Return did not activate the highlighted row") { c.session.selectedTabID == tabs[59].id }
        try toggleSidebar(in: w)
        try await waitUntil("Collapse did not lay out the rail and focus the surviving toggle") {
            guard let content = w.contentView else { return false }
            let all = self.views(content)
            return all.contains { $0.identifier?.rawValue == "sidebarToggleKeyboardFocus" } &&
                all.contains { ($0 as? SidebarTabCollection)?.sidebar?.isRail == true }
        }
        try key(125, "\u{f701}") // Toggle -> selected rail tab.
        try await waitUntil("Toggle did not hand focus to the selected rail row") { self.hasVisibleKeyboardFocus(tabs[59].id, in: w) }
        try checkFocusedRailViewport(tabs[59].id, in: w)
        for index in stride(from: 58, through: 0, by: -1) {
            try key(126, "\u{f700}")
            try await waitUntil("Rail arrow focus lost at row \(index)") {
                self.hasVisibleKeyboardFocus(tabs[index].id, in: w)
            }
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
    func testRailSearchPanelPreservesRailEscapeClearsAndSelectionClearsHiddenFilter() async throws {
        let c = BrowserController(testing: true); defer { c.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTab), second = c.session.addTab(url: URL(string: "https://search.example"), select: false, load: false)
        let w = window(c); defer { w.close() }; try await settle()
        c.compactSidebar = true; c.searchTabs(); try await settle()
        XCTAssertTrue(c.compactSidebar); XCTAssertTrue(c.tabSearchPanel)
        // A styled SwiftUI prompt need not be an NSTextField.placeholderString.
        // Verify the actual focused editor and its search binding instead.
        _ = try XCTUnwrap(w.firstResponder as? NSTextView)
        c.tabSearch = "search.example"; try await settle()
        XCTAssertEqual((w.firstResponder as? NSTextView)?.string, "search.example")
        XCTAssertEqual(c.tabSearchResults(c.tabSearchRequest).map(\.id), [second.id])
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
        XCTAssertFalse(labels.contains("Pinned, 0 tabs")); XCTAssertTrue(labels.contains("Tabs, 2 tabs"))
        let row = try XCTUnwrap(all.first { $0.accessibilityLabel() == SidebarTabs.label(first, selected: true) })
        XCTAssertEqual(row.accessibilityRole(), .row)
        XCTAssertTrue(row.accessibilityCustomActions()?.contains { $0.name == "Close Tab" } == true)
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
        let ci = ["CI", "GITHUB_ACTIONS"].contains {
            ["1", "true", "yes"].contains(ProcessInfo.processInfo.environment[$0, default: ""].lowercased())
        }
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = (0..<100).map { TabRecord(title: "Tab \($0)", url: URL(string: "https://site\($0).example"), isPinned: $0 < 10) }
        try SessionFileStore(fileURL: BrowserProfile.personal.directory(in: root).appendingPathComponent("session.json"))
            .save(BrowserSnapshot(tabs: records, selectedTabID: records[10].id, legacyBookmarksImported: true))
        let c = BrowserController(rootDirectory: root, testing: true); defer { c.shutdown() }
        // Sidebar-only host: the exact same 100 sleeping metadata records and no page loads.
        for solid in [true, false] {
            let w = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: MacBrowserLayout.sidebarWidth, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
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
            let measurement = "SIDEBAR_SCROLL tabs=100 solid=\(solid) samples=\(samples.count) p50_ms=\(sorted[sorted.count / 2]) p95_ms=\(p95) max_ms=\(sorted.last!) over16ms=\(samples.filter { $0 > 16.67 }.count) native_layout_only=true local_budget_enforced=\(!ci)"
            print(measurement)
            let attachment = XCTAttachment(string: measurement + "\nlayout_ms\n" + samples.map(String.init(describing:)).joined(separator: "\n"))
            attachment.name = "Sidebar scroll layout (\(solid ? "solid" : "glass"))"
            attachment.lifetime = .keepAlways
            add(attachment)
            // Hosted VMs record the same samples, but their scheduling latency
            // cannot establish the owner hardware's 60 Hz CPU budget.
            if !ci {
                XCTAssertLessThan(p95, 16.67, "Off-screen native scroll/layout CPU must fit a 60 Hz frame budget")
            }
            XCTAssertFalse(c.session.tabs.contains(where: \.isInstantiated), "Rows/search must never wake sleeping WebViews")
            w.contentView = nil; w.close()
        }
        for count in [12, 50, 100] {
            let tabs = Array(c.session.orderedTabs.prefix(count))
            let start = CACurrentMediaTime()
            for _ in 0..<100 {
                let query = SidebarTabQuery(text: "site9", isPrivate: false)
                _ = tabs.filter { query.matches($0) }
            }
            print("SIDEBAR_SEARCH tabs=\(count) mean_ms=\((CACurrentMediaTime() - start) * 10)")
        }
    }
}
