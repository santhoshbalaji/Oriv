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

    private final class MiniaturizedWindow: BackgroundUIMode.Window {
        var deminiaturizeCalls = 0
        override var isMiniaturized: Bool { true }
        override func deminiaturize(_ sender: Any?) { deminiaturizeCalls += 1 }
    }
}
