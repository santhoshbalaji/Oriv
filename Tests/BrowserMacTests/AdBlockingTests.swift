import BrowserEngine
import Foundation
import WebKit
import XCTest
@testable import PersonalBrowser

@MainActor final class AdBlockingTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8768/adblock")!
    private let fixtureRules: [AdBlockingMode: String] = [
        .balanced: #"[{"trigger":{"url-filter":"/ad-banner\\.js"},"action":{"type":"block"}}]"#,
        .strict: #"[{"trigger":{"url-filter":"/ad-banner\\.js"},"action":{"type":"block"}},{"trigger":{"url-filter":"/analytics\\.js"},"action":{"type":"block"}},{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".ad-banner"}}]"#
    ]

    private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "AdBlockingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture timed out"])
    }

    private func load(_ tab: BrowserTab, host: String = "127.0.0.1") async throws -> [String] {
        let run = UUID().uuidString
        tab.navigate(to: URL(string: "http://\(host):8768/adblock?run=\(run)")!)
        try await wait { tab.title == "Adblock checked \(run)" && !tab.isLoading }
        let result = try await tab.webView.evaluateJavaScript("window.probeResults") as? [String]
        return try XCTUnwrap(result)
    }

    func testFirstLoadModesAndExistingTabsInBothPrivacyContexts() async throws {
        let blocker = AdBlocker(rules: fixtureRules)
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker)
        defer { session.tabs.forEach { $0.close() } }
        let regular = try XCTUnwrap(session.selectedTab)
        let privateTab = session.addTab(isPrivate: true)
        for mode in [AdBlockingMode.balanced, .strict, .off, .balanced] {
            blocker.setMode(mode)
            for tab in [regular, privateTab] {
                let result = try await load(tab)
                XCTAssertEqual(result, mode == .off ? ["loaded", "loaded", "loaded"] :
                    (mode == .strict ? ["blocked", "blocked", "loaded"] : ["blocked", "loaded", "loaded"]))
                let display = try await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.ad-banner')).display") as? String
                XCTAssertEqual(display == "none", mode == .strict)
            }
        }
    }

    func testSiteExceptionsRedirectsAndPrivatePersistenceBoundary() async throws {
        let suite = "OrivAdBlockTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let blocker = AdBlocker(defaults: defaults, rules: fixtureRules)
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker)
        defer { session.tabs.forEach { $0.close() } }
        let regular = try XCTUnwrap(session.selectedTab)
        let privateTab = session.addTab(isPrivate: true)
        blocker.setException(true, for: base, isPrivate: false)
        let regularResult = try await load(regular)
        let privateResult = try await load(privateTab)
        XCTAssertEqual(regularResult.first, "loaded")
        XCTAssertEqual(privateResult.first, "blocked")
        blocker.setException(true, for: URL(string: "http://localhost:8768")!, isPrivate: true)
        XCTAssertEqual(defaults.stringArray(forKey: "adBlockingExceptions"), ["127.0.0.1"])
        let privateAllowed = try await load(privateTab, host: "localhost")
        XCTAssertEqual(privateAllowed.first, "loaded")
        regular.navigate(to: URL(string: "http://127.0.0.1:8768/redirect-adblock?host=localhost")!)
        try await wait { regular.title == "Adblock checked redirect" && !regular.isLoading }
        let redirected = try await regular.webView.evaluateJavaScript("window.probeResults[0]") as? String
        XCTAssertEqual(redirected, "blocked", "A redirect must not carry the previous site's exception")
        let reconstructed = AdBlocker(defaults: defaults, rules: fixtureRules)
        XCTAssertEqual(reconstructed.regularExceptions, ["127.0.0.1"])
        XCTAssertTrue(reconstructed.privateExceptions.isEmpty)
        session.closeTab(privateTab.id)
        XCTAssertTrue(blocker.privateExceptions.isEmpty)
        let nextPrivate = session.addTab(isPrivate: true)
        let nextResult = try await load(nextPrivate, host: "localhost")
        XCTAssertEqual(nextResult.first, "blocked")
        XCTAssertFalse(session.snapshot().tabs.contains { $0.id == nextPrivate.id })
        blocker.removeRegularException("127.0.0.1")
        let reenabled = try await load(regular)
        XCTAssertEqual(reenabled.first, "blocked")
    }

    func testPopupsHaveIndependentFilteringAndKeepPrivateDataStore() async throws {
        for isPrivate in [false, true] {
            let blocker = AdBlocker(rules: fixtureRules)
            let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker)
            var delegates: [MacWebUIDelegate] = []
            session.configureWebView = { view, tab in
                let adapter = MacWebUIDelegate(session: session, tab: tab)
                delegates.append(adapter); view.uiDelegate = adapter
            }
            defer { session.tabs.forEach { $0.close() }; session.configureWebView = nil; _ = delegates }
            let opener = session.addTab(isPrivate: isPrivate)
            blocker.setException(true, for: base, isPrivate: isPrivate)
            _ = try await load(opener)
            _ = try await opener.webView.evaluateJavaScript("document.querySelector('#popup').click()")
            try await wait { session.selectedTab?.title == "Adblock checked popup" }
            let popup = try XCTUnwrap(session.selectedTab)
            XCTAssertNotEqual(popup.id, opener.id)
            XCTAssertEqual(popup.isPrivate, isPrivate)
            XCTAssertTrue(popup.webView.configuration.websiteDataStore === opener.webView.configuration.websiteDataStore)
            XCTAssertFalse(popup.webView.configuration.userContentController === opener.webView.configuration.userContentController)
            let blocked = try await popup.webView.evaluateJavaScript("window.probeResults[0]") as? String
            XCTAssertEqual(blocked, "blocked")
            let openerResult = try await opener.webView.callAsyncJavaScript("return await probe('/ad-banner.js')", arguments: [:], in: nil, contentWorld: .page) as? String
            XCTAssertEqual(openerResult, "loaded")
            let blankResult = try await opener.webView.callAsyncJavaScript("""
                const child = window.open('about:blank');
                try { await child.fetch(location.origin + '/ad-banner.js'); return 'loaded'; }
                catch { return 'blocked'; }
                """, arguments: [:], in: nil, contentWorld: .page) as? String
            XCTAssertEqual(blankResult, "blocked", "Initial about:blank popups need protection before navigation")
        }
    }

    func testBundledRulesCompileAndStrictCosmeticsWork() async throws {
        let blocker = AdBlocker()
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker)
        defer { session.tabs.forEach { $0.close() } }
        let tab = try XCTUnwrap(session.selectedTab)
        _ = try await load(tab)
        blocker.setMode(.strict)
        _ = try await load(tab)
        let display = try await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.ad-banner')).display") as? String
        XCTAssertEqual(display, "none")
        XCTAssertNil(blocker.preparationError)
    }

    func testCompilationFailureStopsNavigationUntilUserChoosesOff() async throws {
        let blocker = AdBlocker(rules: [.balanced: "not valid json", .strict: "not valid json"])
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker)
        defer { session.tabs.forEach { $0.close() } }
        let tab = try XCTUnwrap(session.selectedTab)
        tab.navigate(to: base)
        try await wait { tab.errorMessage != nil }
        XCTAssertNil(tab.webView.url)
        XCTAssertNotNil(blocker.preparationError)
        blocker.setMode(.off)
        let result = try await load(tab)
        XCTAssertEqual(result, ["loaded", "loaded", "loaded"])
    }
}
