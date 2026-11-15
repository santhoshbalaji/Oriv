import XCTest
import SwiftUI
import UIKit
import WebKit
import BrowserEngine
@testable import OrivMobile

/// Same physical viewport, sequential hosts, identical timing-only script.
/// "Cold" means a fresh view/data store, not a reboot or cleared system cache.
@MainActor final class NavigationTimingTests:XCTestCase {
    func testDocumentStartScriptOverhead() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_DEVICE_QA"] == "1", "Isolated hardware QA only")
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device measurement")
        #endif
        XCTAssertTrue(Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true)
        let idleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimer }
        let profiles = MobileProfiles()
        defer { profiles.current.session.shutdown(); profiles.continuity.shutdown() }
        let scripts = try XCTUnwrap(profiles.current.session.selectedTab).webView.configuration.userContentController.userScripts
        XCTAssertTrue(scripts.contains { $0.source.contains("__orivChromeStop") })
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var rows:[[String:Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]) {
                let attachment = XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
                attachment.name = "script-overhead"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        for path in ["/two","/gestures"] {
            for round in 0..<3 {
                let names = ["bare","scripts","scripts-without-chrome"]
                for index in 0..<names.count {
                    let name = names[(index+round)%names.count]
                    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
                    let content = config.userContentController, handler = ScriptCostHandler()
                    for (world,key) in [("OrivPageChrome","chromeEdge"),("OrivContext","orivContext"),("OrivTabState","editedField")] {
                        content.add(handler,contentWorld:.world(name:world),name:key)
                    }
                    if name != "bare" {
                        for script in scripts where name == "scripts" || !script.source.contains("__orivChromeStop") {
                            content.addUserScript(script)
                        }
                    }
                    let web = WKWebView(frame:.zero,configuration:config), probe = NavigationTimingProbe(primary:nil)
                    probe.install(on:web)
                    let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
                    let host = UIViewController(); host.view = web; window.rootViewController = host; window.makeKeyAndVisible()
                    defer {
                        probe.uninstall(from:web); content.removeAllScriptMessageHandlers()
                        window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                    }
                    try await Task.sleep(for:.milliseconds(100))
                    web.load(URLRequest(url:try XCTUnwrap(URL(string:fixture+path))))
                    let deadline = ProcessInfo.processInfo.systemUptime+30
                    while web.isLoading || probe.paint == nil {
                        guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Script fixture timed out"); return }
                        try await Task.sleep(for:.milliseconds(10))
                    }
                    let fcp = try await web.evaluateJavaScript("performance.getEntriesByType('paint').find(e=>e.name==='first-contentful-paint').startTime")
                    rows.append(["host":name,"path":path,"round":round,"fcpMS":fcp,"scriptCount":content.userScripts.count-1])
                }
            }
        }
    }
    func testNavigationOverheadAgainstBareWebView() async throws {
        try await benchmark(hosts:["bare","oriv"])
    }
    func testNativeChromeOverhead() async throws {
        try await benchmark(hosts:["oriv","oriv-without-observer"],publicPages:false)
    }
    func testContentRuleOverhead() async throws {
        try await benchmark(hosts:["bare","bare-with-rules"],publicPages:false)
    }
    /// Starts at the production Return delegate, including view construction,
    /// address-state changes and the unchanged first-navigation privacy gate.
    /// Programmatic dispatch excludes physical input delivery latency.
    func testAddressSubmissionActionTiming() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_DEVICE_QA"] == "1", "Isolated hardware QA only")
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device measurement")
        #endif
        XCTAssertTrue(Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true)
        let idleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimer }
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"])
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        try await c.session.adBlocker.prepare()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        window.rootViewController = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles)
            .browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func editor(_ view:UIView) -> UITextField? {
            if let field = view as? UITextField, field.accessibilityIdentifier == "browserAddress" { return field }
            return view.subviews.lazy.compactMap { editor($0) }.first
        }
        var rows:[[String:Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]) {
                let attachment = XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
                attachment.name = "submission-action-timing"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        for path in ["/two","/gestures"] {
            for round in 0..<3 {
                c.newTab(animated:false)
                let tab = try XCTUnwrap(c.session.selectedTab), probe = NavigationTimingProbe(primary:tab)
                XCTAssertFalse(tab.isInstantiated,"The action must include new-view construction")
                let original = c.session.configureWebView
                c.session.configureWebView = { view,candidate in
                    original?(view,candidate)
                    if candidate.id == tab.id { probe.install(on:view) }
                }
                defer {
                    c.session.configureWebView = original
                    if let web = probe.view { probe.uninstall(from:web) }
                    c.session.closeTab(tab.id)
                }
                let deadline = ProcessInfo.processInfo.systemUptime+60
                while editor(window)?.isFirstResponder != true {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Address editor did not appear"); return }
                    try await Task.sleep(for:.milliseconds(10))
                }
                let field = try XCTUnwrap(editor(window)); field.text = fixture+path
                let started = ProcessInfo.processInfo.systemUptime
                _ = field.delegate?.textFieldShouldReturn?(field)
                while probe.commit == nil || probe.paint == nil || tab.isLoading {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Address submission timed out"); return }
                    try await Task.sleep(for:.milliseconds(10))
                }
                XCTAssertNil(probe.failure)
                rows.append(["path":path,"round":round,"actionToCommitMS":(probe.commit!-started)*1000,
                    "actionToPaintCallbackMS":(probe.paint!-started)*1000,
                    "dispatch":"production Return delegate; physical input delivery excluded"])
            }
        }
    }
    private func benchmark(hosts:[String],publicPages:Bool = true) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_DEVICE_QA"] == "1", "Isolated hardware QA only")
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device measurement")
        #endif
        XCTAssertTrue(Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true)
        let idleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimer }
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let urls = [fixture+"/two",fixture+"/gestures"] + (publicPages ? ["https://example.com/","https://webkit.org/"] : [])
        var rows:[[String:Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]) {
                let attachment = XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
                attachment.name = "navigation-overhead"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        for raw in urls {
            for round in 0..<3 {
                for name in round.isMultiple(of:2) ? hosts : hosts.reversed() {
                    let bare = name.hasPrefix("bare")
                    let profiles:MobileProfiles? = name == "bare" ? nil : MobileProfiles()
                    let tab = bare ? nil : profiles?.current.session.selectedTab
                    if let profiles { try await profiles.current.session.adBlocker.prepare() }
                    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
                    let creationStarted = ProcessInfo.processInfo.systemUptime
                    let web = tab?.webView ?? WKWebView(frame:.zero,configuration:config)
                    let creationMS = (ProcessInfo.processInfo.systemUptime-creationStarted)*1000
                    if name == "bare-with-rules", let profiles {
                        try await profiles.current.session.adBlocker.apply(to:web.configuration.userContentController,
                            url:URL(string:raw),isPrivate:false)
                    }
                    if name == "oriv-without-observer" { profiles?.current.chrome(for:tab).observe(nil) }
                    let probe = NavigationTimingProbe(primary:tab)
                    probe.install(on:web)
                    let previous = scene.windows.first(where:\.isKeyWindow)
                    let window = UIWindow(windowScene:scene)
                    if !bare, let profiles {
                        window.rootViewController = UIHostingController(rootView:MobileRootView(controller:profiles.current,profiles:profiles)
                            .browserAppearance(profiles.current.appearance,followsPage:true).environment(\.scenePhase,.active))
                    } else {
                        let controller = UIViewController(); controller.view = web
                        window.rootViewController = controller
                    }
                    window.makeKeyAndVisible()
                    defer {
                        probe.uninstall(from:web); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                        profiles?.current.session.shutdown(); profiles?.continuity.shutdown()
                    }
                    try await Task.sleep(for:.milliseconds(100))
                    for cache in ["fresh-view","warm-view"] {
                        let url = try XCTUnwrap(URL(string:raw))
                        probe.reset()
                        let start = ProcessInfo.processInfo.systemUptime
                        if let tab { tab.navigate(to:url) } else { web.load(URLRequest(url:url)) }
                        let deadline = start+60
                        while (web.isLoading || probe.paint == nil || probe.commit == nil) && probe.failure == nil && ProcessInfo.processInfo.systemUptime < deadline {
                            try await Task.sleep(for:.milliseconds(10))
                        }
                        XCTAssertNil(probe.failure,"\(name) \(raw)")
                        let commit = try XCTUnwrap(probe.commit,"No commit for \(name) \(raw)")
                        let paint = try XCTUnwrap(probe.paint,"No FCP for \(name) \(raw)")
                        let page = try await web.evaluateJavaScript("""
                            (() => { const n=performance.getEntriesByType('navigation')[0];
                            const f=performance.getEntriesByType('paint').find(e=>e.name==='first-contentful-paint');
                            return {responseStart:n.responseStart,fcp:f?.startTime ?? -1,
                            domContentLoaded:n.domContentLoadedEventEnd,load:n.loadEventEnd}; })()
                            """) as? [String:Any] ?? [:]
                        rows.append(["host":name,"url":raw,"round":round,"cache":cache,
                            "viewConstructionMS":cache == "fresh-view" ? creationMS : 0,
                            "requestToCommitMS":(commit-start)*1000,"requestToPaintCallbackMS":(paint-start)*1000,
                            "navigationTimingMS":page])
                        print("QA_NAVIGATION_SAMPLE host=\(name) cache=\(cache) round=\(round)")
                        try await Task.sleep(for:.milliseconds(100))
                    }
                }
            }
        }

    }
}

@MainActor private final class ScriptCostHandler:NSObject,WKScriptMessageHandler {
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {}
}

/// Forward the complete original policy delegate, including fail-closed
/// preparation. Only commit/failure timestamps are intercepted by this test.
@MainActor private final class NavigationTimingProbe:NSObject,WKNavigationDelegate,WKScriptMessageHandler {
    weak var primary:(any WKNavigationDelegate)?
    weak var view:WKWebView?
    var commit:Double?
    var paint:Double?
    var failure:Error?
    private let world = WKContentWorld.world(name:"OrivQATiming")
    init(primary:(any WKNavigationDelegate)?) { self.primary = primary }
    func reset() { commit = nil; paint = nil; failure = nil }
    override func responds(to selector:Selector!) -> Bool { super.responds(to:selector) || primary?.responds(to:selector) == true }
    override func forwardingTarget(for selector:Selector!) -> Any? { primary?.responds(to:selector) == true ? primary : super.forwardingTarget(for:selector) }
    func install(on web:WKWebView) {
        view = web
        web.navigationDelegate = self
        let content = web.configuration.userContentController
        content.add(self,contentWorld:world,name:"qaPaint")
        content.addUserScript(WKUserScript(source:"""
            (()=>{const p=new PerformanceObserver(list=>{if(list.getEntries().some(e=>e.name==='first-contentful-paint')){
            window.webkit.messageHandlers.qaPaint.postMessage(true);p.disconnect();}});p.observe({type:'paint',buffered:true});})();
            """,injectionTime:.atDocumentStart,forMainFrameOnly:true,in:world))
    }
    func uninstall(from web:WKWebView) {
        web.configuration.userContentController.removeScriptMessageHandler(forName:"qaPaint",contentWorld:world)
        web.navigationDelegate = primary
    }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        if message.frameInfo.isMainFrame && paint == nil { paint = ProcessInfo.processInfo.systemUptime }
    }
    func webView(_ webView:WKWebView,didCommit navigation:WKNavigation!) {
        commit = ProcessInfo.processInfo.systemUptime
        primary?.webView?(webView,didCommit:navigation)
    }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {
        if (error as NSError).code != NSURLErrorCancelled { failure = error }
        primary?.webView?(webView,didFailProvisionalNavigation:navigation,withError:error)
    }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) {
        failure = error; primary?.webView?(webView,didFail:navigation,withError:error)
    }
}
