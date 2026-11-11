import XCTest
import BrowserCore
import BrowserEngine
import WebKit
@testable import OrivMobile

@MainActor final class MobileGestureIntegrationTests: XCTestCase {
    private func session() -> BrowserSession {
        BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
    }
    func testChromeHysteresisKeepsTopJitterOutAndPreservesCachedBand() async throws {
        let s = session(); defer { s.shutdown() }
        let tab = try XCTUnwrap(s.selectedTab), web = tab.webView, chrome = PageChrome()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let controller = UIViewController(); controller.view = MobileWebHost(webView: web)
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { chrome.observe(nil); window.isHidden = true; previous?.makeKeyAndVisible() }
        web.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        web.loadHTMLString("<meta name='viewport' content='width=device-width'><style>body{margin:0;height:5000px;background:#6600cc}</style><p>Boundary fixture</p>", baseURL: URL(string: "https://fixture.invalid"))
        for _ in 0..<100 { if !web.isLoading && web.url != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        chrome.observe(web)
        for _ in 0..<100 { if chrome.sampleCount > 0 { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThan(chrome.sampleCount, 0)
        let band = chrome.color
        for y in [2,0,2,0,8,2,0] {
            _ = try await web.evaluateJavaScript("window.scrollTo(0, \(y))")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(chrome.hasScrolled); XCTAssertEqual(chrome.color, band)
        }
        _ = try await web.evaluateJavaScript("window.scrollTo(0,30)")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(chrome.hasScrolled); XCTAssertTrue(chrome.showsContentUnderChrome)
        _ = try await web.evaluateJavaScript("window.scrollTo(0,2)")
        try await Task.sleep(for: .milliseconds(200)); XCTAssertTrue(chrome.hasScrolled)
        _ = try await web.evaluateJavaScript("window.scrollTo(0,0)")
        try await Task.sleep(for: .milliseconds(250)); XCTAssertFalse(chrome.hasScrolled)
        XCTAssertEqual(chrome.color, band)
    }

    func testNativeRefreshEndsOnFinishFailureCancelAndShortPagesBounce() throws {
        let s = session(); defer { s.shutdown() }
        let tab = try XCTUnwrap(s.selectedTab), view = tab.webView
        let host = UIViewController(); host.view.addSubview(view); view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = view.frame; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let refresh = try XCTUnwrap(view.scrollView.refreshControl)
        XCTAssertTrue(view.scrollView.alwaysBounceVertical)
        refresh.beginRefreshing(); XCTAssertTrue(refresh.isRefreshing); tab.webView(view, didFinish: nil); XCTAssertFalse(refresh.isRefreshing)
        refresh.beginRefreshing(); XCTAssertTrue(refresh.isRefreshing); tab.webView(view, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet)); XCTAssertFalse(refresh.isRefreshing)
        refresh.beginRefreshing(); XCTAssertTrue(refresh.isRefreshing); tab.webView(view, didFail: nil, withError: URLError(.cancelled)); XCTAssertFalse(refresh.isRefreshing)
        refresh.beginRefreshing(); XCTAssertTrue(refresh.isRefreshing); tab.stop(); XCTAssertFalse(refresh.isRefreshing)
        XCTAssertTrue(view.configuration.ignoresViewportScaleLimits)
        XCTAssertTrue(view.allowsBackForwardNavigationGestures)
    }
    func testRefreshInsetsRemainStableDuringSwiftUIUpdates() throws {
        let s = session(); defer { s.shutdown() }
        let tab = try XCTUnwrap(s.selectedTab), view = tab.webView
        let host = MobileWebHost(webView: view)
        host.updateInsets(top: 62, bottom: 100)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let controller = UIViewController(); controller.view = host
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        view.scrollView.refreshControl?.beginRefreshing()
        view.scrollView.contentInset.top = 122
        host.updateInsets(top: 62, bottom: 100)
        XCTAssertEqual(view.scrollView.contentInset.top, 122)
        view.scrollView.refreshControl?.endRefreshing()
        host.updateInsets(top: 62, bottom: 100)
        XCTAssertEqual(view.scrollView.contentInset.top, 62)
    }
    func testImageTransferUsesWebKitAndReturnsOriginalPNGBytes() async throws {
        let s = session(); defer { s.shutdown() }
        let tab = try XCTUnwrap(s.selectedTab), transfer = MobileImageTransfer()
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            transfer.run(url: URL(string: "http://127.0.0.1:8768/gesture-image.png")!, in: tab.webView) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(Array(result.prefix(8)), [137,80,78,71,13,10,26,10])
        XCTAssertNotNil(UIImage(data: result))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL.temporaryDirectory.appendingPathComponent("OrivImage-\(transfer.id.uuidString)").path))
    }
    func testGridAccessibilityMoveActionChangesOrderWithinItsSection() throws {
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown() }
        let first = try XCTUnwrap(c.session.selectedTab), second = c.session.addTab(select: false, load: false)
        let grid = MobileTabGridController(model: MobileTabGrid(controller: c, profiles: profiles, tabs: c.session.orderedTabs, largeText: false, reduceMotion: true, open: { _ in }, onPull: { _, _ in }))
        grid.loadViewIfNeeded()
        grid.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        grid.collectionView.frame = grid.view.bounds
        grid.collectionView.reloadData(); grid.collectionView.layoutIfNeeded()
        let cell = try XCTUnwrap(grid.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
        let actions = try XCTUnwrap(cell.accessibilityCustomActions)
        XCTAssertTrue(Set(["Move Earlier", "Move Later", "Close Tab", "Duplicate Tab", "Copy Link", "Close Other Tabs"]).isSubset(of: Set(actions.map(\.name))))
        let later = try XCTUnwrap(actions.first { $0.name == "Move Later" })
        XCTAssertEqual(later.actionHandler?(later), true)
        XCTAssertEqual(c.session.orderedTabs.map(\.id), [second.id, first.id])
    }
    func testMovingLastExternalPrivateTabDisposesGroupAndPreservesPrivacy() throws {
        let savedProfiles = UserDefaults.standard.data(forKey: "OrivMobileProfiles")
        let savedSelection = UserDefaults.standard.string(forKey: "BrowserProfileID")
        let profiles = MobileProfiles()
        defer { profiles.current.session.shutdown(); profiles.continuity.shutdown() }
        XCTAssertTrue(profiles.openExternalLinksPrivately)
        let url = URL(string: "http://127.0.0.1:8768/gestures")!
        profiles.route(url)
        let source = try XCTUnwrap(profiles.externalPrivate)
        let tab = try XCTUnwrap(source.session.selectedTab)
        let originalStore = tab.webView.configuration.websiteDataStore
        // Exercise the transfer after the user-approved private close; the UI
        // route gates this through MobileController.closeNeedsConfirmation.
        XCTAssertTrue(source.closeNeedsConfirmation([tab.id]))
        source.session.closeTab(tab.id)
        profiles.move(tab, from: source, to: .personal)
        XCTAssertNil(profiles.externalPrivate)
        XCTAssertTrue(source.session.tabs.isEmpty)
        let moved = try XCTUnwrap(profiles.current.session.selectedTab)
        XCTAssertTrue(moved.isPrivate); XCTAssertEqual(moved.url, url)
        XCTAssertFalse(moved.webView.configuration.websiteDataStore === originalStore)
        XCTAssertFalse(profiles.current.session.snapshot().tabs.contains { $0.id == moved.id })
        XCTAssertEqual(UserDefaults.standard.data(forKey: "OrivMobileProfiles"), savedProfiles)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "BrowserProfileID"), savedSelection)
    }
    func testNativeFindSessionPrefillsAndEndsWhenTabChanges() async throws {
        let s = session(); defer { s.shutdown() }
        let tab = try XCTUnwrap(s.selectedTab)
        let webHost = MobileWebHost(webView: tab.webView)
        let host = UIViewController(); host.view = webHost; webHost.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        tab.webView.frame = webHost.bounds
        var findVisible = false
        webHost.onFindVisibilityChange = { findVisible = $0 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = tab.webView.frame; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        tab.webView.loadHTMLString("<meta name='viewport' content='width=device-width'><title>Find Integration</title><p>Alpha alpha alphabet Alpha</p>", baseURL: URL(string: "https://example.test"))
        try await wait { tab.title == "Find Integration" && !tab.isLoading }
        XCTAssertTrue(tab.webView.isFindInteractionEnabled)
        let find = try XCTUnwrap(tab.webView.findInteraction)
        find.searchText = "Alpha"; tab.showFind()
        try await wait { find.isFindNavigatorVisible }
        webHost.refreshFindVisibility()
        try await wait { findVisible }
        XCTAssertEqual(find.searchText, "Alpha")
        XCTAssertNotNil(find.activeFindSession)
        s.addTab(load: false)
        XCTAssertFalse(tab.webView.isFindInteractionEnabled)
        XCTAssertNil(tab.webView.findInteraction)
        webHost.refreshFindVisibility()
        try await wait { !findVisible }
        s.selectTab(tab.id)
        XCTAssertTrue(tab.webView.isFindInteractionEnabled)
        XCTAssertFalse(try XCTUnwrap(tab.webView.findInteraction).isFindNavigatorVisible)
    }
    func testImageContextTrackingAndOwnedLinkMenuHasApprovedCommands() async throws {
        let controller = MobileController()
        defer { controller.session.shutdown() }
        let tab = try XCTUnwrap(controller.session.selectedTab)
        let delegate = try XCTUnwrap(tab.webView.uiDelegate as? MobileWebDelegate)
        tab.webView.loadHTMLString("<img src='https://example.test/image.png'><a href='https://example.test/two'>Link</a>", baseURL: URL(string: "https://example.test"))
        try await wait { tab.hasLoaded && !tab.isLoading }
        let titles = delegate.linkActions(URL(string: "https://example.test/two")!, revision: tab.documentRevision).map(\.title)
        XCTAssertEqual(titles, ["Load Preview", "Open", "Open in New Tab", "Open in Background", "Open in Private Tab", "Open in Another Profile", "Download Linked File", "Copy Link", "Copy Original Link", "Share", "Open on Mac"])
        _ = try await tab.webView.callAsyncJavaScript("window.webkit.messageHandlers.orivContext.postMessage({image:'https://example.test/image.png'})", arguments: [:], in: nil, contentWorld: .world(name: "OrivContext"))
        try await wait { delegate.touchedImageURL != nil }
        XCTAssertEqual(delegate.touchedImageRevision, tab.documentRevision)
    }
    func testNormalEditedCloseIsImmediateAndRecoverableButPrivateAndBulkRequireConfirmation() async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/quality")!)
        try await wait { tab.title == "Browser quality fixture" && !tab.isLoading }
        _ = try await tab.webView.callAsyncJavaScript("window.webkit.messageHandlers.editedField.postMessage(true)",arguments:[:],in:nil,contentWorld:.world(name:"OrivTabState"))
        try await wait { c.session.requiresCloseConfirmation(tab.id) }
        XCTAssertFalse(c.closeNeedsConfirmation([tab.id]))
        XCTAssertTrue(c.closeNeedsConfirmation([tab.id],confirmAll:true))
        c.close([tab.id])
        XCTAssertFalse(c.session.tabs.contains { $0.id == tab.id })
        XCTAssertTrue(c.session.recentlyClosedTabs.contains { $0.id == tab.id })
        let closed = try XCTUnwrap(c.session.recentlyClosedTabs.first)
        c.session.reopenClosedTab(closed.id)
        XCTAssertEqual(c.session.selectedTab?.url,URL(string:"http://127.0.0.1:8768/quality"))
        let privateTab = c.session.addTab(url:URL(string:"https://example.test/private"),isPrivate:true,load:false)
        XCTAssertTrue(c.closeNeedsConfirmation([privateTab.id]))
        XCTAssertTrue(c.closeNeedsConfirmation([privateTab.id],confirmAll:true))
        XCTAssertFalse(c.session.recentlyClosedTabs.contains { $0.id == privateTab.id })
    }
    func testSwipeVelocityThresholdAndPrivateSnapshotRemoval() async throws {
        XCTAssertTrue(MobileTabCell.swipeCommits(distance:-30,velocity:-1000,width:180))
        XCTAssertFalse(MobileTabCell.swipeCommits(distance:-30,velocity:-100,width:180))
        XCTAssertFalse(MobileTabCell.swipeCommits(distance:-5,velocity:-2000,width:180))
        XCTAssertTrue(MobileTabCell.swipeCommits(distance:-100,velocity:0,width:180))
        let c = MobileController(); defer { c.session.shutdown() }
        let tab = c.session.addTab(isPrivate:true,load:false)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        try await wait { tab.title == "Gesture Lab" && !tab.isLoading }
        c.tabPresentation.begin(tab); c.tabPresentation.cardFrames[tab.id] = CGRect(x:16,y:100,width:180,height:250)
        c.tabPresentation.capture(tab)
        c.tabPresentation.settleInGrid(tab)
        c.session.closeTab(tab.id)
        await Task.yield()
        XCTAssertFalse(tab.isInstantiated,"A queued thumbnail must not recreate a closed private web view")
        XCTAssertNil(c.tabPresentation.images[tab.id])
        XCTAssertNil(c.tabPresentation.activeID); XCTAssertNil(c.tabPresentation.cardFrames[tab.id])
    }
    func testNavigationPaintDoesNotWaitForTheSlowImageOnPhone() async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab), web = tab.webView, chrome = PageChrome()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where:\.isKeyWindow)
        let host = UIViewController(); host.view = MobileWebHost(webView:web)
        let window = UIWindow(windowScene:scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { chrome.observe(nil); window.isHidden = true; previous?.makeKeyAndVisible() }
        web.frame = CGRect(x:0,y:0,width:390,height:700)
        var firstPaintAnimated: Bool?
        PageChrome.diagnosticObserver = { current in
            if current === chrome, current.sampledTop != nil, firstPaintAnimated == nil { firstPaintAnimated = current.animatesColor }
        }
        defer { PageChrome.diagnosticObserver = nil }
        chrome.observe(web)
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/chrome-paint")!)
        try await wait { chrome.sampledTop != nil }
        XCTAssertTrue(web.isLoading,"The page colour must arrive while the delayed image still loads")
        XCTAssertEqual(firstPaintAnimated,false,"Initial paint must not fade from the previous page")
        let rgb = UIColor(chrome.color)
        var red:CGFloat=0, green:CGFloat=0, blue:CGFloat=0, alpha:CGFloat=0
        rgb.getRed(&red,green:&green,blue:&blue,alpha:&alpha)
        XCTAssertEqual(red,99.0/255,accuracy:0.002); XCTAssertEqual(blue,221.0/255,accuracy:0.002)
    }

    func testTransitionReparentingKeepsWebKitViewportAndRestoresItsHost() async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab), web = tab.webView
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where:\.isKeyWindow)
        let root = UIViewController(), window = UIWindow(windowScene:scene)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let host = MobileWebHost(webView:web); host.frame = CGRect(x:0,y:0,width:390,height:700)
        root.view.addSubview(host); host.layoutIfNeeded()
        tab.navigate(to:URL(string:"http://127.0.0.1:8768/gestures")!)
        try await wait { tab.title == "Gesture Lab" && !tab.isLoading }
        let viewport = try await web.evaluateJavaScript("[innerWidth,innerHeight]") as? [Double]
        let original = web.bounds
        let clip = UIView(frame:CGRect(x:16,y:130,width:180,height:250)); clip.clipsToBounds = true
        root.view.addSubview(clip); clip.addSubview(web)
        web.transform = CGAffineTransform(scaleX:0.46,y:0.46)
        host.setNeedsLayout(); host.layoutIfNeeded()
        XCTAssertTrue(web.superview === clip,"SwiftUI layout must not steal the page from its transition container")
        XCTAssertEqual(web.bounds,original,"The transform must not resize WebKit's viewport")
        let reparentedViewport = try await web.evaluateJavaScript("[innerWidth,innerHeight]") as? [Double]
        XCTAssertEqual(reparentedViewport, viewport)
        web.transform = .identity; host.addSubview(web); host.setNeedsLayout(); host.layoutIfNeeded()
        XCTAssertEqual(web.frame,host.bounds)
        XCTAssertTrue(web.superview === host)
    }

    private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let end = Date.now.addingTimeInterval(10)
        while !condition() && Date.now < end { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

/// Drive recognizer callbacks without synthesizing system UI or touching user data.
@MainActor private final class CancelTestPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var delta = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func translation(in view: UIView?) -> CGPoint { delta }
    override func velocity(in view: UIView?) -> CGPoint { delta }
}
@MainActor private final class CancelTestPinch: UIPinchGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
}
@MainActor private final class CancelTestHold: UILongPressGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
}

extension MobileGestureIntegrationTests {
    private var interruptions: [Notification.Name?] { [nil, UIApplication.willResignActiveNotification,
        UIApplication.didEnterBackgroundNotification, UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] }

    func testCapsuleCancellationAndSceneInterruptionRestoreChromeWithoutCommitting() throws {
        for notice in interruptions {
            for delta in [CGSize(width: -180, height: 0), CGSize(width: 0, height: -220)] {
                let s = session(); defer { s.shutdown() }
                let source = try XCTUnwrap(s.selectedTabID)
                s.addTab(select: false, load: false)
                let ids = s.tabs.map(\.id), state = MobileChromeGestureState()
                state.capsule(.began, translation: delta, session: s)
                state.capsule(.changed, translation: delta, session: s)
                XCTAssertNotNil(state.source)
                XCTAssertTrue(state.translation != 0 || state.gridProgress > 0)
                if let notice { NotificationCenter.default.post(name: notice, object: nil) }
                else { state.capsule(.cancelled, translation: delta, session: s) }
                XCTAssertNil(state.source); XCTAssertNil(state.axis)
                XCTAssertEqual(state.translation, 0); XCTAssertEqual(state.gridProgress, 0)
                XCTAssertFalse(state.gridClosing)
                XCTAssertFalse(state.capsule(.ended, translation: delta, session: s))
                XCTAssertEqual(s.selectedTabID, source); XCTAssertEqual(s.tabs.map(\.id), ids)
                if notice != nil {
                    // A late callback while inactive cannot restart the gesture.
                    state.capsule(.changed, translation: delta, session: s)
                    XCTAssertNil(state.source)
                    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                }
                state.gridPresented = true; state.gridProgress = 0.4; state.gridClosing = true
                state.cancel()
                XCTAssertEqual(state.gridProgress, 1); XCTAssertFalse(state.gridClosing)
            }
        }
    }
    func testCardSwipeAndPinchCancellationNeverCloseOrOpen() {
        for notice in interruptions {
            for reduced in [false, true] {
                let cell = MobileTabCell(frame: CGRect(x: 0, y: 0, width: 180, height: 280))
                cell.reduceMotion = reduced
                var closes = 0, opens = 0
                cell.close = { closes += 1 }; cell.open = { opens += 1 }
                let pan = CancelTestPan(), pinch = CancelTestPinch()
                pan.delta = CGPoint(x: -140, y: 0); pinch.scale = 1.6
                pan.state = .began; cell.swipe(pan)
                pan.state = .changed; cell.swipe(pan)
                pinch.state = .began; cell.pinch(pinch)
                pinch.state = .changed; cell.pinch(pinch)
                XCTAssertTrue(cell.swiping); XCTAssertTrue(cell.pinching)
                if let notice { NotificationCenter.default.post(name: notice, object: nil) }
                else {
                    pan.state = .cancelled; cell.swipe(pan)
                    pinch.state = .cancelled; cell.pinch(pinch)
                }
                XCTAssertFalse(cell.swiping); XCTAssertFalse(cell.pinching)
                // Complete any visual cancellation animation before reading the model layer.
                cell.contentView.layer.removeAllAnimations()
                XCTAssertEqual(cell.contentView.transform, .identity)
                XCTAssertEqual(cell.contentView.alpha, 1)
                pan.state = .ended; cell.swipe(pan)
                pinch.state = .ended; cell.pinch(pinch)
                XCTAssertEqual(closes, 0); XCTAssertEqual(opens, 0)
                NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            }
        }
    }
    func testGridPullCancellationAndSceneInterruptionRestorePresentedGrid() throws {
        for notice in interruptions {
            let profiles = MobileProfiles(), c = profiles.current
            defer { c.session.shutdown(); profiles.continuity.shutdown() }
            let ids = c.session.tabs.map(\.id), selected = c.session.selectedTabID
            var progress: CGFloat = 1, dismissed = false
            let grid = MobileTabGridController(model: MobileTabGrid(controller: c, profiles: profiles, tabs: c.session.orderedTabs,
                largeText: false, reduceMotion: true, open: { _ in XCTFail("Cancelled grid must not open a tab") }, onPull: { amount, ended in
                    if ended { dismissed = amount > 0.25; progress = dismissed ? 0 : 1 }
                    else { progress = 1 - amount }
                }))
            grid.loadViewIfNeeded(); grid.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            grid.collectionView.contentOffset.y = -grid.collectionView.adjustedContentInset.top
            let pan = CancelTestPan(); pan.delta = CGPoint(x: 0, y: 350)
            pan.state = .began; grid.panGrid(pan)
            pan.state = .changed; grid.panGrid(pan)
            XCTAssertTrue(grid.pulling); XCTAssertLessThan(progress, 1)
            if let notice { NotificationCenter.default.post(name: notice, object: nil) }
            else { pan.state = .cancelled; grid.panGrid(pan) }
            XCTAssertFalse(grid.pulling); XCTAssertFalse(grid.reordering)
            XCTAssertEqual(progress, 1); XCTAssertFalse(dismissed)
            pan.state = .ended; grid.panGrid(pan)
            XCTAssertFalse(dismissed); XCTAssertEqual(c.session.tabs.map(\.id), ids); XCTAssertEqual(c.session.selectedTabID, selected)
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }
    }
    func testImageHoldCancellationAndSceneInterruptionClearContextWithoutNavigation() throws {
        for notice in interruptions {
            let c = MobileController(); defer { c.session.shutdown() }
            let tab = try XCTUnwrap(c.session.selectedTab), delegate = try XCTUnwrap(tab.webView.uiDelegate as? MobileWebDelegate)
            let ids = c.session.tabs.map(\.id), url = tab.url
            let hold = CancelTestHold(); tab.webView.addGestureRecognizer(hold)
            delegate.touchedImageURL = URL(string: "https://example.test/image.png")
            delegate.touchedImageRevision = tab.documentRevision
            hold.state = .began; delegate.imageHeld(hold)
            hold.state = .changed; delegate.imageHeld(hold)
            XCTAssertNotNil(delegate.imageMenuTarget)
            if let notice { NotificationCenter.default.post(name: notice, object: nil) }
            else { hold.state = .cancelled; delegate.imageHeld(hold) }
            XCTAssertNil(delegate.imageMenuTarget); XCTAssertNil(delegate.touchedImageURL)
            hold.state = .ended; delegate.imageHeld(hold)
            XCTAssertEqual(c.session.tabs.map(\.id), ids); XCTAssertEqual(tab.url, url)
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }
    }
}
