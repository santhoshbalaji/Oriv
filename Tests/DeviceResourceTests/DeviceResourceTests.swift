import SwiftUI
import XCTest
import MachO
import Darwin
import WebKit
import UIKit
import BrowserCore
import BrowserEngine
@testable import OrivMobile

/// Isolated QA-host measurements. Never linked into the regular native suite.
@MainActor final class DeviceResourceTests: XCTestCase {
    private var previousIdleTimer:Bool?
    override func tearDown() async throws {
        await MainActor.run {
            if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        }
    }
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_DEVICE_QA"] == "1", "Hardware measurements are opt-in.")
        #if targetEnvironment(simulator)
        throw XCTSkip("Hardware measurements require a real iPhone.")
        #endif
        try XCTSkipUnless(Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true, "Requires an isolated .qa host.")
        await MainActor.run {
            previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
    func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    func evidence(_ name: String, _ row: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: row.merging(["uptime":ProcessInfo.processInfo.systemUptime,"epoch":Date().timeIntervalSince1970,
            "lowPowerMode":ProcessInfo.processInfo.isLowPowerModeEnabled,"thermalState":ProcessInfo.processInfo.thermalState.rawValue,
            "maximumFramesPerSecond":UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.maximumFramesPerSecond ?? 0],uniquingKeysWith:{ _,new in new }), options: [.sortedKeys, .prettyPrinted])
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); a.name = name; a.lifetime = .keepAlways; add(a)
        print("DEVICE_QA \(name) \(String(decoding: data, as: UTF8.self))")
    }
    // Debugging SPI stays in this opt-in test bundle, never an app target.
    // Instruments reports launchd as responsible on this OS. Read only the
    // process identities of this QA session's own views to avoid attributing
    // another browser's WebKit helpers to Oriv.
    func processIdentities(_ controller:MobileController) -> [String:Any] {
        var web = Set<Int>(), network = Set<Int>(), gpu = Set<Int>()
        func pid(_ object:NSObject,_ key:String) -> Int? {
            guard object.responds(to:NSSelectorFromString(key)),
                  let value = object.value(forKey:key) as? NSNumber, value.intValue > 0 else { return nil }
            return value.intValue
        }
        for tab in controller.session.tabs where tab.isInstantiated {
            let view = tab.webView
            if let id = pid(view,"_webProcessIdentifier") { web.insert(id) }
            if let id = pid(view.configuration.websiteDataStore,"_networkProcessIdentifier") { network.insert(id) }
            if let id = pid(view,"_gpuProcessIdentifier") { gpu.insert(id) }
        }
        return ["appPID":Int(getpid()),"webContentPIDs":web.sorted(),"networkPIDs":network.sorted(),"gpuPIDs":gpu.sorted()]
    }
    func test01UncachedProtectionCompile() async throws {
        let namespace = "oriv.deviceqa." + UUID().uuidString
        let blocker = AdBlocker(cacheNamespace:namespace), store = WKContentRuleListStore.default()!
        func identifiers() async -> [String] {
            await withCheckedContinuation { continuation in
                store.getAvailableContentRuleListIdentifiers { continuation.resume(returning:($0 ?? []).filter { $0.hasPrefix(namespace+".") }) }
            }
        }
        let existing = await identifiers(); XCTAssertTrue(existing.isEmpty)
        let before = footprint(); var peak = before; var samples = 0
        let sampler = Task { @MainActor in
            while !Task.isCancelled { peak = max(peak, self.footprint()); samples += 1; try? await Task.sleep(for: .milliseconds(10)) }
        }
        let started = ProcessInfo.processInfo.systemUptime
        try await blocker.prepare()
        let seconds = ProcessInfo.processInfo.systemUptime - started
        sampler.cancel(); peak = max(peak, footprint())
        let compiled = await identifiers(); XCTAssertGreaterThan(compiled.count,0)
        try evidence("uncached-rules", ["seconds": seconds, "beforeBytes": before, "peakBytes": peak, "afterBytes": footprint(), "samples": samples, "rulesCompiled": compiled.count, "maximumScreenHz": (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.maximumFramesPerSecond ?? 0, "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled, "thermalState": ProcessInfo.processInfo.thermalState.rawValue, "scope": "QA app process phys_footprint; excludes WebKit helper processes"])
        // Only this test's uniquely named lists in the QA container are removed.
        for identifier in compiled { try await store.removeContentRuleList(forIdentifier:identifier) }
    }
    func test02OneTenThirtyTabsDiscardRestoreAndLocalWarning() async throws {
        let c = MobileController(); defer { c.session.shutdown() }
        var readings: [[String: Any]] = []
        try await c.session.adBlocker.prepare()
        try await Task.sleep(for: .seconds(5)) // Let startup compile buffers settle before tab checkpoints.
        let initial = try XCTUnwrap(c.session.selectedTab)
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"])
        try XCTSkipUnless(fixture.hasPrefix("http://"), "Requires the configured LAN fixture.")
        for index in 1...30 {
            let tab = index == 1 ? initial : c.session.addTab(load: false)
            tab.webView.frame = CGRect(x:0,y:0,width:390,height:844)
            tab.navigate(to: try XCTUnwrap(URL(string: fixture + "/two?qa_tab=\(index)")))
            try await until { !tab.isLoading && tab.title == "Second page" }
            if [1, 10, 30].contains(index) {
                try await Task.sleep(for: .seconds(1))
                readings.append(["tabs": index, "liveViews": c.session.tabs.filter(\.isInstantiated).count, "footprintBytes": footprint(),"processes":processIdentities(c)])
                try evidence("tabs-\(index)", readings.last!)
                try await Task.sleep(for:.seconds(8))
            }
        }
        let before = footprint(), beforeLive = c.session.tabs.filter(\.isInstantiated).count
        c.trimBackgroundTabs(limit: 8)
        try await until { c.session.tabs.filter(\.isInstantiated).count <= 8 }
        let after = footprint(), afterLive = c.session.tabs.filter(\.isInstantiated).count
        try evidence("discarded",["liveViews":afterLive,"footprintBytes":after,"processes":processIdentities(c)])
        try await Task.sleep(for:.seconds(8))
        c.session.selectTab(initial.id)
        try await until { initial.isInstantiated && !initial.isRestoringWebView && !initial.webView.isLoading }
        XCTAssertEqual(initial.webView.title, "Second page")
        // In-process notification exercises only QA's observer. No system memory pressure is induced.
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await until { c.session.tabs.filter(\.isInstantiated).count <= 1 }
        XCTAssertTrue(c.session.selectedTab?.isInstantiated == true)
        try evidence("local-warning",["liveViews":c.session.tabs.filter(\.isInstantiated).count,"footprintBytes":footprint(),"processes":processIdentities(c)])
        try await Task.sleep(for:.seconds(8))
        try evidence("tab-memory", ["checkpoints": readings, "beforeDiscardBytes": before, "afterDiscardBytes": after, "beforeLive": beforeLive, "afterLive": afterLive, "afterLocalWarningBytes": footprint(), "afterLocalWarningLive": c.session.tabs.filter(\.isInstantiated).count, "restorationVerified": true, "warning": "in-process QA-only notification; not an OS memory-pressure event", "scope": "QA app process; excludes WebContent and Networking helpers"])
    }
    func test03NativeHistoryItemNavigation() async throws {
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"])
        let c = MobileController(); defer { c.session.shutdown() }
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.navigate(to: try XCTUnwrap(URL(string: fixture + "/gestures")))
        try await until { !tab.isLoading && tab.title == "Gesture Lab" }
        tab.navigate(to: try XCTUnwrap(URL(string: fixture + "/two")))
        try await until { !tab.isLoading && tab.title == "Second page" }
        let item = try XCTUnwrap(tab.webView.backForwardList.backItem)
        try evidence("history-item", ["identityPresent": tab.webView.backForwardList.backList.contains { $0 === item }, "backEntries": tab.webView.backForwardList.backList.count])
        tab.go(to: item)
        try await until { !tab.isLoading && tab.webView.url?.path == "/gestures" && tab.title == "Gesture Lab" }
        XCTAssertEqual(tab.title, "Gesture Lab")
    }
    func test04CleanCopyHasURLAndPlainText() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/path?utm_source=deviceqa&keep=1"))
        PrivacyPasteboard.copy(url)
        let expected = "https://example.test/path?keep=1"
        try evidence("clean-copy-types", ["hasURL": UIPasteboard.general.url != nil, "hasString": UIPasteboard.general.string != nil, "types": UIPasteboard.general.types])
        XCTAssertEqual(UIPasteboard.general.url?.absoluteString, expected)
        XCTAssertEqual(UIPasteboard.general.string, expected)
    }
    func test05DecodedSnapshotBudgetAndWarningPurge() throws {
        let c = MobileController(); defer { c.session.shutdown() }
        let cache = c.tabPresentation
        var maximum = 0
        for index in 0..<18 {
            autoreleasepool {
                let context = CGContext(data:nil,width:1024,height:1024,bitsPerComponent:8,bytesPerRow:4096,
                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(UIColor(red:CGFloat(index)/18,green:0.23,blue:0.79,alpha:1).cgColor)
                context.fill(CGRect(x:0,y:0,width:1024,height:1024))
                let image = UIImage(cgImage:context.makeImage()!)
                cache.store(image,for:UUID(),revision:0)
                maximum = max(maximum,cache.snapshotBytes)
                XCTAssertLessThanOrEqual(cache.snapshotBytes,cache.snapshotByteLimit)
            }
        }
        XCTAssertGreaterThan(cache.images.count,0)
        XCTAssertLessThan(cache.images.count,12,"The decoded-byte cap must evict before the count cap")
        NotificationCenter.default.post(name:UIApplication.didReceiveMemoryWarningNotification,object:nil)
        XCTAssertEqual(cache.snapshotBytes,0); XCTAssertTrue(cache.images.isEmpty)
        try evidence("snapshot-budget",["limitBytes":cache.snapshotByteLimit,"maximumDecodedBytes":maximum,
            "afterWarningBytes":cache.snapshotBytes,"capturesOffered":18])
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition())
        if !condition() { throw NSError(domain: "DeviceQA.Timeout", code: 1) }
    }
}

extension DeviceResourceTests {
    func test06GridRenderingWithoutAccessibilityQueries() async throws { try await nativeRendering("grid") }
    func test07BarRenderingWithoutAccessibilityQueries() async throws { try await nativeRendering("bar") }
    func test08SelectionRenderingWithoutAccessibilityQueries() async throws { try await nativeRendering("selection") }
    func test09HomeGridRetainsItsSurfaceUntilNativeFadeCompletes() async throws {
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"])
        let harness = try DeviceRenderingFixture(fixture:fixture)
        defer { harness.close() }
        try await harness.until { harness.child(harness.root,MobileTabGridController.self) != nil }
        let grid = try XCTUnwrap(harness.child(harness.root,MobileTabGridController.self))
        harness.controller.sheet = .tabs
        try await harness.until { !grid.view.isHidden && harness.controller.tabPresentation.activeID == nil }
        harness.controller.sheet = nil
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(grid.view.isHidden)
        try await harness.until { grid.view.isHidden && harness.pageReady }
    }
    func test10BaselineGridMorphKeepsFullViewportAndParent() async throws {
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"])
        let harness = try DeviceRenderingFixture(fixture:fixture)
        defer { harness.close() }
        try await harness.prepare(pages:1)
        let web = try XCTUnwrap(harness.tabs.first).webView, parent = try XCTUnwrap(web.superview)
        let viewport = web.bounds
        harness.controller.sheet = .tabs
        try await harness.until { harness.controller.tabPresentation.activeID != nil }
        XCTAssertTrue(web.superview === parent); XCTAssertEqual(web.bounds,viewport)
        try await harness.until { harness.controller.tabPresentation.activeID == nil }
        harness.controller.sheet = nil
        try await harness.until { harness.pageReady }
        XCTAssertTrue(web.superview === parent); XCTAssertEqual(web.bounds,viewport)
        XCTAssertEqual(web.transform,.identity)
    }
    func test11EndedOnlyHorizontalFlickUsesPreparedHosts() async throws {
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"])
        let harness = try DeviceRenderingFixture(fixture:fixture)
        defer { harness.close() }
        try await harness.prepare(pages:2)
        for destination in [harness.tabs[0],harness.tabs[1]] {
            let delta:CGFloat = destination.id == harness.tabs[0].id ? 40 : -40
            let pan = try XCTUnwrap(harness.capsule(harness.root.view))
            let action = try XCTUnwrap(pan.action)
            action(.began,.zero,.zero)
            action(.ended,CGSize(width:delta,height:0),CGSize(width:delta*8,height:0))
            try await harness.until { harness.controller.session.selectedTabID == destination.id && !harness.controller.tabSwipe.isActive && harness.pageReady }
            XCTAssertTrue(destination.webView.window === harness.window)
            XCTAssertEqual(destination.webView.bounds.size,harness.window.bounds.size)
            XCTAssertEqual(destination.webView.transform,.identity)
        }
    }
    private func nativeRendering(_ mode:String) async throws {
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"])
        let harness = try DeviceRenderingFixture(fixture:fixture)
        defer { harness.close() }
        try await harness.prepare(pages:mode == "grid" ? 1 : 2)
        let checkers = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let path = _dyld_get_image_name(index) else { return nil }
            let name = URL(fileURLWithPath:String(cString:path)).lastPathComponent
            return name.contains("MainThreadChecker") || name == "libRPAC.dylib" || name.contains("clang_rt.asan") || name.contains("clang_rt.tsan") ? name : nil
        }
        let freeBytes = (try? FileManager.default.attributesOfFileSystem(forPath:NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        try evidence("runtime-checker-audit",["runtimeCheckers":checkers,"deviceFilesystemFreeBytes":freeBytes])
        XCTAssertTrue(checkers.isEmpty,"Runtime diagnostics must be absent from a Release rendering measurement: \(checkers)")
        guard checkers.isEmpty else { throw NSError(domain:"DeviceQA.RuntimeCheckerInjected",code:1) }
        try evidence("native-render-start",["mode":mode,"driver":"production state/actions, no accessibility queries; pan input sampled by display link",
            "runtimeCheckers":checkers,"styleControl":ProcessInfo.processInfo.environment["ORIV_QA_STYLE_CONTROL"] ?? "none","pageChromeDark":harness.controller.chrome(for:harness.tabs.first).isDark,"initialWindowStyle":harness.window.traitCollection.userInterfaceStyle.rawValue,"visibleAppWindows":harness.window.windowScene?.windows.filter { !$0.isHidden && $0.alpha > 0 }.count ?? 0,
            "windows":harness.window.windowScene?.windows.map { ["class":String(describing:type(of:$0)),"root":$0.rootViewController.map { String(describing:type(of:$0)) } ?? "none","hidden":$0.isHidden,"alpha":$0.alpha,"level":$0.windowLevel.rawValue,"key":$0.isKeyWindow] as [String:Any] } ?? []])
        print("QA_NATIVE_PROFILE_READY")
        try await Task.sleep(for:.seconds(5)) // Attach before the first measured transition.
        let deadline = ProcessInfo.processInfo.systemUptime+40
        var phases:[[String:Any]] = [], cycles = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            let start = Date().timeIntervalSince1970
            try await harness.cycle(mode:mode)
            phases.append(["startEpoch":start,"endEpoch":Date().timeIntervalSince1970,"mode":mode,"pageWindowStyle":harness.window.traitCollection.userInterfaceStyle.rawValue,"pageStatusStyle":harness.window.windowScene?.statusBarManager?.statusBarStyle.rawValue ?? -1,"gridWindowStyle":harness.lastGridStyle,"gridStatusStyle":harness.lastGridStatusStyle])
            cycles += 1
        }
        XCTAssertGreaterThan(cycles,4)
        try evidence("native-render-phases",["mode":mode,"cycles":cycles,"phases":phases,
            "scope":"Release QA hosted test; excludes touch delivery and external accessibility traversal"])
        // Keep the target alive while Instruments stops its data providers.
        try await Task.sleep(for:.seconds(20))
    }
}

@MainActor private final class DeviceRenderingFixture {
    let profiles:MobileProfiles
    let controller:MobileController
    let window:UIWindow
    let root:UIHostingController<AnyView>
    let previous:UIWindow?
    let fixture:String
    var tabs:[BrowserTab] = []
    var lastGridStyle = -1
    var lastGridStatusStyle = -1
    init(fixture:String) throws {
        self.fixture = fixture
        let profiles = MobileProfiles(), controller = profiles.current
        self.profiles = profiles; self.controller = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where:\.isKeyWindow)
        let window = UIWindow(windowScene:scene)
        self.window = window
        let content = AnyView(MobileRootView(controller:controller,profiles:profiles)
            .browserAppearance(controller.appearance,followsPage:true).environment(\.scenePhase,.active))
        let styleControl = ProcessInfo.processInfo.environment["ORIV_QA_STYLE_CONTROL"]
        let root = UIHostingController(rootView:styleControl == "dark" ? AnyView(content.preferredColorScheme(.dark)) : styleControl == "light" ? AnyView(content.preferredColorScheme(.light)) : content)
        self.root = root
        window.rootViewController = root; window.makeKeyAndVisible()
        previous?.isHidden = true
    }
    func close() {
        window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        controller.session.shutdown(); profiles.continuity.shutdown()
    }
    func until(_ condition:() -> Bool) async throws {
        let limit = ProcessInfo.processInfo.systemUptime+30
        while !condition() {
            guard UIApplication.shared.applicationState == .active,
                  window.windowScene?.activationState == .foregroundActive else {
                throw NSError(domain:"DeviceQA.NotForeground",code:1)
            }
            guard ProcessInfo.processInfo.systemUptime < limit else {
                XCTFail("Native rendering phase did not reach its real endpoint")
                throw NSError(domain:"DeviceQA.RenderingTimeout",code:1)
            }
            try await Task.sleep(for:.milliseconds(20))
        }
    }
    func child<T:UIViewController>(_ parent:UIViewController,_ type:T.Type) -> T? {
        if let value = parent as? T { return value }
        return parent.children.lazy.compactMap { self.child($0,type) }.first
    }
    func capsule(_ view:UIView) -> MobileCapsulePan.Host? {
        if let value = view as? MobileCapsulePan.Host { return value }
        return view.subviews.lazy.compactMap { self.capsule($0) }.first
    }
    var pageReady:Bool {
        controller.sheet == nil && controller.tabPresentation.activeID == nil &&
            child(root,MobileKeyboardBar.Controller.self)?.view.isUserInteractionEnabled == true
    }
    func prepare(pages:Int) async throws {
        try await controller.session.adBlocker.prepare()
        for index in 0..<pages {
            let tab = index == 0 ? try XCTUnwrap(controller.session.selectedTab) : controller.session.addTab(load:false)
            tabs.append(tab)
            let path = index == 0 ? "/gestures" : "/two"
            tab.navigate(to:try XCTUnwrap(URL(string:fixture+path)))
            try await until { !tab.isLoading && !tab.webView.isLoading && tab.webView.url?.path == path && tab.webView.window === self.window }
            try await Task.sleep(for:.milliseconds(350))
            controller.tabPresentation.capture(tab)
            try await until { self.controller.tabPresentation.images[tab.id] != nil }
        }
        try await until { self.pageReady }
    }
    func cycle(mode:String) async throws {
        if mode == "bar" {
            let source = try XCTUnwrap(controller.session.selectedTabID)
            let forward = source == tabs.first?.id
            let destination = forward ? tabs.last!.id : tabs.first!.id
            let delta:CGFloat = forward ? -260 : 260
            let pan = try XCTUnwrap(capsule(root.view))
            let action = try XCTUnwrap(pan.action)
            action(.began,.zero,.zero)
            let driver = DevicePanInputDriver(maximum:Float(window.windowScene?.screen.maximumFramesPerSecond ?? 60)) { progress in
                action(.changed,CGSize(width:delta*progress,height:0),CGSize(width:delta*progress,height:0))
            }
            await driver.run()
            action(.ended,CGSize(width:delta,height:0),CGSize(width:delta*1.3,height:0))
            try await until { self.controller.session.selectedTabID == destination && self.pageReady }
        } else {
            controller.sheet = .tabs
            try await until {
                self.controller.tabPresentation.activeID == nil &&
                    self.child(self.root,MobileTabGridController.self)?.view.isHidden == false &&
                    self.child(self.root,MobileKeyboardBar.Controller.self)?.view.isUserInteractionEnabled == false
            }
            lastGridStyle = window.traitCollection.userInterfaceStyle.rawValue
            lastGridStatusStyle = window.windowScene?.statusBarManager?.statusBarStyle.rawValue ?? -1
            if mode == "selection" {
                let target = controller.session.selectedTabID == tabs.first!.id ? 1 : 0
                let grid = try XCTUnwrap(child(root,MobileTabGridController.self))
                grid.collectionView(grid.collectionView,didSelectItemAt:IndexPath(item:target,section:0))
                try await until { self.controller.session.selectedTabID == self.tabs[target].id && self.pageReady }
            } else {
                controller.sheet = nil
                try await until { self.pageReady }
            }
        }
    }
}

@MainActor private final class DevicePanInputDriver:NSObject {
    let maximum:Float
    let update:(CGFloat) -> Void
    var link:CADisplayLink?
    var start:CFTimeInterval?
    var completion:CheckedContinuation<Void,Never>?
    init(maximum:Float,update:@escaping (CGFloat) -> Void) { self.maximum = maximum; self.update = update }
    func run() async {
        await withCheckedContinuation { continuation in
            completion = continuation
            let value = CADisplayLink(target:self,selector:#selector(frame(_:)))
            value.preferredFrameRateRange = CAFrameRateRange(minimum:min(60,maximum),maximum:maximum,preferred:maximum)
            link = value; value.add(to:.main,forMode:.common)
        }
    }
    @objc func frame(_ value:CADisplayLink) {
        if start == nil { start = value.timestamp }
        let progress = min(1,(value.timestamp-start!)/0.24)
        update(CGFloat(progress))
        if progress == 1 {
            value.invalidate(); link = nil
            let done = completion; completion = nil; done?.resume()
        }
    }
}
