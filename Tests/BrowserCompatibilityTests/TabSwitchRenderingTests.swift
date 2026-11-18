import XCTest
import SwiftUI
import WebKit
import BrowserCore
@testable import BrowserEngine
#if os(macOS)
@testable import PersonalBrowser
#else
@testable import OrivMobile
#endif

/// App-owned offscreen/Simulator evidence. WK snapshots are rendering probes,
/// not a WindowServer compositor recording or a physical display measurement.
@MainActor final class TabSwitchRenderingTests: XCTestCase {
    func testSwitchFrameSequences() async throws {
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        #if os(macOS)
        let window = BackgroundUIMode.Window(contentRect: CGRect(x:0,y:0,width:800,height:600), styleMask:[.titled], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false
        BackgroundUIMode.show(window,key:false)
        defer { window.contentView = nil; window.close() }
        var retainedHost:WebViewHost?
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene:scene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        #endif
        func attach(_ tab:BrowserTab) {
            #if os(macOS)
            if let retainedHost { retainedHost.setTab(tab) }
            else { retainedHost = WebViewHost(webView:tab.webView,tab:tab) }
            window.contentView = retainedHost
            window.contentView?.layoutSubtreeIfNeeded()
            #else
            window.rootViewController = UIHostingController(rootView:MobileWebView(webView:tab.webView,chrome:PageChrome(),topInset:0,bottomInset:0,reduceTransparency:true,obscured:false,onFindVisibilityChange:{ _ in },onAppearanceChange:{ _ in },onScroll:{ _,_ in },tab:tab))
            window.layoutIfNeeded()
            #endif
        }
        var summary:[[String:Any]] = []
        #if os(macOS)
        let appearances = ["light", "dark"]
        #else
        let appearances = ["system"]
        #endif
        for appearance in appearances {
        #if os(macOS)
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        #endif
        for scenario in ["live", "discarded", "launch", "private", "heavy"] {
            let source = session.addTab(url:URL(string:"http://127.0.0.1:8768/swipe-dark")!)
            attach(source)
            try await wait { !source.isLoading && source.title == "Dark swipe page" }
            let path = scenario == "heavy" ? "tab-switch?heavy=1&delay=0.35" : "tab-switch?delay=0.35"
            let target = session.addTab(url:URL(string:"http://127.0.0.1:8768/\(path)")!,isPrivate:scenario == "private",select:false,load:false)
            if scenario != "launch" {
                session.selectTab(target.id); attach(target)
                try await wait { !target.isLoading && target.title == "Tab switch fixture" }
                session.selectTab(source.id); attach(source)
                // Let background capture finish without including it in switch latency.
                try await Task.sleep(for:.milliseconds(120))
            }
            if scenario == "discarded" {
                let discarded = await withCheckedContinuation { continuation in target.discardBackgroundWebView { continuation.resume(returning:$0) } }
                XCTAssertTrue(discarded)
                XCTAssertFalse(target.isInstantiated)
            }
            let started = ProcessInfo.processInfo.systemUptime
            session.selectTab(target.id); attach(target)
            #if os(macOS)
            let cover = try XCTUnwrap(retainedHost?.switchCover)
            #else
            let cover = try XCTUnwrap(findCover(window))
            #endif
            if scenario == "discarded" {
                XCTAssertTrue(cover.containsSnapshot,"A discarded destination must have its last frame before the restore paints")
            }
            if ["discarded","launch"].contains(scenario) { XCTAssertFalse(cover.isHidden) }
            var rows:[[String:Any]] = []
            for frame in 0..<10 {
                let request = ProcessInfo.processInfo.systemUptime-started
                let covered = !cover.isHidden
                let snapshot = cover.containsSnapshot
                XCTAssertTrue(covered || target.hasRenderedContent,"Never expose an unpainted view")
                if covered {
                    #if os(macOS)
                    cover.layoutSubtreeIfNeeded()
                    let rep = try XCTUnwrap(cover.bitmapImageRepForCachingDisplay(in:cover.bounds))
                    cover.cacheDisplay(in:cover.bounds,to:rep)
                    let surface = XCTAttachment(data:try XCTUnwrap(rep.representation(using:.png,properties:[:])),uniformTypeIdentifier:"public.png")
                    #else
                    cover.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(bounds:cover.bounds).image { context in cover.layer.render(in:context.cgContext) }
                    let surface = XCTAttachment(image:image)
                    #endif
                    surface.name = "\(appearance)-\(scenario)-cover-\(frame)-\(Int(request*1000))ms"; surface.lifetime = .keepAlways; add(surface)
                }
                let config = WKSnapshotConfiguration(); config.snapshotWidth = 160; config.afterScreenUpdates = true
                #if os(macOS)
                let image:NSImage = try await withCheckedThrowingContinuation { reply in
                    target.webView.takeSnapshot(with:config) { image,error in
                        if let image { reply.resume(returning:image) } else { reply.resume(throwing:error ?? NSError(domain:"Snapshot",code:1)) }
                    }
                }
                #else
                let image:UIImage = try await withCheckedThrowingContinuation { reply in
                    target.webView.takeSnapshot(with:config) { image,error in
                        if let image { reply.resume(returning:image) } else { reply.resume(throwing:error ?? NSError(domain:"Snapshot",code:1)) }
                    }
                }
                #endif
                let completed = ProcessInfo.processInfo.systemUptime-started
                #if os(macOS)
                let attachment = XCTAttachment(data:try XCTUnwrap(image.tiffRepresentation),uniformTypeIdentifier:"public.tiff")
                #else
                let attachment = XCTAttachment(image:image)
                #endif
                attachment.name = "\(appearance)-\(scenario)-web-\(frame)-\(Int(completed*1000))ms"; attachment.lifetime = .keepAlways; add(attachment)
                rows.append(["requestMs":request*1000,"completedMs":completed*1000,"loading":target.isLoading,
                    "covered":covered,"snapshot":snapshot,"documentPainted":target.hasRenderedContent])
                try await Task.sleep(for:.milliseconds(40))
            }
            summary.append(["appearance":appearance,"scenario":scenario,"frames":rows])
            try await wait { cover.isHidden }
            session.closeTab(target.id); session.closeTab(source.id)
        }
        }
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = "tab-switch-timings"; attachment.lifetime = .keepAlways; add(attachment)
    }
    #if os(iOS)
    private func findCover(_ view:UIView) -> TabSwitchCover? {
        if let cover = view as? TabSwitchCover { return cover }
        return view.subviews.lazy.compactMap { self.findCover($0) }.first
    }
    #endif
    func testTransientRenderBarrierFailureRetriesWithoutExposingTheView() async throws {
        let tab = BrowserTab(dataStore:.nonPersistent())
        defer { tab.close() }
        tab.createWebView = { RetrySnapshotView(frame:CGRect(x:0,y:0,width:800,height:600),configuration:$0) }
        let view = try XCTUnwrap(tab.webView as? RetrySnapshotView)
        tab.webView(view,didFinish:nil)
        #if os(macOS)
        let window = BackgroundUIMode.Window(contentRect:CGRect(x:0,y:0,width:800,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let host = WebViewHost(webView:view,tab:tab)
        window.contentView = host; BackgroundUIMode.show(window,key:false); host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        let host = MobileWebHost(webView:view,tab:tab)
        window.rootViewController = UIViewController(); window.rootViewController!.view.addSubview(host)
        host.frame = window.bounds; window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        #endif
        XCTAssertFalse(host.switchCover.isHidden)
        try await wait { host.switchCover.isHidden }
        XCTAssertEqual(view.attempts,2)
    }
    func testSavedSessionSelectionCoversDormantTabWithoutLoadingItsPeers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = SessionFileStore(fileURL:directory.appendingPathComponent("session.json"))
        let records = [TabRecord(),TabRecord(title:"Restored",url:URL(string:"http://127.0.0.1:8768/tab-switch?delay=0.35")),TabRecord(title:"Dormant",url:URL(string:"http://127.0.0.1:8768/two"))]
        try store.save(BrowserSnapshot(tabs:records,selectedTabID:records[0].id))
        let session = BrowserSession(store:store,dataStore:.nonPersistent(),adBlocker:AdBlocker(defaults:nil),settings:BrowserSettings(defaults:nil))
        defer { session.shutdown() }
        XCTAssertTrue(session.tabs.allSatisfy { !$0.isInstantiated })
        let tab = session.tabs[1], peer = session.tabs[2]
        XCTAssertFalse(tab.hasLoaded); XCTAssertNil(tab.switchSnapshot)
        let started = ProcessInfo.processInfo.systemUptime
        session.selectTab(tab.id)
        #if os(macOS)
        let window = BackgroundUIMode.Window(contentRect:CGRect(x:0,y:0,width:800,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let host = WebViewHost(webView:tab.webView,tab:tab)
        window.contentView = host; BackgroundUIMode.show(window,key:false); host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        let host = MobileWebHost(webView:tab.webView,tab:tab)
        window.rootViewController = UIViewController(); window.rootViewController!.view.addSubview(host)
        host.frame = window.bounds; host.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        #endif
        XCTAssertFalse(host.switchCover.isHidden); XCTAssertTrue(host.switchCover.isOpaque)
        XCTAssertFalse(host.switchCover.containsSnapshot)
        try await wait { host.switchCover.isHidden && tab.hasRenderedContent }
        XCTAssertFalse(peer.isInstantiated,"Selecting a restored tab must not warm or load peers")
        print("TAB_SWITCH_RESTORED_SESSION readyMs=\((ProcessInfo.processInfo.systemUptime-started)*1000)")
    }
    func testPrivateCoverDropsDecodedImageOnCloseAndMemoryPurge() throws {
        let session = BrowserSession(dataStore:.nonPersistent(),adBlocker:AdBlocker(defaults:nil),settings:BrowserSettings(defaults:nil))
        defer { session.shutdown() }
        let tab = session.addTab(isPrivate:true,load:false)
        let context = try XCTUnwrap(CGContext(data:nil,width:16,height:16,bitsPerComponent:8,bytesPerRow:64,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:8,height:8))
        let snapshot = try XCTUnwrap(TabSnapshotCache.compress(try XCTUnwrap(context.makeImage())))
        session.tabSnapshots.insert(snapshot,for:tab.id)
        let cover = TabSwitchCover(); cover.begin(tab,in:tab.webView)
        XCTAssertTrue(cover.containsSnapshot)
        session.tabSnapshots.removeAll()
        XCTAssertFalse(cover.containsSnapshot)
        session.tabSnapshots.insert(snapshot,for:tab.id); cover.begin(tab,in:tab.webView)
        XCTAssertTrue(cover.containsSnapshot)
        session.closeTab(tab.id)
        XCTAssertFalse(cover.containsSnapshot)
    }
    #if os(macOS)
    func testSwitchWaitsForWebKitToReturnItsFullscreenView() {
        let source = BrowserTab(dataStore:.nonPersistent()), target = BrowserTab(dataStore:.nonPersistent())
        defer { source.close(); target.close() }
        source.createWebView = { PresentationWebView(frame:.zero,configuration:$0) }
        let view = source.webView as! PresentationWebView
        let host = WebViewHost(webView:view,tab:source)
        let managed = NSView(); view.removeFromSuperview(); managed.addSubview(view)
        view.presentationState = .inFullscreen
        host.setTab(target)
        XCTAssertTrue(host.webView === view)
        XCTAssertTrue(view.superview === managed,"The host must not remove a WebKit-owned fullscreen view")
        XCTAssertEqual(view.closeRequests,1)
        // Simulate WebKit restoring its own placeholder before completion.
        view.removeFromSuperview(); host.addSubview(view)
        view.presentationState = .notInFullscreen
        view.completePresentation?()
        XCTAssertTrue(host.webView === target.webView)
        XCTAssertNil(view.superview)
    }
    func testIdleReserveAndPressureReleaseRealWebViews() async throws {
        let session = BrowserSession(dataStore:.nonPersistent(),adBlocker:AdBlocker(defaults:nil),settings:BrowserSettings(defaults:nil))
        session.tabReclamationMonitor?.stopSources()
        defer { session.shutdown() }
        var tabs:[BrowserTab] = []
        for _ in 0..<5 {
            let tab = session.addTab(url:URL(string:"http://127.0.0.1:8768/tab-switch")!)
            tab.webView.frame = CGRect(x:0,y:0,width:800,height:600)
            try await wait { !tab.isLoading && tab.title == "Tab switch fixture" }
            tabs.append(tab)
        }
        for (index,tab) in tabs.enumerated() { tab.recoveryClock = { 10000 }; tab.lastSelectedTime = Double(1000+index) }
        let idle = await session.reclaimBackgroundTabs()
        XCTAssertEqual(idle,2); XCTAssertEqual(tabs.filter(\.isInstantiated).map(\.id),tabs.suffix(3).map(\.id))
        let pressure = await session.reclaimBackgroundTabs(underMemoryPressure:true)
        XCTAssertEqual(pressure,2); XCTAssertEqual(tabs.filter(\.isInstantiated).map(\.id),[tabs.last!.id])
        XCTAssertEqual(session.tabSnapshots.count,0)
    }
    func testSwiftUIUpdatesOneHostAcrossLiveTabSelection() async throws {
        let session = BrowserSession(dataStore:.nonPersistent(),adBlocker:AdBlocker(defaults:nil),settings:BrowserSettings(defaults:nil))
        defer { session.shutdown() }
        let a = session.addTab(url:URL(string:"http://127.0.0.1:8768/swipe-dark")!)
        let b = session.addTab(url:URL(string:"http://127.0.0.1:8768/swipe-light")!,select:false,load:false)
        let window = BackgroundUIMode.Window(contentRect:CGRect(x:0,y:0,width:800,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView:SwitchFixture(session:session))
        window.contentView = root; BackgroundUIMode.show(window,key:false)
        defer { window.contentView = nil; window.close() }
        func host(_ view:NSView) -> WebViewHost? {
            if let view = view as? WebViewHost { return view }
            return view.subviews.lazy.compactMap { host($0) }.first
        }
        try await wait { a.webView.window === window }
        let first = try XCTUnwrap(host(root))
        session.selectRelativeTab(1)
        try await wait { b.webView.window === window }
        XCTAssertTrue(host(root) === first); XCTAssertTrue(first.webView === b.webView)
        XCTAssertNil(a.webView.superview)
        XCTAssertTrue(b.switchPresentation == nil || b.switchPresentation === first.switchCover)
        let matches = await session.indexedSuggestions(for: "127.0.0.1", isPrivate: false)
        let match = try XCTUnwrap(matches.first { $0.tabID == a.id })
        session.selectTab(try XCTUnwrap(match.tabID))
        try await wait { a.webView.window === window }
        XCTAssertTrue(host(root) === first); XCTAssertTrue(first.webView === a.webView)
        XCTAssertNil(b.webView.superview)
        XCTAssertNil(b.switchPresentation, "Switching away cancels the previous destination cover")
        session.selectTab(b.id)
        try await wait { b.webView.window === window }
        b.close(); first.setTab(b)
        XCTAssertFalse(b.isInstantiated,"A late host update must not recreate a closed tab")
    }
    private struct SwitchFixture:View {
        let session:BrowserSession
        var body:some View { if let tab = session.selectedTab { WebPageView(tab:tab) } }
    }
    #endif
    private func wait(_ predicate:@escaping () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for:.milliseconds(30)) }
        XCTFail("Fixture did not settle"); throw NSError(domain:"TabSwitchFixture",code:1)
    }
}

#if os(macOS)
@MainActor private final class PresentationWebView:WKWebView {
    var presentationState:WKWebView.FullscreenState = .notInFullscreen
    override var fullscreenState:WKWebView.FullscreenState { presentationState }
    var closeRequests = 0
    var completePresentation:(@MainActor @Sendable () -> Void)?
    override func closeAllMediaPresentations(completionHandler:(@MainActor @Sendable () -> Void)? = nil) {
        closeRequests += 1; completePresentation = completionHandler
    }
}
#endif

@MainActor private final class RetrySnapshotView:WKWebView {
    var attempts = 0
    #if os(macOS)
    override func takeSnapshot(with configuration:WKSnapshotConfiguration?,completionHandler:@escaping @MainActor @Sendable (NSImage?,Error?) -> Void) {
        attempts += 1
        completionHandler(attempts == 1 ? nil : NSImage(size:CGSize(width:8,height:8)),nil)
    }
    #else
    override func takeSnapshot(with configuration:WKSnapshotConfiguration?,completionHandler:@escaping @MainActor @Sendable (UIImage?,Error?) -> Void) {
        attempts += 1
        completionHandler(attempts == 1 ? nil : UIGraphicsImageRenderer(size:CGSize(width:8,height:8)).image { _ in },nil)
    }
    #endif
}
