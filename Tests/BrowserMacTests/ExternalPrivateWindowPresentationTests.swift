import AppKit
import SwiftUI
import XCTest
@testable import PersonalBrowser

@MainActor final class ExternalPrivateWindowPresentationTests: BackgroundUITestCase {
    private func makeWindow(identifier: String = "external-private") -> NSWindow {
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 60, y: 60, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        return window
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        try await eventually("private window presentation", timeout: 2, poll: .milliseconds(20), condition)
    }

    func testEachRequestPresentsOwnWindowOnNextMainTurnAndDeduplicatesLayout() async {
        let window = makeWindow()
        var shown: [NSWindow] = []
        let presenter = ExternalPrivateWindowPresenter(present: { shown.append($0) })
        defer { presenter.cancel(); window.close() }
        presenter.request(0, in: window)
        presenter.request(1, in: window)
        XCTAssertTrue(shown.isEmpty)
        await nextMainTurn()
        XCTAssertEqual(shown, [window])
        presenter.request(1, in: window)
        await nextMainTurn()
        XCTAssertEqual(shown.count, 1)
        presenter.request(2, in: window)
        await nextMainTurn()
        XCTAssertEqual(shown, [window, window])
    }

    func testLateMainSceneKeyRetriesOnceAndLaterUserSelectionIsRespected() async {
        let center = NotificationCenter(), window = makeWindow(), main = makeWindow(identifier: "browser")
        var time: TimeInterval = 10, shown = 0
        let presenter = ExternalPrivateWindowPresenter(center: center, now: { time }, present: { _ in shown += 1 })
        defer { presenter.cancel(); window.close(); main.close() }
        presenter.request(1, in: window)
        await nextMainTurn()
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await nextMainTurn()
        XCTAssertEqual(shown, 1)
        time = 10.49
        center.post(name: NSWindow.didBecomeKeyNotification, object: main)
        XCTAssertEqual(shown, 1)
        await nextMainTurn()
        XCTAssertEqual(shown, 2)
        center.post(name: NSWindow.didBecomeKeyNotification, object: main)
        await nextMainTurn()
        XCTAssertEqual(shown, 2)
        presenter.request(2, in: window)
        await nextMainTurn()
        time = 11
        center.post(name: NSWindow.didBecomeKeyNotification, object: main)
        await nextMainTurn()
        XCTAssertEqual(shown, 3, "An expired request must not take focus back from the user")
    }

    func testSheetDefersInitialPresentationAndRaceCorrectionUntilDetached() async {
        let center = NotificationCenter(), window = makeWindow(), main = makeWindow(identifier: "browser")
        var blocked = true, shown = 0
        let presenter = ExternalPrivateWindowPresenter(center: center, hasBlockingSheet: { _ in blocked }, present: { _ in shown += 1 })
        defer { presenter.cancel(); window.close(); main.close() }
        presenter.request(1, in: window)
        await nextMainTurn()
        XCTAssertEqual(shown, 0)
        center.post(name: NSWindow.didEndSheetNotification, object: main)
        blocked = false // AppKit detaches after posting, before the next turn.
        await nextMainTurn()
        XCTAssertEqual(shown, 1)
        blocked = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: main)
        await nextMainTurn()
        XCTAssertEqual(shown, 1)
        blocked = false
        center.post(name: NSWindow.didEndSheetNotification, object: main)
        await nextMainTurn()
        XCTAssertEqual(shown, 2)
    }

    func testSupersededCancelledAndClosedRequestsCannotReopenWindow() async {
        let center = NotificationCenter(), window = makeWindow()
        var shown = 0
        let presenter = ExternalPrivateWindowPresenter(center: center, present: { _ in shown += 1 })
        defer { presenter.cancel(); window.close() }
        presenter.request(1, in: window)
        presenter.request(2, in: window)
        await nextMainTurn()
        XCTAssertEqual(shown, 1)
        presenter.request(3, in: window)
        presenter.cancel()
        await nextMainTurn()
        XCTAssertEqual(shown, 1)
        presenter.request(4, in: window)
        center.post(name: NSWindow.willCloseNotification, object: window)
        await nextMainTurn()
        XCTAssertEqual(shown, 1)
    }

    func testColdRequestSurvivesSceneAttachmentAndWarmRequestShowsExistingWindowInBackground() async throws {
        try XCTSkipUnless(BackgroundUIMode.isEnabled, "Background-only presentation policy regression")
        let profiles = BrowserProfiles(testing: true)
        profiles.handleIncomingURL(URL(string: "https://example.test/first")!)
        let context = try XCTUnwrap(profiles.externalPrivate)
        let window = makeWindow()
        window.contentViewController = NSHostingController(rootView: BrowserWindow(controller: context, profiles: profiles))
        defer { window.close(); profiles.shutdown() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitUntil { window.isVisible }
        window.orderOut(nil)
        profiles.handleIncomingURL(URL(string: "https://example.test/second")!)
        try await waitUntil { window.isVisible }
        XCTAssertTrue(profiles.externalPrivate === context)
        XCTAssertEqual(context.session.selectedTab?.url?.path, "/second")
        XCTAssertTrue(context.session.tabs.allSatisfy(\.isPrivate))
        XCTAssertTrue(BackgroundUIMode.isOutsideAllScreens(window.frame))
        XCTAssertFalse(NSApp.isActive)
        XCTAssertEqual(BackgroundUIMode.audit().activationViolations, 0)
    }

    func testBackgroundPresentationNeverDeminiaturizesOrActivates() async throws {
        try XCTSkipUnless(BackgroundUIMode.isEnabled, "Background-only presentation policy regression")
        let window = MiniaturizedWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let presenter = ExternalPrivateWindowPresenter()
        let initialDeminiaturizeCalls = window.deminiaturizeCalls
        defer { presenter.cancel(); window.close() }
        presenter.request(1, in: window)
        await nextMainTurn()
        XCTAssertEqual(window.deminiaturizeCalls, initialDeminiaturizeCalls)
        XCTAssertTrue(BackgroundUIMode.isOutsideAllScreens(window.frame))
        XCTAssertFalse(NSApp.isActive)
        XCTAssertEqual(BackgroundUIMode.audit().frontmostViolations, 0)
        XCTAssertEqual(BackgroundUIMode.audit().activationViolations, 0)
    }

    func testForegroundOrderingMinimizedWindowAndAttachedMainSheet() async throws {
        try XCTSkipIf(BackgroundUIMode.isEnabled || !BackgroundUIMode.foregroundAllowed, BackgroundUIMode.foregroundOnlyReason)
        let main = makeWindow(identifier: "browser"), window = makeWindow(), sheet = makeWindow(identifier: "sheet")
        let presenter = ExternalPrivateWindowPresenter()
        defer { presenter.cancel(); main.endSheet(sheet); sheet.close(); window.close(); main.close() }
        presenter.request(1, in: window)
        try await waitUntil { window.isKeyWindow && NSApp.isActive }
        BackgroundUIMode.show(main)
        try await waitUntil { window.isKeyWindow }
        XCTAssertTrue(NSApp.orderedWindows.first === window)
        window.miniaturize(nil)
        try await waitUntil { window.isMiniaturized }
        presenter.request(2, in: window)
        try await waitUntil { !window.isMiniaturized && window.isKeyWindow }
        try await Task.sleep(for: .milliseconds(550))
        BackgroundUIMode.show(main)
        main.beginSheet(sheet, completionHandler: nil)
        presenter.request(3, in: window)
        await nextMainTurn()
        XCTAssertTrue(main.attachedSheet === sheet)
        XCTAssertFalse(window.isKeyWindow)
        main.endSheet(sheet)
        try await waitUntil { main.attachedSheet == nil && window.isKeyWindow }
        XCTAssertTrue(NSApp.orderedWindows.first === window)
    }

    private func makeHostedBrowserWindow<V: View>(size: NSSize, identifier: String, rootView: V) -> NSWindow {
        let window = BackgroundUIMode.Window(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        window.setContentSize(size)
        BackgroundUIMode.show(window, key: false)
        return window
    }

    func testExternalPrivateHandoffBarGeometryNarrowCollapseAndActions() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        profiles.handleIncomingURL(URL(string: "https://example.test/handoff")!, sourceName: "Slack")
        let context = try XCTUnwrap(profiles.externalPrivate)
        let tab = try XCTUnwrap(context.session.selectedTab)
        tab.webView.loadHTMLString("<title>Handoff Fixture</title><body><p>External content</p></body>",
                                   baseURL: URL(string: "https://example.test/handoff"))

        let window = makeHostedBrowserWindow(
            size: NSSize(width: 1100, height: 740),
            identifier: "external-private",
            rootView: BrowserWindow(controller: context, profiles: profiles).browserAppearance(.light)
        )
        defer { window.close() }

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func marker(_ name: String) -> NSView? {
            window.contentView.flatMap(descendants)?.first { $0.identifier?.rawValue == name && !$0.bounds.isEmpty }
        }
        func markerFrame(_ name: String) throws -> NSRect {
            let view = try XCTUnwrap(marker(name), "Missing geometry marker \(name)")
            return view.convert(view.bounds, to: nil)
        }

        try await eventually("external private handoff bar mounted", timeout: 5, poll: .milliseconds(25)) {
            window.contentView?.layoutSubtreeIfNeeded()
            return marker("externalPrivateBarGeometry") != nil
                && marker("browserTopBarGeometry") != nil
                && marker("sidebarSection-Private") != nil
                && marker("externalPrivateNoticeGeometry") != nil
                && marker("externalMoveProfileGeometry") != nil
                && marker("moveExternalPageGeometry") != nil
                && marker("keepExternalPrivateGeometry") != nil
                && tab.webView.superview != nil
                && !tab.webView.bounds.isEmpty
        }

        let barFrame = try markerFrame("externalPrivateBarGeometry")
        let toolbarFrame = try markerFrame("browserTopBarGeometry")
        let webFrame = tab.webView.convert(tab.webView.bounds, to: nil)

        XCTAssertEqual(barFrame.height, OrivMacV3.ToolbarLayout.handoffHeight, accuracy: 1, "Handoff bar must be 44 pt single-line")
        XCTAssertLessThanOrEqual(barFrame.maxY, toolbarFrame.minY + 1, "Handoff bar must sit below toolbar without overlap")
        XCTAssertLessThanOrEqual(webFrame.maxY, barFrame.minY + 1, "Page content must start below the handoff bar")
        XCTAssertEqual(toolbarFrame.height, OrivMacV3.ToolbarLayout.overlayHeight, accuracy: 1, "Handoff bar must not push or resize toolbar")

        let wideBarFrame = try markerFrame("externalPrivateBarGeometry")
        let wideControlWidths = try ["externalMoveProfileGeometry", "moveExternalPageGeometry", "keepExternalPrivateGeometry"]
            .map { try markerFrame($0).width }
        XCTAssertEqual(barFrame.height, wideBarFrame.height)
        XCTAssertEqual(try markerFrame("keepExternalPrivateGeometry").height, OrivMacV3.ToolbarLayout.handoffControlHeight, accuracy: 1)
        XCTAssertEqual(try markerFrame("moveExternalPageGeometry").height, OrivMacV3.ToolbarLayout.handoffControlHeight, accuracy: 1)

        let wideNoticeWidth = try markerFrame("externalPrivateNoticeGeometry").width
        func assertSingleLineBar(_ context: String) throws -> NSRect {
            let bar = try markerFrame("externalPrivateBarGeometry")
            XCTAssertEqual(bar.height, OrivMacV3.ToolbarLayout.handoffHeight, accuracy: 1, "\(context): bar stays single-line 44 pt")
            XCTAssertLessThanOrEqual(bar.maxY, try markerFrame("browserTopBarGeometry").minY + 1, "\(context): bar never overlaps the toolbar")
            XCTAssertEqual(try markerFrame("browserTopBarGeometry").height, OrivMacV3.ToolbarLayout.overlayHeight, accuracy: 1)
            XCTAssertLessThanOrEqual(tab.webView.convert(tab.webView.bounds, to: nil).maxY, bar.minY + 1, "\(context): page starts below the bar")
            var previousMaxX = bar.minX
            for id in ["externalPrivateNoticeGeometry", "externalMoveProfileGeometry", "moveExternalPageGeometry", "keepExternalPrivateGeometry"] {
                let rect = try markerFrame(id)
                XCTAssertGreaterThanOrEqual(rect.width, OrivMacV3.ToolbarLayout.handoffControlHeight - 1, "\(context): \(id) stays visible")
                XCTAssertGreaterThanOrEqual(rect.minX, previousMaxX - 1, "\(context): \(id) must not overlap its leading neighbour")
                XCTAssertLessThanOrEqual(rect.maxX, bar.maxX + 1, "\(context): \(id) must not clip past the trailing bar edge")
                XCTAssertGreaterThanOrEqual(rect.minY, bar.minY - 1); XCTAssertLessThanOrEqual(rect.maxY, bar.maxY + 1)
                previousMaxX = rect.maxX
            }
            return bar
        }
        _ = try assertSingleLineBar("wide")

        // A long source name in a medium window: only the label truncates; every button keeps its full width.
        profiles.externalSourceName = "Very Long Messenger Application Name For Handoff Testing"
        window.setContentSize(NSSize(width: 1000, height: 680))
        try await eventually("medium handoff layout", timeout: 4, poll: .milliseconds(25)) {
            window.contentView?.layoutSubtreeIfNeeded()
            guard abs((window.contentView?.bounds.width ?? 0) - 1000) <= 1,
                  let bar = marker("externalPrivateBarGeometry") else { return false }
            return bar.convert(bar.bounds, to: nil).width < wideBarFrame.width - 50
        }
        _ = try assertSingleLineBar("medium")
        for (id, wideWidth) in zip(["externalMoveProfileGeometry", "moveExternalPageGeometry", "keepExternalPrivateGeometry"], wideControlWidths) {
            XCTAssertEqual(try markerFrame(id).width, wideWidth, accuracy: 1, "\(id) keeps its full width; the label truncates first")
        }
        XCTAssertLessThan(try markerFrame("externalPrivateNoticeGeometry").width, wideNoticeWidth + 200,
                          "The long source name is truncated rather than widening the bar")

        // Narrowest app window (760 pt, PersonalBrowserApp minWidth): still one 44 pt line, nothing clipped;
        // the profile picker and Move keep their full labels.
        window.setContentSize(NSSize(width: 760, height: 640))
        try await eventually("narrow handoff layout", timeout: 4, poll: .milliseconds(25)) {
            window.contentView?.layoutSubtreeIfNeeded()
            guard abs((window.contentView?.bounds.width ?? 0) - 760) <= 1,
                  let bar = marker("externalPrivateBarGeometry") else { return false }
            return bar.convert(bar.bounds, to: nil).width < wideBarFrame.width - 200
        }
        _ = try assertSingleLineBar("narrow")
        XCTAssertEqual(try markerFrame("externalMoveProfileGeometry").width, wideControlWidths[0], accuracy: 1)
        XCTAssertEqual(try markerFrame("moveExternalPageGeometry").width, wideControlWidths[1], accuracy: 1)

        // Nil sourceName fallback renders cleanly without crashing or dropping the notice.
        profiles.externalSourceName = nil
        try await eventually("unknown source fallback still mounted", timeout: 3, poll: .milliseconds(25)) {
            window.contentView?.layoutSubtreeIfNeeded()
            return marker("externalPrivateNoticeGeometry") != nil
        }

        // Dismiss (Keep Private) removes the bar while keeping the private tab open.
        profiles.externalBannerVisible = false
        try await eventually("handoff bar dismissed", timeout: 3, poll: .milliseconds(25)) {
            window.contentView?.layoutSubtreeIfNeeded()
            return marker("externalPrivateBarGeometry") == nil
        }
        XCTAssertEqual(context.session.tabs.count, 1)

        // Re-show and verify Move to selected profile moves the URL and closes the private tab.
        profiles.externalBannerVisible = true
        profiles.externalMoveProfileID = work.id
        try await eventually("handoff bar restored", timeout: 3, poll: .milliseconds(25)) {
            window.contentView?.layoutSubtreeIfNeeded()
            return marker("moveExternalPageGeometry") != nil
        }
        try profiles.moveExternalTab()
        XCTAssertEqual(profiles.active.id, work.id)
        XCTAssertNil(profiles.externalPrivate)
        XCTAssertEqual(profiles.controller.session.selectedTab?.url?.path, "/handoff")
        XCTAssertEqual(profiles.controller.session.selectedTab?.isPrivate, false)
    }

    func testRegularWindowWithPrivateTabDoesNotSwitchToAmethystDusk() async throws {
        // Binding Q5: only standalone/external Private windows switch backdrop/sidebar to Amethyst Dusk.
        XCTAssertEqual(OrivMacV3.AppearanceMode.resolve(theme: .graphite, colorScheme: .light, isPrivateWindow: false), .light)
        XCTAssertEqual(OrivMacV3.AppearanceMode.resolve(theme: .graphite, colorScheme: .dark, isPrivateWindow: false), .dark)
        XCTAssertEqual(OrivMacV3.AppearanceMode.resolve(theme: .t3Code, colorScheme: .dark, isPrivateWindow: false), .black)
        XCTAssertEqual(OrivMacV3.AppearanceMode.resolve(theme: .graphite, colorScheme: .light, isPrivateWindow: true), .private)
        XCTAssertEqual(OrivMacV3.AppearanceMode.resolve(theme: .t3Code, colorScheme: .dark, isPrivateWindow: true), .private)

        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let regularController = profiles.controller
        regularController.appearance = .light
        _ = regularController.session.addTab(isPrivate: true, select: true, load: false)

        let regularWindow = makeHostedBrowserWindow(
            size: NSSize(width: 1000, height: 700),
            identifier: "browser",
            rootView: BrowserWindow(controller: regularController, profiles: profiles).browserAppearance(.light)
        )
        defer { regularWindow.close() }

        let privateID = profiles.createPrivateWindow()
        let privateController = try XCTUnwrap(profiles.privateWindows[privateID])
        privateController.appearance = .light
        let privateWindow = makeHostedBrowserWindow(
            size: NSSize(width: 1000, height: 700),
            identifier: "private-browser",
            rootView: BrowserWindow(controller: privateController).browserAppearance(.light)
        )
        defer { privateWindow.close() }

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func marker(_ name: String, in window: NSWindow) -> NSView? {
            window.contentView.flatMap(descendants)?.first { $0.identifier?.rawValue == name && !$0.bounds.isEmpty }
        }

        try await eventually("regular mixed-private and standalone private windows mounted", timeout: 5, poll: .milliseconds(25)) {
            regularWindow.contentView?.layoutSubtreeIfNeeded()
            privateWindow.contentView?.layoutSubtreeIfNeeded()
            return marker("privateAddressPillGeometry", in: regularWindow) != nil
                && marker("sidebarSurfaceGeometry", in: regularWindow) != nil
                && marker("privateAddressPillGeometry", in: privateWindow) != nil
                && marker("sidebarSection-Private", in: privateWindow) != nil
                && marker("sidebarSurfaceGeometry", in: privateWindow) != nil
        }

        func samplePixel(in window: NSWindow, point: NSPoint) throws -> NSColor {
            let content = try XCTUnwrap(window.contentView)
            let rect = NSRect(x: point.x, y: point.y, width: 2, height: 2)
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: rect))
            content.cacheDisplay(in: rect, to: bitmap)
            return try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        }
        func luminance(_ color: NSColor) -> Double {
            func linear(_ c: CGFloat) -> Double { c <= 0.04045 ? Double(c) / 12.92 : pow((Double(c) + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }

        // Sample the outer 8 pt backdrop margin and the sidebar body in both windows.
        let regularBackdrop = try samplePixel(in: regularWindow, point: NSPoint(x: 2, y: 200))
        let regularSidebar = try samplePixel(in: regularWindow, point: NSPoint(x: 120, y: 200))
        let privateBackdrop = try samplePixel(in: privateWindow, point: NSPoint(x: 2, y: 200))
        let privateSidebar = try samplePixel(in: privateWindow, point: NSPoint(x: 120, y: 200))

        // Regular Light window with private tab selected keeps a light backdrop & sidebar.
        XCTAssertGreaterThan(luminance(regularBackdrop), 0.55, "Regular Light window backdrop must stay light with a private tab selected")
        XCTAssertGreaterThan(luminance(regularSidebar), 0.55, "Regular Light window sidebar must stay light with a private tab selected")

        // Standalone Private window switches both backdrop and sidebar to dark Amethyst Dusk (purple: blue > green).
        XCTAssertLessThan(luminance(privateBackdrop), 0.15, "Private window backdrop must be dark Amethyst Dusk")
        XCTAssertLessThan(luminance(privateSidebar), 0.15, "Private window sidebar must be dark Amethyst Dusk")
        XCTAssertGreaterThan(privateSidebar.blueComponent, privateSidebar.greenComponent, "Private window sidebar must carry Amethyst Dusk purple hue")

        // Private windows draw their traffic lights for the dark Amethyst chrome; the regular window keeps the app appearance.
        try await eventually("window control appearance", timeout: 3, poll: .milliseconds(25)) {
            privateWindow.standardWindowButton(.closeButton)?.appearance?.name == .darkAqua
        }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(privateWindow.standardWindowButton(type)?.appearance?.name, .darkAqua)
            XCTAssertNil(regularWindow.standardWindowButton(type)?.appearance, "Q5: a private tab never restyles regular window controls")
        }
    }

    private final class MiniaturizedWindow: BackgroundUIMode.Window {
        var deminiaturizeCalls = 0
        override var isMiniaturized: Bool { true }
        override func deminiaturize(_ sender: Any?) { deminiaturizeCalls += 1 }
    }
}
