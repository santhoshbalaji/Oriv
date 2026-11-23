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

    func testFreshBeginDiscardsAnUnfinishedGesture() {
        var gesture = Gesture()
        XCTAssertEqual(gesture.send(.began, x: -7), .pass)
        XCTAssertEqual(gesture.send(.began, x: -6), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -80), .track(-86))
        XCTAssertEqual(gesture.send(.began, y: 20), .pass)
        XCTAssertEqual(gesture.send(.changed, x: -100), .pass)
        XCTAssertEqual(gesture.send(.ended), .pass)
        XCTAssertEqual(gesture.send(.momentum), .pass)
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
            BrowserWindow(controller: profiles.controller, profiles: profiles)
                .overlay { ProfileSidebarOverlayHost(profiles: profiles) }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func wheel(_ phase: NSEvent.Phase, x: Int32 = 0, y: Int32 = 0,
                       momentum: Int64 = 0, time: TimeInterval? = nil, units: CGScrollEventUnit = .pixel,
                       screenPoint: NSPoint? = nil) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        // CoreGraphics has its own phase bit values.
        let phases: [UInt: Int64] = [0: 0, NSEvent.Phase.mayBegin.rawValue: 128,
                                      NSEvent.Phase.began.rawValue: 1, NSEvent.Phase.changed.rawValue: 2,
                                      NSEvent.Phase.ended.rawValue: 4, NSEvent.Phase.cancelled.rawValue: 8]
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: try XCTUnwrap(phases[phase.rawValue]))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        if let screenPoint, let primary = NSScreen.screens.first {
            event.location = CGPoint(x: screenPoint.x, y: primary.frame.maxY - screenPoint.y)
        }
        if let time { event.timestamp = UInt64(time * 1_000_000_000) }
        XCTAssertEqual(NSEvent(cgEvent: event)?.phase, phase)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func makeWindow<Content: View>(_ content: Content) -> NSWindow {
        let host = NSHostingController(rootView: content)
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1000, height: 600))
        BackgroundUIMode.show(window)
        return window
    }

    func testProfileSwitchTurnBudget() async throws {
        guard ProcessInfo.processInfo.environment["ORIV_PROFILE_SWITCH_BUDGET"] == "1" else {
            throw XCTSkip("Opt-in profile switch timing")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = BrowserProfiles(rootDirectory: root, testing: true)
        defer { profiles.shutdown() }
        profiles.profileSwipePreference = .on
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        let cold = try profiles.create(name: "Cold", color: .fern, symbol: .work)
        for id in [work.id, BrowserProfile.personalID] {
            try profiles.select(id)
            profiles.controller.sidebar.setPreference(false)
            profiles.controller.sidebarColor = id == work.id ? .profile : .rose
            let session = profiles.controller.session
            for _ in 0..<12 { session.addTab(select: false, load: false) }
            let tab = try XCTUnwrap(session.selectedTab)
            tab.webView.loadHTMLString("<title>Profile timing fixture</title><body>Profile timing fixture</body>",
                                       baseURL: URL(string: "https://profile-timing.test"))
            try await eventually("timing page loaded") { tab.hasLoaded && !tab.isLoading }
        }
        let window = makeWindow(Fixture(profiles: profiles).frame(width: 1000, height: 600))
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        func anchor() -> ProfileSidebarAnchor.Anchor? {
            content.layoutSubtreeIfNeeded()
            return descendants(content).compactMap { $0 as? ProfileSidebarAnchor.Anchor }
                .first { $0.window === window && $0.controller === profiles.controller && !$0.bounds.isEmpty }
        }
        var measured: Double?
        profiles.sidebarSwitch.selectTurnMeasured = { measured = $0 }
        var drag: [Double] = []
        var revisit: [Double] = []
        var tabTurns: [Double] = []
        let session = profiles.controller.session
        var legacyPersistence: [Double] = []
        var enqueuedPersistence: [Double] = []
        for _ in 0..<6 {
            let pending = session.addTab(select: false, load: false)
            let legacyStart = ProcessInfo.processInfo.systemUptime
            session.saveNow()
            session.setProfileActive(false)
            legacyPersistence.append((ProcessInfo.processInfo.systemUptime - legacyStart) * 1_000)
            session.setProfileActive(true)
            session.closeTab(pending.id)
            let enqueueStart = ProcessInfo.processInfo.systemUptime
            let barrier = session.deactivateForProfileSwitch()
            enqueuedPersistence.append((ProcessInfo.processInfo.systemUptime - enqueueStart) * 1_000)
            await Task.detached { barrier() }.value
            session.setProfileActive(true)
        }
        let originalTab = try XCTUnwrap(session.selectedTabID)
        let secondTab = try XCTUnwrap(session.tabs.first { $0.id != originalTab }).id
        for id in [secondTab, originalTab, secondTab, originalTab, secondTab, originalTab] {
            let start = ProcessInfo.processInfo.systemUptime
            session.selectTab(id)
            await withCheckedContinuation { continuation in
                ProfileSidebarSwitch.atTurnEnd {
                    tabTurns.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                    continuation.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        for index in 0...24 {
            try await eventually("expanded sidebar ready at sample \(index)") { anchor() != nil && !profiles.sidebarSwitch.isCovering }
            let view = try XCTUnwrap(anchor())
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let step: Int32 = index == 24 || index.isMultiple(of: 2) ? -150 : 150
            let destination = index == 24 ? cold.id : (step < 0 ? work.id : BrowserProfile.personalID)
            measured = nil
            func route(_ event: NSEvent) -> Bool {
                profiles.sidebarSwitch.route(event, window: window, profiles: profiles,
                                             source: profiles.controller, location: point)
            }
            if index == 24 {
                profiles.switchFromSidebar(destination, source: profiles.controller)
            } else {
                _ = route(try wheel(.began, x: 0, time: 1))
                let track = try wheel(.changed, x: step, time: 1.02)
                let start = ProcessInfo.processInfo.systemUptime
                XCTAssertTrue(route(track))
                drag.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                XCTAssertTrue(route(try wheel(.ended, time: 1.04)))
            }
            try await eventually("switch turn recorded") { measured != nil && profiles.active.id == destination }
            let ms = try XCTUnwrap(measured)
            if index == 24 { print("PROFILE_BUDGET firstVisit=\(ms)") }
            else { revisit.append(ms) }
        }
        func percentile(_ samples: [Double], _ fraction: Double) -> Double {
            samples.sorted()[Int(ceil(Double(samples.count) * fraction)) - 1]
        }
        for (name, samples) in [("selectTurn", revisit), ("dragStart", drag), ("tabTurn", tabTurns),
                                ("legacyPersistence", legacyPersistence), ("enqueuedPersistence", enqueuedPersistence)] {
            print("PROFILE_BUDGET \(name) n=\(samples.count) p50=\(percentile(samples, 0.5)) p95=\(percentile(samples, 0.95)) max=\(samples.max() ?? 0)")
        }
        XCTAssertLessThanOrEqual(percentile(revisit, 0.95), 40)
        XCTAssertLessThanOrEqual(percentile(revisit, 0.95), 3 * percentile(tabTurns, 0.95))
    }

    func testSwipeSwitchFocusesLoadedPage() async throws {
        try await assertSwitchFocus(viaSwipe: true, hasPage: true)
    }

    func testSwipeSwitchLeavesEmptyTabUnfocused() async throws {
        try await assertSwitchFocus(viaSwipe: true, hasPage: false)
    }

    func testProfileDotFocusesLoadedPage() async throws {
        try await assertSwitchFocus(viaSwipe: false, hasPage: true)
    }

    func testProfileDotLeavesEmptyTabUnfocused() async throws {
        try await assertSwitchFocus(viaSwipe: false, hasPage: false)
    }

    private func assertSwitchFocus(viaSwipe: Bool, hasPage: Bool) async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        profiles.profileSwipePreference = .on
        let target = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        try profiles.select(target.id)
        let destination = profiles.controller
        let tab = try XCTUnwrap(destination.session.selectedTab)
        if hasPage {
            tab.webView.loadHTMLString("<title>Profile focus fixture</title><p>Loaded page</p>",
                                       baseURL: URL(string: "https://profile-focus.test"))
            try await eventually("destination page loaded") { tab.hasLoaded && tab.url != nil && !tab.isLoading }
        }

        let window = makeWindow(Fixture(profiles: profiles).frame(width: 1000, height: 600))
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        func addressField() -> FocusAwareAddressField? {
            descendants(content).compactMap { $0 as? FocusAwareAddressField }.first { $0.window === window }
        }
        func marker(_ name: String) -> NSView? {
            content.layoutSubtreeIfNeeded()
            return descendants(content).first { $0.identifier?.rawValue == name && $0.window === window && !$0.bounds.isEmpty }
        }
        func editAddress(in controller: BrowserController) async throws -> FocusAwareAddressField {
            controller.focusAddress()
            try await eventually("explicit address command starts editing") { addressField()?.currentEditor() != nil }
            return try XCTUnwrap(addressField())
        }

        // Seed the same first focus request in both profiles.
        let previousDestinationField = try await editAddress(in: destination)
        try profiles.select(BrowserProfile.personalID)
        profiles.controller.sidebar.setPreference(false)
        let sourceTab = try XCTUnwrap(profiles.controller.session.selectedTab)
        if hasPage {
            sourceTab.webView.loadHTMLString("<title>Source profile</title><p>Source page</p>",
                                             baseURL: URL(string: "https://source-profile.test"))
            try await eventually("source page mounted") { sourceTab.webView.superview is WebViewHost }
        }
        try await eventually("source profile mounted") { previousDestinationField.currentEditor() == nil }
        XCTAssertTrue(addressField() === previousDestinationField)
        _ = try await editAddress(in: profiles.controller)
        XCTAssertEqual(profiles.controller.addressFocusRequest, destination.addressFocusRequest)
        // The next destination command will reuse the source field's last
        // handled request number. A coordinator keyed by number alone loses it.
        XCTAssertTrue(window.makeFirstResponder(nil))
        let sourceField = try await editAddress(in: profiles.controller)
        let lastSourceRequest = profiles.controller.addressFocusRequest
        let sourceHost = hasPage ? sourceTab.webView.superview as? WebViewHost : nil
        let collection = try XCTUnwrap(descendants(content).compactMap { $0 as? SidebarTabCollection }.first)
        let chrome = try XCTUnwrap(descendants(content).compactMap { $0 as? BrowserWindowChrome.WindowChromeView }.first)
        let sourceText = "source-only address"
        let editor = try XCTUnwrap(sourceField.currentEditor() as? NSTextView)
        editor.insertText(sourceText, replacementRange: editor.selectedRange())
        try await eventually("source profile dots laid out") { marker("sidebarProfileDot-1") != nil }
        let dot = try XCTUnwrap(marker("sidebarProfileDot-1"))
        let point = dot.convert(NSPoint(x: dot.bounds.midX, y: dot.bounds.midY), to: nil)

        var springBeforeSelection = false
        let source = profiles.controller
        profiles.sidebarSwitch.springCommitted = { [weak profiles] in
            springBeforeSelection = profiles?.controller === source
        }
        if viaSwipe {
            let events: [(NSEvent.Phase, Int32, TimeInterval)] = [
                (.began, -4, 1), (.changed, -150, 1.02), (.ended, 0, 1.04)
            ]
            for (phase, delta, time) in events {
                let event = try wheel(phase, x: delta, time: time)
                XCTAssertEqual(profiles.sidebarSwitch.route(event, window: window, profiles: profiles,
                                                           source: profiles.controller, location: point), phase != .began)
            }
        } else {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
            }
        }

        try await eventually("destination selected") { profiles.active.id == target.id }
        XCTAssertTrue(springBeforeSelection)
        XCTAssertEqual(profiles.sidebarSwitch.fallbackClearCount, 0)
        try await eventually("destination rebound and overlay settled") {
            content.layoutSubtreeIfNeeded()
            return !profiles.sidebarSwitch.isCovering
        }
        XCTAssertTrue(addressField() === sourceField)
        XCTAssertTrue(descendants(content).contains { $0 === collection })
        XCTAssertTrue(descendants(content).contains { $0 === chrome })
        if hasPage {
            XCTAssertNotNil(sourceHost)
            XCTAssertTrue(tab.webView.superview === sourceHost)
            XCTAssertNil(sourceTab.webView.superview)
        }
        let field = try XCTUnwrap(addressField())
        XCTAssertNil(field.currentEditor())
        XCTAssertFalse(field.stringValue.contains(sourceText))
        XCTAssertFalse(window.firstResponder === field)
        if hasPage {
            let responder = try XCTUnwrap(window.firstResponder as? NSView)
            XCTAssertTrue(responder === tab.webView || responder.isDescendant(of: tab.webView))
        } else {
            XCTAssertTrue(window.firstResponder === window)
        }

        _ = try await editAddress(in: destination)
        XCTAssertEqual(destination.addressFocusRequest, lastSourceRequest)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertNil(field.currentEditor())
        destination.newTab()
        XCTAssertNotEqual(destination.session.selectedTabID, tab.id)
        try await eventually("new tab starts address editing") { addressField()?.currentEditor() != nil }
    }

    func testProfileRebindIsolatesFindSearchSuggestionsAndPresentations() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        let source = profiles.controller
        let window = makeWindow(Fixture(profiles: profiles).frame(width: 1000, height: 600))
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let query = "only in the source"
        source.tabSearch = query
        source.profileUI.findText = query
        source.profileUI.findCaseSensitive = true
        source.profileUI.showFind = true
        source.focusAddress()
        func editor() -> NSTextView? {
            descendants(content).compactMap { ($0 as? FocusAwareAddressField)?.currentEditor() as? NSTextView }.first
        }
        try await eventually("source address editing") { editor() != nil }
        let fieldEditor = try XCTUnwrap(editor())
        fieldEditor.insertText(query, replacementRange: fieldEditor.selectedRange())
        try await eventually("source suggestions populated") {
            source.profileUI.addressMatches.query == query && !source.profileUI.addressMatches.rows.isEmpty
        }
        try await eventually("source tab query applied") { source.profileUI.settledQuery == query }
        source.profileUI.showProtection = true
        source.profileUI.showPasswords = true
        source.profileUI.showSiteInfo = true
        source.profileUI.showTabs = true
        source.profileUI.siteToForget = BrowserSite(url: try XCTUnwrap(URL(string: "https://source-only.test")))
        source.profileUI.closeOthers = source.session.selectedTabID
        source.profileUI.closeToRight = true

        // The synthetic state above has not yet presented a native sheet.
        try profiles.select(work.id)
        let destination = profiles.controller
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(destination.profileUI.address, "")
        XCTAssertEqual(destination.profileUI.addressMatches.rows.count, 0)
        XCTAssertEqual(destination.profileUI.findText, "")
        XCTAssertFalse(destination.profileUI.findCaseSensitive)
        XCTAssertFalse(destination.profileUI.showFind)
        XCTAssertEqual(destination.tabSearch, "")
        XCTAssertEqual(destination.profileUI.settledQuery, "")
        XCTAssertFalse(destination.profileUI.showProtection)
        XCTAssertFalse(destination.profileUI.showPasswords)
        XCTAssertFalse(destination.profileUI.showSiteInfo)
        XCTAssertFalse(destination.profileUI.showTabs)
        XCTAssertNil(destination.profileUI.siteToForget)
        XCTAssertNil(destination.profileUI.closeOthers)
        XCTAssertFalse(destination.profileUI.closeToRight)
        XCTAssertFalse(destination.profileUI.pageChrome === source.profileUI.pageChrome)
        XCTAssertFalse(source.profileUI.showPasswords)
        XCTAssertNil(source.profileUI.siteToForget)
        XCTAssertNil(source.profileUI.closeOthers)
        try profiles.select(BrowserProfile.personalID)
        XCTAssertEqual(source.profileUI.findText, query)
        XCTAssertTrue(source.profileUI.showFind)
        XCTAssertEqual(source.tabSearch, query)
    }

    func testExpandedToRailSettlesWithoutFallback() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let work = try profiles.create(name: "Rail", color: .ocean, symbol: .work)
        try profiles.select(work.id)
        profiles.controller.sidebar.setPreference(true)
        try profiles.select(BrowserProfile.personalID)
        profiles.controller.sidebar.setPreference(false)
        let window = makeWindow(Fixture(profiles: profiles).frame(width: 1000, height: 600))
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        try await eventually("source anchor attached") {
            content.layoutSubtreeIfNeeded()
            return descendants(content).contains { ($0 as? ProfileSidebarAnchor.Anchor)?.controller === profiles.controller }
        }
        profiles.switchFromSidebar(work.id, source: profiles.controller)
        try await eventually("rail profile selected and artwork cleared") {
            content.layoutSubtreeIfNeeded()
            return profiles.active.id == work.id && !profiles.sidebarSwitch.isCovering
        }
        XCTAssertTrue(profiles.controller.sidebar.rail)
        XCTAssertEqual(profiles.sidebarSwitch.fallbackClearCount, 0)
    }

    func testScrollViewReceivesGestureTailWithoutTheMonitorAndPreservesVerticalMomentum() async throws {
        for overDots in [false, true] {
            let profiles = BrowserProfiles(testing: true)
            defer { profiles.shutdown() }
            profiles.profileSwipePreference = .on
            profiles.controller.sidebar.setPreference(false)
            let target = try profiles.create(name: "Work", color: .ocean, symbol: .work)
            if !overDots {
                for _ in 0..<28 { profiles.controller.session.addTab(select: false, load: false) }
            }
            let window = makeWindow(
                BrowserSidebar(controller: profiles.controller, profiles: profiles)
                    .frame(width: MacBrowserLayout.sidebarWidth, height: 560)
                    .overlay { ProfileSidebarOverlayHost(profiles: profiles) }
            )
            defer { window.close() }
            let content = try XCTUnwrap(window.contentView)
            func scrollView() -> ProfileSidebarScrollView? {
                content.layoutSubtreeIfNeeded()
                return descendants(content).compactMap { $0 as? ProfileSidebarScrollView }
                    .first { ($0 is SidebarTabScrollView) != overDots && !$0.bounds.isEmpty }
            }
            func center(of scroll: NSView) -> NSPoint {
                scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
            }
            try await eventually("sidebar scroll view laid out (dots: \(overDots))") {
                guard let scroll = scrollView(), scroll.window === window,
                      overDots || (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height else { return false }
                let views = descendants(content)
                return views.contains {
                    guard let anchor = $0 as? ProfileSidebarAnchor.Anchor else { return false }
                    return anchor.window === window && anchor.controller === profiles.controller && !anchor.bounds.isEmpty
                } && views.contains {
                    guard let region = $0 as? ProfileSidebarSwipeRegion.Region, region.kind == .sidebar else { return false }
                    return region.window === window && region.controller === profiles.controller &&
                        region.convert(region.bounds, to: nil).contains(center(of: scroll))
                }
            }
            let scroll = try XCTUnwrap(scrollView())
            let host = try XCTUnwrap(descendants(content).compactMap { $0 as? ProfileSidebarOverlayHost.Host }.first)
            XCTAssertFalse(type(of: scroll).isCompatibleWithResponsiveScrolling)
            let windowPoint = center(of: scroll)
            let point = window.convertPoint(toScreen: windowPoint)
            var time = ProcessInfo.processInfo.systemUptime
            func event(_ phase: NSEvent.Phase, x: Int32 = 0, y: Int32 = 0, momentum: Int64 = 0) throws -> NSEvent {
                time += 0.02
                return try wheel(phase, x: x, y: y, momentum: momentum, time: time, screenPoint: point)
            }

            if !overDots {
                let vertical: [(NSEvent.Phase, Int32, Int64)] = [
                    (.began, -5, 0), (.changed, -50, 0), (.ended, 0, 0),
                    ([], -25, 1), ([], -25, 2), ([], 0, 3),
                ]
                for (phase, delta, momentum) in vertical {
                    let verticalEvent = try wheel(phase, y: delta, momentum: momentum, screenPoint: point)
                    scroll.scrollWheel(with: verticalEvent)
                    XCTAssertFalse(host.routeScrollWheel(verticalEvent), "Vertical gesture phases must pass through to AppKit")
                }
                XCTAssertFalse(profiles.sidebarSwitch.isCovering)
                XCTAssertEqual(profiles.active.id, BrowserProfile.personalID)
            }

            // CGEvent-to-NSEvent conversion does not attach the offscreen
            // window. Enter at the host's callback after its window filter.
            let began = try event(.began, x: -4)
            let eventPoint = window.convertPoint(fromScreen: began.locationInWindow)
            XCTAssertEqual(eventPoint.x, windowPoint.x, accuracy: 1)
            XCTAssertEqual(eventPoint.y, windowPoint.y, accuracy: 1)
            XCTAssertFalse(host.routeScrollWheel(began))
            scroll.scrollWheel(with: began)
            let changed = try event(.changed, x: -7)
            XCTAssertFalse(host.routeScrollWheel(changed))
            scroll.scrollWheel(with: changed)
            XCTAssertFalse(profiles.sidebarSwitch.isCovering, "The shared event must only contribute its delta once")

            // Deliver the remaining events straight to the responder.
            scroll.scrollWheel(with: try event(.changed, x: -150))
            XCTAssertTrue(profiles.sidebarSwitch.isCovering)
            scroll.scrollWheel(with: try event(.cancelled))
            XCTAssertEqual(profiles.active.id, BrowserProfile.personalID)
            XCTAssertFalse(host.routeScrollWheel(try event(.began, x: -5)))
            scroll.scrollWheel(with: try event(.changed, x: -150))
            scroll.scrollWheel(with: try event(.ended))
            try await eventually("destination selected") { profiles.active.id == target.id }
            let momentum = try event([], x: -50, momentum: 1)
            scroll.scrollWheel(with: momentum)
            XCTAssertTrue(host.routeScrollWheel(momentum), "Horizontal momentum remains claimed after selection")
        }
    }

    func testSyntheticWindowRoutingKeepsGesturesInTheirStartingRegion() async throws {
        for rtl in [false, true] {
            let profiles = BrowserProfiles(testing: true)
            defer { profiles.shutdown() }
            profiles.profileSwipePreference = .on
            let source = profiles.controller
            let target = try profiles.create(name: "Work", color: .ocean, symbol: .work)
            let window = makeWindow(Fixture(profiles: profiles)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .frame(width: 1000, height: 600))
            defer { window.close() }
            let content = try XCTUnwrap(window.contentView)
            func point(_ identifier: String) -> NSPoint? {
                window.contentView?.layoutSubtreeIfNeeded()
                return descendants(content).first {
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
            try await eventually("destination selected") { profiles.active.id == target.id }
            XCTAssertFalse(source.session.isProfileActive)
            XCTAssertTrue(profiles.controller.session.isProfileActive)
            XCTAssertTrue(try route([], momentum: 1, at: pagePoint))
            XCTAssertTrue(try route([], momentum: 3, at: pagePoint))

            XCTAssertTrue(profiles.sidebarSwitch.isCovering, "The second swipe interrupts the first spring")
            XCTAssertFalse(try route(.mayBegin, at: dots))
            XCTAssertFalse(try route(.began, at: dots))
            for delta: Int32 in [5, 13, 14, 8, 2, 1] {
                _ = try route(.changed, x: -delta * sign, at: dots, after: 0.008)
            }
            XCTAssertTrue(try route(.ended, at: dots, after: 0.135))
            try await eventually("source selected") { profiles.active.id == BrowserProfile.personalID }
            try await eventually("settled overlay removed") { !profiles.sidebarSwitch.isCovering }

            XCTAssertFalse(try route(.began, at: footer))
            XCTAssertTrue(try route(.changed, x: dx, at: footer))
            XCTAssertTrue(try route(.ended, at: footer))
            try await eventually("destination selected") { profiles.active.id == target.id }
            try await eventually("next settled overlay removed") { !profiles.sidebarSwitch.isCovering }
            XCTAssertEqual(profiles.sidebarSwitch.fallbackClearCount, 0)
        }
    }
}
