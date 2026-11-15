import XCTest
import WebKit
import UIKit
import BrowserEngine
@testable import OrivMobile

@MainActor final class LifecycleTests:XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORIV_DEVICE_QA"] == "1", "Isolated hardware QA only")
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device suite")
        #endif
        XCTAssertTrue(Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true)
    }
    func testClosingDuringNativeThumbnailReleasesObjects() async throws {
        let presentation = MobileTabPresentation()
        var tab:BrowserTab? = BrowserTab(dataStore:.nonPersistent())
        var web:WKWebView? = tab!.webView
        web!.frame = CGRect(x:0,y:0,width:390,height:844)
        weak var weakTab = tab
        weak var weakWeb = web
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["ORIV_QA_FIXTURE_URL"])
        tab!.navigate(to:try XCTUnwrap(URL(string:fixture+"/two")))
        let loadDeadline = ProcessInfo.processInfo.systemUptime+30
        while tab!.isLoading && ProcessInfo.processInfo.systemUptime < loadDeadline {
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertEqual(tab!.title,"Second page")
        let id = tab!.id
        presentation.capture(tab!)
        tab!.close(); presentation.remove(id)
        tab = nil; web = nil
        let deadline = ProcessInfo.processInfo.systemUptime+2
        while (weakTab != nil || weakWeb != nil) && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertNil(weakTab); XCTAssertNil(weakWeb)
    }
    func testClosedTabsAndShutdownReleaseNativeObjects() async throws {
        let idleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimer }
        print("QA_LEAKS_READY")
        try await Task.sleep(for:.seconds(5)) // Attach Leaks before allocating the tab batch.
        var objects:[WeakNativeObject] = []
        for _ in 0..<3 {
            var controller:MobileController? = MobileController()
            objects.append(WeakNativeObject(controller!)); objects.append(WeakNativeObject(controller!.session))
            for index in 0..<10 {
                let tab = controller!.session.addTab(url:URL(string:"https://example.test/"),isPrivate:index.isMultiple(of:2),select:false,load:false)
                objects.append(WeakNativeObject(tab))
                objects.append(WeakNativeObject(tab.webView))
                let chrome = controller!.chrome(for:tab)
                objects.append(WeakNativeObject(chrome))
                objects.append(WeakNativeObject(chrome.observerLifetime))
                if let adapter = tab.webView.uiDelegate { objects.append(WeakNativeObject(adapter)) }
                if index.isMultiple(of:3) { controller!.session.closeTab(tab.id) }
            }
            controller!.session.shutdown(); controller = nil
            try await Task.sleep(for:.milliseconds(100))
        }
        let deadline = ProcessInfo.processInfo.systemUptime+10
        while objects.contains(where:{ $0.object != nil }) && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertTrue(objects.allSatisfy { $0.object == nil },"Views, tabs, chrome, adapters, controllers and sessions must deallocate")
        print("QA_LEAKS_SETTLED checked=\(objects.count) alive=\(objects.filter { $0.object != nil }.count)")
        // Give Instruments a stable post-close heap to scan.
        try await Task.sleep(for:.seconds(ProcessInfo.processInfo.environment["ORIV_QA_LEAKS_CAPTURE"] == "1" ? 120 : 20))
    }
}

@MainActor private final class WeakNativeObject {
    weak var object:AnyObject?
    init(_ object:AnyObject) { self.object = object }
}
