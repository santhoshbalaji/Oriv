import AppKit
import XCTest
@testable import PersonalBrowser

class BackgroundUITestCase: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await BackgroundRunObserver.install()
    }
    override func tearDown() async throws {
        await MainActor.run {
            guard BackgroundUIMode.isEnabled else { return }
            let audit = BackgroundUIMode.audit()
            XCTAssertEqual(audit.frontmostViolations, 0, "Test app became frontmost during this run")
            XCTAssertEqual(audit.activationViolations, 0, "Test app activated during this run")
            XCTAssertEqual(audit.onscreenWindowViolations, 0, "A test-app window overlapped a display during this run")
            print("Background UI audit: \(audit.samples) frontmost checks, \(audit.windowFrameSamples) frame checks, \(audit.frontmostViolations) frontmost / \(audit.activationViolations) activation / \(audit.onscreenWindowViolations) display violations")
        }
        try await super.tearDown()
    }
}

/// Cover shared compatibility cases too, including the privacy fixtures.
private final class BackgroundRunObserver: NSObject, XCTestObservation, @unchecked Sendable {
    private static let shared = BackgroundRunObserver()
    @MainActor private var registered = false
    @MainActor static func install() {
        guard !shared.registered else { return }
        shared.registered = true
        XCTestObservationCenter.shared.addTestObserver(shared)
    }
    @MainActor private static func check(final: Bool = false) {
        guard BackgroundUIMode.isEnabled else { return }
        let audit = BackgroundUIMode.audit()
        XCTAssertEqual(audit.frontmostViolations, 0)
        XCTAssertEqual(audit.activationViolations, 0)
        XCTAssertEqual(audit.onscreenWindowViolations, 0)
        XCTAssertFalse(NSApp.isActive)
        if final, let data = try? JSONEncoder().encode(audit) {
            print("BACKGROUND_UI_FINAL: \(String(decoding: data, as: UTF8.self))")
        }
    }
    private func checkOnMain(final: Bool = false) {
        if Thread.isMainThread { MainActor.assumeIsolated { Self.check(final: final) } }
        else { DispatchQueue.main.sync { MainActor.assumeIsolated { Self.check(final: final) } } }
    }
    func testCaseDidFinish(_ testCase: XCTestCase) { checkOnMain() }
    func testBundleDidFinish(_ testBundle: Bundle) { checkOnMain(final: true) }
}

@MainActor final class BackgroundUIModeTests: BackgroundUITestCase {
    func testNativeSchemeDefaultsToBackgroundBeforeWindows() throws {
        try XCTSkipIf(BackgroundUIMode.foregroundAllowed, "Background-only policy regression; foreground override is active")
        XCTAssertTrue(BackgroundUIMode.isEnabled)
        XCTAssertFalse(BackgroundUIMode.foregroundAllowed)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "browser" && $0.isVisible }, "Background launch must suppress the regular SwiftUI browser window")
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
    }

    func testKeyWindowsStayBehindOwnerWithoutActivation() async throws {
        try XCTSkipIf(BackgroundUIMode.foregroundAllowed, "Background-only policy regression; foreground override is active")
        XCTAssertTrue(BackgroundUIMode.isEnabled, "The native test scheme must enable background UI")
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 60, y: 60, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        BackgroundUIMode.show(window, key: true, activate: true)
        for _ in 0..<10 {
            XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
            XCTAssertFalse(NSApp.isActive)
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertTrue(window.contentView?.wantsLayer == true)
        XCTAssertTrue(BackgroundUIMode.isOutsideAllScreens(window.frame))
        let audit = BackgroundUIMode.audit()
        XCTAssertEqual(audit.frontmostViolations, 0)
        XCTAssertEqual(audit.activationViolations, 0)
        XCTAssertEqual(audit.onscreenWindowViolations, 0)
        XCTAssertGreaterThan(audit.samples, 0)
    }

    func testFrameRequestsAndResizingCannotMoveWindowOntoAnyDisplay() async throws {
        try XCTSkipIf(BackgroundUIMode.foregroundAllowed, "Background-only placement regression")
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertTrue(BackgroundUIMode.isOutsideAllScreens(window.frame))
        BackgroundUIMode.show(window)
        for screen in NSScreen.screens {
            window.setFrame(screen.frame, display: true)
            XCTAssertTrue(BackgroundUIMode.isOutsideAllScreens(window.frame))
            window.setFrame(screen.frame, display: true, animate: true)
            XCTAssertTrue(BackgroundUIMode.isOutsideAllScreens(window.frame))
            window.setFrameOrigin(screen.frame.origin)
            XCTAssertTrue(BackgroundUIMode.isOutsideAllScreens(window.frame))
            window.setFrameTopLeftPoint(NSPoint(x: screen.frame.minX, y: screen.frame.maxY))
            XCTAssertTrue(BackgroundUIMode.isOutsideAllScreens(window.frame))
            window.center()
            XCTAssertTrue(BackgroundUIMode.isOutsideAllScreens(window.frame))
            window.setContentSize(NSSize(width: 1000, height: 700))
            XCTAssertTrue(BackgroundUIMode.isOutsideAllScreens(window.frame))
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertEqual(BackgroundUIMode.audit().onscreenWindowViolations, 0)
    }
}
