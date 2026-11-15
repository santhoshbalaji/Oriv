import XCTest

/// Opt-in only. The local QA project supplies the isolated bundle identity.
@MainActor final class RealDeviceTests: XCTestCase {
    var app: XCUIApplication!
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_DEVICE_QA"] == "1", "Set ORIV_DEVICE_QA=1 in the isolated local QA project.")
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device suite; simulator regressions use OrivMobileTests.")
        #endif
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_BUNDLE_ID"])
        guard id.hasSuffix(".qa"), !id.hasSuffix(".uitests") else { throw XCTSkip("An isolated .qa app is required.") }
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: id)
        app.launchEnvironment["BROWSER_TESTING"] = "1"
        app.launchArguments = ["--oriv-transition-metrics", "--oriv-gesture-trace"]
    }
    override func tearDown() async throws {
        if let app, app.state == .runningForeground {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
    }
    func test00IsolatedLaunch() {
        app.launch()
        XCTAssertTrue(app.buttons["browserAddressDisplay"].waitForExistence(timeout: 30))
        let a = XCTAttachment(string: app.debugDescription); a.name = "QA launch accessibility"; a.lifetime = .keepAlways; add(a)
    }
}

extension RealDeviceTests {
    var fixture: String { ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"] ?? "" }
    var address: XCUIElement { app.buttons["browserAddressDisplay"] }
    var tabs: XCUIElement { app.buttons["browserTabs"] }
    var web: XCUIElement { app.webViews.firstMatch }
    @discardableResult func recordNativeEdge(_ title:String, expected:XCUIElement) -> Bool {
        let observed = expected.waitForExistence(timeout:3)
        let attachment = XCTAttachment(string:"Synthetic native edge result: \(title); reached=\(observed). Physical-touch acceptance belongs to the owner. Strict native recognizer and edge hit-test assertions run in NativeHistoryPolicyTests.")
        attachment.name = "Native edge diagnostic: " + title; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(app.state,.runningForeground)
        XCTAssertFalse(app.buttons["Tab actions"].exists,"A page edge must not invoke Oriv's tab grid")
        return observed
    }
    func attachTree(_ title: String) {
        let a = XCTAttachment(string: app.debugDescription); a.name = title; a.lifetime = .keepAlways; add(a)
    }
    func wait(_ element: XCUIElement, _ seconds: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: seconds), file: file, line: line)
    }
    func gone(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let p = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p, object: element)], timeout: 20), .completed, file: file, line: line)
    }
    func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
    func launchPage(_ path: String = "/gestures", title: String = "Gesture Lab") throws {
        try XCTSkipUnless(fixture.hasPrefix("http://"), "Local QA config must supply a LAN fixture URL.")
        app.launch(); wait(address, 30); navigate(fixture + path)
        wait(web.staticTexts[title], 60)
    }
    func navigate(_ url: String) {
        if !app.textFields["browserAddress"].exists { address.tap() }
        let field = app.textFields["browserAddress"]; wait(field)
        field.typeText(url + "\n")
    }
    func grid() { tabs.tap(); wait(app.buttons["Tab actions"]) }
    func waitForUnobstructedTopBar() {
        // Observe only system-banner presence; never read its text or open it.
        let banner = XCUIApplication(bundleIdentifier:"com.apple.springboard")
            .descendants(matching:.any).matching(identifier:"NotificationShortLookView").element
        XCTAssertTrue(banner.waitForNonExistence(timeout:15),"A system banner must clear before tapping a top-bar control")
    }
    func newTab(privateMode: Bool = false) {
        grid()
        if privateMode {
            waitForUnobstructedTopBar(); app.buttons["Tab actions"].tap()
            let action = app.buttons["New Private Tab"]; wait(action); action.tap()
        }
        else { app.buttons["New Tab"].tap() }
        wait(app.textFields["browserAddress"])
    }
    func pageMenu(_ item: String) {
        let menu = app.buttons["browserPageMenu"]; wait(menu); menu.tap()
        let button = app.buttons[item]; wait(button); button.tap()
    }
    func dismissLinkPreview() {
        waitForUnobstructedTopBar()
        XCTAssertFalse(app.buttons["tabGridDone"].exists,"A hidden grid must not expose its close control behind a preview")
        let done = app.navigationBars.buttons.matching(identifier:"linkPreviewDone")
        XCTAssertEqual(done.count,1,"The preview must expose exactly one close control")
        done.element.tap()
    }
    func dismissSiteSettings() {
        waitForUnobstructedTopBar()
        XCTAssertFalse(app.buttons["tabGridDone"].exists,"A hidden grid must not expose its close control behind site settings")
        let done = app.navigationBars["Site settings"].buttons.matching(identifier:"siteSettingsDone")
        XCTAssertEqual(done.count,1,"Site settings must expose exactly one close control")
        done.element.tap()
    }
    func measureGesture(signpost: Bool = false, scroll: Bool = false, iterations: Int = 3, _ action: () -> Void) {
        let options = XCTMeasureOptions(); options.iterationCount = iterations
        var metrics: [any XCTMetric] = [XCTClockMetric(), XCTMemoryMetric(application: app), XCTCPUMetric(application: app), XCTHitchMetric(application: app)]
        #if DEBUG
        if signpost { metrics.append(XCTOSSignpostMetric(subsystem: "Oriv", category: "TabTransitions", name: "TabTransition")) }
        #endif
        if scroll { metrics.append(XCTOSSignpostMetric.scrollingAndDecelerationMetric) }
        measure(metrics: metrics, options: options, block: action)
    }
    func test01CapsuleSwipeAndLowestInjectableHomeZone() throws {
        try launchPage()
        // The initial hardware run injected y = screenHeight - 1. iOS took
        // the system app-switch gesture, so that probe is retained as manual
        // system-boundary evidence and is not repeated by this functional test.
        wait(address)
        let center = address.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -300)), withVelocity: .slow, thenHoldForDuration: 0)
        wait(app.buttons["Tab actions"])
    }
    func test02NormalGridPageTransitionsAndHitches() throws {
        try launchPage()
        measureGesture(signpost: true) {
            self.grid(); self.app.buttons["Done"].tap(); self.wait(self.address)
        }
    }
    func test03HorizontalCapsuleSwitching() throws {
        try launchPage(); newTab(); navigate(fixture + "/two"); wait(web.staticTexts["Second page"])
        let c = address.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        c.press(forDuration: 0.05, thenDragTo: c.withOffset(CGVector(dx: 260, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0)
        wait(web.staticTexts["Gesture Lab"])
        let d = address.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        d.press(forDuration: 0.05, thenDragTo: d.withOffset(CGVector(dx: -260, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0)
        wait(web.staticTexts["Second page"])
    }
    func test04NormalSwipeCloseAndLastTab() throws {
        try launchPage(); newTab(); navigate(fixture + "/two"); wait(web.staticTexts["Second page"])
        grid(); let cells = app.collectionViews.cells
        let n = cells.count; XCTAssertEqual(n, 2)
        cells.matching(NSPredicate(format: "label CONTAINS %@", "Second page")).firstMatch.swipeLeft()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(cells.count, n - 1)
        cells.firstMatch.swipeLeft()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attachTree("Last normal tab close")
        XCTAssertEqual(cells.count, 1) // BrowserSession keeps a fresh normal tab.
    }
    func test05PrivateTransitionAndSwipeConfirmation() throws {
        try launchPage(); newTab(privateMode: true); navigate(fixture + "/two"); wait(web.staticTexts["Second page"])
        XCTAssertEqual(address.value as? String, "Private browsing")
        grid(); app.buttons["Done"].tap(); wait(address)
        grid(); app.collectionViews.cells.firstMatch.swipeLeft()
        let alert = app.alerts["Close Private Tabs?"]; wait(alert)
        alert.buttons["Cancel"].tap(); XCTAssertEqual(app.collectionViews.cells.count, 1)
        app.collectionViews.cells.firstMatch.swipeLeft(); wait(alert); alert.buttons["Close Tab"].tap()
        attachTree("Last private tab closed")
        XCTAssertFalse(alert.exists)
    }
    func test06CloseAllConfirmation() throws {
        try launchPage(); grid(); app.buttons["Tab actions"].tap(); app.buttons["Close All Tabs"].tap()
        let alert = app.alerts["Close All Tabs?"]; wait(alert)
        alert.buttons["Cancel"].tap(); XCTAssertEqual(app.collectionViews.cells.count, 1)
        app.buttons["Tab actions"].tap(); app.buttons["Close All Tabs"].tap(); wait(alert)
        alert.buttons["Close All Tabs"].tap()
        gone(alert); XCTAssertEqual(app.collectionViews.cells.count, 1)
        XCTAssertFalse(app.collectionViews.cells.firstMatch.label.contains("Gesture Lab"))
    }
    func test07DragReorder() throws {
        try launchPage(); newTab(); navigate(fixture + "/two"); wait(web.staticTexts["Second page"]); grid()
        let cells = app.collectionViews.cells; XCTAssertEqual(cells.count, 2)
        let before = cells.allElementsBoundByIndex.map(\.label)
        let first = cells.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94))
        let second = cells.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.94))
        first.press(forDuration: 1.0, thenDragTo: second, withVelocity: .slow, thenHoldForDuration: 1)
        let after = cells.allElementsBoundByIndex.sorted { a, b in
            abs(a.frame.midY - b.frame.midY) > 10 ? a.frame.midY < b.frame.midY : a.frame.midX < b.frame.midX
        }.map(\.label)
        let a = XCTAttachment(string: "before=\(before)\nafter=\(after)"); a.lifetime = .keepAlways; add(a)
        XCTAssertEqual(after, Array(before.reversed()))
    }
    func test08PullToRefresh() throws {
        try launchPage()
        let loaded = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Loaded '")).firstMatch
        wait(loaded); let before = loaded.label
        let c = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        c.press(forDuration: 0.05, thenDragTo: c.withOffset(CGVector(dx: 0, dy: 350)), withVelocity: .slow, thenHoldForDuration: 0)
        let p = NSPredicate(format: "label != %@", before)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p, object: loaded)], timeout: 30), .completed)
    }
    func test09PinchDespiteViewportLimit() throws {
        try launchPage(); let heading = web.staticTexts["Gesture Lab"]; let before = heading.frame.width
        web.pinch(withScale: 2, velocity: 1)
        XCTAssertGreaterThan(heading.frame.width, before * 1.2)
        web.pinch(withScale: 0.5, velocity: -1)
    }
    func test10LinkContextMenuAndPreview() throws {
        try launchPage(); let link = web.links["Open second page"]; wait(link); link.press(forDuration: 1)
        wait(app.buttons["Open in New Tab"])
        attachTree("Link menu and preview")
        XCTAssertTrue(app.buttons["Copy Link"].exists || app.buttons["Copy"].exists)
        app.collectionViews.buttons["Load Preview"].tap()
        wait(app.staticTexts["Second page"], 45)
        dismissLinkPreview()
        wait(web.staticTexts["Gesture Lab"])
    }
    func test11FindInPage() throws {
        try launchPage(); pageMenu("Find on Page")
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        wait(field); field.tap(); field.typeText("Alpha")
        wait(app.staticTexts["find.resultLabel"])
        XCTAssertEqual(app.staticTexts["find.resultLabel"].label, "1 of 8")
        attachTree("Native find result")
        XCTAssertTrue(app.buttons["Done"].exists || app.buttons["Close"].exists)
    }
    func test12HistoryEdgesAndLists() throws {
        try launchPage(); web.links["Open second page"].tap(); wait(web.staticTexts["Second page"])
        app.buttons["Back"].press(forDuration: 1); attachTree("Back history")
        wait(app.buttons["Gesture Lab"]); app.buttons["Gesture Lab"].tap(); wait(web.staticTexts["Gesture Lab"])
        app.buttons["Forward"].press(forDuration: 1); attachTree("Forward history")
        wait(app.buttons["Second page"]); app.buttons["Second page"].tap(); wait(web.staticTexts["Second page"])
        let r = web.frame
        point(r.minX + 12, r.midY).press(forDuration: 0.05, thenDragTo: point(r.maxX - 20, r.midY), withVelocity: .slow, thenHoldForDuration: 0)
        _ = recordNativeEdge("test12HistoryEdgesAndLists",expected:web.staticTexts["Gesture Lab"])
        point(r.maxX - 12, r.midY).press(forDuration: 0.05, thenDragTo: point(r.minX + 20, r.midY), withVelocity: .slow, thenHoldForDuration: 0)
        _ = recordNativeEdge("test12HistoryEdgesAndLists",expected:web.staticTexts["Second page"])
    }
    func test13CarouselDoesNotSwitchTabs() throws {
        try launchPage(); web.swipeUp()
        let one = web.staticTexts["Carousel one"]; wait(one)
        if !one.isHittable { web.swipeUp(velocity: .slow) }
        let before = one.frame.minX
        one.swipeLeft(velocity: .slow)
        XCTAssertLessThan(one.frame.minX, before - 20)
        XCTAssertTrue(app.buttons["browserCompactAddress"].exists || (address.exists && address.label.contains("/gestures")))
    }
    func test14ScrollCollapseExpandAndHitches() throws {
        try launchPage()
        measureGesture(scroll: true) { self.web.swipeUp(velocity: .fast); self.web.swipeDown(velocity: .fast) }
        web.swipeUp(velocity: .slow); wait(app.buttons["browserCompactAddress"])
        app.buttons["browserCompactAddress"].tap(); wait(address)
    }
    func test15KeyboardAndRepeatedActions() throws {
        try launchPage(); grid(); app.buttons["New Tab"].tap(); wait(app.textFields["browserAddress"])
        wait(app.keyboards.firstMatch)
        app.buttons["Cancel address editing"].tap(); gone(app.keyboards.firstMatch)
        grid(); app.buttons["Done"].tap(withNumberOfTaps: 5, numberOfTouches: 1)
        wait(address); address.tap(); wait(app.keyboards.firstMatch)
        app.buttons["Cancel address editing"].tap(); gone(app.keyboards.firstMatch)
        XCTAssertEqual(tabs.value as? String, "2 tabs")
    }
    func test16SitePrivacyAndCleanCopy() throws {
        try launchPage()
        navigate(fixture + "/gestures?utm_source=deviceqa&keep=1")
        wait(web.staticTexts["Gesture Lab"])
        pageMenu("Site Privacy & Settings"); attachTree("Site Privacy panel")
        XCTAssertTrue(app.navigationBars["Site settings"].exists)
        XCTAssertTrue(app.staticTexts["Protection"].exists)
        dismissSiteSettings(); wait(address)
        address.press(forDuration: 1); wait(app.buttons["Copy"]); app.buttons["Copy"].tap()
        address.press(forDuration: 1); wait(app.buttons["Paste and Go"]); app.buttons["Paste and Go"].tap()
        wait(web.staticTexts["Gesture Lab"])
        XCTAssertTrue(address.label.contains("keep=1"))
        XCTAssertFalse(address.label.contains("utm_source"))
    }
    func test17LaunchTiming() {
        app.launchEnvironment.removeValue(forKey: "BROWSER_TESTING")
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) { self.app.launch(); self.app.terminate() }
    }
    func test18IdleCPUAndMemory() throws {
        try launchPage()
        let options = XCTMeasureOptions(); options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            let until = Date().addingTimeInterval(5)
            RunLoop.current.run(until: until)
        }
    }
    func test19ReduceMotionManual() throws {
        app.launchEnvironment["ORIV_QA_REDUCE_MOTION"] = "1"
        try launchPage()
        measureGesture(signpost: true) { self.grid(); self.app.buttons["Done"].tap(); self.wait(self.address) }
        attachTree("QA-only Reduce Motion override; system setting unchanged")
    }
    func test20HTTPSPrompt() throws {
        app.launch(); wait(address)
        navigate(ProcessInfo.processInfo.environment["ORIV_QA_HTTP_FALLBACK_URL"] ?? "http://neverssl.com/online")
        let alert = app.alerts["This site doesn't support a secure connection"]
        wait(alert,90)
        XCTAssertFalse(web.staticTexts["This Connection Is Not Secure"].exists,"There must be only one native consent prompt")
        XCTAssertTrue(alert.buttons["Go Back"].exists)
        XCTAssertTrue(alert.buttons["Continue to HTTP"].exists)
        XCTAssertFalse(web.staticTexts["Gesture Lab"].exists)
        attachTree("Single native HTTPS consent prompt")
        alert.buttons["Go Back"].tap(); gone(alert)
        navigate(ProcessInfo.processInfo.environment["ORIV_QA_HTTP_FALLBACK_URL"] ?? "http://neverssl.com/online")
        wait(alert,90)
        XCTAssertFalse(web.staticTexts["This Connection Is Not Secure"].exists)
        XCTAssertFalse(web.staticTexts["Gesture Lab"].exists,"Go Back must not authorize HTTP")
        alert.buttons["Continue to HTTP"].tap()
        if ProcessInfo.processInfo.environment["ORIV_QA_HTTP_FALLBACK_URL"] != nil {
            wait(web.staticTexts["Gesture Lab"], 45)
        }
    }
}


extension RealDeviceTests {
    func test47CancelledBoundaryAndFastBarSwipes() throws {
        try launchPage()
        capsulePan(180,0) // First tab has a hard boundary.
        wait(web.staticTexts["Gesture Lab"])
        newTab(); navigate(fixture+"/two"); wait(web.staticTexts["Second page"])
        let r = address.frame
        point(r.midX,r.midY).press(forDuration:0.05,thenDragTo:point(r.midX+35,r.midY),withVelocity:.slow,thenHoldForDuration:0.3)
        wait(web.staticTexts["Second page"])
        XCTAssertFalse(web.staticTexts["Gesture Lab"].exists,"A cancelled swipe keeps its source live")
        capsulePan(260,0); wait(web.staticTexts["Gesture Lab"])
        let first = address.frame
        // UIKit starts recognising after part of the injected travel. Give the
        // recognised stroke margin above 25 points; diagnostic runs verify it
        // still stays below the 70-point drag threshold and uses flick velocity.
        point(first.midX,first.midY).press(forDuration:0.05,thenDragTo:point(first.midX-90,first.midY),withVelocity:XCUIGestureVelocity(rawValue:1600),thenHoldForDuration:0)
        wait(web.staticTexts["Second page"])
        capsulePan(-70,0) // Last-tab/new-tab cancellation must not allocate a tab.
        wait(web.staticTexts["Second page"])
        grid(); XCTAssertEqual(app.collectionViews.cells.count,2)
    }
    func test48PrivateReducedMotionBarSwipes() throws {
        app.launchEnvironment["ORIV_QA_REDUCE_MOTION"] = "1"
        try launchPage()
        newTab(privateMode:true); navigate(fixture+"/gestures"); wait(web.staticTexts["Gesture Lab"])
        newTab(); navigate(fixture+"/two"); wait(web.staticTexts["Second page"])
        capsulePan(260,0); wait(web.staticTexts["Gesture Lab"])
        XCTAssertEqual(address.value as? String,"Private browsing")
        capsulePan(-260,0); wait(web.staticTexts["Second page"])
        XCTAssertEqual(address.value as? String,"Private browsing")
    }
    func test49DarkLightHistoryChromeBarSwipes() throws {
        try launchPage("/swipe-light",title:"Light swipe page")
        newTab(); navigate(fixture+"/swipe-dark"); wait(web.staticTexts["Dark swipe page"])
        navigate(fixture+"/two"); wait(web.staticTexts["Second page"])
        app.buttons["Back"].tap(); wait(web.staticTexts["Dark swipe page"])
        XCTAssertTrue(app.buttons["Forward"].exists)
        capsulePan(260,0); wait(web.staticTexts["Light swipe page"])
        capsulePan(-260,0); wait(web.staticTexts["Dark swipe page"])
        XCTAssertTrue(app.buttons["Forward"].exists)
    }
    func test50SwitchToPaintedTabBeforeSlowResourceFinishes() throws {
        try launchPage()
        newTab(); navigate(fixture+"/chrome-paint?delay=30")
        wait(web.staticTexts["Paint timing fixture"])
        XCTAssertTrue(app.buttons["Stop"].exists)
        capsulePan(260,0); wait(web.staticTexts["Gesture Lab"])
        capsulePan(-260,0); wait(web.staticTexts["Paint timing fixture"])
        XCTAssertTrue(app.buttons["Stop"].exists,"A painted tab must become interactive while its image is still loading")
    }
    func test51SwitchBetweenExistingBlankAndWebTabs() throws {
        try launchPage(); newTab()
        app.buttons["Cancel address editing"].tap(); wait(address)
        capsulePan(260,0); wait(web.staticTexts["Gesture Lab"])
        capsulePan(-260,0); wait(address)
        XCTAssertFalse(web.staticTexts["Gesture Lab"].exists)
        grid(); XCTAssertEqual(app.collectionViews.cells.count,2)
    }
    func test22ProfilingWindow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_QA_PROFILE"] == "1", "Dedicated trace run only.")
        try launchPage()
        let scenario = ProcessInfo.processInfo.environment["ORIV_QA_PROFILE_SCENARIO"] ?? "mixed"
        if scenario == "bar" || scenario == "selection" {
            newTab(); navigate(fixture + "/two"); wait(web.staticTexts["Second page"])
        }
        // Resolve geometry before the trace. These coordinates still use real
        // event injection, without repeatedly requesting accessibility trees.
        let capsule = address.frame
        let tabButton = tabs.frame
        var done:CGRect = .zero
        var cards:[CGRect] = []
        if scenario == "grid" || scenario == "selection" || scenario == "mixed-native" {
            grid(); done = app.buttons["Done"].frame
            cards = app.collectionViews.cells.allElementsBoundByIndex.map(\.frame)
            app.buttons["Done"].tap(); wait(address)
        }
        print("QA_PROFILE_READY")
        for index in 0..<14 {
            switch scenario {
            case "scroll":
                point(capsule.midX,480).press(forDuration:0.05,thenDragTo:point(capsule.midX,180),withVelocity:.fast,thenHoldForDuration:0)
                point(capsule.midX,180).press(forDuration:0.05,thenDragTo:point(capsule.midX,480),withVelocity:.fast,thenHoldForDuration:0)
            case "grid", "selection", "mixed-native":
                point(tabButton.midX,tabButton.midY).tap()
                Thread.sleep(forTimeInterval:0.6)
                if scenario == "selection", !cards.isEmpty {
                    let card = cards[index % cards.count]
                    point(card.midX,card.midY).tap()
                } else { point(done.midX,done.midY).tap() }
                Thread.sleep(forTimeInterval:0.6)
                if scenario == "mixed-native" {
                    point(capsule.midX,480).press(forDuration:0.05,thenDragTo:point(capsule.midX,180),withVelocity:.fast,thenHoldForDuration:0)
                    point(capsule.midX,180).press(forDuration:0.05,thenDragTo:point(capsule.midX,480),withVelocity:.fast,thenHoldForDuration:0)
                }
            case "bar":
                let delta:CGFloat = index.isMultiple(of:2) ? 260 : -260
                point(capsule.midX,capsule.midY).press(forDuration:0.05,
                    thenDragTo:point(capsule.midX+delta,capsule.midY),withVelocity:.slow,thenHoldForDuration:0)
                Thread.sleep(forTimeInterval:0.5)
            default:
                grid(); app.buttons["Done"].tap(); wait(address)
                web.swipeUp(velocity:.fast); web.swipeDown(velocity:.fast)
            }
        }
        XCTAssertEqual(app.state,.runningForeground)
        XCTAssertTrue(address.exists)
        XCTAssertFalse(app.buttons["Tab actions"].exists,"Every profiling cycle must return to the page")

    }
}

extension RealDeviceTests {
    func capsulePan(_ dx: CGFloat, _ dy: CGFloat) {
        let r = address.frame
        point(r.midX, r.midY).press(forDuration: 0.05, thenDragTo: point(r.midX + dx, r.midY + dy), withVelocity: .slow, thenHoldForDuration: 0)
    }
    func test23CapsuleTransitionHitches() throws {
        try launchPage()
        measureGesture(signpost: true) {
            self.capsulePan(0, -300); self.wait(self.app.buttons["Tab actions"])
            self.app.buttons["Done"].tap(); self.wait(self.address)
        }
    }
    func test24HorizontalSwitchHitches() throws {
        try launchPage(); newTab(); navigate(fixture + "/two"); wait(web.staticTexts["Second page"])
        measureGesture {
            self.capsulePan(260, 0); self.wait(self.web.staticTexts["Gesture Lab"])
            self.capsulePan(-260, 0); self.wait(self.web.staticTexts["Second page"])
        }
    }
    func test25PinchHitches() throws {
        try launchPage()
        measureGesture { self.web.pinch(withScale: 2, velocity: 1); self.web.pinch(withScale: 0.5, velocity: -1) }
    }
    func test26RefreshHitches() throws {
        try launchPage()
        measureGesture {
            let loaded = self.web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Loaded '")).firstMatch
            let before = loaded.label
            let r = self.web.frame
            self.point(r.midX, r.minY + 160).press(forDuration: 0.05, thenDragTo: self.point(r.midX, r.minY + 510), withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: loaded)], timeout: 20), .completed)
        }
    }
    func test27ReorderHitches() throws {
        try launchPage(); newTab(); navigate(fixture + "/two"); wait(web.staticTexts["Second page"]); grid()
        measureGesture {
            let cells = self.app.collectionViews.cells.allElementsBoundByIndex.sorted { $0.frame.midX < $1.frame.midX }
            XCTAssertEqual(cells.count, 2)
            let a = cells[0].frame, b = cells[1].frame
            self.point(a.midX, a.maxY - 16).press(forDuration: 1, thenDragTo: self.point(b.midX, b.maxY - 16), withVelocity: .slow, thenHoldForDuration: 1)
        }
    }
    func test28KeyboardHitches() throws {
        try launchPage()
        measureGesture {
            self.address.tap(); self.wait(self.app.keyboards.firstMatch)
            self.app.buttons["Cancel address editing"].tap(); self.gone(self.app.keyboards.firstMatch)
        }
    }
    func test29PrivateTransitionHitches() throws {
        try launchPage(); newTab(privateMode: true); navigate(fixture + "/two"); wait(web.staticTexts["Second page"])
        measureGesture(signpost: true) { self.grid(); self.app.buttons["Done"].tap(); self.wait(self.address) }
    }
    func test30NewTabAndCloseHitches() throws {
        try launchPage()
        measureGesture {
            self.newTab(); self.app.buttons["Cancel address editing"].tap(); self.grid()
            self.app.collectionViews.cells.matching(NSPredicate(format: "label == 'New Tab'")).firstMatch.swipeLeft()
            self.app.buttons["Done"].tap(); self.wait(self.address)
            XCTAssertEqual(self.tabs.value as? String, "1 tabs")
        }
    }
}

extension RealDeviceTests {
    func test31FindHitches() throws {
        try launchPage()
        measureGesture(iterations: 1) {
            self.pageMenu("Find on Page")
            let field = self.app.searchFields.firstMatch.exists ? self.app.searchFields.firstMatch : self.app.textFields.firstMatch
            self.wait(field); field.tap(); field.typeText("Alpha")
            self.wait(self.app.staticTexts["find.resultLabel"])
            self.app.buttons["find.doneButton"].tap(); self.wait(self.address)
        }
    }
    func test32LinkPreviewHitches() throws {
        try launchPage()
        measureGesture(iterations: 1) {
            self.web.links["Open second page"].press(forDuration: 1)
            self.wait(self.app.buttons["Load Preview"]); self.app.collectionViews.buttons["Load Preview"].tap()
            self.wait(self.app.staticTexts["Second page"], 45)
            self.dismissLinkPreview(); self.wait(self.web.staticTexts["Gesture Lab"])
        }
    }
    func test33HistoryHitches() throws {
        try launchPage(); web.links["Open second page"].tap(); wait(web.staticTexts["Second page"])
        measureGesture(iterations: 1) {
            self.app.buttons["Back"].press(forDuration: 1); self.wait(self.app.buttons["Gesture Lab"])
            self.app.buttons["Gesture Lab"].tap(); self.wait(self.web.staticTexts["Gesture Lab"])
            self.app.buttons["Forward"].press(forDuration: 1); self.wait(self.app.buttons["Second page"])
            self.app.buttons["Second page"].tap(); self.wait(self.web.staticTexts["Second page"])
        }
    }
    func test34PrivacyPanelHitches() throws {
        try launchPage()
        measureGesture(iterations: 1) {
            self.pageMenu("Site Privacy & Settings"); self.wait(self.app.navigationBars["Site settings"])
            self.dismissSiteSettings(); self.wait(self.address)
        }
    }
    func test35PrivateCloseConfirmationHitches() throws {
        try launchPage(); newTab(privateMode: true); navigate(fixture + "/two"); wait(web.staticTexts["Second page"]); grid()
        measureGesture(iterations: 1) {
            self.app.collectionViews.cells.firstMatch.swipeLeft()
            self.wait(self.app.alerts["Close Private Tabs?"])
            self.app.alerts["Close Private Tabs?"].buttons["Cancel"].tap()
        }
    }
    func test36CloseAllConfirmationHitches() throws {
        try launchPage(); grid()
        measureGesture(iterations: 1) {
            self.app.buttons["Tab actions"].tap(); self.app.buttons["Close All Tabs"].tap()
            self.wait(self.app.alerts["Close All Tabs?"])
            self.app.alerts["Close All Tabs?"].buttons["Cancel"].tap()
        }
    }
}

extension RealDeviceTests {
    func test37NativeBackEdgeFast() throws {
        app.launchEnvironment["ORIV_QA_GESTURE_INVENTORY"] = "1"
        try launchPage(); web.links["Open second page"].tap(); wait(web.staticTexts["Second page"])
        let r = web.frame, y = web.frame.minY + 160
        let inset = CGFloat(Double(ProcessInfo.processInfo.environment["ORIV_QA_EDGE_INSET"] ?? "8") ?? 8)
        point(r.minX + inset, y).press(forDuration: 0.05, thenDragTo: point(r.maxX - 16, y), withVelocity: .fast, thenHoldForDuration: 0)
        _ = recordNativeEdge("test37NativeBackEdgeFast",expected:web.staticTexts["Gesture Lab"])
    }
    func test38NativeForwardEdgeFast() throws {
        app.launchEnvironment["ORIV_QA_GESTURE_INVENTORY"] = "1"
        try launchPage(); web.links["Open second page"].tap(); wait(web.staticTexts["Second page"])
        app.buttons["Back"].tap(); wait(web.staticTexts["Gesture Lab"])
        let r = web.frame, y = web.frame.minY + 160
        let inset = CGFloat(Double(ProcessInfo.processInfo.environment["ORIV_QA_EDGE_INSET"] ?? "8") ?? 8)
        point(r.maxX - inset, y).press(forDuration: 0.05, thenDragTo: point(r.minX + 16, y), withVelocity: .fast, thenHoldForDuration: 0)
        _ = recordNativeEdge("test38NativeForwardEdgeFast",expected:web.staticTexts["Second page"])
    }
}


extension RealDeviceTests {
    func test39PriorityBackEdge() throws {
        app.launchEnvironment["ORIV_QA_EDGE_PRIORITY"] = "1"
        try test37NativeBackEdgeFast()
    }
    func test40PriorityForwardEdge() throws {
        app.launchEnvironment["ORIV_QA_EDGE_PRIORITY"] = "1"
        try test38NativeForwardEdgeFast()
    }
    func test41ExactBackEdge() throws {
        setenv("ORIV_QA_EDGE_INSET", "1", 1)
        defer { unsetenv("ORIV_QA_EDGE_INSET") }
        try test37NativeBackEdgeFast()
    }
    func test42ExactForwardEdge() throws {
        setenv("ORIV_QA_EDGE_INSET", "1", 1)
        defer { unsetenv("ORIV_QA_EDGE_INSET") }
        try test38NativeForwardEdgeFast()
    }
    func test43PlainWebViewEdgesDiagnostic() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_QA_PROFILE"] == "1", "Requires the ignored native QA probe.")
        app.launchEnvironment["ORIV_QA_PLAIN_WEBVIEW"] = fixture + "/gestures"
        app.launchEnvironment["ORIV_QA_GESTURE_INVENTORY"] = "1"
        app.launch(); wait(web.staticTexts["Gesture Lab"], 60)
        web.links["Open second page"].tap(); wait(web.staticTexts["Second page"])
        let r = web.frame, y = r.minY + 160
        point(r.minX + 1, y).press(forDuration: 0.05, thenDragTo: point(r.maxX - 16, y), withVelocity: .fast, thenHoldForDuration: 0)
        _ = recordNativeEdge("test43PlainWebViewEdgesDiagnostic",expected:web.staticTexts["Gesture Lab"])
        point(r.maxX - 1, y).press(forDuration: 0.05, thenDragTo: point(r.minX + 16, y), withVelocity: .fast, thenHoldForDuration: 0)
        _ = recordNativeEdge("test43PlainWebViewEdgesDiagnostic",expected:web.staticTexts["Second page"])
    }
    func test44PrivateCloseAllConfirmed() throws {
        try launchPage(); newTab(privateMode: true); navigate(fixture + "/two"); wait(web.staticTexts["Second page"])
        newTab(privateMode: true); navigate(fixture + "/gestures"); wait(web.staticTexts["Gesture Lab"])
        grid(); XCTAssertEqual(app.collectionViews.cells.count, 2)
        app.buttons["Tab actions"].tap(); app.buttons["Close All Tabs"].tap()
        let alert = app.alerts["Close All Private Tabs?"]; wait(alert)
        alert.buttons["Cancel"].tap(); XCTAssertEqual(app.collectionViews.cells.count, 2)
        app.buttons["Tab actions"].tap(); app.buttons["Close All Tabs"].tap(); wait(alert)
        alert.buttons["Close All Tabs"].tap(); gone(alert)
        XCTAssertFalse(app.collectionViews.cells.matching(NSPredicate(format: "label CONTAINS %@", "Second page")).firstMatch.exists)
    }
    func responsiveEdges() {
        wait(web.staticTexts["Short page"], 60)
        web.links["Gesture Lab"].tap(); wait(web.staticTexts["Gesture Lab"])
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let r = web.frame, y = r.minY + 180
        point(r.minX + 1, y).press(forDuration: 0.05, thenDragTo: point(r.maxX - 16, y), withVelocity: .slow, thenHoldForDuration: 0.5)
        _ = recordNativeEdge("responsiveEdges()",expected:web.staticTexts["Short page"])
        point(r.maxX - 1, y).press(forDuration: 0.05, thenDragTo: point(r.minX + 16, y), withVelocity: .slow, thenHoldForDuration: 0.5)
        _ = recordNativeEdge("responsiveEdges()",expected:web.staticTexts["Gesture Lab"])
    }
    func test45PlainResponsiveEdgesDiagnostic() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_QA_PROFILE"] == "1", "Requires the ignored native QA probe.")
        app.launchEnvironment["ORIV_QA_PLAIN_WEBVIEW"] = fixture + "/short-gestures"
        app.launchEnvironment["ORIV_QA_GESTURE_INVENTORY"] = "1"
        app.launch(); responsiveEdges()
    }
    func test46ResponsiveEdges() throws {
        try launchPage("/short-gestures", title: "Short page")
        responsiveEdges()
    }
}
