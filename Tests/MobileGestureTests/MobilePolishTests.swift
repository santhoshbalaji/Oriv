import XCTest
import Darwin
import SwiftUI
import WebKit
import BrowserCore
@testable import BrowserEngine
@testable import OrivMobile

@MainActor final class MobilePolishTests: XCTestCase {
    func testHomeZoneCannotBeginEvenWhenBarHitAreaExtendsIntoSafeArea() {
        for (window,insets,bar) in [
            (CGRect(x:0,y:0,width:390,height:844),UIEdgeInsets(top:47,left:0,bottom:34,right:0),CGRect(x:70,y:755,width:250,height:89)),
            (CGRect(x:0,y:0,width:844,height:390),UIEdgeInsets(top:0,left:47,bottom:21,right:47),CGRect(x:100,y:320,width:640,height:70))
        ] {
            let y = window.maxY-insets.bottom
            for bottomY in stride(from:y,through:window.maxY,by:1) {
                XCTAssertFalse(MobileCapsulePan.Host.acceptsStart(CGPoint(x:window.midX,y:bottomY),bar:bar,window:window,insets:insets))
            }
            XCTAssertTrue(MobileCapsulePan.Host.acceptsStart(CGPoint(x:window.midX,y:y-10),bar:bar,window:window,insets:insets))
            XCTAssertFalse(MobileCapsulePan.Host.acceptsStart(CGPoint(x:window.midX,y:100),bar:bar,window:window,insets:insets))
            XCTAssertFalse(MobileCapsulePan.Host.acceptsStart(CGPoint(x:4,y:y-10),bar:bar,window:window,insets:insets))
        }
    }

    func testCapsuleRequiresUpwardOrHorizontalIntentAndNeverTwoTouches() {
        let host = MobileCapsulePan.Host(frame:CGRect(x:0,y:0,width:200,height:48)), pan = PolishPan()
        for velocity in [CGPoint(x:50,y:500),CGPoint(x:200,y:-180),CGPoint(x:0,y:200)] {
            pan.speed = velocity; XCTAssertFalse(host.gestureRecognizerShouldBegin(pan))
        }
        for velocity in [CGPoint(x:10,y:-500),CGPoint(x:500,y:20),CGPoint(x:-500,y:20)] {
            pan.speed = velocity; XCTAssertTrue(host.gestureRecognizerShouldBegin(pan))
        }
        host.enabled = false
        XCTAssertFalse(host.gestureRecognizerShouldBegin(pan))
    }

    func testZeroTranslationBeganDoesNotLockHorizontalSwipeToVertical() throws {
        let c = MobileController(); defer { c.session.shutdown() }
        let source = c.session.selectedTabID, next = c.session.addTab(select:false,load:false)
        let state = MobileChromeGestureState()
        state.capsule(.began,translation:.zero,session:c.session)
        XCTAssertNil(state.axis)
        state.capsule(.changed,translation:CGSize(width:-6,height:0),session:c.session)
        XCTAssertNil(state.axis)
        state.capsule(.changed,translation:CGSize(width:-90,height:0),session:c.session)
        XCTAssertEqual(state.axis,.horizontal); XCTAssertEqual(state.gridProgress,0)
        XCTAssertEqual(c.session.selectedTabID,source)
        state.capsule(.ended,translation:CGSize(width:-90,height:0),session:c.session)
        XCTAssertEqual(c.session.selectedTabID,next.id)
    }

    func testResignActiveRevertsTransitionAndLateEndsCannotCommit() throws {
        let controller = MobileController(); defer { controller.session.shutdown() }
        let source = controller.session.selectedTabID, state = MobileChromeGestureState()
        state.capsule(.began,translation:CGSize(width:0,height:-90),session:controller.session)
        XCTAssertGreaterThan(state.gridProgress,0)
        NotificationCenter.default.post(name:UIApplication.willResignActiveNotification,object:nil)
        XCTAssertEqual(state.gridProgress,0); XCTAssertNil(state.source)
        XCTAssertFalse(state.capsule(.ended,translation:CGSize(width:0,height:-320),session:controller.session))
        state.capsule(.changed,translation:CGSize(width:0,height:-150),session:controller.session)
        XCTAssertEqual(state.gridProgress,0); XCTAssertNil(state.source)
        XCTAssertEqual(controller.session.selectedTabID,source)
        NotificationCenter.default.post(name:UIApplication.didBecomeActiveNotification,object:nil)
        state.capsule(.changed,translation:CGSize(width:0,height:-150),session:controller.session)
        XCTAssertNil(state.source); XCTAssertEqual(state.gridProgress,0)
    }

    func testResignDuringOverviewAnimationRestoresThePageAndItsInput() async throws {
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        try await wait { tab.title == "Gesture Lab" && !tab.isLoading }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }), selected = c.session.selectedTabID
        let previous = scene.windows.first(where:\.isKeyWindow)
        let root = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles).browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        let window = UIWindow(windowScene:scene); window.rootViewController = root; window.makeKeyAndVisible()
        defer { NotificationCenter.default.post(name:UIApplication.didBecomeActiveNotification,object:nil); window.isHidden = true; previous?.makeKeyAndVisible() }
        try await wait { tab.webView.window === window }
        c.sheet = .tabs
        try await wait { c.tabPresentation.activeID != nil }
        NotificationCenter.default.post(name:UIApplication.willResignActiveNotification,object:nil)
        try await wait { c.sheet == nil && c.tabPresentation.activeID == nil }
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertEqual(c.session.selectedTabID,selected); XCTAssertEqual(tab.webView.transform,.identity)
        XCTAssertTrue(window.hitTest(CGPoint(x:window.bounds.midX,y:window.bounds.midY),with:nil)?.isDescendant(of:tab.webView) == true)
    }

    func testInactiveGridCancellationDoesNotInventAPullTransition() {
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        var pulls = 0
        let grid = MobileTabGridController(model:MobileTabGrid(controller:c,profiles:profiles,tabs:c.session.orderedTabs,
            largeText:false,reduceMotion:true,open:{ _ in XCTFail() },onPull:{ _,_ in pulls += 1 },presented:false,visible:false))
        grid.loadViewIfNeeded(); grid.cancelGestures()
        XCTAssertEqual(pulls,0)
    }

    func testReorderingAndPinchingExcludeCardSwipe() {
        let cell = MobileTabCell(frame:CGRect(x:0,y:0,width:180,height:280)), pan = PolishPan()
        pan.speed = CGPoint(x:-900,y:5)
        cell.canInteract = { false }
        XCTAssertFalse(cell.gestureRecognizerShouldBegin(pan))
        cell.canInteract = { true }
        XCTAssertTrue(cell.gestureRecognizerShouldBegin(pan))
        let pinch = PolishPinch(); pinch.phase = .began; cell.pinch(pinch)
        XCTAssertTrue(cell.pinching); XCTAssertFalse(cell.gestureRecognizerShouldBegin(pan))
        cell.cancelGestures()
    }

    func testBackgroundDiscardRestoresHistoryAndScrollAndKeepsSelectedAndPrivateViews() async throws {
        let previousTiming = getenv("ORIV_CHROME_TIMING").map { String(cString:$0) }
        setenv("ORIV_CHROME_TIMING","1",1)
        defer {
            if let previousTiming { setenv("ORIV_CHROME_TIMING",previousTiming,1) }
            else { unsetenv("ORIV_CHROME_TIMING") }
        }
        let c = MobileController(); defer { c.session.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab), web = tab.webView
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        try await wait { !tab.isLoading && tab.title == "Gesture Lab" }
        web.frame = CGRect(x:0,y:0,width:390,height:700)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/chrome-paint")!)
        try await wait { !tab.isLoading && tab.canGoBack }
        _ = try await web.evaluateJavaScript("window.scrollTo(0,500)")
        try await Task.sleep(for:.milliseconds(100))
        let scrollBefore = try await web.evaluateJavaScript("scrollY") as? Double
        XCTAssertEqual(scrollBefore ?? 0,500,accuracy:1)
        let selectedDiscarded = await discard(tab)
        XCTAssertFalse(selectedDiscarded)
        let scriptsBefore = web.configuration.userContentController.userScripts.count
        let selected = c.session.addTab(load:false)
        weak var oldWeb = web
        let discarded = await discard(tab)
        XCTAssertTrue(discarded); XCTAssertFalse(tab.isInstantiated)
        XCTAssertEqual(c.session.selectedTabID,selected.id)
        c.session.selectTab(tab.id)
        try await wait { tab.isInstantiated && !tab.isLoading && !tab.isRestoringWebView && tab.webView.url?.path == "/chrome-paint" }
        try await Task.sleep(for:.milliseconds(150))
        let scrollAfter = try await tab.webView.evaluateJavaScript("scrollY") as? Double
        XCTAssertEqual(scrollAfter ?? 0,scrollBefore ?? 500,accuracy:1)
        print("POLISH_RESTORE scrollBefore=\(scrollBefore ?? -1) scrollAfter=\(scrollAfter ?? -1)")
        XCTAssertEqual(tab.webView.configuration.userContentController.userScripts.count,scriptsBefore)
        XCTAssertFalse(tab.webView === oldWeb); XCTAssertTrue(tab.webView.canGoBack)
        tab.goBack()
        try await wait { !tab.isLoading && tab.webView.url?.path == "/gestures" }
        let privateTab = c.session.addTab(url:URL(string:"http://127.0.0.1:8768/two"),isPrivate:true)
        try await wait { !privateTab.isLoading }
        c.session.selectTab(tab.id)
        let privateDiscarded = await discard(privateTab)
        XCTAssertFalse(privateDiscarded); XCTAssertTrue(privateTab.isInstantiated)
    }

    func testIdleTabWorkingSetIsBoundedAndCanRestoreDiscardedTab() async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        for i in 0..<10 { c.session.addTab(url:URL(string:"http://127.0.0.1:8768/two?working-set=\(i)")!) }
        try await wait { c.session.tabs.filter(\.isInstantiated).allSatisfy {
            !$0.isLoading && !$0.webView.isLoading && $0.webView.url?.path == "/two" && $0.title == "Second page"
        } }
        let before = c.session.tabs.filter(\.isInstantiated).count
        c.trimBackgroundTabs(limit:2)
        try await wait { c.session.tabs.filter(\.isInstantiated).count <= 2 }
        let after = c.session.tabs.filter(\.isInstantiated).count
        let state = c.session.tabs.filter(\.isInstantiated).map { "selected=\($0.id == c.session.selectedTabID) loading=\($0.isLoading)/\($0.webView.isLoading) attached=\($0.webView.superview != nil) urlMatches=\($0.url == $0.webView.url)" }
        XCTAssertEqual(before,10); XCTAssertEqual(after,2,state.joined(separator:"; "))
        let dormant = try XCTUnwrap(c.session.tabs.first { !$0.isInstantiated && $0.url != nil })
        c.session.selectTab(dormant.id)
        try await wait { dormant.isInstantiated && !dormant.isLoading && dormant.webView.url?.path == "/two" }
        print("POLISH_WORKING_SET before=\(before) after=\(after) restored=\(dormant.isInstantiated)")
    }

    func testChromeObserverOwnershipTransferKeepsTheSuccessorInstalled() async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab), second = PageChrome()
        let web = tab.webView
        web.frame = CGRect(x:0,y:0,width:390,height:700)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/chrome-paint")!)
        let first = c.chrome(for:tab)
        second.observe(web)
        first.observe(nil)
        try await wait { second.sampledTop != nil }
        XCTAssertGreaterThan(second.sampleCount,0)
        second.observe(nil)
    }

    func testActiveCardKeepsItsRenderedBackingWhileTheLiveHostMounts() throws {
        let c = MobileController(); defer { c.session.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab), presentation = c.tabPresentation
        func render() throws -> UIImage {
            let renderer = ImageRenderer(content:MobileGridCard(tab:tab,presentation:presentation,selected:true,
                largeText:false,close:{}).frame(width:180,height:282).browserAppearance(c.appearance))
            renderer.scale = 1
            return try XCTUnwrap(renderer.uiImage)
        }
        let resting = try render()
        presentation.begin(tab)
        let mounting = try render()
        XCTAssertGreaterThan(try XCTUnwrap(resting.pngData()).count,1000)
        XCTAssertEqual(resting.pngData(),mounting.pngData(),"Preparing a live surface must never erase its backing card")
        for (name,image) in [("Resting card",resting),("Card during live-host preparation",mounting)] {
            let attachment = XCTAttachment(image:image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testLivePaintPreparationWaitsForAttachmentAndCancelsStaleCompletion() async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        try await wait { !tab.isLoading && tab.title == "Gesture Lab" }
        let host = MobileWebHost(webView:tab.webView)
        host.frame = CGRect(x:0,y:0,width:402,height:874); host.layoutIfNeeded()
        var completed:[UUID] = [], succeeded = false
        let first = UUID()
        host.prepareTransition(first) { token,success in completed.append(token); succeeded = success }
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertTrue(completed.isEmpty,"An unattached host is not ready to expose")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where:\.isKeyWindow), root = UIViewController()
        let window = UIWindow(windowScene:scene); window.rootViewController = root
        root.view.addSubview(host); host.frame = root.view.bounds; host.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        window.makeKeyAndVisible()
        defer { host.prepareTransition(nil); window.isHidden = true; previous?.makeKeyAndVisible() }
        try await wait { completed == [first] }
        XCTAssertTrue(succeeded)
        host.prepareTransition(UUID()) { token,_ in completed.append(token) }
        host.prepareTransition(nil)
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertEqual(completed,[first],"Cancelled render completions must not expose a stale destination")
    }

    func testGridToDifferentPageKeepsLiveHostAndChromeThroughEverySampledFrame() async throws {
        try await verifyHandoff(reduced:false)
    }
    func testReducedMotionHandoffKeepsLiveHostWithoutScaling() async throws {
        try await verifyHandoff(reduced:true)
    }
    private func verifyHandoff(reduced:Bool) async throws {
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTab)
        first.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        try await wait { !first.isLoading && first.title == "Gesture Lab" }
        let second = c.session.addTab(url:URL(string:"http://127.0.0.1:8768/chrome-paint")!)
        try await wait { !second.isLoading }
        second.webView.frame = CGRect(x:0,y:0,width:402,height:874)
        let destinationChrome = c.chrome(for:second)
        destinationChrome.requestSample()
        try await wait { destinationChrome.sampledTop != nil }
        c.session.selectTab(first.id)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where:\.isKeyWindow)
        let root = PolishHostingController(rootView:MobileBrowserView(controller:c,profiles:profiles,reduceMotionOverride:reduced).browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        let window = UIWindow(windowScene:scene); window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await wait { first.webView.window === window }
        try await wait { root.appeared && window.isKeyWindow && scene.activationState == .foregroundActive && root.view.bounds == window.bounds }
        let hit = window.hitTest(CGPoint(x:window.bounds.midX,y:window.bounds.midY),with:nil)
        XCTAssertTrue(hit?.isDescendant(of:first.webView) == true,"Page input must pass through the chrome overlay")
        c.sheet = .tabs
        // Observe entry before rest: activeID is also nil before SwiftUI has
        // consumed the sheet request, so checking only rest races the update.
        try await wait { c.tabPresentation.activeID == first.id }
        try await wait { c.tabPresentation.activeID == nil && c.sheet == .tabs && c.tabPresentation.cardFrames[second.id] != nil }
        let expected = destinationChrome.color
        var samples = 0, parents = Set<ObjectIdentifier>(), sizes = Set<CGSizeKey>(), mismatches = 0, motionFrames = 0
        var unexpectedTransforms:[String] = []
        let sampler = PolishFrameSampler {
            guard c.session.selectedTabID == second.id, second.webView.window === window else { return }
            samples += 1
            if let parent = second.webView.superview { parents.insert(ObjectIdentifier(parent)) }
            sizes.insert(CGSizeKey(second.webView.bounds.size))
            if c.chrome(for:second).color != expected { mismatches += 1 }
            let transform = second.webView.layer.presentation()?.affineTransform() ?? second.webView.transform
            if transform != .identity {
                motionFrames += 1
                if reduced && unexpectedTransforms.count < 5 { unexpectedTransforms.append(String(describing:transform)) }
            }
        }
        sampler.start(); defer { sampler.stop() }
        c.tabPresentation.pendingSelection = second.id; c.sheet = nil
        try await wait { c.session.selectedTabID == second.id && c.tabPresentation.activeID == nil }
        // Sample additional resting frames as well as the transition itself;
        // the minimum count must not depend on animation duration.
        let settledSamples = samples
        try await wait { samples > settledSamples+10 }
        XCTAssertGreaterThan(samples,10); XCTAssertEqual(parents.count,1); XCTAssertEqual(sizes.count,1)
        XCTAssertEqual(mismatches,0); XCTAssertEqual(second.webView.transform,.identity)
        if reduced { XCTAssertEqual(motionFrames,0,"Reduce Motion must cross-fade without scaling the live page: \(unexpectedTransforms)") }
        let attachment = XCTAttachment(string:"frames=\(samples), parents=\(parents.count), viewportSizes=\(sizes.count), chromeMismatches=\(mismatches), motionFrames=\(motionFrames), reduced=\(reduced)")
        attachment.name = "Live handoff frame samples reduced=\(reduced)"; attachment.lifetime = .keepAlways; add(attachment)
        // Pixel correctness of the final actual WebKit backing, in addition to
        // the per-frame host/chrome invariant. Device recordings cover compositing.
        let image = try await second.webView.takeSnapshot(configuration:nil)
        XCTAssertNotNil(image)
        let pixels = XCTAttachment(image:image); pixels.name = "Destination live page reduced=\(reduced)"; pixels.lifetime = .keepAlways; add(pixels)
    }

    func testNewTabAddressEditorStaysAboveKeyboardWithoutANavigationHitShield() async throws {
        let profiles = MobileProfiles(), c = profiles.current, keyboard = PolishKeyboardRecorder()
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where:\.isKeyWindow)
        let root = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles).browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        let window = UIWindow(windowScene:scene); window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKeyAndVisible() }
        c.newTab(animated:false)
        try await wait { keyboard.frame != nil && self.focusedField(in:root.view) != nil }
        try await Task.sleep(for:.milliseconds(350))
        let field = try XCTUnwrap(focusedField(in:root.view)), frame = try XCTUnwrap(keyboard.frame)
        let rect = field.convert(field.bounds,to:window), keyboardRect = window.convert(frame,from:nil)
        XCTAssertLessThanOrEqual(rect.maxY,keyboardRect.minY+1)
        XCTAssertGreaterThanOrEqual(rect.maxY,keyboardRect.minY-24)
        XCTAssertGreaterThan(rect.minY,window.safeAreaInsets.top)
    }
    private func focusedField(in view:UIView) -> UITextField? {
        if let field = view as? UITextField, field.isFirstResponder { return field }
        return view.subviews.lazy.compactMap { self.focusedField(in:$0) }.first
    }

    func testProtectionWarmupCompletesBeforeFirstNavigationWithoutRecompiling() async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        c.warmProtection()
        try await wait { !c.session.adBlocker.isPreparing && c.session.adBlocker.compilationMeasurements.count >= 5 }
        let before = c.session.adBlocker.compilationMeasurements.count, started = ProcessInfo.processInfo.systemUptime
        try c.session.navigate("http://127.0.0.1:8768/two")
        try await wait { c.session.selectedTab?.title == "Second page" && c.session.selectedTab?.isLoading == false }
        XCTAssertEqual(c.session.adBlocker.compilationMeasurements.count,before)
        print("POLISH_PREWARM navigationMs=\((ProcessInfo.processInfo.systemUptime-started)*1000) recompilations=0")
    }

    func testRulePreparationYieldsUIActorWhileProtectingFirstNavigation() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let blocker = AdBlocker(cacheNamespace:"oriv.polish."+UUID().uuidString)
        let creation = ProcessInfo.processInfo.systemUptime-start
        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { heartbeats += 1; try? await Task.sleep(for:.milliseconds(10)) }
        }
        defer { heartbeat.cancel() }
        try await blocker.prepare()
        XCTAssertGreaterThan(heartbeats,1)
        print("POLISH_RULES initMs=\(creation*1000) prepareMs=\((ProcessInfo.processInfo.systemUptime-start)*1000) UIHeartbeats=\(heartbeats)")
        for measurement in blocker.compilationMeasurements { try await WKContentRuleListStore.default()!.removeContentRuleList(forIdentifier:measurement.identifier) }
    }

    private func discard(_ tab:BrowserTab) async -> Bool {
        await withCheckedContinuation { continuation in tab.discardBackgroundWebView { continuation.resume(returning:$0) } }
    }

    func testUnlaidOutLiveHostNeverScalesTheUnmorphedPageToZero() {
        let web = WKWebView(frame:CGRect(x:0,y:0,width:402,height:874))
        let host = MobileWebHost(webView:web)
        XCTAssertEqual(host.bounds.size,.zero)
        host.applyMorph(progress:0,card:CGRect(x:16,y:120,width:180,height:280),animated:false)
        XCTAssertEqual(web.transform,.identity,"Initial zero-sized SwiftUI layout must not collapse the live page")
        host.frame = CGRect(x:0,y:0,width:402,height:874); host.layoutIfNeeded()
        XCTAssertEqual(web.transform,.identity)
        XCTAssertEqual(web.bounds.size,host.bounds.size)
    }

    func testLivePaintPreparationFailsWithinBoundWhenHostNeverAttaches() async throws {
        let host = MobileWebHost(webView:WKWebView())
        host.frame = CGRect(x:0,y:0,width:402,height:874); host.layoutIfNeeded()
        var results:[Bool] = []
        host.prepareTransition(UUID()) { _,success in results.append(success) }
        defer { host.prepareTransition(nil) }
        try await Task.sleep(for:.seconds(4))
        XCTAssertEqual(results,[false],"An unattached destination must fail within the preparation deadline")
    }

    func testLivePaintPreparationTimesOutOnceAndRejectsLateSnapshotCompletion() async throws {
        let web = PolishControlledSnapshotWebView(), host = MobileWebHost(webView:web)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow, root = UIViewController(), window = UIWindow(windowScene:scene)
        root.view = host; window.rootViewController = root; window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { host.prepareTransition(nil); window.isHidden = true; previous?.makeKeyAndVisible() }
        var results:[Bool] = []
        host.prepareTransition(UUID()) { _,success in results.append(success) }
        try await wait { web.completions.count == 1 }
        try await Task.sleep(for:.seconds(4))
        XCTAssertEqual(results,[false],"A WebKit callback that never arrives must not hold the transition")
        web.completions[0](UIImage(systemName:"circle"),nil)
        XCTAssertEqual(results,[false],"Late paint must not expose a timed-out destination")
        host.prepareTransition(UUID()) { _,success in results.append(success) }
        try await wait { web.completions.count == 2 }
        host.prepareTransition(nil)
        web.completions[1](UIImage(systemName:"circle"),nil)
        XCTAssertEqual(results,[false],"Cancelled callbacks must remain stale")
    }

    func testGridSettlementReleasesLiveHostOnFailedOrStalledSnapshotAndRejectsLateCompletion() async throws {
        let web = PolishControlledSnapshotWebView(), tab = BrowserTab(dataStore:.nonPersistent())
        defer { tab.close() }
        tab.createWebView = { _ in web }
        _ = tab.webView
        let presentation = MobileTabPresentation()
        presentation.begin(tab); presentation.settleInGrid(tab)
        try await wait { web.completions.count == 1 }
        web.completions[0](nil,URLError(.cannotLoadFromNetwork))
        try await wait { presentation.activeID == nil }
        presentation.begin(tab); presentation.settleInGrid(tab)
        try await wait { web.completions.count == 2 }
        try await Task.sleep(for:.seconds(3))
        XCTAssertNil(presentation.activeID,"A stalled thumbnail must leave an interactive resting grid")
        presentation.begin(tab)
        web.completions[1](UIImage(systemName:"circle"),nil)
        XCTAssertEqual(presentation.activeID,tab.id,"A late thumbnail cannot finish a newer interaction")
        XCTAssertNil(presentation.images[tab.id],"A stale thumbnail cannot replace the backing card")
        presentation.finish()
    }

    private func wait(file:StaticString = #filePath,line:UInt = #line,_ condition:() -> Bool) async throws {
        let end = Date.now.addingTimeInterval(15)
        while !condition() && Date.now < end { try await Task.sleep(for:.milliseconds(20)) }
        let ready = condition()
        XCTAssertTrue(ready,file:file,line:line)
        if !ready { throw PolishReadinessTimeout() }
    }
}

@MainActor private final class PolishFrameSampler: NSObject {
    private var link:CADisplayLink?
    private let sample:() -> Void
    init(_ sample:@escaping () -> Void) { self.sample = sample }
    func start() { let link = CADisplayLink(target:self,selector:#selector(tick)); self.link = link; link.add(to:.main,forMode:.common) }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick() { sample() }
}
private struct CGSizeKey: Hashable {
    let width:Double, height:Double
    init(_ size:CGSize) { width = size.width; height = size.height }
}
@MainActor private final class PolishPan: UIPanGestureRecognizer {
    var speed = CGPoint.zero
    override func velocity(in view:UIView?) -> CGPoint { speed }
}
@MainActor private final class PolishPinch: UIPinchGestureRecognizer {
    var phase:UIGestureRecognizer.State = .possible
    override var state:UIGestureRecognizer.State { get { phase } set { phase = newValue } }
}

@MainActor private final class PolishKeyboardRecorder:NSObject {
    var frame:CGRect?
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self,selector:#selector(changed(_:)),name:UIResponder.keyboardWillChangeFrameNotification,object:nil)
    }
    @objc private func changed(_ notification:Notification) { frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect }
    deinit { NotificationCenter.default.removeObserver(self) }
}

@MainActor private final class PolishControlledSnapshotWebView: WKWebView {
    var completions:[@MainActor @Sendable (UIImage?,Error?) -> Void] = []
    override func takeSnapshot(with snapshotConfiguration:WKSnapshotConfiguration?,completionHandler:@escaping @MainActor @Sendable (UIImage?,Error?) -> Void) {
        completions.append(completionHandler)
    }
}

private struct PolishReadinessTimeout:Error {}

@MainActor private final class PolishHostingController<Content:View>:UIHostingController<Content> {
    private(set) var appeared = false
    override func viewDidAppear(_ animated:Bool) { super.viewDidAppear(animated); appeared = true }
}
