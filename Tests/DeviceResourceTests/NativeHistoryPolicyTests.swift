import XCTest
import SwiftUI
import WebKit
import UIKit
import BrowserEngine
@testable import OrivMobile

@MainActor final class NativeHistoryPolicyTests:XCTestCase {
    func testOrivLeavesNativeHistoryRecognizersAndEdgeHitTestingInControl() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_DEVICE_QA"] == "1", "Isolated device QA only")
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device suite")
        #endif
        XCTAssertTrue(Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true)
        let idleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimer }
        let profiles = MobileProfiles(), c = profiles.current
        defer { c.session.shutdown(); profiles.continuity.shutdown() }
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"])
        let tab = try XCTUnwrap(c.session.selectedTab)
        tab.navigate(to:try XCTUnwrap(URL(string:fixture+"/gestures")))
        let deadline = ProcessInfo.processInfo.systemUptime+60
        while tab.isLoading || tab.title != "Gesture Lab" {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Fixture did not load"); return }
            try await Task.sleep(for:.milliseconds(50))
        }
        tab.navigate(to:try XCTUnwrap(URL(string:fixture+"/two")))
        while tab.isLoading || tab.title != "Second page" {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Second fixture did not load"); return }
            try await Task.sleep(for:.milliseconds(50))
        }
        tab.navigate(to:try XCTUnwrap(URL(string:fixture+"/short-gestures")))
        while tab.isLoading || tab.title != "Short Gesture Page" {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Third fixture did not load"); return }
            try await Task.sleep(for:.milliseconds(50))
        }
        tab.goBack()
        while tab.isLoading || tab.title != "Second page" {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("History fixture did not restore"); return }
            try await Task.sleep(for:.milliseconds(50))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
        let root = UIHostingController(rootView:MobileRootView(controller:c,profiles:profiles)
            .browserAppearance(c.appearance,followsPage:true).environment(\.scenePhase,.active))
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for:.milliseconds(300))
        let web = tab.webView
        XCTAssertTrue(web.allowsBackForwardNavigationGestures)
        XCTAssertTrue(web.canGoBack && web.canGoForward,"Both native history directions need real entries")
        XCTAssertTrue(root.preferredScreenEdgesDeferringSystemGestures.intersection([.top,.bottom]).isEmpty)
        for x in [CGFloat(1),window.bounds.width-1] {
            XCTAssertTrue(window.hitTest(CGPoint(x:x,y:180),with:nil)?.isDescendant(of:web) == true,
                          "Oriv chrome must not intercept the page's native history edge")
        }
        let adapter = try XCTUnwrap(web.uiDelegate as? MobileWebDelegate)
        let hold = try XCTUnwrap(web.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first { $0.delegate === adapter })
        XCTAssertFalse(hold.cancelsTouchesInView)
        let edge = UIScreenEdgePanGestureRecognizer(); edge.edges = .left
        XCTAssertTrue(adapter.gestureRecognizer(hold,shouldRecognizeSimultaneouslyWith:edge))
        for selector in ["gestureRecognizer:shouldRequireFailureOfGestureRecognizer:","gestureRecognizer:shouldBeRequiredToFailByGestureRecognizer:"] {
            XCTAssertFalse(adapter.responds(to:NSSelectorFromString(selector)),"Oriv must not add native-edge failure dependencies")
        }
        func edgePolicy(_ view:WKWebView) -> [UInt:[Bool]] {
            let edges = (view.gestureRecognizers ?? []).compactMap { $0 as? UIScreenEdgePanGestureRecognizer }
            return Dictionary(grouping:edges,by:{ $0.edges.rawValue }).mapValues { $0.map(\.isEnabled) }
        }
        let orivPolicy = edgePolicy(web)
        XCTAssertFalse(orivPolicy.isEmpty)
        for recognizer in web.gestureRecognizers ?? [] where recognizer is UIScreenEdgePanGestureRecognizer {
            XCTAssertFalse(recognizer.delegate === adapter)
        }
        // WebKit controls these recognizers' enabled state, including disabling
        // its edge recognizers on some OS versions even with real history.
        // Compare an attached plain WKWebView on the same device; never force
        // them on or treat WebKit's own state as an Oriv policy requirement.
        let bare = WKWebView(frame:window.bounds)
        bare.allowsBackForwardNavigationGestures = true
        root.view.addSubview(bare)
        defer { bare.stopLoading(); bare.removeFromSuperview() }
        for (path,title) in [("/gestures","Gesture Lab"),("/two","Second page"),("/short-gestures","Short Gesture Page")] {
            bare.load(URLRequest(url:try XCTUnwrap(URL(string:fixture+path))))
            let limit = ProcessInfo.processInfo.systemUptime+30
            while bare.isLoading || bare.title != title {
                guard ProcessInfo.processInfo.systemUptime < limit else { XCTFail("Plain WebKit control did not load"); return }
                try await Task.sleep(for:.milliseconds(50))
            }
        }
        bare.goBack()
        let limit = ProcessInfo.processInfo.systemUptime+30
        while bare.isLoading || bare.title != "Second page" {
            guard ProcessInfo.processInfo.systemUptime < limit else { XCTFail("Plain WebKit control did not restore"); return }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertTrue(bare.canGoBack && bare.canGoForward)
        try await Task.sleep(for:.milliseconds(300))
        XCTAssertEqual(orivPolicy,edgePolicy(bare),"Oriv must preserve the native recognizer policy of plain WebKit")
        let evidence = XCTAttachment(string:"Oriv native edge policy: \(orivPolicy); plain WebKit: \(edgePolicy(bare)). Physical-touch acceptance remains with the owner.")
        evidence.name = "Native history recognizer control"; evidence.lifetime = .keepAlways; add(evidence)
    }
}
