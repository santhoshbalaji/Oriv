import AppKit
import XCTest
@testable import PersonalBrowser

/// Registers a guard for every subsequent case, not just the privacy fixtures.
@MainActor final class BackgroundUIModeTests: XCTestCase {
    override func setUp() async throws { BackgroundRunObserver.install() }
    func testLaunchAndBackgroundWindowsNeverActivateTheTestHost() async throws {
        XCTAssertTrue(BackgroundUIMode.isEnabled, "Native Mac test scheme must default ORIV_BACKGROUND_UI=1")
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        BackgroundUIMode.present(window, key: false)
        XCTAssertTrue(window.ignoresMouseEvents)
        try await Task.sleep(for: .milliseconds(250))
        BackgroundRunObserver.check()
    }
}

private final class BackgroundRunObserver: NSObject, XCTestObservation, @unchecked Sendable {
    private static let shared = BackgroundRunObserver()
    @MainActor private var registered = false
    @MainActor static func install() {
        guard !shared.registered else { return }
        shared.registered = true
        XCTestObservationCenter.shared.addTestObserver(shared)
    }
    @MainActor static func check() {
        guard BackgroundUIMode.isEnabled else { return }
        XCTAssertEqual(BackgroundUIMode.activationViolationCount, 0, "A background Mac test/capture host became frontmost")
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier,
                          "The test host must never take the owner's focus")
        XCTAssertFalse(NSApp.isActive)
    }
    func testCaseDidFinish(_ testCase: XCTestCase) {
        if Thread.isMainThread { MainActor.assumeIsolated { Self.check() } }
        else { DispatchQueue.main.sync { MainActor.assumeIsolated { Self.check() } } }
    }
}
