import AppKit
import BrowserCore
import SwiftUI
import XCTest
@testable import PersonalBrowser

final class ProfileSwipeTests: XCTestCase {
    private struct Gesture {
        var swipe = ProfileSwipe()
        var time: TimeInterval = 0

        mutating func send(_ phase: ProfileSwipe.Phase, x: CGFloat = 0, y: CGFloat = 0,
                           after interval: TimeInterval = 0.02, eligible: Bool = true,
                           previous: Bool = true, next: Bool = true, presentation: CGFloat = 0) -> ProfileSwipe.Result {
            time += interval
            return swipe.update(phase, dx: x, dy: y, at: time, eligible: eligible, width: 240,
                                previous: previous, next: next, presentationOffset: presentation)
        }
    }

    func testVerticalLockPassesThroughEvenAfterLargeHorizontalDelta() {
        var gesture = Gesture()
        XCTAssertEqual(gesture.send(.began, x: -3, y: 1), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -3, y: 3), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -180), .pass)
        XCTAssertEqual(gesture.send(.ended), .pass)
        XCTAssertEqual(gesture.send(.momentum, x: -80), .pass)
    }

    func testDistanceAndMomentum() {
        var gesture = Gesture()
        XCTAssertEqual(gesture.send(.began, x: -4), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -126), .track(-130))
        XCTAssertEqual(gesture.send(.ended, after: 0.2), .settle(step: 1))
        XCTAssertEqual(gesture.send(.momentum, x: -100), .swallow)
        XCTAssertEqual(gesture.send(.began, y: 8), .pass)
        XCTAssertEqual(gesture.send(.momentum, x: -80), .pass)
    }

    func testFlickRequiresDistanceSpeedAndDirection() {
        var gesture = Gesture()
        XCTAssertEqual(gesture.send(.began), .pass)
        XCTAssertEqual(gesture.send(.changed, x: 32), .track(32))
        XCTAssertEqual(gesture.send(.ended), .settle(step: -1))
        XCTAssertEqual(gesture.send(.began), .pass)
        XCTAssertEqual(gesture.send(.changed, x: 23), .track(23))
        XCTAssertEqual(gesture.send(.ended), .settle(step: nil))
        XCTAssertEqual(gesture.send(.began), .pass)
        XCTAssertEqual(gesture.send(.changed, x: 50), .track(50))
        XCTAssertEqual(gesture.send(.changed, x: -15), .track(35))
        XCTAssertEqual(gesture.send(.ended), .settle(step: nil))
        XCTAssertEqual(gesture.send(.began), .pass)
        XCTAssertEqual(gesture.send(.changed, x: 32), .track(32))
        XCTAssertEqual(gesture.send(.ended, after: 0.2), .settle(step: nil))
    }

    func testEdgeRubberBandDoesNotWrapAndCanReverse() {
        var gesture = Gesture()
        XCTAssertEqual(gesture.send(.began, previous: false), .pass)
        guard case .track(let small) = gesture.send(.changed, x: 30, previous: false),
              case .track(let large) = gesture.send(.changed, x: 500, previous: false) else {
            return XCTFail("Expected resisted tracking at the edge")
        }
        XCTAssertGreaterThan(small, 0)
        XCTAssertGreaterThan(large, small)
        XCTAssertLessThan(large, 72)
        XCTAssertEqual(gesture.send(.ended, previous: false), .settle(step: nil))
        XCTAssertEqual(gesture.send(.began, previous: false), .pass)
        _ = gesture.send(.changed, x: 30, previous: false)
        XCTAssertEqual(gesture.send(.changed, x: -154, previous: false), .track(-124))
        XCTAssertEqual(gesture.send(.ended, previous: false), .settle(step: 1))
    }

    func testInterruptionStartsAtPresentationOffsetAndCancellationNeverCommits() {
        var gesture = Gesture()
        XCTAssertEqual(gesture.send(.began), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -8, presentation: -112), .track(-120))
        XCTAssertEqual(gesture.send(.cancelled), .settle(step: nil))
        XCTAssertEqual(gesture.send(.momentum), .swallow)
    }

    func testIneligibleStartAndBlockerDuringTracking() {
        var gesture = Gesture()
        XCTAssertEqual(gesture.send(.began, eligible: false), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -180), .pass)
        XCTAssertEqual(gesture.send(.ended), .pass)
        XCTAssertEqual(gesture.send(.began), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -180), .track(-180))
        XCTAssertEqual(gesture.send(.ended, eligible: false), .settle(step: nil))
        XCTAssertEqual(gesture.send(.began), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -180), .track(-180))
        XCTAssertEqual(gesture.send(.changed, x: -20, eligible: false), .settle(step: nil))
    }

    func testSwipePreferenceOverridesTheSystemSetting() {
        XCTAssertFalse(ProfileSwipePreference.system.enabled(system: false))
        XCTAssertTrue(ProfileSwipePreference.system.enabled(system: true))
        XCTAssertTrue(ProfileSwipePreference.on.enabled(system: false))
        XCTAssertFalse(ProfileSwipePreference.off.enabled(system: true))
    }
}

@MainActor final class ProfileSwipeWindowTests: BackgroundUITestCase {
    private struct Fixture: View {
        let profiles: BrowserProfiles
        var body: some View {
            BrowserWindow(controller: profiles.controller, profiles: profiles).id(profiles.active.id)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func wheel(_ phase: NSEvent.Phase, x: Int32 = 0, y: Int32 = 0) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        // CoreGraphics has its own phase bit values.
        let phases: [UInt: Int64] = [NSEvent.Phase.began.rawValue: 1, NSEvent.Phase.changed.rawValue: 2,
                                      NSEvent.Phase.ended.rawValue: 4, NSEvent.Phase.cancelled.rawValue: 8]
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: try XCTUnwrap(phases[phase.rawValue]))
        XCTAssertEqual(NSEvent(cgEvent: event)?.phase, phase)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    func testSyntheticWindowRoutingKeepsGesturesInTheirStartingRegion() async throws {
        for rtl in [false, true] {
            let profiles = BrowserProfiles(testing: true)
            defer { profiles.shutdown() }
            profiles.profileSwipePreference = .on
            let source = profiles.controller
            let target = try profiles.create(name: "Work", color: .ocean, symbol: .work)
            let host = NSHostingController(rootView: Fixture(profiles: profiles)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight))
            let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1000, height: 600))
            BackgroundUIMode.show(window)
            defer { window.close() }
            var sidebarPoint = NSPoint.zero
            try await eventually("expanded sidebar gesture region") {
                window.contentView?.layoutSubtreeIfNeeded()
                guard let anchor = self.descendants(host.view).compactMap({ $0 as? ProfileSidebarAnchor.Anchor }).first,
                      anchor.bounds.width > 0 else { return false }
                sidebarPoint = anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
                return true
            }
            let pagePoint = NSPoint(x: try XCTUnwrap(window.contentView).bounds.midX, y: sidebarPoint.y)
            func route(_ phase: NSEvent.Phase, x: Int32 = 0, y: Int32 = 0, at point: NSPoint) throws -> Bool {
                try profiles.sidebarSwitch.route(wheel(phase, x: x, y: y), window: window,
                                                profiles: profiles, source: source, location: point)
            }
            let dx: Int32 = rtl ? 150 : -150
            XCTAssertFalse(try route(.began, at: pagePoint))
            XCTAssertFalse(try route(.changed, x: dx, at: sidebarPoint))
            XCTAssertFalse(try route(.ended, at: sidebarPoint))
            XCTAssertFalse(try route(.began, at: sidebarPoint))
            XCTAssertFalse(try route(.changed, x: 1, y: 14, at: sidebarPoint))
            XCTAssertFalse(try route(.changed, x: dx, at: sidebarPoint))
            XCTAssertFalse(try route(.ended, at: sidebarPoint))
            XCTAssertEqual(profiles.active.id, BrowserProfile.personalID)

            profiles.profileSwipePreference = .off
            XCTAssertFalse(try route(.began, at: sidebarPoint))
            XCTAssertFalse(try route(.changed, x: dx, at: sidebarPoint))
            XCTAssertFalse(try route(.ended, at: sidebarPoint))
            profiles.profileSwipePreference = .on
            source.sidebar.dragging = true
            XCTAssertFalse(try route(.began, at: sidebarPoint))
            XCTAssertFalse(try route(.changed, x: dx, at: sidebarPoint))
            source.sidebar.dragging = false

            XCTAssertFalse(try route(.began, at: sidebarPoint))
            XCTAssertTrue(try route(.changed, x: dx, at: pagePoint))
            XCTAssertTrue(profiles.sidebarSwitch.isCovering)
            XCTAssertNil(profiles.loadedController(target.id), "Preview must leave the profile asleep")
            XCTAssertTrue(try route(.ended, at: pagePoint))
            XCTAssertEqual(profiles.active.id, target.id)
            XCTAssertFalse(source.session.isProfileActive)
            XCTAssertTrue(profiles.controller.session.isProfileActive)
            try await eventually("settled overlay removed") { !profiles.sidebarSwitch.isCovering }
        }
    }
}
