import XCTest
import Darwin
import SwiftUI
import WebKit
import BrowserCore
@testable import BrowserEngine
@testable import OrivMobile

@MainActor final class MobilePolishTests: XCTestCase {
    func testChromeRegistrationsReleaseWithTheirOwnerWithoutExplicitDetach() async throws {
        var web:WKWebView? = WKWebView()
        var chrome:PageChrome? = PageChrome()
        chrome!.observe(web)
        weak var owner = chrome
        weak var registrations = chrome!.observerLifetime
        weak var page = web
        chrome = nil; web = nil
        try await wait { owner == nil && registrations == nil && page == nil }
        XCTAssertNil(owner); XCTAssertNil(registrations); XCTAssertNil(page)
    }

    func testSnapshotCacheBoundsDecodedBytesAndRetainsActiveBacking() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let image = UIGraphicsImageRenderer(size:CGSize(width:32,height:48),format:format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x:0,y:0,width:32,height:48))
        }
        let pixels = try XCTUnwrap(image.cgImage), bytes = pixels.bytesPerRow*pixels.height
        let cache = MobileTabPresentation(snapshotByteLimit:bytes*2)
        let active = UUID(), old = UUID(), newest = UUID()
        cache.store(image,for:active,revision:1); cache.activeID = active
        cache.store(image,for:old,revision:1); cache.store(image,for:newest,revision:1)
        XCTAssertEqual(cache.snapshotBytes,bytes*2)
        XCTAssertNotNil(cache.images[active]); XCTAssertNil(cache.images[old]); XCTAssertNotNil(cache.images[newest])
        cache.store(image,for:newest,revision:2)
        XCTAssertEqual(cache.snapshotBytes,bytes*2,"Replacement must not double-count decoded memory")
        cache.remove(active)
        XCTAssertEqual(cache.snapshotBytes,bytes)
        let tooSmall = MobileTabPresentation(snapshotByteLimit:bytes-1)
        tooSmall.store(image,for:UUID(),revision:0)
        XCTAssertEqual(tooSmall.snapshotBytes,0); XCTAssertTrue(tooSmall.images.isEmpty)
    }

    func testDiscardTimeoutKeepsUncertainPageAndIgnoresLateMediaReply() async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.createWebView = { PolishControlledMediaWebView(frame:.zero,configuration:$0) }
        let web = try XCTUnwrap(tab.webView as? PolishControlledMediaWebView)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/two")!)
        try await wait { !tab.isLoading && tab.title == "Second page" }
        c.session.addTab(load:false)
        tab.discardTimeout = .milliseconds(100)
        var result:Bool?, completions = 0
        tab.discardBackgroundWebView { result = $0; completions += 1 }
        try await wait { result != nil }
        XCTAssertEqual(result,false); XCTAssertTrue(tab.isInstantiated)
        XCTAssertEqual(web.mediaReplies.count,1)
        web.mediaReplies.removeFirst()(.none)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(completions,1); XCTAssertTrue(tab.isInstantiated,"Late permission to discard must not mutate an expired request")
    }

    func testPendingTrimDoesNotRetainItsController() async throws {
        var c:MobileController? = MobileController()
        let session = c!.session
        defer { session.shutdown() }
        var views:[PolishControlledMediaWebView] = []
        for _ in 0..<2 {
            let tab = session.addTab(load:false)
            tab.createWebView = { PolishControlledMediaWebView(frame:.zero,configuration:$0) }
            let view = try XCTUnwrap(tab.webView as? PolishControlledMediaWebView); views.append(view)
            tab.navigate(to:URL(string:"http://127.0.0.1:8768/two")!)
            try await wait { !tab.isLoading && tab.title == "Second page" }
        }
        session.addTab(load:false)
        c!.trimBackgroundTabs(limit:1)
        try await wait { views.contains { !$0.mediaReplies.isEmpty } }
        weak var owner = c; c = nil
        XCTAssertNil(owner,"A native IPC wait must not keep an abandoned controller alive")
        session.shutdown()
        for view in views {
            let replies = view.mediaReplies; view.mediaReplies.removeAll()
            replies.forEach { $0(.none) }
        }
    }

    func testMemoryWarningReleasesSnapshotsAndInvalidatesPendingCaptures() async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        try await wait { !tab.isLoading && tab.title == "Gesture Lab" }
        let image = UIGraphicsImageRenderer(size:CGSize(width:40,height:80)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x:0,y:0,width:40,height:80))
        }
        c.tabPresentation.store(image,for:tab.id,revision:tab.documentRevision)
        c.tabPresentation.capture(tab,refresh:true)
        NotificationCenter.default.post(name:UIApplication.didReceiveMemoryWarningNotification,object:nil)
        XCTAssertTrue(c.tabPresentation.images.isEmpty); XCTAssertEqual(c.tabPresentation.snapshotBytes,0)
        try await Task.sleep(for:.milliseconds(300))
        XCTAssertTrue(c.tabPresentation.images.isEmpty,"Stale snapshot callbacks must not refill a purged cache")
    }

    func testClosingTabReleasesWebViewChromeAndContextAdapter() async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        var tab:BrowserTab? = c.session.addTab(load:false)
        tab?.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        try await wait { tab?.title == "Gesture Lab" && tab?.isLoading == false }
        weak var weakTab = tab
        weak var view = tab?.webView
        weak var chrome = c.chrome(for:tab)
        weak var adapter = tab?.webView.uiDelegate
        let id = try XCTUnwrap(tab?.id)
        c.session.closeTab(id); tab = nil
        try await wait { weakTab == nil && view == nil && chrome == nil && adapter == nil }
    }

    func testNativeSwipeMovesBothSurfacesWithoutObservableFrameUpdates() {
        let swipe = MobileTabSwipe(), source = UUID(), target = UUID()
        let outgoing = UIView(frame:CGRect(x:0,y:0,width:390,height:844))
        let incoming = UIView(frame:outgoing.frame), backing = UIView(frame:outgoing.frame)
        swipe.attach(outgoing,for:source)
        swipe.begin(source:source,destination:target,direction:1,image:nil,reduceMotion:false)
        swipe.attach(incoming,for:target); swipe.attachBacking(backing)
        swipe.prepared(swipe.preparation!,success:true)
        let invalidations = PolishInvalidations()
        withObservationTracking { _ = swipe.sourceID; _ = swipe.destinationID; _ = swipe.preparation } onChange: {
            MainActor.assumeIsolated { invalidations.count += 1 }
        }
        for x in stride(from:CGFloat(-14),through:-220,by:-2) { swipe.move(x) }
        XCTAssertEqual(invalidations.count,0)
        XCTAssertEqual(outgoing.transform.tx,-220); XCTAssertEqual(incoming.transform.tx,170)
        XCTAssertEqual(backing.transform,incoming.transform)
        swipe.cancel()
        XCTAssertEqual(outgoing.transform,.identity); XCTAssertEqual(incoming.transform,.identity)
        XCTAssertEqual(outgoing.alpha,1); XCTAssertEqual(incoming.alpha,0); XCTAssertEqual(backing.alpha,0)
    }

    func testNativeSwipeWaitsForPaintAndRejectsStaleCompletions() async throws {
        let swipe = MobileTabSwipe(), source = UUID(), target = UUID()
        let outgoing = UIView(frame:CGRect(x:0,y:0,width:390,height:844)), incoming = UIView(frame:CGRect(x:0,y:0,width:390,height:844))
        swipe.attach(outgoing,for:source)
        swipe.begin(source:source,destination:target,direction:1,image:nil,reduceMotion:false)
        swipe.attach(incoming,for:target)
        let token = try XCTUnwrap(swipe.preparation)
        var commits = 0
        swipe.move(-170); swipe.finish(commit:true) { commits += 1 }
        try await Task.sleep(for:.milliseconds(600))
        XCTAssertEqual(commits,0,"A finished spring cannot expose an unpainted destination")
        XCTAssertTrue(swipe.isActive)
        XCTAssertEqual(outgoing.transform,.identity,"Keep the painted source visible while the peer has no snapshot or paint")
        swipe.prepared(UUID(),success:true); XCTAssertEqual(commits,0)
        swipe.prepared(token,success:true)
        try await wait { commits == 1 }
        XCTAssertEqual(commits,1); XCTAssertFalse(swipe.isActive)
        XCTAssertEqual(incoming.transform,.identity)
        XCTAssertEqual(outgoing.transform.tx,-390,"Do not reset the old surface into the handoff frame")
    }

    func testNewDestinationNavigationInvalidatesThePreviousPaintToken() async throws {
        let swipe = MobileTabSwipe(), source = UUID(), target = UUID()
        let outgoing = UIView(frame:CGRect(x:0,y:0,width:390,height:844))
        let host = MobileWebHost(webView:WKWebView()); host.frame = outgoing.frame; host.layoutIfNeeded()
        let backing = UIView(frame:outgoing.frame)
        let image = UIGraphicsImageRenderer(size:CGSize(width:16,height:16)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x:0,y:0,width:16,height:16))
        }
        swipe.attach(outgoing,for:source)
        swipe.begin(source:source,destination:target,direction:1,image:image,reduceMotion:false)
        swipe.attach(host.swipeSurface,for:target); swipe.attachBacking(backing)
        let previous = try XCTUnwrap(swipe.preparation)
        swipe.prepared(previous,success:true)
        NotificationCenter.default.post(name:BrowserTab.navigationStarted,object:host.webView)
        let current = try XCTUnwrap(swipe.preparation)
        XCTAssertNotEqual(previous,current); XCTAssertFalse(swipe.isPrepared)
        var committed = false
        swipe.finish(commit:true) { committed = true }
        try await Task.sleep(for:.milliseconds(450))
        swipe.prepared(previous,success:true)
        XCTAssertFalse(committed); XCTAssertTrue(swipe.isActive)
        swipe.prepared(current,success:true)
        try await wait { committed }
    }

    func testDetachedSwipePeerCancelsAndRejectsLatePaint() async throws {
        let swipe = MobileTabSwipe(), source = UUID(), target = UUID()
        let outgoing = UIView(frame:CGRect(x:0,y:0,width:390,height:844)), incoming = UIView(frame:CGRect(x:0,y:0,width:390,height:844))
        swipe.attach(outgoing,for:source)
        swipe.begin(source:source,destination:target,direction:1,image:nil,reduceMotion:false)
        swipe.attach(incoming,for:target)
        let token = try XCTUnwrap(swipe.preparation)
        swipe.prepared(token,success:true); swipe.move(-100)
        swipe.detach(incoming)
        var committed = false
        swipe.finish(commit:true) { committed = true }
        try await wait { !swipe.isActive }
        swipe.prepared(token,success:true)
        XCTAssertFalse(committed); XCTAssertEqual(outgoing.transform,.identity); XCTAssertEqual(outgoing.alpha,1)
    }

    func testCancelledAndReducedMotionSwipesNeverScaleOrCommitLatePaint() async throws {
        let swipe = MobileTabSwipe(), source = UUID(), target = UUID()
        let outgoing = UIView(frame:CGRect(x:0,y:0,width:390,height:844)), incoming = UIView(frame:CGRect(x:0,y:0,width:390,height:844))
        swipe.attach(outgoing,for:source)
        swipe.begin(source:source,destination:target,direction:-1,image:nil,reduceMotion:true)
        swipe.attach(incoming,for:target)
        let token = try XCTUnwrap(swipe.preparation)
        swipe.move(100)
        XCTAssertEqual(outgoing.transform,.identity); XCTAssertEqual(incoming.transform,.identity)
        var cancelled = false
        swipe.finish(commit:false) { cancelled = true }
        try await wait { cancelled }
        swipe.prepared(token,success:true)
        XCTAssertFalse(swipe.isActive); XCTAssertEqual(outgoing.alpha,1)
    }

    func testBarSwipeKeepsDestinationParentAndChromeAcrossSelection() async throws {
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        let source = try XCTUnwrap(c.session.selectedTab)
        source.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        let target = c.session.addTab(url:URL(string:"http://127.0.0.1:8768/two"),select:false,load:false)
        target.activate()
        try await wait { !source.isLoading && source.title == "Gesture Lab" && !target.isLoading && target.title == "Second page" }
        let chrome = c.chrome(for:target)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where:\.isKeyWindow)
        let root = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles).browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        let window = UIWindow(windowScene:scene); window.rootViewController = root; window.makeKeyAndVisible()
        defer { c.tabSwipe.cancel(); window.isHidden = true; previous?.makeKeyAndVisible() }
        try await wait { source.webView.window === window && source.webView.bounds.size == window.bounds.size }
        // The newly created test window must finish its initial geometry and
        // appearance callbacks before starting an interaction.
        try await Task.sleep(for:.milliseconds(100))
        let sourceParent = source.webView.superview
        c.tabSwipe.begin(source:source.id,destination:target.id,direction:1,image:nil,reduceMotion:false)
        try await wait { target.webView.window === window }
        try await wait { c.tabSwipe.isPrepared }
        let targetParent = try XCTUnwrap(target.webView.superview), viewport = target.webView.bounds.size
        let sourceFrame = source.webView.convert(source.webView.bounds,to:window)
        c.tabSwipe.move(-180)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(source.webView.convert(source.webView.bounds,to:window).minX,sourceFrame.minX-180,accuracy:1,
                       "SwiftUI must not overwrite the interactive UIKit transform")
        XCTAssertEqual(target.webView.convert(target.webView.bounds,to:window).minX,sourceFrame.minX+window.bounds.width-180,accuracy:1)
        XCTAssertTrue(source.webView.superview === sourceParent)
        c.tabSwipe.finish(commit:true) {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { c.session.selectTab(target.id) }
        }
        try await wait { c.session.selectedTabID == target.id && !c.tabSwipe.isActive }
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertNil(source.webView.window,"Chrome animation must not retain or reveal the departing page")
        XCTAssertTrue(target.webView.superview === targetParent,"Selection must retain the already-painted host")
        XCTAssertEqual(target.webView.bounds.size,viewport)
        XCTAssertTrue(c.chrome(for:target) === chrome,"Chrome observation must precede and survive the handoff")
    }

    func testBarSwipeCanCommitAfterFirstPaintWhileResourceStillLoads() async throws {
        for privateMode in [false,true] {
            let profiles = MobileProfiles(), c = profiles.current
            defer { c.session.shutdown(); profiles.continuity.shutdown() }
            let source = c.session.addTab(url:URL(string:"http://127.0.0.1:8768/two")!,isPrivate:privateMode)
            try await wait { !source.isLoading && source.title == "Second page" }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
            window.rootViewController = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles)
                .browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            try await wait { source.webView.window === window }
            try await Task.sleep(for:.milliseconds(100))
            let target = c.session.addTab(url:URL(string:"http://127.0.0.1:8768/chrome-paint?delay=4")!,isPrivate:privateMode,select:false)
            target.activate()
            c.tabSwipe.begin(source:source.id,destination:target.id,direction:1,image:nil,reduceMotion:false)
            try await wait { c.tabSwipe.isPrepared }
            XCTAssertTrue(target.webView.isLoading,"First paint must release a busy page before its slow image finishes")
            c.tabSwipe.move(-140)
            c.tabSwipe.finish(commit:true) {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { c.session.selectTab(target.id) }
            }
            try await wait { c.session.selectedTabID == target.id && !c.tabSwipe.isActive }
            XCTAssertTrue(target.webView.isLoading)
        }
    }

    func testBarSwipesBetweenHomeAndPagePrepareTheSameDestinationHost() async throws {
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        let home = try XCTUnwrap(c.session.selectedTab)
        let page = c.session.addTab(url:URL(string:"http://127.0.0.1:8768/two")!,select:false,load:false)
        page.activate()
        try await wait { !page.isLoading && page.title == "Second page" }
        let chrome = c.chrome(for:page)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        window.rootViewController = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles)
            .browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func pan(_ view:UIView) -> MobileCapsulePan.Host? {
            if let host = view as? MobileCapsulePan.Host { return host }
            return view.subviews.lazy.compactMap { pan($0) }.first
        }
        try await wait { (pan(window)?.bounds.width ?? 0) > 100 }
        try await Task.sleep(for:.milliseconds(100))
        let first = try XCTUnwrap(pan(window))
        first.action?(.began,.zero,.zero)
        first.action?(.changed,CGSize(width:-140,height:0),.zero)
        try await wait { page.webView.window === window }
        let parent = try XCTUnwrap(page.webView.superview), viewport = page.webView.bounds.size
        first.action?(.ended,CGSize(width:-140,height:0),CGSize(width:-220,height:0))
        try await wait { c.session.selectedTabID == page.id }
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertTrue(page.webView.superview === parent)
        XCTAssertEqual(page.webView.bounds.size,viewport); XCTAssertTrue(c.chrome(for:page) === chrome)
        let reverse = try XCTUnwrap(pan(window))
        reverse.action?(.began,.zero,.zero)
        reverse.action?(.changed,CGSize(width:140,height:0),.zero)
        reverse.action?(.ended,CGSize(width:140,height:0),CGSize(width:220,height:0))
        try await wait { c.session.selectedTabID == home.id }
        XCTAssertFalse(home.isInstantiated,"A blank tab must stay lazy and must not enter the WKWebView handoff gate")
        XCTAssertEqual(c.session.tabs.count,2)
    }

    func testEndedOnlyHorizontalFlickPreservesPaintHandoffAndBoundaries() async throws {
        for sourceIsHome in [false,true] {
            let profiles = MobileProfiles(), c = profiles.current
            defer { c.session.shutdown(); profiles.continuity.shutdown() }
            let source = try XCTUnwrap(c.session.selectedTab)
            if !sourceIsHome { source.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!) }
            let target = c.session.addTab(url:URL(string:"http://127.0.0.1:8768/two")!,select:false)
            target.activate()
            try await wait { !target.isLoading && target.title == "Second page" && (sourceIsHome || source.title == "Gesture Lab") }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
            window.rootViewController = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles)
                .browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            func pan(_ view:UIView) -> MobileCapsulePan.Host? {
                if let host = view as? MobileCapsulePan.Host { return host }
                return view.subviews.lazy.compactMap { pan($0) }.first
            }
            try await wait { (pan(window)?.bounds.width ?? 0)>100 && (sourceIsHome || source.webView.window === window) }
            try await Task.sleep(for:.milliseconds(100))
            func flick(_ distance:CGFloat) throws {
                let host = try XCTUnwrap(pan(window))
                XCTAssertTrue(host.acceptsInput)
                host.action?(.began,.zero,.zero)
                // UIKit can finish a short pan without delivering .changed.
                host.action?(.ended,CGSize(width:distance,height:0),CGSize(width:distance*8,height:0))
            }
            try flick(-40)
            try await wait { c.session.selectedTabID == target.id && !c.tabSwipe.isActive }
            let parent = try XCTUnwrap(target.webView.superview), viewport = target.webView.bounds.size
            try await Task.sleep(for:.milliseconds(100))
            XCTAssertTrue(target.webView.superview === parent); XCTAssertEqual(target.webView.bounds.size,viewport)
            try flick(20) // Velocity alone must not bypass the minimum travel.
            try await Task.sleep(for:.milliseconds(500))
            XCTAssertEqual(c.session.selectedTabID,target.id)
            try flick(40)
            try await wait { c.session.selectedTabID == source.id && !c.tabSwipe.isActive }
            try await Task.sleep(for:.milliseconds(100))
            try flick(40) // First-tab boundary.
            try await Task.sleep(for:.milliseconds(500))
            XCTAssertEqual(c.session.selectedTabID,source.id)
            try flick(-40)
            try await wait { c.session.selectedTabID == target.id && !c.tabSwipe.isActive }
            try await Task.sleep(for:.milliseconds(100))
            try flick(-40) // A short flick must not allocate a new last tab.
            try await Task.sleep(for:.milliseconds(500))
            XCTAssertEqual(c.session.selectedTabID,target.id); XCTAssertEqual(c.session.tabs.count,2)
            if sourceIsHome { XCTAssertFalse(source.isInstantiated) }
        }
    }

    func testHistoryControlsDoNotInstantiateADormantTab() throws {
        let controller = MobileController(); defer { controller.session.shutdown() }
        let tab = try XCTUnwrap(controller.session.selectedTab)
        XCTAssertFalse(tab.isInstantiated)
        let host = UIHostingController(rootView:HStack {
            MobileHistoryMenuSource(tab:tab,forward:false)
            MobileHistoryMenuSource(tab:tab,forward:true)
        })
        host.loadViewIfNeeded(); host.view.frame = CGRect(x:0,y:0,width:120,height:48)
        host.view.layoutIfNeeded()
        XCTAssertFalse(tab.isInstantiated, "Rendering disabled history controls must not allocate a WebKit view")
    }

    func testHighRefreshRequestEndsWhenInteractionAndWindowEnd() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow)
        let window = UIWindow(windowScene:scene), controller = UIViewController()
        let host = MobileWebHost(webView:WKWebView())
        controller.view = host; window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.layoutIfNeeded(); host.requestHighRefresh()
        XCTAssertTrue(host.requestsHighRefresh)
        try await wait { !host.requestsHighRefresh }
        host.applyMorph(progress:0.5,card:CGRect(x:16,y:80,width:180,height:260),animated:false)
        XCTAssertTrue(host.requestsHighRefresh)
        host.applyMorph(progress:0,card:.zero,animated:false)
        try await wait { !host.requestsHighRefresh }
        host.requestHighRefresh(); window.isHidden = true; window.rootViewController = nil
        try await wait { !host.requestsHighRefresh }
    }

    func testPreparedGridIsHiddenFromAccessibilityBeforeAndDuringSiteSettings() async throws {
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        try await wait { !tab.isLoading && tab.title == "Gesture Lab" }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene:scene)
        let root = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles)
            .browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func grid(_ parent:UIViewController) -> MobileTabGridController? {
            if let value = parent as? MobileTabGridController { return value }
            return parent.children.lazy.compactMap { grid($0) }.first
        }
        try await wait { grid(root)?.navigationController != nil }
        let native = try XCTUnwrap(grid(root)), navigation = try XCTUnwrap(native.navigationController)
        try await wait { native.view.isHidden && native.view.accessibilityElementsHidden }
        XCTAssertTrue(navigation.view.accessibilityElementsHidden)
        c.sheet = .site
        try await wait { root.presentedViewController != nil }
        XCTAssertTrue(native.view.isHidden)
        XCTAssertTrue(native.view.accessibilityElementsHidden)
        XCTAssertTrue(navigation.view.accessibilityElementsHidden,"The prepared grid must not expose Done behind a real sheet")
        c.sheet = nil
        try await wait { root.presentedViewController == nil }
        c.sheet = .tabs
        try await wait { c.tabPresentation.activeID == nil && !native.view.isHidden && !native.view.accessibilityElementsHidden }
        XCTAssertFalse(navigation.view.accessibilityElementsHidden)
    }

    func testGridGeometryUpdatesDoNotRebuildKeyboardContent() async throws {
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        try await wait { !tab.isLoading && tab.title == "Gesture Lab" }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow)
        let root = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles).browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        let window = UIWindow(windowScene:scene); window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await wait { tab.webView.window === window }
        c.sheet = .tabs
        try await wait { c.tabPresentation.activeID == nil }
        try await Task.sleep(for:.milliseconds(600))
        func findBar(_ controller:UIViewController) -> MobileKeyboardBar.Controller? {
            if let bar = controller as? MobileKeyboardBar.Controller { return bar }
            return controller.children.lazy.compactMap { findBar($0) }.first
        }
        let bar = try XCTUnwrap(findBar(root)), before = bar.contentUpdates
        c.tabPresentation.begin(tab)
        for index in 0..<24 {
            c.tabPresentation.cardFrames[tab.id] = CGRect(x:16+CGFloat(index),y:100,width:180,height:260)
            try await Task.sleep(for:.milliseconds(12))
        }
        XCTAssertLessThanOrEqual(bar.contentUpdates-before,1,"Card geometry must not rebuild the bar's SwiftUI graph per frame")
        c.tabPresentation.finish()
    }

    func testGridOpenCloseKeepsBarGraphAndReadsNativeAvailabilityLive() async throws {
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        try await wait { !tab.isLoading && tab.title == "Gesture Lab" }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        let root = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles).browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func bar(_ controller:UIViewController) -> MobileKeyboardBar.Controller? {
            if let value = controller as? MobileKeyboardBar.Controller { return value }
            return controller.children.lazy.compactMap { bar($0) }.first
        }
        try await wait { tab.webView.window === window }
        try await Task.sleep(for:.milliseconds(700))
        let native = try XCTUnwrap(bar(root)), initial = native.contentUpdates
        func grid(_ parent:UIViewController) -> MobileTabGridController? {
            if let value = parent as? MobileTabGridController { return value }
            return parent.children.lazy.compactMap { grid($0) }.first
        }
        let gridController = try XCTUnwrap(grid(root))
        func capsule(_ view:UIView) -> MobileCapsulePan.Host? {
            if let value = view as? MobileCapsulePan.Host { return value }
            return view.subviews.lazy.compactMap { capsule($0) }.first
        }
        let pan = try XCTUnwrap(capsule(native.view))
        XCTAssertTrue(pan.acceptsInput)
        for _ in 0..<3 {
            c.sheet = .tabs
            try await wait { c.tabPresentation.activeID == nil && !native.view.isUserInteractionEnabled && !gridController.view.isHidden }
            XCTAssertFalse(pan.acceptsInput,"Native input availability must read current grid state")
            c.sheet = nil
            try await wait { c.tabPresentation.activeID == nil && native.view.isUserInteractionEnabled && gridController.view.isHidden }
            XCTAssertTrue(pan.acceptsInput,"Returning to the page must restore input without replacing the bar")
            try await Task.sleep(for:.milliseconds(100))
        }
        let updates = native.contentUpdates-initial
        let evidence = XCTAttachment(string:"Three grid open/close cycles rebuilt the floating bar graph \(updates) times")
        evidence.name = "Grid bar graph invalidation"; evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertLessThanOrEqual(updates,1,"Input gating must not replace the resting floating bar graph")
    }

    func testHomeGridStaysVisibleUntilItsTransitionFinishes() async throws {
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        let root = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles)
            .browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func grid(_ parent:UIViewController) -> MobileTabGridController? {
            if let value = parent as? MobileTabGridController { return value }
            return parent.children.lazy.compactMap { grid($0) }.first
        }
        try await wait { grid(root) != nil }
        let native = try XCTUnwrap(grid(root))
        c.sheet = .tabs
        try await wait { !native.view.isHidden && c.tabPresentation.activeID == nil }
        c.sheet = nil
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(native.view.isHidden,"Home must not remove the grid during its transition")
        try await wait { native.view.isHidden && c.tabPresentation.activeID == nil }
    }

    func testNativeViewportCoalescesBarGeometryAndPreservesInsets() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        let controller = UIViewController(), web = WKWebView(), host = MobileWebHost(webView:web)
        controller.view = host; window.rootViewController = controller; window.makeKeyAndVisible()
        defer { host.detachViewport(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let viewport = MobileViewportLayout()
        host.configureViewport(viewport,top:47,bottom:34,includesBar:true)
        for index in 0..<20 { viewport.update(barHeight:64+CGFloat(index),keyboardOverlap:34) }
        try await Task.sleep(for:.milliseconds(40))
        XCTAssertEqual(web.obscuredContentInsets.top,47)
        XCTAssertEqual(web.obscuredContentInsets.bottom,117)
        XCTAssertEqual(web.scrollView.contentInset.bottom,117)
        viewport.update(barHeight:64,keyboardOverlap:310)
        try await Task.sleep(for:.milliseconds(40))
        XCTAssertEqual(web.obscuredContentInsets.bottom,374)
        host.configureViewport(viewport,top:47,bottom:34,includesBar:false)
        XCTAssertEqual(web.obscuredContentInsets.bottom,310,"Native Find omits the floating bar, not the keyboard occlusion")
    }

    func testFirstDocumentViewportPreparationKeepsRestoredGeometry() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene:scene), viewport = MobileViewportLayout()
        viewport.update(barHeight:56,keyboardOverlap:34)
        viewport.update(barHeight:72,keyboardOverlap:350,resting:false)
        let fresh = WKWebView(frame:.zero)
        viewport.prepare(fresh,window:window)
        XCTAssertEqual(fresh.bounds.size,window.bounds.size)
        XCTAssertEqual(fresh.obscuredContentInsets.bottom,window.safeAreaInsets.bottom+56,
                       "A new document starts with the resting bar, not the address keyboard")
        let restored = WKWebView(frame:CGRect(x:0,y:0,width:390,height:700))
        restored.scrollView.contentInset = UIEdgeInsets(top:17,left:0,bottom:21,right:0)
        viewport.prepare(restored,window:window)
        XCTAssertEqual(restored.bounds.size,CGSize(width:390,height:700))
        XCTAssertEqual(restored.scrollView.contentInset.top,17)
        XCTAssertEqual(restored.scrollView.contentInset.bottom,21)
    }

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

    func testShortFastFlickCommitsButHeldReversedAndBoundarySwipesDoNot() throws {
        let c = MobileController(); defer { c.session.shutdown() }
        let source = try XCTUnwrap(c.session.selectedTabID), target = c.session.addTab(select:false,load:false)
        let state = MobileChromeGestureState()
        for predicted in [CGFloat(-28),92] { // Held, then moving back toward the source.
            state.capsule(.began,translation:.zero,session:c.session)
            state.capsule(.changed,translation:CGSize(width:-28,height:0),session:c.session)
            state.capsule(.ended,translation:CGSize(width:-28,height:0),predicted:CGSize(width:predicted,height:0),session:c.session)
            XCTAssertEqual(c.session.selectedTabID,source)
        }
        state.capsule(.began,translation:.zero,session:c.session)
        state.capsule(.changed,translation:CGSize(width:28,height:0),session:c.session)
        state.capsule(.ended,translation:CGSize(width:28,height:0),predicted:CGSize(width:148,height:0),session:c.session)
        XCTAssertEqual(c.session.selectedTabID,source,"The first tab remains a hard boundary")
        state.capsule(.began,translation:.zero,session:c.session)
        state.capsule(.changed,translation:CGSize(width:-28,height:0),session:c.session)
        state.capsule(.ended,translation:CGSize(width:-28,height:0),predicted:CGSize(width:-148,height:0),session:c.session)
        XCTAssertEqual(c.session.selectedTabID,target.id)
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
        try await checkDiscardRestoration(withChrome:true)
    }
    func testDiscardRestorationWithoutChromeControl() async throws {
        try await checkDiscardRestoration(withChrome:false)
    }
    private func checkDiscardRestoration(withChrome:Bool) async throws {
        let previousTiming = getenv("ORIV_CHROME_TIMING").map { String(cString:$0) }
        setenv("ORIV_CHROME_TIMING","1",1)
        defer {
            if let previousTiming { setenv("ORIV_CHROME_TIMING",previousTiming,1) }
            else { unsetenv("ORIV_CHROME_TIMING") }
        }
        let c = MobileController(); defer { c.session.shutdown() }
        if !withChrome { c.session.configureWebView = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let tab = try XCTUnwrap(c.session.selectedTab), web = tab.webView
        web.frame = CGRect(x:0,y:0,width:390,height:700); host.view.addSubview(web)
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
        web.removeFromSuperview()
        let discarded = await discard(tab)
        XCTAssertTrue(discarded); XCTAssertFalse(tab.isInstantiated)
        XCTAssertEqual(c.session.selectedTabID,selected.id)
        c.session.selectTab(tab.id)
        host.view.addSubview(tab.webView)
        try await wait(context:{ "restore loading=\(tab.isLoading)/\(tab.webView.isLoading) restoring=\(tab.isRestoringWebView) path=\(tab.webView.url?.path ?? "nil") error=\(tab.errorMessage ?? "nil")" }) {
            tab.isInstantiated && !tab.isLoading && !tab.isRestoringWebView && tab.webView.url?.path == "/chrome-paint"
        }
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
        try await checkIdleWorkingSet(withChrome:true)
    }
    func testIdleWorkingSetWithoutChromeControl() async throws {
        try await checkIdleWorkingSet(withChrome:false)
    }
    private func checkIdleWorkingSet(withChrome:Bool) async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        if !withChrome { c.session.configureWebView = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        // Each selected page gets the same attachment lifecycle as the app.
        // WebKit may defer history/media work for never-presented views.
        for i in 0..<10 {
            let tab = c.session.addTab(url:URL(string:"http://127.0.0.1:8768/two?working-set=\(i)")!)
            host.view.subviews.forEach { $0.removeFromSuperview() }
            tab.webView.frame = window.bounds; host.view.addSubview(tab.webView)
            try await wait { !tab.isLoading && tab.title == "Second page" }
        }
        try await wait { c.session.tabs.filter(\.isInstantiated).allSatisfy {
            !$0.isLoading && !$0.webView.isLoading && $0.webView.url?.path == "/two" && $0.title == "Second page"
        } }
        let before = c.session.tabs.filter(\.isInstantiated).count
        c.trimBackgroundTabs(limit:2)
        try await wait(timeout:45,context:{ c.session.tabs.filter(\.isInstantiated).map {
            "selected=\($0.id == c.session.selectedTabID) private=\($0.isPrivate) loading=\($0.isLoading)/\($0.webView.isLoading) edited=\($0.hasEditedFields) attached=\($0.webView.superview != nil) matches=\($0.url == $0.webView.url)"
        }.joined(separator:"; ") }) { c.session.tabs.filter(\.isInstantiated).count <= 2 }
        let after = c.session.tabs.filter(\.isInstantiated).count
        let state = c.session.tabs.filter(\.isInstantiated).map { "selected=\($0.id == c.session.selectedTabID) loading=\($0.isLoading)/\($0.webView.isLoading) attached=\($0.webView.superview != nil) urlMatches=\($0.url == $0.webView.url)" }
        XCTAssertEqual(before,10); XCTAssertEqual(after,2,state.joined(separator:"; "))
        let dormant = try XCTUnwrap(c.session.tabs.first { !$0.isInstantiated && $0.url != nil })
        c.session.selectTab(dormant.id)
        host.view.subviews.forEach { $0.removeFromSuperview() }
        host.view.addSubview(dormant.webView)
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
        XCTAssertTrue(hit?.isDescendant(of:first.webView) == true,"Page input must pass through the chrome overlay: \(String(describing:hit))")
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
        try await wait { self.focusedField(in:root.view) != nil }
        let field = try XCTUnwrap(focusedField(in:root.view))
        // A headless simulator may have a hardware keyboard and report a zero
        // height software keyboard. Supply a native test input view so this
        // regression always exercises an actual positive-height keyboard.
        let previousInputView = field.inputView
        defer { field.inputView = previousInputView; field.reloadInputViews() }
        field.inputView = UIInputView(frame:CGRect(x:0,y:0,width:window.bounds.width,height:240),inputViewStyle:.keyboard)
        field.reloadInputViews()
        try await wait { (keyboard.frame?.height ?? 0) >= 240 }
        try await Task.sleep(for:.milliseconds(350))
        let frame = try XCTUnwrap(keyboard.frame)
        let rect = field.convert(field.bounds,to:window), keyboardRect = window.convert(frame,from:nil)
        XCTAssertLessThanOrEqual(rect.maxY,keyboardRect.minY+1)
        XCTAssertGreaterThanOrEqual(rect.maxY,keyboardRect.minY-24,"field=\(rect), keyboard=\(keyboardRect), window=\(window.bounds), safe=\(window.safeAreaInsets)")
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

    func testBaselineGridMorphKeepsFullViewportAndCancelsWithoutReparenting() async throws {
        let web = WKWebView(), host = MobileWebHost(webView:web)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, root = UIViewController(), window = UIWindow(windowScene:scene)
        root.view = host; window.rootViewController = root; window.makeKeyAndVisible(); host.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let parent = try XCTUnwrap(web.superview), viewport = web.bounds
        let card = CGRect(x:16,y:120,width:180,height:280)
        for progress:CGFloat in [0.2,0.5,0.9,1] {
            host.applyMorph(progress:progress,card:card,animated:false)
            XCTAssertTrue(web.superview === parent)
            XCTAssertEqual(web.bounds,viewport,"The baseline live morph must never give WebKit a card-sized viewport")
        }
        host.applyMorph(progress:0,card:card,animated:true)
        try await wait { !host.requestsHighRefresh }
        XCTAssertEqual(web.transform,.identity); XCTAssertTrue(web.superview === parent)
        XCTAssertTrue(window.hitTest(CGPoint(x:window.bounds.midX,y:window.bounds.midY),with:nil)?.isDescendant(of:web) == true)
        host.bounds.size.width -= 20; host.setNeedsLayout(); host.layoutIfNeeded()
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

    func testClosingTabReleasesViewsWhileThumbnailCallbackIsPending() async throws {
        let presentation = MobileTabPresentation()
        var web:PolishControlledSnapshotWebView? = PolishControlledSnapshotWebView()
        var tab:BrowserTab? = BrowserTab(dataStore:.nonPersistent())
        tab!.createWebView = { [view = web!] _ in view }
        weak var weakTab = tab
        weak var weakWeb = web
        tab!.navigate(to:URL(string:"http://127.0.0.1:8768/two")!)
        let id = tab!.id
        presentation.capture(tab!)
        try await wait { web?.completions.count == 1 }
        tab!.close(); presentation.remove(id)
        tab = nil; web = nil
        try await wait(timeout:2) { weakTab == nil && weakWeb == nil }
    }

    func testExpiredThumbnailAllowsRetryAndRejectsItsLateImage() async throws {
        let presentation = MobileTabPresentation(), web = PolishControlledSnapshotWebView()
        let tab = BrowserTab(dataStore:.nonPersistent())
        defer { tab.close(); presentation.remove(tab.id) }
        tab.createWebView = { _ in web }
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/two")!)
        try await wait { !tab.isLoading }
        presentation.capture(tab)
        XCTAssertEqual(web.completions.count,1)
        try await Task.sleep(for:.milliseconds(3200))
        presentation.capture(tab)
        XCTAssertEqual(web.completions.count,2,"A dropped snapshot reply cannot block future thumbnails")
        guard web.completions.count == 2 else { return }
        let image = UIGraphicsImageRenderer(size:CGSize(width:32,height:32)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x:0,y:0,width:32,height:32))
        }
        web.completions[0](image,nil)
        XCTAssertNil(presentation.images[tab.id],"An expired capture cannot overwrite the current backing")
        web.completions[1](image,nil)
        XCTAssertNotNil(presentation.images[tab.id])
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

    private func wait(timeout:TimeInterval = 15,context:() -> String = { "" },file:StaticString = #filePath,line:UInt = #line,_ condition:() -> Bool) async throws {
        let end = Date.now.addingTimeInterval(timeout)
        while !condition() && Date.now < end { try await Task.sleep(for:.milliseconds(20)) }
        let ready = condition()
        XCTAssertTrue(ready,context(),file:file,line:line)
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
@MainActor private final class PolishInvalidations { var count = 0 }

@MainActor private final class PolishHostingController<Content:View>:UIHostingController<Content> {
    private(set) var appeared = false
    override func viewDidAppear(_ animated:Bool) { super.viewDidAppear(animated); appeared = true }
}

@MainActor private final class PolishControlledMediaWebView:WKWebView {
    var mediaReplies:[@MainActor @Sendable (WKMediaPlaybackState) -> Void] = []
    override func requestMediaPlaybackState(completionHandler:@escaping @MainActor @Sendable (WKMediaPlaybackState) -> Void) {
        mediaReplies.append(completionHandler)
    }
}
