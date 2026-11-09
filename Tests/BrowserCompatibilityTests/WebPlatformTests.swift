import XCTest
import BrowserCore
import BrowserEngine
import WebKit

/// App-shell regression coverage, not a replacement for the Web Platform Tests suite.
@MainActor final class WebPlatformTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8768")!
    private func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(25)
        while !predicate() && Date.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertTrue(predicate(), message)
    }
    func testDOMLayoutHistoryStorageAndCrossOriginPolicies() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent(), settings: BrowserSettings(defaults: nil))
        defer { tab.close() }
        tab.navigate(to: base.appendingPathComponent("standards"))
        try await wait("Standards fixture completed") { tab.title == "Web platform complete" }
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
        tab.navigate(to: base.appendingPathComponent("standards-csp"))
        try await wait("CSP page loaded") { tab.title == "CSP fixture" && !tab.isLoading }
        let result = try await tab.webView.evaluateJavaScript("window.blockedScriptExecuted === undefined") as? Bool
        XCTAssertEqual(result, true)
    }
    func testServiceWorkerAndCacheStorageWhenPlatformAllowsThem() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        tab.navigate(to: base.appendingPathComponent("quality"))
        try await wait("Worker fixture loaded") { tab.title == "Browser quality fixture" && !tab.isLoading }
        let available = try await tab.webView.evaluateJavaScript("'serviceWorker' in navigator") as? Bool
        guard available == true else { throw XCTSkip("This iPhone build lacks Apple's managed default-browser entitlement; unrestricted service workers require it.") }
        let result = try await tab.webView.callAsyncJavaScript("""
            const registration = await navigator.serviceWorker.register('/standards-worker.js');
            await navigator.serviceWorker.ready;
            try {
              return await new Promise((resolve, reject) => {
                const channel = new MessageChannel();
                const timer = setTimeout(() => reject(new Error('Worker reply timed out')), 8000);
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
        regular.navigate(to: base.appendingPathComponent("quality"))
        try await wait("Regular page loaded") { regular.title == "Browser quality fixture" }
        _ = try await regular.webView.evaluateJavaScript("localStorage.setItem('scope','regular')")
        let privateTab = session.addTab(url: base.appendingPathComponent("quality"), isPrivate: true)
        try await wait("Private page loaded") { privateTab.title == "Browser quality fixture" }
        let initial = try await privateTab.webView.evaluateJavaScript("localStorage.getItem('scope') === null") as? Bool
        XCTAssertEqual(initial, true)
        _ = try await privateTab.webView.evaluateJavaScript("localStorage.setItem('scope','private')")
        session.closeTab(privateTab.id)
        let next = session.addTab(url: base.appendingPathComponent("quality"), isPrivate: true)
        try await wait("Fresh private page loaded") { next.title == "Browser quality fixture" }
        let fresh = try await next.webView.evaluateJavaScript("localStorage.getItem('scope') === null") as? Bool
        XCTAssertEqual(fresh, true)
        let retained = try await regular.webView.evaluateJavaScript("localStorage.getItem('scope')") as? String
        XCTAssertEqual(retained, "regular")
    }
}
