import AppKit
import BrowserEngine
import ObjectiveC
import SwiftUI
import WebKit
import XCTest
@testable import PersonalBrowser

/// Real off-screen browser-window input with the production label and button
/// style. A DEBUG presentation substitute avoids screen-constrained AppKit menu
/// windows; native menu tracking and keyboard navigation remain separate checks.
@MainActor final class PageMenuTests: BackgroundUITestCase {
    private final class Presentations {
        var count = 0
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func marker(_ name: String, in window: NSWindow) -> NSView? {
        window.contentView.flatMap { descendants($0).first { $0.identifier?.rawValue == name } }
    }
    private func makeWindow(_ controller: BrowserController, probe: Presentations, width: CGFloat = 1000) -> NSWindow {
        let host = NSHostingController(rootView: BrowserWindow(controller: controller)
            .browserAppearance(.t3Code)
            .environment(\.pageMenuPresentationProbe, { probe.count += 1 }))
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: width, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: width, height: 650))
        BackgroundUIMode.show(window, key: true)
        return window
    }
    private func click(_ point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
    func testPageMenuGlassPaddingAndEdgesReceiveClicks() async throws {
        let controller = BrowserController(testing: true); defer { controller.shutdown() }
        let probe = Presentations()
        let window = makeWindow(controller, probe: probe); defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        let button = try XCTUnwrap(marker("browserPageMenuGeometry", in: window))
        XCTAssertEqual(button.bounds.width, 36, accuracy: 0.5)
        XCTAssertEqual(button.bounds.height, 32, accuracy: 0.5)
        // Prevent a regressed padding hit from entering a WindowServer drag loop.
        let original = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, #selector(NSWindow.performDrag(with:))))
        let replacement = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, #selector(NSWindow.pageMenuTestDrag(with:))))
        method_exchangeImplementations(original, replacement)
        defer { method_exchangeImplementations(original, replacement) }
        for width: CGFloat in [1000, 760] {
            window.setContentSize(NSSize(width: width, height: 650))
            try await Task.sleep(for: .milliseconds(150))
            for point in [NSPoint(x: 18,y: 16), NSPoint(x: 2,y: 16), NSPoint(x: 34,y: 16),
                          NSPoint(x: 18,y: 2), NSPoint(x: 18,y: 30), NSPoint(x: 2,y: 2),
                          NSPoint(x: 34,y: 30), NSPoint(x: 6,y: 8), NSPoint(x: 30,y: 24)] {
                let count = probe.count
                controller.focusAddress()
                try await Task.sleep(for: .milliseconds(50))
                try click(button.convert(point, to: nil), in: window)
                try await Task.sleep(for: .milliseconds(50))
                // The fallback lets this same assertion measure the pre-fix overlay
                // with only its diagnostic geometry marker added.
                let opened = probe.count - count + (marker("browserPageMenuPanelGeometry", in: window) == nil ? 0 : 1)
                XCTAssertEqual(opened, 1, "Menu must open exactly once at \(point), width \(width)")
                print("PAGE_MENU_CLICK width=\(width) point=\(point) presentations=\(opened)")
            }
        }
    }

    func testRepeatedClicksWithPageFocusAndInactiveWindow() async throws {
        let controller = BrowserController(testing: true); defer { controller.shutdown() }
        let tab = try XCTUnwrap(controller.session.selectedTab)
        tab.webView.loadHTMLString("<body><input id='edit' value='Page focus'></body>", baseURL: URL(string: "https://fixture.invalid/menu"))
        let probe = Presentations()
        let window = makeWindow(controller, probe: probe); defer { window.close() }
        try await Task.sleep(for: .milliseconds(700))
        let button = try XCTUnwrap(marker("browserPageMenuGeometry", in: window))
        for index in 0..<20 {
            window.makeFirstResponder(tab.webView)
            _ = try await tab.webView.evaluateJavaScript("document.querySelector('#edit').focus()")
            if index >= 10 { window.resignKey(); XCTAssertFalse(window.isKeyWindow) }
            XCTAssertFalse(NSApp.isActive)
            let count = probe.count
            try click(button.convert(NSPoint(x: 18,y: 16), to: nil), in: window)
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(probe.count, count + 1, "Each press after dismissal must open exactly once (\(index))")
        }
        XCTAssertEqual(probe.count, 20)
    }

}

private extension NSWindow {
    @objc func pageMenuTestDrag(with event: NSEvent) {}
}
