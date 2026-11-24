import AppKit
import BrowserCore
@testable import BrowserEngine
import WebKit
import XCTest
import SwiftUI
@testable import PersonalBrowser

@MainActor final class ProfileIntegrationTests: BackgroundUITestCase {
    func testSwitchingSeparatesBookmarksHistoryPrivateStoresAndOpenForms() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let personal = profiles.controller
        let saved = Bookmark(title: "Personal only", url: URL(string: "https://personal.test")!)
        personal.session.importBookmarks([saved])
        let regular = try XCTUnwrap(personal.session.selectedTab)
        regular.webView.loadHTMLString("<html><body><input id='draft' value='kept'><p>Personal document</p></body></html>", baseURL: URL(string: "https://profile.test"))
        for _ in 0..<200 { if !regular.webView.isLoading { break }; try await Task.sleep(for: .milliseconds(10)) }
        let privateTab = personal.session.addTab(isPrivate: true)
        let privateStore = privateTab.webView.configuration.websiteDataStore
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        try profiles.select(work.id)
        let workController = profiles.controller
        XCTAssertFalse(personal.session.isProfileActive)
        XCTAssertTrue(workController.session.isProfileActive)
        XCTAssertTrue(workController.session.bookmarks.isEmpty)
        XCTAssertTrue(workController.session.history.isEmpty)
        let workPrivate = workController.session.addTab(isPrivate: true)
        XCTAssertFalse(privateStore === workPrivate.webView.configuration.websiteDataStore)
        try profiles.select(BrowserProfile.personalID)
        XCTAssertTrue(profiles.controller === personal)
        XCTAssertEqual(personal.session.bookmarks, [saved])
        let retainedDraft = try await regular.webView.evaluateJavaScript("document.querySelector('#draft').value") as? String
        XCTAssertEqual(retainedDraft, "kept")
        XCTAssertTrue(regular.isProfileActive)
        XCTAssertFalse(workPrivate.isProfileActive)
    }
    func testProfilePersistenceMigrationAndRecoverableArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyTab = TabRecord(title: "Legacy", url: URL(string: "https://legacy.test"))
        try SessionFileStore(fileURL: root.appendingPathComponent("session.json")).save(BrowserSnapshot(tabs: [legacyTab], selectedTabID: legacyTab.id))
        let profiles = BrowserProfiles(rootDirectory: root, testing: true)
        XCTAssertEqual(profiles.controller.session.selectedTab?.id, legacyTab.id)
        let work = try profiles.create(name: "Work", color: .fern, symbol: .work)
        try profiles.select(work.id)
        let item = Bookmark(title: "Work saved link", url: URL(string: "https://work.test/saved")!)
        profiles.controller.session.importBookmarks([item])
        profiles.controller.session.addTab(url: URL(string: "https://work.test"), load: false)
        profiles.saveAll(); profiles.shutdown()
        let reopened = BrowserProfiles(rootDirectory: root, testing: true)
        defer { reopened.shutdown() }
        XCTAssertEqual(reopened.active.id, work.id)
        XCTAssertEqual(reopened.controller.session.bookmarks.first?.id, item.id)
        XCTAssertEqual(reopened.controller.session.selectedTab?.url?.host, "work.test")
        try reopened.select(BrowserProfile.personalID)
        try reopened.archive(work.id)
        XCTAssertThrowsError(try reopened.select(work.id))
        try reopened.restore(work.id); try reopened.select(work.id)
        XCTAssertEqual(reopened.controller.session.bookmarks.first?.id, item.id)
        XCTAssertEqual(reopened.controller.session.selectedTab?.url?.host, "work.test")
        XCTAssertThrowsError(try reopened.archive(BrowserProfile.personalID))
        XCTAssertThrowsError(try reopened.create(name: " work ", color: .ocean, symbol: .work))
    }
    func testSelectionSaveOrdersOutgoingSessionAndProfileMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = BrowserProfiles(rootDirectory: root, testing: true)
        defer { profiles.shutdown() }
        let work = try profiles.create(name: "Work", color: .fern, symbol: .work)
        let personal = profiles.controller
        let tab = personal.session.addTab(url: URL(string: "https://retained.test"), load: false)
        try profiles.select(work.id, deferSelectionSave: true)
        let store = ProfileRegistryStore(fileURL: root.appendingPathComponent("profiles.json"))
        try await eventually("deferred active ID reaches disk") {
            (try? store.load().registry.activeID) == work.id
        }
        let savedSession = try XCTUnwrap(SessionFileStore(fileURL: root.appendingPathComponent("session.json")).load().snapshot)
        XCTAssertTrue(savedSession.tabs.contains { $0.id == tab.id })

        try profiles.select(BrowserProfile.personalID, deferSelectionSave: true)
        try profiles.update(work.id, name: "Renamed", color: .ocean, symbol: .work)
        try await Task.sleep(for: .milliseconds(600))
        let latest = try store.load().registry
        XCTAssertEqual(latest.activeID, BrowserProfile.personalID)
        XCTAssertEqual(latest.profiles.first { $0.id == work.id }?.name, "Renamed")
    }

    func testWebsiteCookiesAndDataClearingStayInTheirNamedPersistentStore() async throws {
        let a = UUID(), b = UUID()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "profiles.example.test", .path: "/", .name: "login", .value: "synthetic-A",
            .expires: Date.now.addingTimeInterval(3600)
        ]))
        do {
            let first = WKWebsiteDataStore(forIdentifier: a), second = WKWebsiteDataStore(forIdentifier: b)
            XCTAssertEqual(first.identifier, a); XCTAssertEqual(second.identifier, b)
            XCTAssertTrue(first.isPersistent && second.isPersistent)
            await first.httpCookieStore.setCookie(cookie)
            let isolated = await second.httpCookieStore.allCookies()
            XCTAssertTrue(isolated.isEmpty)
            let reopened = WKWebsiteDataStore(forIdentifier: a)
            let retained = await reopened.httpCookieStore.allCookies()
            XCTAssertEqual(retained.first?.value, "synthetic-A")
            await second.httpCookieStore.setCookie(cookie)
            let beforeClearing = await second.httpCookieStore.allCookies()
            XCTAssertEqual(beforeClearing.count, 1)
            await WebsiteDataManager(store: second).clear(since: .distantPast, cacheOnly: false)
            let cleared = await second.httpCookieStore.allCookies()
            XCTAssertTrue(cleared.isEmpty)
            let untouched = await first.httpCookieStore.allCookies()
            XCTAssertEqual(untouched.map(\.value), ["synthetic-A"])
        }
        // No WebViews use these stores, and the test's store references have
        // gone out of scope before removing the named directories.
        for id in [a, b] {
            do { try await SessionFactory.removeNamedWebsiteDataStore(id) }
            catch { XCTFail("Could not remove test website data store \(id): \(error)") }
        }
        let remaining = await WKWebsiteDataStore.allDataStoreIdentifiers
        XCTAssertFalse(remaining.contains(a) || remaining.contains(b))
    }
    func testPreferencesAndPermissionsDoNotInheritAnotherProfile() throws {
        let bundle = "OrivProfileTest-\(UUID())"
        let a = BrowserProfile(name: "A"), b = BrowserProfile(name: "B")
        let an = try XCTUnwrap(a.defaultsName(bundleID: bundle)), bn = try XCTUnwrap(b.defaultsName(bundleID: bundle))
        let ad = try XCTUnwrap(UserDefaults(suiteName: an)), bd = try XCTUnwrap(UserDefaults(suiteName: bn))
        defer { ad.removePersistentDomain(forName: an); bd.removePersistentDomain(forName: bn) }
        let first = BrowserSettings(defaults: ad), second = BrowserSettings(defaults: bd)
        first.searchEngine = .google; first.defaultZoom = 1.5
        var rule = SiteRule(); rule.camera = .block
        first.setRule(rule, for: URL(string: "https://profile.test")!, isPrivate: false)
        XCTAssertEqual(second.searchEngine, .duckDuckGo); XCTAssertEqual(second.defaultZoom, 1)
        XCTAssertTrue(second.rules.isEmpty)
        XCTAssertEqual(BrowserSettings(defaults: ad).searchEngine, .google)
        XCTAssertEqual(BrowserSettings(defaults: ad).defaultZoom, 1.5)
    }

    func testDeleteProfileRemovesLocalDataAndKeepsPersonal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = BrowserProfiles(rootDirectory: root, testing: true)
        defer { profiles.shutdown() }
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        try profiles.select(work.id)
        let tab = try XCTUnwrap(profiles.controller.session.selectedTab)
        _ = tab.webView
        profiles.controller.session.importBookmarks([Bookmark(title: "Work", url: URL(string: "https://work.example")!)])
        try profiles.select(BrowserProfile.personalID)
        let directory = work.directory(in: root)
        let icons = directory.appendingPathComponent("Favicons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: icons.appendingPathComponent("cached-icon"))
        try await profiles.delete(work)
        XCTAssertFalse(tab.isInstantiated)
        XCTAssertNil(profiles.loadedController(work.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(profiles.continuity.state.isProfileDeleted(work.id))
        let registry = try ProfileRegistryStore(fileURL: root.appendingPathComponent("profiles.json")).load().registry
        XCTAssertEqual(registry.profiles.map(\.id), [BrowserProfile.personalID])
        do { try await profiles.delete(.personal); XCTFail("Deleted Personal") }
        catch ProfileError.protectedProfile {}
    }

    func testDeleteRemovesNamedWebKitStoreAndDefaults() async throws {
        let profile = BrowserProfile(name: "Disposable")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundleID = "local.oriv.profile-test"
        let suite = try XCTUnwrap(profile.defaultsName(bundleID: bundleID))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "profiles.example.test", .path: "/", .name: "login", .value: "synthetic"]))
        do {
            let store = WKWebsiteDataStore(forIdentifier: profile.id)
            await store.httpCookieStore.setCookie(cookie)
        }
        defaults.set("fixture", forKey: "example")
        try await SessionFactory.removeProfileData(profile, rootOverride: root, bundleID: bundleID, testing: false)
        try await SessionFactory.removeProfileData(profile, rootOverride: root, bundleID: bundleID, testing: false)
        let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
        XCTAssertFalse(identifiers.contains(profile.id))
        XCTAssertNil(defaults.object(forKey: "example"))
    }

    func testPrivateContextsCopyPreferencesWithoutSiteState() throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let source = profiles.controller.session
        let url = URL(string: "https://fixture.example")!
        source.adBlocker.setMode(.strict)
        source.adBlocker.setException(true, for: url, isPrivate: false)
        source.settings.searchEngine = .brave
        source.settings.privacy.setEnabled(true, .cookieBanners)
        source.importBookmarks([Bookmark(title: "Fixture", url: url)])
        profiles.controller.appearance = .light
        let id = profiles.createPrivateWindow()
        let context = try XCTUnwrap(profiles.privateWindows[id])
        profiles.handleIncomingURL(url)
        let external = try XCTUnwrap(profiles.externalPrivate)
        source.settings.searchEngine = .google
        for copy in [context, external] {
            XCTAssertEqual(copy.session.settings.searchEngine, .brave)
            XCTAssertEqual(copy.session.adBlocker.mode, .strict)
            XCTAssertTrue(copy.session.adBlocker.cookieBannersEnabled)
            XCTAssertTrue(copy.session.adBlocker.regularExceptions.isEmpty)
            XCTAssertTrue(copy.session.bookmarks.isEmpty)
            XCTAssertTrue(copy.session.history.isEmpty)
            XCTAssertFalse(copy.session.selectedTab!.webView.configuration.websiteDataStore.isPersistent)
            XCTAssertEqual(copy.appearance, .light)
        }
    }

    func testBasicAuthenticationChallengesAgainInAnotherProfile() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        let url = URL(string: "http://127.0.0.1:8768/basic-auth")!
        for profile in [BrowserProfile.personal, work] {
            try profiles.select(profile.id)
            let tab = try XCTUnwrap(profiles.controller.session.selectedTab)
            _ = tab.webView
            var challenges = 0
            tab.onAuthentication = { challenge, completion in
                XCTAssertEqual(challenge.protectionSpace.authenticationMethod, NSURLAuthenticationMethodHTTPBasic)
                challenges += 1
                completion(.useCredential, URLCredential(user: "test", password: "pass", persistence: .forSession))
            }
            tab.navigate(to: url)
            try await waitForFixtureCondition("authenticated fixture", timeout: 20) { tab.title == "Authenticated fixture" && !tab.isLoading }
            XCTAssertEqual(challenges, 1)
        }
    }

    func testSwitchSuspendsMediaUntilReturningToProfile() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let tab = profiles.controller.session.addTab(configuration: config, load: false)
        let view = tab.webView
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        BackgroundUIMode.show(window, key: false)
        defer { window.contentView = nil; window.close() }
        tab.navigate(to: URL(string: "http://127.0.0.1:8768/one")!)
        try await waitForFixtureCondition("profile media fixture page", timeout: 20) { tab.title == "Browser foundation" && !tab.isLoading }
        _ = try await view.evaluateJavaScript("""
            window.fixtureAudio = new Audio('/media-files/tone.wav');
            fixtureAudio.loop = true;
            fixtureAudio.volume = 0;
            document.body.append(fixtureAudio);
            fixtureAudio.play().catch(error => window.fixtureMediaError = String(error));
            true;
            """)
        func playback() async -> WKMediaPlaybackState {
            await withCheckedContinuation { reply in view.requestMediaPlaybackState { reply.resume(returning: $0) } }
        }
        try await waitForFixtureCondition("media playing in Personal", timeout: 15) { await playback() == .playing }
        try profiles.select(work.id)
        try await waitForFixtureCondition("media suspended in inactive Personal", timeout: 15) { await playback() == .suspended }
        try profiles.select(BrowserProfile.personalID)
        try await waitForFixtureCondition("media resumes on returning to Personal", timeout: 15) { await playback() == .playing }
    }

    func testInactiveMacSelectionCanBeReclaimedAfterFiveIdleMinutes() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let personal = profiles.controller
        let tab = try XCTUnwrap(personal.session.selectedTab)
        let view = tab.webView
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        tab.navigate(to: URL(string: "http://127.0.0.1:8768/one")!)
        try await waitForFixtureCondition("discardable profile fixture", timeout: 20) { tab.title == "Browser foundation" && !tab.isLoading }
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        try profiles.select(work.id)
        var now = 1000.0
        tab.recoveryClock = { now }
        tab.lastSelectedTime = now - 299
        let before = await personal.session.reclaimBackgroundTabs()
        XCTAssertEqual(before, 0)
        XCTAssertTrue(tab.isInstantiated)
        now += 2
        let after = await personal.session.reclaimBackgroundTabs()
        XCTAssertEqual(after, 1)
        XCTAssertFalse(tab.isInstantiated)
        XCTAssertEqual(personal.session.selectedTabID, tab.id)
    }

    func testDeleteProfileConfirmationCapture() throws {
        let renderer = ImageRenderer(content: DeleteProfileConfirmation(profile: BrowserProfile(name: "Work"), confirm: {})
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(width: 420, height: nil)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "mac-delete-profile-confirmation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNamedProfileDoesNotReadPersonalDefaults() throws {
        let suite = "OrivProfileTest-\(UUID())"
        let key = "OrivTestPersonalOnly-\(UUID())"
        let named = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removeObject(forKey: key); named.removePersistentDomain(forName: suite) }
        UserDefaults.standard.set("personal", forKey: key)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "personal")
        XCTAssertNil(named.object(forKey: key))
    }

    func testSwitchIsBlockedDuringPageExportAndDoesNotChangeCurrentProfile() throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        let original = profiles.controller
        original.isExportingPage = true
        XCTAssertThrowsError(try profiles.select(work.id))
        XCTAssertTrue(profiles.controller === original)
        XCTAssertEqual(profiles.active.id, BrowserProfile.personalID)
        original.isExportingPage = false
        try profiles.select(work.id)
        XCTAssertEqual(profiles.active.id, work.id)
    }
    func testExternalLinksReuseProfilelessPrivateContextAndMoveCurrentURL() async throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        let personal = profiles.controller
        let originalPersonalTabs = personal.session.tabs.map(\.id)
        let work = try profiles.create(name: "Work", color: .ocean, symbol: .work)
        try profiles.select(work.id)
        let workController = profiles.controller
        let bookmark = Bookmark(title: "Work only", url: URL(string: "https://example.test/saved")!)
        workController.session.importBookmarks([bookmark])
        var opened = 0, closed = 0, presentationRequests: [Int] = []
        XCTAssertEqual(profiles.externalPresentationRequest, 0)
        profiles.showExternalWindow = { opened += 1; presentationRequests.append(profiles.externalPresentationRequest) }
        profiles.closeExternalWindow = { closed += 1 }
        profiles.handleIncomingURL(URL(string: "https://example.test/original")!, sourceName: "Test App")
        let context = try XCTUnwrap(profiles.externalPrivate)
        XCTAssertNil(context.profile)
        XCTAssertTrue(context.session.tabs.allSatisfy(\.isPrivate))
        XCTAssertEqual(profiles.externalMoveProfileID, work.id)
        XCTAssertTrue(context.session.bookmarks.isEmpty); XCTAssertTrue(context.session.history.isEmpty)
        let store = try XCTUnwrap(context.session.selectedTab).webView.configuration.websiteDataStore
        XCTAssertFalse(store.isPersistent)
        profiles.handleIncomingURL(URL(string: "https://example.test/second")!)
        XCTAssertTrue(profiles.externalPrivate === context); XCTAssertEqual(context.session.tabs.count, 2); XCTAssertEqual(opened, 2)
        XCTAssertEqual(presentationRequests, [1, 2], "Both first and subsequent URLs must request presentation before opening the scene")
        XCTAssertFalse(context.session.selectedTab?.webView.configuration.websiteDataStore === store)
        let current = URL(string: "https://example.test/after-navigation")!
        context.session.setProfileActive(false)
        context.session.selectedTab?.navigate(to: current)
        profiles.externalMoveProfileID = BrowserProfile.personalID
        let movedPrivateID = try XCTUnwrap(context.session.selectedTabID)
        try profiles.moveExternalTab()
        XCTAssertFalse(context.session.tabs.contains { $0.id == movedPrivateID })
        XCTAssertEqual(personal.session.tabs.count, originalPersonalTabs.count + 1)
        XCTAssertTrue(originalPersonalTabs.allSatisfy { id in personal.session.tabs.contains { $0.id == id } })
        XCTAssertTrue(personal.session.tabs.allSatisfy { !$0.isPrivate })
        XCTAssertTrue(profiles.controller === personal); XCTAssertEqual(personal.session.selectedTab?.url, current)
        XCTAssertFalse(personal.session.selectedTab?.isPrivate ?? true)
        XCTAssertEqual(context.session.tabs.count, 1)
        profiles.externalMoveProfileID = work.id
        try profiles.moveExternalTab()
        XCTAssertNil(profiles.externalPrivate); XCTAssertEqual(closed, 1)
        XCTAssertTrue(context.session.tabs.isEmpty); XCTAssertNil(context.session.selectedTabID)
        XCTAssertEqual(workController.session.bookmarks, [bookmark]); XCTAssertTrue(workController.session.history.isEmpty)
    }
    func testExternalSettingOffPreservesRegularRouteAndBadSchemesNeverMove() throws {
        let profiles = BrowserProfiles(testing: true)
        defer { profiles.shutdown() }
        profiles.openExternalLinksPrivately = false
        let url = URL(string: "https://example.test/regular")!
        profiles.handleIncomingURL(url)
        XCTAssertEqual(profiles.externalPresentationRequest, 0)
        XCTAssertNil(profiles.externalPrivate); XCTAssertEqual(profiles.controller.session.selectedTab?.url, url)
        XCTAssertFalse(profiles.controller.session.selectedTab?.isPrivate ?? true)
        profiles.openExternalLinksPrivately = true
        profiles.handleIncomingURL(URL(string: "file:///tmp/synthetic")!)
        XCTAssertEqual(profiles.externalPresentationRequest, 0)
        XCTAssertNil(profiles.externalPrivate)
        profiles.handleIncomingURL(URL(string: "https://example.test/private")!)
        let context = try XCTUnwrap(profiles.externalPrivate)
        context.session.addTab(load: false)
        let count = profiles.controller.session.tabs.count
        try profiles.moveExternalTab()
        XCTAssertEqual(profiles.controller.session.tabs.count, count)
        XCTAssertNotNil(profiles.externalPrivate)
        XCTAssertTrue(context.session.snapshot().tabs.isEmpty)
    }

}
