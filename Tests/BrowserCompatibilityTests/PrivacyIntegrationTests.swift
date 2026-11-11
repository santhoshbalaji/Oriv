import BrowserCore
@testable import BrowserEngine
import WebKit
import XCTest
#if os(macOS)
@testable import PersonalBrowser
import AppKit
#else
@testable import OrivMobile
import UIKit
#endif

@MainActor final class PrivacyIntegrationTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:18768")!
    #if os(macOS)
    private var fixtureWindows: [UUID: NSWindow] = [:]
    override func tearDown() async throws {
        fixtureWindows.values.forEach { $0.close() }; fixtureWindows = [:]
        XCTAssertTrue(BackgroundUIMode.isEnabled)
        let audit = BackgroundUIMode.audit()
        XCTAssertEqual(audit.frontmostViolations, 0)
        XCTAssertEqual(audit.activationViolations, 0)
        XCTAssertEqual(audit.onscreenWindowViolations, 0)
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
    }
    private func hostInBackground(_ tab: BrowserTab) {
        guard fixtureWindows[tab.id] == nil else { return }
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = tab.webView
        fixtureWindows[tab.id] = window
        BackgroundUIMode.show(window, key: false)
    }
    #else
    private func hostInBackground(_ tab: BrowserTab) {}
    #endif
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(40)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "Privacy fixture timed out")
    }
    private func load(_ tab: BrowserTab, _ path: String = "/privacy") async throws {
        hostInBackground(tab)
        tab.navigate(to: URL(string: path, relativeTo: base)!.absoluteURL)
        try await wait { tab.title == "Privacy fixture" && !tab.isLoading || tab.errorMessage != nil }
        XCTAssertNil(tab.errorMessage)
    }
    func testBundledRulesCompileColdAndWarm() async throws {
        let namespace = "oriv.privacy-benchmark." + UUID().uuidString
        let cold = AdBlocker(cacheNamespace: namespace)
        try await cold.prepare()
        let warm = AdBlocker(cacheNamespace: namespace)
        try await warm.prepare()
        for (name, blocker) in [("first", cold), ("warm", warm)] {
            let data = try JSONEncoder().encode(blocker.compilationMeasurements)
            let text = String(decoding: data, as: UTF8.self)
            print("PRIVACY_COMPILE_\(name): \(text)")
            let attachment = XCTAttachment(string: text); attachment.name = "Privacy compilation \(name)"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertGreaterThanOrEqual(blocker.compilationMeasurements.count, 5)
        }
        XCTAssertTrue(warm.compilationMeasurements.allSatisfy(\.cached))
        for measurement in cold.compilationMeasurements {
            try await WKContentRuleListStore.default()!.removeContentRuleList(forIdentifier: measurement.identifier)
        }
    }
    func testShippedCookieListAndLayerIndependence() async throws {
        let settings = BrowserSettings(defaults: nil), blocker = AdBlocker()
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker, settings: settings)
        defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        try await load(tab)
        let visible = try await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#onetrust-banner-sdk')).display !== 'none'") as? Bool
        XCTAssertEqual(visible, true)
        let shippingBlocked = try await tab.webView.evaluateJavaScript("window.shippingTrackerBlocked === true && window.shippingTrackerLoaded !== true") as? Bool
        XCTAssertEqual(shippingBlocked, true, "Pinned EasyList /ads-front.min.js rule must block the actual fixture script")
        settings.privacy.setEnabled(true, .cookieBanners)
        blocker.setMode(.off) // Cookie hiding must be independent of ad blocking.
        try await load(tab)
        let hidden = try await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#onetrust-banner-sdk')).display") as? String
        XCTAssertEqual(hidden, "none")
        let overflow = try await tab.webView.evaluateJavaScript("getComputedStyle(document.body).overflow") as? String
        XCTAssertEqual(overflow, "auto", "Hiding a recognized CMP must restore the page's scroll lock")
        _ = try await tab.webView.evaluateJavaScript("document.body.appendChild(document.createElement('div')); true")
        let styleCount = try await tab.webView.evaluateJavaScript("document.querySelectorAll('#oriv-cookie-scroll-restoration').length") as? Int
        XCTAssertEqual(styleCount, 1, "Scroll restoration must not observe and duplicate its own style")
        let shippingAllowed = try await tab.webView.evaluateJavaScript("window.shippingTrackerLoaded === true") as? Bool
        XCTAssertEqual(shippingAllowed, true, "Off restores the script while cookie hiding stays independent")
        settings.privacy.setException(true, .cookieBanners, for: base, isPrivate: false)
        try await load(tab)
        let restored = try await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#onetrust-banner-sdk')).display !== 'none'") as? Bool
        XCTAssertEqual(restored, true)
    }
    func testFixtureTrackerBlockingAndPrivateHistory() async throws {
        let rules = #"[{"trigger":{"url-filter":"/ad-banner\\.js"},"action":{"type":"block"}}]"#
        let blocker = AdBlocker(rules: [.balanced: rules, .strict: rules])
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker, settings: BrowserSettings(defaults: nil), externalPrivate: true)
        defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        hostInBackground(tab)
        tab.navigate(to: base.appendingPathComponent("adblock"))
        try await wait { tab.title.hasPrefix("Adblock checked") && !tab.isLoading }
        let first = try await tab.webView.evaluateJavaScript("window.probeResults[0]") as? String
        XCTAssertEqual(first, "blocked"); XCTAssertTrue(session.history.isEmpty); XCTAssertTrue(session.snapshot().tabs.isEmpty)
        blocker.setException(true, for: base, isPrivate: true)
        let run = UUID().uuidString
        tab.navigate(to: base.appendingPathComponent("adblock").appending(queryItems: [URLQueryItem(name: "run", value: run)]))
        try await wait { tab.title == "Adblock checked \(run)" && !tab.isLoading }
        let allowed = try await tab.webView.evaluateJavaScript("window.probeResults[0]") as? String
        XCTAssertEqual(allowed, "loaded"); XCTAssertTrue(session.history.isEmpty)
    }
    func testExceptionProfileAndPrivateScopingAndMigration() throws {
        let name = "PrivacyTests-\(UUID())", name2 = name + "-other"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)), other = try XCTUnwrap(UserDefaults(suiteName: name2))
        defer { defaults.removePersistentDomain(forName: name); other.removePersistentDomain(forName: name2) }
        defaults.set("Strict", forKey: "adBlockingMode")
        let settings = BrowserSettings(defaults: defaults), blocker = AdBlocker(defaults: defaults)
        XCTAssertEqual(blocker.mode, .strict)
        for layer in PrivacyLayer.allCases { XCTAssertEqual(settings.privacy.isEnabled(layer), layer.defaultEnabled) }
        let regularURL = URL(string: "https://regular.example/")!, privateURL = URL(string: "https://private.example/")!
        for layer in PrivacyLayer.allCases {
            settings.privacy.setException(true, layer, for: regularURL, isPrivate: false)
            settings.privacy.setException(true, layer, for: privateURL, isPrivate: true)
        }
        let recreated = BrowserSettings(defaults: defaults)
        XCTAssertEqual(recreated.privacy.regularExceptions, settings.privacy.regularExceptions)
        XCTAssertTrue(recreated.privacy.privateExceptions.isEmpty)
        XCTAssertTrue(BrowserSettings(defaults: other).privacy.regularExceptions.isEmpty)
        XCTAssertFalse(String(decoding: defaults.data(forKey: "privacy.exceptions")!, as: UTF8.self).contains("private.example"))
        XCTAssertFalse(settings.privacy.isException(.linkCleaning, for: URL(string: "https://sub.regular.example/"), isPrivate: false))
        settings.endPrivateSession(); XCTAssertTrue(settings.privacy.privateExceptions.isEmpty)
        let prefs = WKWebpagePreferences(); var request = URLRequest(url: URL(string: "http://public.example")!)
        settings.privacy.apply(to: prefs, request: request, isPrivate: false)
        XCTAssertEqual(prefs.preferredHTTPSNavigationPolicy, .userMediatedFallbackToHTTP)
        request.url = URL(string: "https://public.example/")
        settings.privacy.apply(to: prefs, request: request, isPrivate: false)
        XCTAssertEqual(prefs.preferredHTTPSNavigationPolicy, .userMediatedFallbackToHTTP, "HTTPS-origin navigations retain the policy for a later HTTP redirect")
        request.httpMethod = "POST"; settings.privacy.apply(to: prefs, request: request, isPrivate: false)
        XCTAssertEqual(prefs.preferredHTTPSNavigationPolicy, .keepAsRequested)
    }
    func testCleanCopyAndContinuity() throws {
        let dirty = URL(string: "https://example.test/page?utm_source=fixture&keep=%2f#anchor")!
        PrivacyPasteboard.copy(dirty)
        #if os(macOS)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), URLCleaner.clean(dirty).absoluteString)
        #else
        XCTAssertEqual(UIPasteboard.general.url, URLCleaner.clean(dirty))
        #endif
        PrivacyPasteboard.copy(dirty, original: true)
        #if os(macOS)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), dirty.absoluteString)
        #else
        XCTAssertEqual(UIPasteboard.general.url, dirty)
        #endif
        XCTAssertEqual(ContinuityPage(url: dirty, title: "Fixture", profile: .personal, isPrivate: false)?.url, URLCleaner.clean(dirty))
        XCTAssertNil(ContinuityPage(url: dirty, title: "Fixture", profile: .personal, isPrivate: true))
        var replica = ContinuityReplica(deviceName: "Fixture device")
        let record = TabRecord(url: dirty)
        try replica.capture(profile: .personal, bookmarks: [], history: [], regularTabs: [record], preferences: [:])
        XCTAssertEqual(replica.tabs(for: BrowserProfile.personalID, device: replica.deviceID).first?.url, URLCleaner.clean(dirty))
        XCTAssertEqual(record.url, dirty, "Cleaning an outgoing tab must not mutate the local tab record")
    }
    func testCrossHostGETCleaningAndHistoryTraversal() async throws {
        let blocker = AdBlocker(); blocker.setMode(.off)
        let tab = BrowserTab(dataStore: .nonPersistent(), adBlocker: blocker, settings: BrowserSettings(defaults: nil))
        defer { tab.close() }
        try await load(tab)
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('#cross').click()")
        try await wait { tab.title == "Privacy destination" && !tab.isLoading }
        XCTAssertEqual(tab.url?.query, "keep=1")
        XCTAssertEqual(tab.webView.backForwardList.backList.count, 1)
        tab.goBack(); try await wait { tab.title == "Privacy fixture" && !tab.isLoading }
        XCTAssertEqual(tab.webView.backForwardList.forwardList.count, 1)
        tab.goForward(); try await wait { tab.title == "Privacy destination" && !tab.isLoading }
        XCTAssertEqual(tab.url?.query, "keep=1")
    }
    func testNativeGPCHeaderAndProperty() async throws {
        guard BrowserPrivacy.supportsGPC else { throw XCTSkip("Native GPC unavailable on OS 26; no shim is installed") }
        let blocker = AdBlocker(); blocker.setMode(.off)
        let settings = BrowserSettings(defaults: nil)
        let tab = BrowserTab(dataStore: .nonPersistent(), adBlocker: blocker, settings: settings)
        defer { tab.close() }
        for enabled in [true, false] {
            settings.privacy.setEnabled(enabled, .globalPrivacyControl)
            try await load(tab)
            let result = try await tab.webView.callAsyncJavaScript("await window.privacyReady; return {header:window.privacyHeaders.gpc,top:window.privacyTopHeader,script:window.privacyScriptHeader,frame:document.querySelector('#gpc-frame').contentWindow.frameHeader,frameProperty:document.querySelector('#gpc-frame').contentWindow.navigator.globalPrivacyControl,property:navigator.globalPrivacyControl};", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(result?["header"] as? String, enabled ? "1" : nil)
            XCTAssertEqual(result?["property"] as? Bool, enabled)
            XCTAssertEqual(result?["top"] as? String, enabled ? "1" : nil)
            XCTAssertEqual(result?["script"] as? String, enabled ? "1" : nil)
            XCTAssertEqual(result?["frame"] as? String, enabled ? "1" : nil)
            XCTAssertEqual(result?["frameProperty"] as? Bool, enabled)
        }
    }
    func testCheckoutSensitiveQueryAndFormRemainUsable() async throws {
        let session = BrowserSession(dataStore: .nonPersistent(), settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        hostInBackground(tab)
        let url = URL(string: "/privacy-checkout?token=synthetic&utm_source=retained&order=123", relativeTo: base)!.absoluteURL
        tab.navigate(to: url)
        try await wait { tab.title == "Checkout fixture" && !tab.isLoading }
        XCTAssertEqual(tab.url, url)
        let value = try await tab.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(value, "synthetic")
        for layer in PrivacyLayer.allCases { session.settings.privacy.setException(true, layer, for: url, isPrivate: false) }
        session.adBlocker.setException(true, for: url, isPrivate: false)
        let retained = try await tab.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(retained, value, "Toggling layers must not reload forms")
    }
    func testDismissingHTTPInterstitialPreservesCurrentHistoryItem() async throws {
        let blocker = AdBlocker(); blocker.setMode(.off)
        let tab = BrowserTab(dataStore: .nonPersistent(), adBlocker: blocker, settings: BrowserSettings(defaults: nil))
        defer { tab.close() }
        try await load(tab)
        let current = tab.webView.backForwardList.currentItem
        let request = URLRequest(url: URL(string: "http://public.example/")!)
        XCTAssertFalse(tab.interceptHTTPFallback(request, kind: .newNavigation))
        XCTAssertTrue(tab.interceptHTTPFallback(request, kind: .newNavigation))
        tab.cancelHTTPFallback()
        XCTAssertTrue(tab.webView.backForwardList.currentItem === current)
        XCTAssertEqual(tab.url, current?.url)
        XCTAssertNil(tab.httpWarningURL)
    }
    func testHTTPFallbackRequiresGETAndRemembersOnlyItsScope() {
        let settings = BrowserSettings(defaults: nil)
        let tab = BrowserTab(isPrivate: true, dataStore: .nonPersistent(), settings: settings)
        defer { tab.close() }
        hostInBackground(tab)
        var request = URLRequest(url: URL(string: "http://public.example")!)
        XCTAssertFalse(tab.interceptHTTPFallback(request, kind: .newNavigation))
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: URLError(.serverCertificateUntrusted))
        XCTAssertNil(tab.httpWarningURL)
        XCTAssertNotNil(tab.errorMessage)
        tab.dismissError()
        XCTAssertFalse(tab.interceptHTTPFallback(request, kind: .newNavigation), "Certificate failure clears any pending fallback")
        request.httpMethod = "POST"
        XCTAssertFalse(tab.interceptHTTPFallback(request, kind: .newNavigation)); XCTAssertNil(tab.httpWarningURL)
        request.httpMethod = "GET"
        XCTAssertFalse(tab.interceptHTTPFallback(request, kind: .backForward))
        request.url = URL(string: "http://public.example/") // WebKit canonicalizes an empty root path.
        XCTAssertTrue(tab.interceptHTTPFallback(request, kind: .newNavigation))
        XCTAssertEqual(tab.httpWarningURL, request.url)
        tab.continueToHTTP()
        XCTAssertTrue(settings.privacy.isException(.httpsUpgrade, for: request.url, isPrivate: true))
        XCTAssertFalse(settings.privacy.isException(.httpsUpgrade, for: request.url, isPrivate: false))
        XCTAssertNil(tab.httpWarningURL)
    }
    func testLiveSiteSpotChecks() async throws {
        guard ProcessInfo.processInfo.environment["ORIV_PRIVACY_LIVE"] == "1" else { throw XCTSkip("Live public-site spot checks are opt-in; fixtures run without external traffic") }
        let settings = BrowserSettings(defaults: nil), blocker = AdBlocker()
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker, settings: settings)
        defer { session.shutdown() }
        try await blocker.prepare()
        let tab = try XCTUnwrap(session.selectedTab)
        hostInBackground(tab)
        let sites = ["https://www.joinef.com", "https://news.ycombinator.com", "https://www.apple.com", "https://github.com", "https://stripe.com", "https://linear.app", "https://vercel.com", "https://en.wikipedia.org", "https://www.nytimes.com", "https://www.theverge.com", "https://www.youtube.com", "https://www.reddit.com", "https://www.bbc.com", "https://www.figma.com", "https://www.notion.so", "https://www.airbnb.com", "https://open.spotify.com", "https://duckduckgo.com", "https://www.google.com", "https://medium.com", "https://github.com/login", "http://example.com", "http://neverssl.com"]
        #if os(macOS)
        tab.webView.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        #else
        tab.webView.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        #endif
        let filter = ProcessInfo.processInfo.environment["ORIV_PRIVACY_SITE_FILTER"]
        for raw in sites where filter == nil || raw.contains(filter!) {
            let url = URL(string: raw)!
            tab.navigate(to: url)
            let deadline = Date().addingTimeInterval(15)
            while tab.isLoading && tab.errorMessage == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            // Allow client-rendered pages and locale redirects to settle before sampling.
            try await Task.sleep(for: .seconds(2))
            var row: [String: Any] = ["requested": raw, "url": tab.url?.absoluteString ?? "", "title": tab.title, "loading": tab.isLoading, "error": tab.errorMessage ?? "", "httpWarning": tab.httpWarningURL != nil]
            if let result = try? await tab.webView.callAsyncJavaScript("return {text:document.body ? document.body.innerText.length:0,links:document.links.length,scrollable:document.documentElement.scrollHeight>innerHeight};", arguments: [:], in: nil, contentWorld: .page) as? [String: Any] { row["document"] = result }
            if raw.contains("youtube") { row["sample"] = try? await tab.webView.evaluateJavaScript("document.body.innerText.slice(0,300)") }
            let broken = raw.contains("youtube") || tab.errorMessage != nil || tab.isLoading || ((row["document"] as? [String: Any])?["text"] as? Int ?? 0) < 20
            if broken {
                blocker.setException(true, for: url, isPrivate: false)
                for layer in PrivacyLayer.allCases { settings.privacy.setException(true, layer, for: url, isPrivate: false) }
                tab.navigate(to: url)
                let retryDeadline = Date().addingTimeInterval(12)
                while tab.isLoading && tab.errorMessage == nil && Date() < retryDeadline { try await Task.sleep(for: .milliseconds(100)) }
                try await Task.sleep(for: .seconds(2))
                row["offTitle"] = tab.title; row["offError"] = tab.errorMessage ?? ""; row["offLoading"] = tab.isLoading
                if raw.contains("youtube") { row["offSample"] = try? await tab.webView.evaluateJavaScript("document.body.innerText.slice(0,300)") }
                row["offDocument"] = try? await tab.webView.callAsyncJavaScript("return {text:document.body ? document.body.innerText.length:0,links:document.links.length};", arguments: [:], in: nil, contentWorld: .page)
                blocker.setException(false, for: url, isPrivate: false)
                for layer in PrivacyLayer.allCases { settings.privacy.setException(false, layer, for: url, isPrivate: false) }
            }
            print("PRIVACY_SITE: " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            tab.stop()
        }
    }
    #if os(iOS)
    func testPreviewRequiresExplicitLoadAndKeepsSourceStore() async throws {
        let blocker = AdBlocker(); blocker.setMode(.off)
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker, settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        func destinationRequests(_ run: String) async throws -> Int {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("privacy-stats").appending(queryItems: [URLQueryItem(name: "run", value: run)]))
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Int]
            return try XCTUnwrap(value?["destinationRequests"])
        }
        for isPrivate in [false, true] {
            let source = session.addTab(isPrivate: isPrivate)
            let run = UUID().uuidString
            let before = try await destinationRequests(run)
            let target = base.appendingPathComponent("privacy-destination").appending(queryItems: [URLQueryItem(name: "run", value: run)])
            let preview = MobileLinkPreview(url: target, title: "Fixture link", source: source, session: session)
            preview.loadViewIfNeeded(); XCTAssertNil(preview.preview)
            try await Task.sleep(for: .milliseconds(250)); XCTAssertNil(preview.preview)
            let metadataRequests = try await destinationRequests(run)
            XCTAssertEqual(metadataRequests, before)
            preview.loadPreview()
            let tab = try XCTUnwrap(preview.preview)
            XCTAssertTrue(tab.webView.configuration.websiteDataStore === source.webView.configuration.websiteDataStore)
            XCTAssertEqual(tab.isPrivate, isPrivate)
            try await wait { tab.title == "Privacy destination" && !tab.isLoading }
            let loadedRequests = try await destinationRequests(run)
            XCTAssertEqual(loadedRequests, before + 1)
            XCTAssertTrue(session.history.isEmpty)
            preview.viewDidDisappear(false)
        }
    }
    #endif
}
