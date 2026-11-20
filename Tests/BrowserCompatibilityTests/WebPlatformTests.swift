import XCTest
import BrowserCore
import BrowserEngine
import WebKit

/// App-shell regression coverage, not a replacement for the Web Platform Tests suite.
@MainActor final class WebPlatformTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8768")!
    func testDOMLayoutHistoryStorageAndCrossOriginPolicies() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent(), settings: BrowserSettings(defaults: nil))
        defer { tab.close() }
        let detach = try mountWebFixture(tab)
        defer { detach() }
        tab.navigate(to: base.appendingPathComponent("standards"))
        try await waitForWebCondition("standards fixture completion", timeout: 25) { tab.title == "Web platform complete" }
        let results = try await tab.webView.evaluateJavaScript("window.orivStandardsResults") as? [String: Any]
        XCTAssertEqual(results?.count, 14)
        for (name, result) in results ?? [:] { XCTAssertEqual(result as? Bool, true, "\(name): \(result)") }
        let capabilities = try await tab.webView.evaluateJavaScript("JSON.stringify(window.orivCapabilities)") as? String ?? "Unavailable"
        let attachment = XCTAttachment(string: capabilities); attachment.name = "WebKit runtime capabilities"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(tab.canGoBack)
    }
    func testContentSecurityPolicyBlocksPageScript() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        let detach = try mountWebFixture(tab)
        defer { detach() }
        let url = base.appendingPathComponent("standards-csp")
        try await waitForWebFixture(tab, at: url) { tab.navigate(to: url) }
        let result = try await tab.webView.evaluateJavaScript("window.blockedScriptExecuted === undefined") as? Bool
        XCTAssertEqual(result, true)
    }
    func testServiceWorkerAndCacheStorageWhenPlatformAllowsThem() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        let detach = try mountWebFixture(tab)
        defer { detach() }
        let url = base.appendingPathComponent("quality")
        try await waitForWebFixture(tab, at: url) { tab.navigate(to: url) }
        let available = try await tab.webView.evaluateJavaScript("'serviceWorker' in navigator") as? Bool
        guard available == true else { throw XCTSkip("This iPhone build lacks Apple's managed default-browser entitlement; unrestricted service workers require it.") }
        let result = try await tab.webView.callAsyncJavaScript("""
            const registration = await navigator.serviceWorker.register('/standards-worker.js');
            await navigator.serviceWorker.ready;
            try {
              return await new Promise((resolve, reject) => {
                const channel = new MessageChannel();
                const timer = setTimeout(() => reject(new Error('Worker reply timed out')), \(Int(webFixtureTimeout(8) * 1_000)));
                channel.port1.onmessage = event => { clearTimeout(timer); resolve(event.data); };
                registration.active.postMessage('check', [channel.port2]);
              });
            } finally { await registration.unregister(); await caches.delete('oriv-worker-regression'); }
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(result, "worker-cache-ok")
    }
    func testPrivateStorageCannotLeakToRegularTabsOrNextPrivateSession() async throws {
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        let regular = try XCTUnwrap(session.selectedTab)
        let detachRegular = try mountWebFixture(regular)
        defer { detachRegular() }
        let url = base.appendingPathComponent("quality")
        try await waitForWebFixture(regular, at: url) { regular.navigate(to: url) }
        _ = try await regular.webView.evaluateJavaScript("localStorage.setItem('scope','regular')")
        do {
            let privateTab = session.addTab(isPrivate: true, load: false)
            let detachPrivate = try mountWebFixture(privateTab)
            defer { detachPrivate() }
            try await waitForWebFixture(privateTab, at: url) { privateTab.navigate(to: url) }
            let initial = try await privateTab.webView.evaluateJavaScript("localStorage.getItem('scope') === null") as? Bool
            XCTAssertEqual(initial, true)
            _ = try await privateTab.webView.evaluateJavaScript("localStorage.setItem('scope','private')")
            session.closeTab(privateTab.id)
        }
        do {
            let next = session.addTab(isPrivate: true, load: false)
            let detachNext = try mountWebFixture(next)
            defer { detachNext() }
            try await waitForWebFixture(next, at: url) { next.navigate(to: url) }
            let fresh = try await next.webView.evaluateJavaScript("localStorage.getItem('scope') === null") as? Bool
            XCTAssertEqual(fresh, true)
        }
        let retained = try await regular.webView.evaluateJavaScript("localStorage.getItem('scope')") as? String
        XCTAssertEqual(retained, "regular")
    }
}
