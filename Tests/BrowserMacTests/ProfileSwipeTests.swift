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
        XCTAssertEqual(gesture.send(.began, x: -3, y: 6), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -3, y: 7), .pass)
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

    func testRecordedStyleSlowDiagonalDragAndDeceleratingFlick() {
        var gesture = Gesture()
        XCTAssertEqual(gesture.send(.mayBegin), .pass)
        XCTAssertEqual(gesture.send(.began), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -5, y: 3, after: 0.025), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -6, y: 3, after: 0.025), .track(-11))
        for index in 1...11 {
            XCTAssertEqual(gesture.send(.changed, x: -6, y: 2, after: 0.045), .track(CGFloat(-11 - 6 * index)))
        }
        XCTAssertEqual(gesture.send(.ended, after: 0.22), .settle(step: 1))
        XCTAssertEqual(gesture.send(.momentumEnded), .swallow)

        XCTAssertEqual(gesture.send(.mayBegin), .pass)
        XCTAssertEqual(gesture.send(.began), .pass)
        for dx: CGFloat in [5, 13, 14, 8, 2, 1] {
            _ = gesture.send(.changed, x: dx, after: 0.008)
        }
        XCTAssertEqual(gesture.send(.stationary, after: 0.07), .swallow)
        XCTAssertEqual(gesture.send(.ended, after: 0.065), .settle(step: -1))
    }

    func testSettlePresentationOffsetCannotCommitAnotherSwitch() {
        var gesture = Gesture()
        XCTAssertEqual(gesture.send(.began), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -14, presentation: 110), .track(96))
        XCTAssertEqual(gesture.send(.ended), .settle(step: nil))
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
        XCTAssertEqual(gesture.send(.changed, x: -13, presentation: -112), .track(-125))
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
                .overlay { ProfileSidebarOverlayHost(profiles: profiles) }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func wheel(_ phase: NSEvent.Phase, x: Int32 = 0, y: Int32 = 0,
                       momentum: Int64 = 0, time: TimeInterval = 0, units: CGScrollEventUnit = .pixel) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        // CoreGraphics has its own phase bit values.
        let phases: [UInt: Int64] = [0: 0, NSEvent.Phase.mayBegin.rawValue: 128,
                                      NSEvent.Phase.began.rawValue: 1, NSEvent.Phase.changed.rawValue: 2,
                                      NSEvent.Phase.ended.rawValue: 4, NSEvent.Phase.cancelled.rawValue: 8]
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: try XCTUnwrap(phases[phase.rawValue]))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.timestamp = UInt64(time * 1_000_000_000)
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
            func point(_ identifier: String) -> NSPoint? {
                window.contentView?.layoutSubtreeIfNeeded()
                return descendants(host.view).first {
                    $0.identifier?.rawValue == identifier && !$0.bounds.isEmpty && $0.window === window
                }.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
            }
            try await eventually("expanded sidebar gesture region") { point("sidebarProfileGeometry") != nil }
            let sidebarPoint = try XCTUnwrap(point("sidebarProfileGeometry"))
            let dots = try XCTUnwrap(point("sidebarProfileDotsGeometry"))
            let footer = try XCTUnwrap(point("sidebarFooterGeometry"))
            let pagePoint = NSPoint(x: try XCTUnwrap(window.contentView).bounds.midX, y: sidebarPoint.y)
            var time: TimeInterval = 1
            func route(_ phase: NSEvent.Phase, x: Int32 = 0, y: Int32 = 0, momentum: Int64 = 0,
                       at point: NSPoint, after interval: TimeInterval = 0.02,
                       units: CGScrollEventUnit = .pixel) throws -> Bool {
                time += interval
                return try profiles.sidebarSwitch.route(wheel(phase, x: x, y: y, momentum: momentum, time: time, units: units),
                    window: window, profiles: profiles, source: profiles.controller, location: point)
            }
            let dx: Int32 = rtl ? 150 : -150
            XCTAssertFalse(try route(.began, at: pagePoint))
            XCTAssertFalse(try route(.changed, x: dx, at: sidebarPoint))
            XCTAssertFalse(try route(.ended, at: sidebarPoint))
            XCTAssertFalse(try route(.began, at: sidebarPoint))
            XCTAssertFalse(try route(.changed, x: 1, y: 14, at: sidebarPoint))
            XCTAssertFalse(try route(.changed, x: dx, at: sidebarPoint))
            XCTAssertFalse(try route(.ended, at: sidebarPoint))
            XCTAssertFalse(try route([], x: dx, momentum: 1, at: sidebarPoint))
            XCTAssertFalse(try route([], x: dx, momentum: 3, at: sidebarPoint))
            XCTAssertEqual(profiles.active.id, BrowserProfile.personalID)

            XCTAssertFalse(try route(.began, x: dx, at: footer, units: .line))
            XCTAssertFalse(try route(.ended, at: footer, units: .line))
            profiles.profileSwipePreference = .off
            XCTAssertFalse(try route(.began, at: sidebarPoint))
            XCTAssertFalse(try route(.changed, x: dx, at: sidebarPoint))
            XCTAssertFalse(try route(.ended, at: sidebarPoint))
            profiles.profileSwipePreference = .on
            source.sidebar.dragging = true
            XCTAssertFalse(try route(.began, at: sidebarPoint))
            XCTAssertFalse(try route(.changed, x: dx, at: sidebarPoint))
            source.sidebar.dragging = false

            // Keep this interruption deterministic even if SwiftUI reattachment
            // is slower than the animation on a loaded runner.
            XCTAssertFalse(try route(.began, at: footer))
            XCTAssertTrue(try route(.changed, x: dx, at: footer))
            XCTAssertTrue(try route(.cancelled, at: footer))
            XCTAssertTrue(profiles.sidebarSwitch.isCovering)

            XCTAssertFalse(try route(.mayBegin, at: sidebarPoint))
            XCTAssertFalse(try route(.began, at: sidebarPoint))
            let sign: Int32 = rtl ? 1 : -1
            XCTAssertFalse(try route(.changed, x: 5 * sign, y: 3, at: pagePoint))
            for _ in 0..<12 {
                XCTAssertTrue(try route(.changed, x: 7 * sign, y: 3, at: pagePoint, after: 0.045))
            }
            XCTAssertTrue(profiles.sidebarSwitch.isCovering)
            XCTAssertNil(profiles.loadedController(target.id), "Preview must leave the profile asleep")
            XCTAssertTrue(try route(.ended, at: pagePoint, after: 0.22))
            XCTAssertEqual(profiles.active.id, target.id)
            XCTAssertFalse(source.session.isProfileActive)
            XCTAssertTrue(profiles.controller.session.isProfileActive)
            XCTAssertTrue(try route([], momentum: 1, at: pagePoint))
            XCTAssertTrue(try route([], momentum: 3, at: pagePoint))

            try await eventually("destination anchor reattached") {
                window.contentView?.layoutSubtreeIfNeeded()
                return self.descendants(host.view).contains {
                    guard let anchor = $0 as? ProfileSidebarAnchor.Anchor else { return false }
                    return anchor.window === window && anchor.controller === profiles.controller && anchor.bounds.width > 0
                }
            }
            XCTAssertFalse(try route(.mayBegin, at: dots))
            XCTAssertFalse(try route(.began, at: dots))
            for delta: Int32 in [5, 13, 14, 8, 2, 1] {
                _ = try route(.changed, x: -delta * sign, at: dots, after: 0.008)
            }
            XCTAssertTrue(try route(.ended, at: dots, after: 0.135))
            XCTAssertEqual(profiles.active.id, BrowserProfile.personalID)
            try await eventually("settled overlay removed") { !profiles.sidebarSwitch.isCovering }

            XCTAssertFalse(try route(.began, at: footer))
            XCTAssertTrue(try route(.changed, x: dx, at: footer))
            XCTAssertTrue(try route(.ended, at: footer))
            XCTAssertEqual(profiles.active.id, target.id)
            try await eventually("next settled overlay removed") { !profiles.sidebarSwitch.isCovering }
        }
    }
}
