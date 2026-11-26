import BrowserCore
@testable import BrowserEngine
import WebKit
import Network
import XCTest
import SwiftUI
#if os(macOS)
@testable import PersonalBrowser
import AppKit
#else
@testable import OrivMobile
import UIKit
#endif

@MainActor private final class PrivacyCountingContentController:WKUserContentController {
    var ruleAdds = 0, ruleRemoves = 0, scriptAdds = 0, scriptResets = 0
    func resetCounts() { ruleAdds = 0; ruleRemoves = 0; scriptAdds = 0; scriptResets = 0 }
    override func add(_ rule:WKContentRuleList) { ruleAdds += 1; super.add(rule) }
    override func remove(_ rule:WKContentRuleList) { ruleRemoves += 1; super.remove(rule) }
    override func addUserScript(_ script:WKUserScript) { scriptAdds += 1; super.addUserScript(script) }
    override func removeAllUserScripts() { scriptResets += 1; super.removeAllUserScripts() }
}

@MainActor final class PrivacyIntegrationTests: XCTestCase {
    func testPreparedPolicyAvoidsScriptReinstallationAndStillAppliesExceptions() async throws {
        let fixture = """
        [{"trigger":{"url-filter":"blocked.example"},"action":{"type":"block"}}]
        """
        let blocker = AdBlocker(rules:[.balanced:fixture,.strict:fixture],cacheNamespace:"oriv.hot-path."+UUID().uuidString)
        let content = PrivacyCountingContentController()
        let script = WKUserScript(source:"window.syntheticPrivacyFixture=true",injectionTime:.atDocumentStart,forMainFrameOnly:true)
        content.addUserScript(script); content.resetCounts()
        let url = URL(string:"https://fixture.example/")!
        XCTAssertFalse(blocker.applyIfPrepared(to:content,url:url,isPrivate:false),"Unprepared protection must remain fail-closed")
        XCTAssertEqual(content.ruleAdds,0)
        try await blocker.prepare()
        XCTAssertTrue(blocker.applyIfPrepared(to:content,url:url,isPrivate:false))
        XCTAssertGreaterThan(content.ruleAdds,0)
        content.resetCounts()
        for _ in 0..<10 { XCTAssertTrue(blocker.applyIfPrepared(to:content,url:url,isPrivate:false)) }
        XCTAssertEqual(content.ruleAdds,0); XCTAssertEqual(content.ruleRemoves,0)
        XCTAssertEqual(content.scriptAdds,0); XCTAssertEqual(content.scriptResets,0)
        XCTAssertTrue(content.userScripts.first === script)
        blocker.setException(true,for:url,isPrivate:false)
        XCTAssertTrue(blocker.applyIfPrepared(to:content,url:url,isPrivate:false))
        XCTAssertGreaterThan(content.ruleRemoves,0)
        content.resetCounts()
        XCTAssertTrue(blocker.applyIfPrepared(to:content,url:URL(string:"https://other.example/"),isPrivate:false))
        XCTAssertGreaterThan(content.ruleAdds,0,"A host exception must not disable protection on the next host")
        XCTAssertEqual(content.scriptResets,0)
        for identifier in Set(blocker.compilationMeasurements.map(\.identifier)) {
            try await WKContentRuleListStore.default()!.removeContentRuleList(forIdentifier:identifier)
        }
    }
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
    private func hostFixture(_ tab: BrowserTab) throws {
        guard fixtureWindows[tab.id] == nil else { return }
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = tab.webView
        fixtureWindows[tab.id] = window
        BackgroundUIMode.show(window, key: false)
    }
    #else
    private var fixtureDetachers: [() -> Void] = []
    private var hostedTabs: Set<UUID> = []
    override func tearDown() async throws {
        for detach in fixtureDetachers.reversed() { detach() }
        fixtureDetachers.removeAll()
        hostedTabs.removeAll()
    }
    private func hostFixture(_ tab: BrowserTab) throws {
        guard !hostedTabs.contains(tab.id) else { return }
        fixtureDetachers.append(try mountWebFixture(tab))
        hostedTabs.insert(tab.id)
    }
    #endif
    private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
        try await waitForFixtureCondition("the privacy fixture", timeout: 40, file: file, line: line, condition)
    }
    /// The ~332k-rule CNAME list compiles in minutes on hosted iPhone simulators.
    private func waitForCNAME(file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
        try await waitForFixtureCondition("the CNAME rule list", timeout: 120, file: file, line: line, condition)
    }
    private func load(_ tab: BrowserTab, _ path: String = "/privacy") async throws {
        try hostFixture(tab)
        tab.navigate(to: URL(string: path, relativeTo: base)!.absoluteURL)
        try await wait { tab.title == "Privacy fixture" && !tab.isLoading || tab.errorMessage != nil }
        XCTAssertNil(tab.errorMessage)
    }
    func testYouTubeUserScriptIsScopedAndRespectsBothExceptions() throws {
        let settings = BrowserSettings(defaults: nil)
        let blocker = AdBlocker()
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker, settings: settings)
        defer { session.shutdown() }
        let controller = WKUserContentController()
        let youtube = URL(string: "https://www.youtube.com/watch?v=fixture")!
        func script(for url: URL, privateTab: Bool = false) -> WKUserScript? {
            blocker.applyPrepared(to: controller, url: url, isPrivate: privateTab)
            return controller.userScripts.first { $0.source.hasPrefix("// Oriv YouTube policy") }
        }
        for host in YouTubeProtection.hosts {
            XCTAssertNotNil(script(for: URL(string: "https://\(host)")!))
        }
        XCTAssertNil(script(for: URL(string: "https://www.youtube.com.example/")!))
        XCTAssertNil(script(for: URL(string: "https://browserbench.org/Speedometer3.1/")!))
        let installed = try XCTUnwrap(script(for: youtube))
        XCTAssertEqual(installed.injectionTime, .atDocumentStart)
        XCTAssertFalse(installed.isForMainFrameOnly)
        XCTAssertTrue(script(for: youtube) === installed)
        XCTAssertTrue(installed.source.contains("const skipAds = false;"))
        settings.privacy.skipYouTubeAds = true
        XCTAssertTrue(script(for: youtube)?.source.contains("const skipAds = true;") == true)
        settings.privacy.setException(true, .youtubeAds, for: youtube, isPrivate: true)
        XCTAssertNil(script(for: youtube, privateTab: true))
        XCTAssertNotNil(script(for: youtube))
        blocker.setException(true, for: youtube, isPrivate: false)
        XCTAssertNil(script(for: youtube))
        blocker.setException(false, for: youtube, isPrivate: false)
        blocker.setMode(.off)
        XCTAssertNil(script(for: youtube))
        blocker.setMode(.balanced)
        settings.privacy.setEnabled(false, .youtubeAds)
        XCTAssertNil(script(for: youtube))
    }

    func testYouTubeFixturePrunesInlineFetchAndXHR() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        defer { session.shutdown() }
        let tab = session.addTab(isPrivate: true)
        try hostFixture(tab)
        let shippingSource = try XCTUnwrap(YouTubeProtection.source(disabledHosts: [], skipAds: false))
        // Keep production host matching strict. This copy targets the local QA server.
        let localSource = shippingSource.replacingOccurrences(of: "// Oriv YouTube policy", with: "// Local YouTube fixture")
            .replacingOccurrences(of: "'youtube.com'", with: "'127.0.0.1'")
        tab.webView.configuration.userContentController.addUserScript(WKUserScript(
            source: localSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        tab.navigate(to: base.appendingPathComponent("youtube-protection"))
        try await waitForFixtureCondition("YouTube endpoint fixture", timeout: 20) {
            (try? await tab.webView.evaluateJavaScript("window.youtubeFixture !== undefined")) as? Bool == true
        }
        let result = try await tab.webView.evaluateJavaScript("window.youtubeFixture")
        XCTAssertEqual(result as? [String: Bool], [
            "runtime": true, "inline": true, "fetch": true, "xhr": true, "untouched": true,
            "source": true, "cosmetics": true
        ], String(describing: result))
    }

    func testCookieBannerModeMigratesExplicitChoices() throws {
        let name = "oriv.consent-mode." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "browser.restoreTabs")
        XCTAssertEqual(BrowserPrivacy(defaults: defaults).cookieBannerMode, .reject)
        defaults.set(false, forKey: "privacy.cookieBanners")
        XCTAssertEqual(BrowserPrivacy(defaults: defaults).cookieBannerMode, .off)
        defaults.set(true, forKey: "privacy.cookieBanners")
        let privacy = BrowserPrivacy(defaults: defaults)
        XCTAssertEqual(privacy.cookieBannerMode, .hide)
        privacy.setCookieBannerMode(.reject)
        XCTAssertEqual(BrowserPrivacy(defaults: defaults).cookieBannerMode, .reject)
    }

    func testRejectCookieBannersAndHideUnknownInPrivateTabs() async throws {
        let settings = BrowserSettings(defaults: nil)
        let session = BrowserSession(dataStore: .nonPersistent(), settings: settings)
        defer { session.shutdown() }
        let tab = session.addTab(isPrivate: true)
        try hostFixture(tab)
        func loadConsent(_ cmp: String) async throws {
            let url = base.appendingPathComponent("consent").appending(queryItems: [.init(name: "cmp", value: cmp)])
            tab.navigate(to: url)
            try await wait { tab.url == url && tab.title == "Consent fixture" && !tab.isLoading }
        }
        for cmp in ["onetrust", "cookiebot"] {
            try await loadConsent(cmp)
            try await waitForFixtureCondition("the \(cmp) reject control", timeout: 18) {
                (try? await tab.webView.evaluateJavaScript("JSON.stringify(window.consentClicks)")) as? String == "[\"reject\"]"
            }
        }
        try await loadConsent("unknown")
        try await waitForFixtureCondition("fallback CSS hides the unknown banner", timeout: 18) {
            (try? await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#AlertCookieBanner')).display")) as? String == "none"
        }
        let clicks = try await tab.webView.evaluateJavaScript("JSON.stringify(window.consentClicks)") as? String
        XCTAssertEqual(clicks, "[]")
        settings.privacy.setException(true, .cookieBanners, for: base, isPrivate: true)
        try await loadConsent("onetrust")
        let available = try await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#onetrust-banner-sdk')).display !== 'none'") as? Bool
        XCTAssertEqual(available, true)
        XCTAssertFalse(tab.webView.configuration.userContentController.userScripts.contains { $0.source.hasPrefix("// Oriv cookie consent policy") })
    }

    func testAppearancePreservesExplicitProfileChoicesAndDefaultsUnsetToSystem() {
        XCTAssertEqual(BrowserAppearance.saved(nil), .system)
        XCTAssertEqual(BrowserAppearance.saved("Future theme"), .system)
        for choice in BrowserAppearance.allCases {
            XCTAssertEqual(BrowserAppearance.saved(choice.rawValue), choice)
        }
        XCTAssertNil(BrowserAppearance.system.colorScheme)
        XCTAssertFalse(BrowserAppearance.system.theme.isT3Code)
        XCTAssertTrue(BrowserAppearance.t3Code.theme.isT3Code)
        let session = BrowserSession(dataStore: .nonPersistent())
        defer { session.shutdown() }
        XCTAssertNil(ContinuityPreferences.snapshot(session: session, appearance: nil)["appearance"])
        XCTAssertEqual(ContinuityPreferences.snapshot(session: session, appearance: "System")["appearance"], "System")
    }

    func testSystemAccentMarkersMeetContrastOnEverySelection() {
        for appearance in [BrowserAppearance.light, .dark, .t3Code] {
            var environment = EnvironmentValues()
            environment.colorScheme = appearance.colorScheme ?? .light
            let theme = appearance.theme
            for color in [theme.selection, theme.sidebar.selection] {
                let surface = color.resolve(in: environment)
                let marker = theme.markerAccent(on: surface, in: environment).resolve(in: environment)
                let foreground = Theme.luminance(marker)
                let background = Theme.luminance(surface)
                let ratio = (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 3, appearance.rawValue)
            }
        }
    }

    #if os(iOS)
    func testThemeSurfaceCaptures() async throws {
        for appearance in [BrowserAppearance.light, .dark] {
            try await captureThemeSurfaces(appearance)
        }
    }

    private func captureThemeSurfaces(_ appearance: BrowserAppearance) async throws {
        let profiles = MobileProfiles(forceEphemeral: true)
        let controller = profiles.current
        let session = controller.session
        defer { session.shutdown() }
        let page = try XCTUnwrap(session.selectedTab)
        _ = session.addTab(url: URL(string: "https://reading.example"), select: false, load: false)
        _ = session.addTab(isPrivate: true, select: false, load: false)
        _ = session.importBookmarks([Bookmark(title: "Field Notes", url: URL(string: "https://field.example")!)])

        controller.appearance = appearance
        let host = UIHostingController(rootView: MobileBrowserView(controller: controller, profiles: profiles, reduceMotionOverride: true)
            .browserAppearance(appearance, followsPage: true).environment(\.scenePhase, .active))
        host.overrideUserInterfaceStyle = appearance == .light ? .light : .dark
        let detach = try mountFixtureController(host)
        defer { detach() }
        let window = try XCTUnwrap(host.view.window)
        func capture(_ surface: String) async {
            // Give native hosting, sheet and collection layout time to settle.
            try? await Task.sleep(for: .milliseconds(650))
            window.layoutIfNeeded()
            var drewHierarchy = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drewHierarchy)
            let attachment = XCTAttachment(image: image)
            attachment.name = "iphone-theme-\(appearance.rawValue.lowercased())-\(surface)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        await capture("start")
        let url = URL(string: "https://field.example/guide")!
        try await waitForWebFixture(page, at: url) {
            page.webView.loadHTMLString("""
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <meta name="color-scheme" content="light dark">
                <title>Field Notes</title>
                <style>body { font: 18px system-ui; margin: 28px; line-height: 1.55; }</style>
                <h1>Field Notes</h1><p>A short guide to documenting a local walk.</p>
                <h2>What to record</h2><p>Sketch the route, note the weather and mark places to revisit.</p>
                """, baseURL: url)
        }
        await capture("browsing")
        controller.sheet = .tabs
        await capture("tabs")
        controller.sheet = nil
        try? await Task.sleep(for: .milliseconds(550))
        controller.sheet = .settings
        await capture("settings")
        controller.sheet = nil

    }
    #endif

    func testPrivacySettingsCapture() throws {
        let session = BrowserSession(dataStore: .nonPersistent(), settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        #if os(macOS)
        let content = VStack(alignment: .leading, spacing: 12) {
            Text("Privacy").font(.title2)
            PrivacySettingsControls(session: session)
        }.padding(20).background(.background).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: 560, height: nil)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "mac-privacy-settings"
        #else
        let host = UIHostingController(rootView: NavigationStack {
            Form { Section { PrivacySettingsControls(session: session) } }
                .navigationTitle("Privacy")
                .navigationBarTitleDisplayMode(.inline)
        }.preferredColorScheme(.light))
        let detach = try mountFixtureController(host)
        defer { detach() }
        let bounds = host.view.bounds
        var drewHierarchy = false
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drewHierarchy = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drewHierarchy)
        let attachment = XCTAttachment(image: image)
        attachment.name = "iphone-privacy-settings"
        #endif
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPrivateTabIsolationDefaultsOnAndSavesExplicitOptOut() throws {
        let name = "oriv.private-isolation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // An existing installation with unrelated settings also defaults to on.
        defaults.set(false, forKey: "browser.restoreTabs")
        let isolation = PrivateTabIsolation(defaults: defaults)
        XCTAssertTrue(isolation.isEnabled)
        isolation.isEnabled = false
        XCTAssertFalse(PrivateTabIsolation(defaults: defaults).isEnabled)
    }

    func testPrivateCookieIsolationPreservesPopupAndExistingTabStores() async throws {
        #if os(macOS)
        let controller = BrowserController(testing: true, websiteStore: .nonPersistent())
        #else
        let controller = MobileController()
        #endif
        let session = controller.session
        defer { session.shutdown() }
        let url = base.appendingPathComponent("private-cookie-fixture")
        let regular = try XCTUnwrap(session.selectedTab)
        let opener = session.addTab(isPrivate: true, load: false)
        let isolated = session.addTab(isPrivate: true, load: false)
        let openerStore = try XCTUnwrap(opener.websiteDataStore)
        XCTAssertFalse(openerStore.isPersistent)
        XCTAssertFalse(isolated.websiteDataStore === openerStore)

        func navigate(_ tab: BrowserTab) async throws {
            try hostFixture(tab)
            try await waitForWebFixture(tab, at: url, timeout: 35) { tab.navigate(to: url) }
        }
        func assertCookie(_ tab: BrowserTab, present: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            let cookie = try await tab.webView.evaluateJavaScript("document.cookie") as? String
            XCTAssertEqual(cookie?.contains("oriv-private=synthetic"), present, file: file, line: line)
        }
        func setCookie(_ tab: BrowserTab) async throws {
            _ = try await tab.webView.evaluateJavaScript("document.cookie = 'oriv-private=synthetic; path=/'")
            try await assertCookie(tab, present: true)
        }
        try await navigate(opener)
        try await setCookie(opener)
        try await navigate(isolated)
        try await assertCookie(isolated, present: false)

        session.duplicateTab(opener.id)
        let duplicate = try XCTUnwrap(session.selectedTab)
        XCTAssertEqual(duplicate.url, url)
        XCTAssertFalse(duplicate.websiteDataStore === openerStore)
        session.closeTab(duplicate.id)

        // Flip the setting before requesting a real WebKit popup.
        session.settings.privateTabIsolation.isEnabled = false
        var rule = SiteRule()
        rule.allowsAutomaticPopups = true
        session.settings.setRule(rule, for: url, isPrivate: true)
        session.selectTab(opener.id)
        let previousIDs = Set(session.tabs.map(\.id))
        _ = try await opener.webView.evaluateJavaScript("window.open('/private-cookie-fixture', 'login'); true")
        try await waitForFixtureCondition("WebKit login popup creation", timeout: 35) {
            session.tabs.contains { !previousIDs.contains($0.id) }
        }
        let popup = try XCTUnwrap(session.tabs.first { !previousIDs.contains($0.id) })
        try hostFixture(popup)
        try await waitForFixtureCondition("the popup fixture document", timeout: 35) {
            popup.title == "Private cookie fixture" && !popup.isLoading
        }
        XCTAssertTrue(popup.websiteDataStore === openerStore)
        try await assertCookie(popup, present: true)
        let hasOpener = try await popup.webView.evaluateJavaScript("window.opener !== null") as? Bool
        XCTAssertEqual(hasOpener, true)
        session.closeTab(opener.id)
        XCTAssertNil(opener.websiteDataStore)
        try await assertCookie(popup, present: true)
        session.closeTab(popup.id)
        XCTAssertNil(popup.websiteDataStore)

        let sharedA = session.addTab(isPrivate: true, load: false)
        let sharedB = session.addTab(isPrivate: true, load: false)
        XCTAssertTrue(sharedA.websiteDataStore === sharedB.websiteDataStore)
        try await navigate(sharedA)
        try await assertCookie(sharedA, present: false)
        try await setCookie(sharedA)
        try await navigate(sharedB)
        try await assertCookie(sharedB, present: true)
        try await assertCookie(isolated, present: false)
        try await navigate(regular)
        try await assertCookie(regular, present: false)

        session.closeTab(sharedA.id)
        session.closeTab(sharedB.id)
        let freshShared = session.addTab(isPrivate: true, load: false)
        try await navigate(freshShared)
        try await assertCookie(freshShared, present: false)
        XCTAssertFalse(session.canReopenTab)
        XCTAssertEqual(session.snapshot().tabs.map(\.id), [regular.id])
    }

    func testBundledRulesCompileColdAndWarm() async throws {
        // A cold strict compile took 157 s on a hosted iPhone simulator runner;
        // use the 180 s maximum that scripts/check-iphone.sh allows.
        executionTimeAllowance = 180
        let namespace = "oriv.privacy-benchmark." + UUID().uuidString
        let cold = AdBlocker(cacheNamespace: namespace)
        cold.setMode(.strict)
        try await cold.prepare()
        try await waitForCNAME { !cold.isPreparingCNAME }
        XCTAssertNil(cold.cnamePreparationError)
        let warm = AdBlocker(cacheNamespace: namespace)
        warm.setMode(.strict)
        try await warm.prepare()
        try await waitForCNAME { !warm.isPreparingCNAME }
        XCTAssertNil(warm.cnamePreparationError)
        for (name, blocker) in [("first", cold), ("warm", warm)] {
            let data = try JSONEncoder().encode(blocker.compilationMeasurements)
            let text = String(decoding: data, as: UTF8.self)
            print("PRIVACY_COMPILE_\(name): \(text)")
            let attachment = XCTAttachment(string: text); attachment.name = "Privacy compilation \(name)"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertGreaterThanOrEqual(blocker.compilationMeasurements.count, 5)
        }
        XCTAssertTrue(warm.compilationMeasurements.allSatisfy(\.cached))
        XCTAssertTrue(cold.compilationMeasurements.contains { $0.component.hasPrefix("network-cname-") })
        for measurement in cold.compilationMeasurements {
            try await WKContentRuleListStore.default()!.removeContentRuleList(forIdentifier: measurement.identifier)
        }
    }

    func testForgetSiteClearsCookieStorageAndHistoryAndResetsLiveTab() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let blocker = AdBlocker()
        blocker.setMode(.off)
        let session = BrowserSession(dataStore: store, adBlocker: blocker,
                                     settings: BrowserSettings(defaults: nil), recordsQAFixtureHistory: true)
        defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        try await load(tab)
        let url = try XCTUnwrap(tab.url)
        let site = try XCTUnwrap(session.forgettableSite(for: tab))
        let originalView = tab.webView
        session.toggleBookmark()
        _ = try await originalView.evaluateJavaScript("""
            document.cookie = 'oriv_forget=1; path=/';
            localStorage.setItem('oriv_forget', '1');
            sessionStorage.setItem('oriv_forget', '1');
            """)
        let unrelated = try XCTUnwrap(HTTPCookie(properties: [
            .name: "oriv_keep", .value: "1", .domain: "keep.example", .path: "/"
        ]))
        await store.httpCookieStore.setCookie(unrelated)
        let otherProfile = WKWebsiteDataStore.nonPersistent()
        let otherProfileCookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "other_profile", .value: "1", .domain: site.domain, .path: "/"
        ]))
        await otherProfile.httpCookieStore.setCookie(otherProfileCookie)
        let before = await store.dataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage])
        XCTAssertTrue(before.contains { site.contains(host: $0.displayName) })
        XCTAssertTrue(session.history.contains { site.contains($0.url) })
        try await session.forgetSite(site)
        XCTAssertIdentical(session.selectedTab, tab)
        XCTAssertFalse(tab.webView === originalView)
        XCTAssertEqual(tab.url, url)
        XCTAssertEqual(session.bookmarks.map(\.url), [url])
        try await wait { tab.title == "Privacy fixture" && !tab.isLoading }
        let state = try await tab.webView.evaluateJavaScript("""
            !document.cookie.includes('oriv_forget') && localStorage.getItem('oriv_forget') === null &&
                sessionStorage.getItem('oriv_forget') === null
            """) as? Bool
        XCTAssertEqual(state, true)
        let cookies = await store.httpCookieStore.allCookies()
        XCTAssertEqual(cookies.map(\.name), [unrelated.name])
        let otherProfileCookies = await otherProfile.httpCookieStore.allCookies()
        XCTAssertEqual(otherProfileCookies.map(\.name), [otherProfileCookie.name])
        XCTAssertFalse(session.history.contains { site.contains($0.url) })
        let privateTab = session.addTab(url: url, isPrivate: true, load: false)
        XCTAssertNil(session.forgettableSite(for: privateTab))
    }

    func testCNAMEHostAllowsTopLevelAndBlocksSameOriginSubresource() async throws {
        let data = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 18768))
        proxy.allowFailover = false
        data.proxyConfigurations = [proxy]
        let settings = BrowserSettings(defaults: nil)
        settings.privacy.setEnabled(false, .httpsUpgrade)
        settings.privacy.setCookieBannerMode(.off)
        let namespace = "oriv.tests.cname-bundled." + UUID().uuidString
        let blocker = AdBlocker(cacheNamespace: namespace)
        let ruleStore = try XCTUnwrap(WKContentRuleListStore.default())
        let oldIdentifiers = Set(try BundledPrivacyRules.resources(cnameOnly: true).map { "\(namespace).\($0.sha256)" })
        let cnamePrefix = namespace + ".cname."
        func cacheIdentifiers() async throws -> [String] {
            let identifiers = await ruleStore.availableIdentifiers()
            return try XCTUnwrap(identifiers).filter { $0.hasPrefix(namespace + ".") }
        }
        func cnameIdentifiers() async throws -> [String] {
            try await cacheIdentifiers().filter { $0.hasPrefix(cnamePrefix) || oldIdentifiers.contains($0) }
        }
        let session = BrowserSession(dataStore: data, adBlocker: blocker, settings: settings)
        defer { session.shutdown() }
        session.siteIcons.document = nil // The synthetic origin is reachable only through the WebKit proxy.
        let tab = try XCTUnwrap(session.selectedTab)
        try hostFixture(tab)
        // This host is in the bundled CNAME list and absent from the core filters.
        let url = URL(string: "http://analytics.airtm.com/cname-page")!
        func loadProbe() async throws -> String? {
            tab.navigate(to: URL(string: url.absoluteString + "?run=" + UUID().uuidString)!)
            try await wait { tab.errorMessage != nil || (tab.title == "CNAME fixture" && !tab.isLoading) }
            XCTAssertNil(tab.errorMessage)
            XCTAssertEqual(tab.title, "CNAME fixture")
            return try await tab.webView.evaluateJavaScript("window.probe ?? null") as? String
        }
        let balanced = try await loadProbe()
        XCTAssertEqual(balanced, "loaded")
        XCTAssertFalse(blocker.isPreparingCNAME)
        XCTAssertFalse(blocker.compilationMeasurements.contains { $0.component.hasPrefix("network-cname") })
        let balancedIdentifiers = try await cnameIdentifiers()
        XCTAssertEqual(balancedIdentifiers, [])
        let coreIdentifiers = try await cacheIdentifiers()
        XCTAssertFalse(coreIdentifiers.isEmpty)

        blocker.setMode(.strict)
        try await waitForCNAME { !blocker.isPreparingCNAME }
        XCTAssertNil(blocker.cnamePreparationError)
        let strictIdentifiers = try await cnameIdentifiers()
        XCTAssertEqual(strictIdentifiers.count, 4)
        let liveStrict = try await loadCNAMEProbe(in: tab)
        XCTAssertEqual(liveStrict, "blocked")
        let strict = try await loadProbe()
        XCTAssertEqual(strict, "blocked")
        blocker.setException(true, for: url, isPrivate: false)
        let excepted = try await loadProbe()
        XCTAssertEqual(excepted, "loaded")
        blocker.setException(false, for: url, isPrivate: false)
        let liveUnexcepted = try await loadCNAMEProbe(in: tab)
        XCTAssertEqual(liveUnexcepted, "blocked")
        blocker.setMode(.balanced)
        let liveBalanced = try await loadCNAMEProbe(in: tab)
        XCTAssertEqual(liveBalanced, "loaded")
        blocker.setMode(.off)
        let off = try await loadProbe()
        XCTAssertEqual(off, "loaded")
        let offIdentifiers = try await cnameIdentifiers()
        XCTAssertEqual(Set(offIdentifiers), Set(strictIdentifiers))

        // Exercise the next-launch cleanup against the same WebKit store.
        session.shutdown()
        await AdBlocker.removeCNAMECache(namespace: namespace).value
        let remaining = try await cacheIdentifiers()
        XCTAssertEqual(Set(remaining), Set(coreIdentifiers))
        for identifier in remaining {
            try await ruleStore.removeContentRuleList(forIdentifier: identifier)
        }
    }

    func testDeferredCNAMEDoesNotGateNavigationAndAppliesToOpenTabs() async throws {
        let (rules, release) = AsyncStream<String>.makeStream()
        defer { release.finish() }
        let suite = "oriv.tests.cname-late." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AdBlockingMode.strict.rawValue, forKey: "adBlockingMode")
        let blocker = AdBlocker(defaults: defaults,
                                rules: [.strict: "[{\"trigger\":{\"url-filter\":\"blocked.example\"},\"action\":{\"type\":\"block\"}}]"],
                                cacheNamespace: suite, cnameFixture: {
            for await rule in rules { return rule }
            throw CancellationError()
        })
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 18768))
        proxy.allowFailover = false
        let settings = BrowserSettings(defaults: nil)
        settings.privacy.setEnabled(false, .httpsUpgrade)
        settings.privacy.setCookieBannerMode(.off)
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker, settings: settings, externalPrivate: true)
        defer { session.shutdown() }
        session.siteIcons.document = nil
        let first = try XCTUnwrap(session.selectedTab)
        let second = session.addTab(isPrivate: true, load: false)
        let allowedURL = URL(string: "http://analytics.sixt.com/cname-page")!
        let blockedURL = URL(string: "http://analytics.seagate.com/cname-page")!
        for (tab, url) in [(first, allowedURL), (second, blockedURL)] {
            tab.websiteDataStore?.proxyConfigurations = [proxy]
            try hostFixture(tab)
            tab.navigate(to: url)
            try await wait { tab.title == "CNAME fixture" && !tab.isLoading }
            let initial = try await tab.webView.evaluateJavaScript("window.probe") as? String
            XCTAssertEqual(initial, "loaded")
            XCTAssertTrue(blocker.isPreparingCNAME)
        }
        blocker.setException(true, for: allowedURL, isPrivate: true)
        // An exception in the regular profile must not disable a private tab.
        blocker.setException(true, for: blockedURL, isPrivate: false)
        release.yield("""
        [{"trigger":{"url-filter":"^http://analytics","resource-type":["script"]},"action":{"type":"block"}}]
        """)
        release.finish()
        try await waitForCNAME { !blocker.isPreparingCNAME }
        XCTAssertNil(blocker.cnamePreparationError)
        for (tab, expected) in [(first, "loaded"), (second, "blocked")] {
            let result = try await loadCNAMEProbe(in: tab)
            XCTAssertEqual(result, expected)
        }
    }

    private func loadCNAMEProbe(in tab: BrowserTab) async throws -> String? {
        try await tab.webView.callAsyncJavaScript("""
        return await new Promise(resolve => {
            const script = document.createElement('script');
            script.onload = () => resolve('loaded');
            script.onerror = () => resolve('blocked');
            script.src = '/cname-probe.js?late=' + Math.random();
            document.head.append(script);
        });
        """, arguments: [:], contentWorld: .page) as? String
    }

    func testDeferredCNAMEKeepsOffAndDoesNotAddRulesTwice() async throws {
        let (rules, release) = AsyncStream<String>.makeStream()
        defer { release.finish() }
        let core = "[{\"trigger\":{\"url-filter\":\"core.example\"},\"action\":{\"type\":\"block\"}}]"
        let cname = "[{\"trigger\":{\"url-filter\":\"tracker.example\"},\"action\":{\"type\":\"block\"}}]"
        let namespace = "oriv.tests.cname-off." + UUID().uuidString
        let blocker = AdBlocker(rules: [.balanced: core, .strict: core],
                                cacheNamespace: namespace, cnameFixture: {
            for await rule in rules { return rule }
            throw CancellationError()
        })
        let controller = PrivacyCountingContentController()
        let url = URL(string: "https://fixture.example")!
        blocker.setMode(.strict)
        try await blocker.apply(to: controller, url: url, isPrivate: false)
        XCTAssertTrue(blocker.isPreparingCNAME)
        blocker.setMode(.off)
        blocker.refreshPrepared(on: controller)
        controller.resetCounts()
        release.yield(cname)
        release.finish()
        // The completed compilation is measured even though the Off status is hidden.
        try await wait { blocker.compilationMeasurements.contains { $0.component == "network-cname" } }
        XCTAssertNil(blocker.cnamePreparationError)
        XCTAssertEqual(controller.ruleAdds, 0)
        blocker.setMode(.balanced)
        blocker.refreshPrepared(on: controller)
        blocker.refreshPrepared(on: controller)
        XCTAssertEqual(controller.ruleAdds, 1)
        blocker.setMode(.strict)
        blocker.refreshPrepared(on: controller)
        XCTAssertEqual(controller.ruleAdds, 2)

        blocker.setMode(.balanced)
        XCTAssertEqual(controller.ruleRemoves, 1)

        // A switch to Strict while next-launch cleanup is pending must leave
        // the newly prepared lists in the store.
        let cleanup = AdBlocker.removeCNAMECache(namespace: namespace)
        let reopened = AdBlocker(rules: [.strict: core], cacheNamespace: namespace, cnameFixture: { cname })
        reopened.setMode(.strict)
        try await reopened.prepare()
        try await waitForCNAME { !reopened.isPreparingCNAME }
        await cleanup.value
        let compiled = try XCTUnwrap(reopened.compilationMeasurements.first { $0.component == "network-cname" })
        XCTAssertFalse(compiled.cached)
        let ruleStore = try XCTUnwrap(WKContentRuleListStore.default())
        let identifiers = await ruleStore.availableIdentifiers()
        XCTAssertTrue(try XCTUnwrap(identifiers).contains(compiled.identifier))
        reopened.setMode(.balanced)
        await AdBlocker.removeCNAMECache(namespace: namespace).value
        try await ruleStore.removeContentRuleList(forIdentifier: "\(namespace).\(BundledPrivacyRules.digest(Data(core.utf8)))")
    }

    func testDeferredCNAMEFailurePreservesCorePreparation() async throws {
        let blocker = AdBlocker(rules: [.strict: "[{\"trigger\":{\"url-filter\":\"core.example\"},\"action\":{\"type\":\"block\"}}]"],
                                cacheNamespace: "oriv.tests.cname-failure", cnameFixture: { "invalid" })
        let controller = PrivacyCountingContentController()
        blocker.setMode(.strict)
        try await blocker.apply(to: controller, url: base, isPrivate: false)
        try await waitForCNAME { !blocker.isPreparingCNAME }
        XCTAssertNotNil(blocker.cnamePreparationError)
        XCTAssertNil(blocker.preparationError)
        XCTAssertTrue(blocker.applyIfPrepared(to: controller, url: base, isPrivate: false))
        XCTAssertEqual(controller.ruleAdds, 1)
        XCTAssertEqual(controller.ruleRemoves, 0)
        blocker.setMode(.balanced)
        XCTAssertNil(blocker.cnamePreparationError)
        blocker.setMode(.off)
        XCTAssertNil(blocker.cnamePreparationError)
    }
    func testShippedCookieListAndLayerIndependence() async throws {
        let settings = BrowserSettings(defaults: nil), blocker = AdBlocker()
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker, settings: settings)
        defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        settings.privacy.setCookieBannerMode(.off)
        try await load(tab)
        let visible = try await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#onetrust-banner-sdk')).display !== 'none'") as? Bool
        XCTAssertEqual(visible, true)
        let shippingBlocked = try await tab.webView.evaluateJavaScript("window.shippingTrackerBlocked === true && window.shippingTrackerLoaded !== true") as? Bool
        XCTAssertEqual(shippingBlocked, true, "Pinned EasyList /ads-front.min.js rule must block the actual fixture script")
        settings.privacy.setCookieBannerMode(.hide)
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
    func testBundledCosmeticsInMainAndEmbeddedDocuments() async throws {
        let settings = BrowserSettings(defaults: nil)
        let blocker = AdBlocker()
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker, settings: settings)
        defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        settings.privacy.setCookieBannerMode(.hide)
        for mode in [AdBlockingMode.balanced, .strict, .off] {
            blocker.setMode(mode)
            let frames = try await loadAdBlockFrames(tab, expecting: mode == .off ? ["shipped"] : [])
            let expectedAd = mode == .off ? "block" : "none"
            let main = try await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.ad-slot')).display") as? String
            XCTAssertEqual(main, expectedAd, "\(mode)")
            let mainID = try await tab.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#ad-slot')).display") as? String
            XCTAssertEqual(mainID, expectedAd, "\(mode) generic ID")
            let blank = try await tab.webView.evaluateJavaScript("blankDisplay()") as? String
            XCTAssertEqual(blank, expectedAd, "\(mode) script-written about:blank")
            // The bundled /side-ads- rule covers child-document requests.
            XCTAssertEqual(frames["shipped"] != nil, mode == .off, "\(mode) cross-origin ad document")
            for id in ["same", "cross"] {
                let frame = try XCTUnwrap(frames[id])
                XCTAssertEqual(frame["generic"], expectedAd, "\(mode) \(id)")
                XCTAssertEqual(frame["genericID"], expectedAd, "\(mode) \(id) generic ID")
                XCTAssertEqual(frame["similarID"], "block", "\(mode) \(id) similar ID")
                XCTAssertEqual(frame["ordinary"], "block", "\(mode) \(id)")
                XCTAssertEqual(frame["cookie"], "none", "\(mode) \(id)")
            }
        }
    }

    func testScopedCosmeticsAndThirdPartyFrameNetworkExceptions() async throws {
        // Mirrors converter output: if-domain and unless-domain refer to the
        // top URL. A network @@ is an ordered ignore-previous-rules action.
        let rules = #"""
        [
          {"trigger":{"url-filter":".*","if-domain":["127.0.0.1"]},"action":{"type":"css-display-none","selector":".scoped-ad"}},
          {"trigger":{"url-filter":".*","unless-domain":["127.0.0.1"]},"action":{"type":"css-display-none","selector":".excepted-ad"}},
          {"trigger":{"url-filter":"/adblock-frame-a","resource-type":["child-document"],"load-type":["third-party"]},"action":{"type":"block"}},
          {"trigger":{"url-filter":"/adblock-frame-allowed","resource-type":["child-document"]},"action":{"type":"ignore-previous-rules"}}
        ]
        """#
        let blocker = AdBlocker(rules: [.balanced: rules])
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker)
        defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        let filtered = try await loadAdBlockFrames(tab, expecting: ["allowed"])
        XCTAssertNil(filtered["blocked"])
        XCTAssertNotNil(filtered["allowed"])
        for id in ["same", "cross"] {
            XCTAssertEqual(filtered[id]?["scoped"], "none", id)
            XCTAssertEqual(filtered[id]?["excepted"], "block", id)
        }
        let otherHost = try await loadAdBlockFrames(tab, from: URL(string: "http://localhost:18768")!, expecting: ["allowed"])
        for id in ["same", "cross"] {
            XCTAssertEqual(otherHost[id]?["scoped"], "block", id)
            XCTAssertEqual(otherHost[id]?["excepted"], "none", id)
        }
        blocker.setMode(.off)
        let unfiltered = try await loadAdBlockFrames(tab, expecting: ["blocked", "allowed"])
        XCTAssertNotNil(unfiltered["blocked"])
        XCTAssertEqual(unfiltered["cross"]?["scoped"], "block")
    }

    private func loadAdBlockFrames(_ tab: BrowserTab, from origin: URL? = nil, expecting additionalFrames: [String]) async throws -> [String: [String: String]] {
        try hostFixture(tab)
        let url = (origin ?? base).appendingPathComponent("adblock-frames")
        try await waitForWebFixture(tab, at: url, timeout: 40) { tab.navigate(to: url) }
        XCTAssertNil(tab.errorMessage)
        XCTAssertEqual(tab.webView.url, url)
        let expectedFrames = ["same", "cross"] + additionalFrames
        var results: [String: [String: String]] = [:]
        // A finished top-level navigation can precede delivery of child-frame messages.
        try await waitForFixtureCondition("frame reports for \(expectedFrames.joined(separator: ", "))", timeout: 20) {
            let reports = try await tab.webView.evaluateJavaScript("window.frameResults") as? [String: [String: String]]
            results = try XCTUnwrap(reports)
            return expectedFrames.allSatisfy { results[$0] != nil }
        }
        return results
    }
    func testFixtureTrackerBlockingAndPrivateHistory() async throws {
        let rules = #"[{"trigger":{"url-filter":"/ad-banner\\.js"},"action":{"type":"block"}}]"#
        let blocker = AdBlocker(rules: [.balanced: rules, .strict: rules])
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker, settings: BrowserSettings(defaults: nil), externalPrivate: true)
        defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        try hostFixture(tab)
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
        XCTAssertEqual(prefs.preferredHTTPSNavigationPolicy, .errorOnFailure)
        request.url = URL(string: "https://public.example/")
        settings.privacy.apply(to: prefs, request: request, isPrivate: false)
        XCTAssertEqual(prefs.preferredHTTPSNavigationPolicy, .errorOnFailure, "HTTPS-origin navigations retain the policy for a later HTTP redirect")
        request.httpMethod = "POST"; settings.privacy.apply(to: prefs, request: request, isPrivate: false)
        XCTAssertEqual(prefs.preferredHTTPSNavigationPolicy, .keepAsRequested)
    }
    func testCleanCopyAndContinuity() throws {
        let dirty = URL(string: "https://example.test/page?utm_source=fixture&keep=%2f#anchor")!
        PrivacyPasteboard.copy(dirty)
        #if os(macOS)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), URLCleaner.clean(dirty).absoluteString)
        #else
        let cleaned = try copiedURL()
        XCTAssertEqual(cleaned, URLCleaner.clean(dirty))
        XCTAssertEqual(cleaned.absoluteString, URLCleaner.clean(dirty).absoluteString)
        #endif
        PrivacyPasteboard.copy(dirty, original: true)
        #if os(macOS)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), dirty.absoluteString)
        #else
        let original = try copiedURL()
        XCTAssertEqual(original, dirty)
        XCTAssertEqual(original.absoluteString,dirty.absoluteString)
        #endif
        XCTAssertEqual(ContinuityPage(url: dirty, title: "Fixture", profile: .personal, isPrivate: false)?.url, URLCleaner.clean(dirty))
        XCTAssertNil(ContinuityPage(url: dirty, title: "Fixture", profile: .personal, isPrivate: true))
        var replica = ContinuityReplica(deviceName: "Fixture device")
        let record = TabRecord(url: dirty)
        try replica.capture(profile: .personal, bookmarks: [], history: [], regularTabs: [record], preferences: [:])
        XCTAssertEqual(replica.tabs(for: BrowserProfile.personalID, device: replica.deviceID).first?.url, URLCleaner.clean(dirty))
        XCTAssertEqual(record.url, dirty, "Cleaning an outgoing tab must not mutate the local tab record")
    }
    #if os(iOS)
    private func copiedURL() throws -> URL {
        // Inspect the actual public.url payload. UIKit's URL convenience getter
        // and item-provider coercion can wait indefinitely in the Simulator.
        let value = try XCTUnwrap(UIPasteboard.general.value(forPasteboardType:"public.url"))
        if let url = value as? URL { return url }
        if let string = value as? String { return try XCTUnwrap(URL(string:string)) }
        let data = try XCTUnwrap(value as? Data)
        return try XCTUnwrap(URL(string:try XCTUnwrap(String(data:data,encoding:.utf8))))
    }
    #endif

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
        try hostFixture(tab)
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
    private func failHTTPUpgrade(_ tab:BrowserTab, url:URL, code:Int = NSURLErrorSecureConnectionFailed) {
        tab.webView(tab.webView,didFailProvisionalNavigation:nil,withError:NSError(
            domain:NSURLErrorDomain,code:code,userInfo:[NSURLErrorFailingURLErrorKey:url]))
    }
    func testDismissingHTTPPromptPreservesCurrentHistoryItem() async throws {
        let blocker = AdBlocker(); blocker.setMode(.off)
        let tab = BrowserTab(dataStore:.nonPersistent(),adBlocker:blocker,settings:BrowserSettings(defaults:nil))
        defer { tab.close() }
        try await load(tab)
        let current = tab.webView.backForwardList.currentItem
        let request = URLRequest(url:URL(string:"http://public.example/")!)
        tab.recordHTTPUpgrade(request,kind:.newNavigation)
        failHTTPUpgrade(tab,url:URL(string:"https://public.example/")!)
        XCTAssertEqual(tab.httpWarningURL,request.url)
        tab.cancelHTTPFallback()
        XCTAssertTrue(tab.webView.backForwardList.currentItem === current)
        XCTAssertEqual(tab.url,current?.url); XCTAssertNil(tab.httpWarningURL)
    }
    func testHTTPPromptRequiresFailedGETAndExactDestinationConsent() throws {
        let settings = BrowserSettings(defaults:nil)
        let tab = BrowserTab(isPrivate:true,dataStore:.nonPersistent(),settings:settings)
        defer { tab.close() }
        try hostFixture(tab)
        let original = URL(string:"http://public.example/path?keep=1")!
        let upgraded = URL(string:"https://public.example/path?keep=1")!
        let request = URLRequest(url:original)
        tab.recordHTTPUpgrade(request,kind:.newNavigation)
        XCTAssertNil(tab.httpWarningURL,"No consent UI before an actual failure")
        failHTTPUpgrade(tab,url:upgraded)
        XCTAssertEqual(tab.httpWarningURL,original)
        XCTAssertFalse(settings.privacy.isException(.httpsUpgrade,for:original,isPrivate:true))
        tab.continueToHTTP(URL(string:"http://different.example/")!)
        XCTAssertEqual(tab.httpWarningURL,original,"Stale or mismatched prompt cannot grant consent")
        tab.continueToHTTP(original)
        XCTAssertTrue(settings.privacy.isException(.httpsUpgrade,for:original,isPrivate:true))
        XCTAssertFalse(settings.privacy.isException(.httpsUpgrade,for:original,isPrivate:false))
        XCTAssertFalse(settings.privacy.isException(.httpsUpgrade,for:URL(string:"http://sub.public.example/")!,isPrivate:true))
        XCTAssertNil(tab.httpWarningURL)
    }
    func testHTTPPromptNeverBypassesCertificatesFormsOrUnrelatedFailures() {
        let tab = BrowserTab(dataStore:.nonPersistent(),settings:BrowserSettings(defaults:nil))
        defer { tab.close() }
        let original = URL(string:"http://public.example/")!, upgraded = URL(string:"https://public.example/")!
        for code in [NSURLErrorServerCertificateHasBadDate,NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasUnknownRoot,NSURLErrorServerCertificateNotYetValid,
                     NSURLErrorClientCertificateRejected,NSURLErrorClientCertificateRequired] {
            tab.recordHTTPUpgrade(URLRequest(url:original),kind:.newNavigation)
            failHTTPUpgrade(tab,url:upgraded,code:code)
            XCTAssertNil(tab.httpWarningURL)
        }
        for kind:PrivacyNavigationKind in [.newNavigation,.backForward,.reload] {
            var request = URLRequest(url:original)
            if kind == .newNavigation { request.httpMethod = "POST" }
            tab.recordHTTPUpgrade(request,kind:kind)
            failHTTPUpgrade(tab,url:upgraded)
            XCTAssertNil(tab.httpWarningURL)
        }
        var request = URLRequest(url:original); request.httpBody = Data("form".utf8)
        tab.recordHTTPUpgrade(request,kind:.newNavigation); failHTTPUpgrade(tab,url:upgraded)
        XCTAssertNil(tab.httpWarningURL)
        tab.recordHTTPUpgrade(URLRequest(url:original),kind:.newNavigation)
        failHTTPUpgrade(tab,url:URL(string:"https://different.example/")!)
        XCTAssertNil(tab.httpWarningURL)
        tab.recordHTTPUpgrade(URLRequest(url:upgraded),kind:.newNavigation)
        failHTTPUpgrade(tab,url:upgraded)
        XCTAssertNil(tab.httpWarningURL,"An explicitly requested HTTPS URL has no HTTP bypass")
    }
    func testExplicitHTTPSLinkCannotReuseAnUnfinishedHTTPUpgrade() async throws {
        let blocker = AdBlocker(); blocker.setMode(.off)
        let tab = BrowserTab(dataStore:.nonPersistent(),adBlocker:blocker,settings:BrowserSettings(defaults:nil))
        defer { tab.close() }
        try await load(tab)
        let original = URL(string:"http://public.example/unfinished-upgrade")!
        tab.recordHTTPUpgrade(URLRequest(url:original),kind:.newNavigation)
        // A second explicit HTTPS link replaces an unfinished HTTP attempt.
        // Use WebKit's actual navigation delegate rather than BrowserTab.navigate,
        // which independently invalidates a previous request.
        _ = try await tab.webView.evaluateJavaScript("let a=document.createElement('a');a.href='https://public.example/unfinished-upgrade';document.body.append(a);a.click();true")
        try await wait { tab.errorMessage != nil || tab.httpWarningURL != nil }
        XCTAssertNil(tab.httpWarningURL,"An explicit HTTPS link must not inherit a prior HTTP bypass prompt")
    }
    func testHTTPUpgradeConsentRejectsReplacedAndStaleNavigationObjects() throws {
        let tab = BrowserTab(dataStore:.nonPersistent(),settings:BrowserSettings(defaults:nil))
        defer { tab.close() }
        try hostFixture(tab)
        let original = URL(string:"http://public.example/unfinished-upgrade")!
        let upgraded = URL(string:"https://public.example/unfinished-upgrade")!
        let first = try XCTUnwrap(tab.webView.loadHTMLString("<p>First</p>",baseURL:nil))
        tab.recordHTTPUpgrade(URLRequest(url:original),kind:.newNavigation)
        tab.webView(tab.webView,didStartProvisionalNavigation:first)
        let replacement = try XCTUnwrap(tab.webView.loadHTMLString("<p>Replacement</p>",baseURL:nil))
        tab.webView(tab.webView,didStartProvisionalNavigation:replacement)
        let error = NSError(domain:NSURLErrorDomain,code:NSURLErrorCannotConnectToHost,
                            userInfo:[NSURLErrorFailingURLErrorKey:upgraded])
        tab.webView(tab.webView,didFailProvisionalNavigation:replacement,withError:error)
        XCTAssertNil(tab.httpWarningURL,"A new navigation, including a script navigation, must invalidate the old upgrade")
        tab.recordHTTPUpgrade(URLRequest(url:original),kind:.newNavigation)
        tab.webView(tab.webView,didStartProvisionalNavigation:replacement)
        tab.webView(tab.webView,didFailProvisionalNavigation:first,withError:error)
        XCTAssertNil(tab.httpWarningURL,"An old failure with the same URL must not authorize a newer attempt")
        tab.webView(tab.webView,didFailProvisionalNavigation:replacement,withError:error)
        XCTAssertEqual(tab.httpWarningURL,original,"The failed original navigation still offers exact-host consent")
    }
    func testLiveSiteSpotChecks() async throws {
        guard ProcessInfo.processInfo.environment["ORIV_PRIVACY_LIVE"] == "1" else { throw XCTSkip("Live public-site spot checks are opt-in; fixtures run without external traffic") }
        let settings = BrowserSettings(defaults: nil), blocker = AdBlocker()
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: blocker, settings: settings)
        defer { session.shutdown() }
        try await blocker.prepare()
        let tab = try XCTUnwrap(session.selectedTab)
        try hostFixture(tab)
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
            let detach = try mountFixtureController(preview)
            defer { detach() }
            XCTAssertNil(preview.preview)
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
