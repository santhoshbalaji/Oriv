import BrowserCore
import BrowserEngine
import AppKit
import WebKit
import XCTest
import SwiftUI
@testable import PersonalBrowser

@MainActor
final class BrowserIntegrationTests: XCTestCase {
    let base = URL(string: "http://127.0.0.1:8768")!

    func testBrowserIdentityReachesRequestsAndSubframes() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        tab.navigate(to: base.appendingPathComponent("one"))
        try await waitUntil("Identity fixture loads") { tab.title == "Browser foundation" && !tab.isLoading }
        let result = try await tab.webView.callAsyncJavaScript("""
            const response = await fetch('/identity').then(r => r.json());
            const frame = document.createElement('iframe'); frame.src = '/two';
            const loaded = new Promise(resolve => frame.onload = resolve);
            document.body.append(frame); await loaded;
            return [navigator.userAgent, response.userAgent, frame.contentWindow.navigator.userAgent];
            """, arguments: [:], in: nil, contentWorld: .page) as? [String]
        let agents = try XCTUnwrap(result)
        XCTAssertEqual(agents.count, 3)
        for agent in agents {
            XCTAssertTrue(agent.contains("Version/\(BrowserRuntime.safariCompatibilityVersion) Safari/605.1.15"), agent)
            XCTAssertTrue(agent.contains("AppleWebKit/"))
            XCTAssertFalse(agent.contains("Chrome/"))
        }
        XCTAssertEqual(Set(agents).count, 1)
    }

    func testContainerFullscreenKeepsViewportAndRestoresSwiftUILayout() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        let window = mediaWindow(for: tab.webView)
        defer { window.close() }
        // Exercise the actual SwiftUI representable, with a sidebar-sized sibling.
        window.contentView = NSHostingView(rootView: HStack(spacing: 0) {
            Color.gray.frame(width: 200)
            WebPageView(tab: tab)
        })
        tab.navigate(to: base.appendingPathComponent("fullscreen"))
        try await waitUntil("Container fixture loads") { tab.title == "Fullscreen container regression" && !tab.isLoading }
        try await requireVisibleMediaWindow(window, view: tab.webView)
        XCTAssertFalse(window.styleMask.contains(.fullScreen), "Start in a normal window")
        let original = tab.webView.bounds.size
        XCTAssertGreaterThan(original.width, 700)
        for _ in 0..<2 {
            _ = try await tab.webView.evaluateJavaScript("document.querySelector('#player').requestFullscreen(); true")
            try await waitUntil("WebKit enters fullscreen") { tab.webView.fullscreenState == .inFullscreen }
            try await waitForScript("innerWidth > 700 && innerHeight > 500 && Math.abs(player.getBoundingClientRect().width - innerWidth) < 2 && Math.abs(player.getBoundingClientRect().height - innerHeight) < 2", in: tab.webView)
            let screen = try XCTUnwrap(tab.webView.window?.screen)
            XCTAssertEqual(tab.webView.bounds.width, screen.frame.width, accuracy: 2)
            XCTAssertEqual(tab.webView.bounds.height, screen.frame.height, accuracy: 2)
            _ = try await tab.webView.evaluateJavaScript("document.exitFullscreen(); true")
            try await waitUntil("WebKit exits fullscreen") { tab.webView.fullscreenState == .notInFullscreen }
            try await waitUntil("Original layout restored") {
                abs(tab.webView.bounds.width - original.width) < 2 && abs(tab.webView.bounds.height - original.height) < 2
            }
            XCTAssertFalse(window.styleMask.contains(.fullScreen), "Restore the normal window")
        }
    }

    func testStartPageSuggestionsRespectPrivateBrowsingBoundary() {
        let controller = BrowserController()
        let regular = controller.session.addTab(url: URL(string: "https://example.com/research")!, load: false)
        controller.session.toggleBookmark()
        let privateTab = controller.session.addTab(url: URL(string: "https://example.com/private")!, isPrivate: true, load: false)
        XCTAssertEqual(controller.suggestions(for: "example.com", isPrivate: false).map(\.url), [regular.url!])
        XCTAssertEqual(controller.suggestions(for: "example.com", isPrivate: true).map(\.url), [privateTab.url!])
        XCTAssertEqual(controller.suggestions(for: "research", isPrivate: false).first?.tabID, regular.id)
        XCTAssertTrue(controller.suggestions(for: "research", isPrivate: true).isEmpty)
        controller.session.tabs.forEach { $0.close() }
    }

    private func waitUntil(_ description: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), description)
    }

    private func waitForScript(_ expression: String, in view: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if (try? await view.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let state = try? await view.evaluateJavaScript("JSON.stringify(window.mediaState?.())")
        throw NSError(domain: "MediaFixture", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Timed out waiting for \(expression). State: \(String(describing: state))"])
    }

    // WebKit suppresses video rendering in detached/hidden documents. Exercise the
    // production configuration in a visible window instead of relaxing that policy.
    private func mediaWindow(for view: WKWebView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 800),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Personal Browser media verification"
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        window.contentView = view
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return window
    }

    private func requireVisibleMediaWindow(_ window: NSWindow, view: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !window.occlusionState.contains(.visible) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        // An occluded test desktop cannot certify rendered video. Skip explicitly
        // rather than disabling WebKit visibility/power protections to make it pass.
        try XCTSkipUnless(window.isVisible && window.occlusionState.contains(.visible),
                          "Video rendering requires an unoccluded test window. Window visible: \(window.isVisible), occlusion: \(window.occlusionState.rawValue), app active: \(NSApp.isActive), app hidden: \(NSApp.isHidden). An unlocked desktop alone is insufficient; activate the test app on the current Space.")
        try await waitForScript("document.visibilityState === 'visible'", in: view)
    }

    func testMediaMetadataAndCaptions() async throws {
        for query in ["?autoplay=muted", "?codec=hevc&autoplay=muted"] {
            let tab = BrowserTab(dataStore: .nonPersistent())
            defer { tab.close() }
            let window = mediaWindow(for: tab.webView)
            defer { window.close() }
            tab.navigate(to: URL(string: "http://127.0.0.1:8768/media\(query)")!)
            try await waitUntil("Media metadata fixture loads") { tab.title == "Media compatibility check" && !tab.isLoading }
            try await waitForScript("video.duration === 12 && video.videoWidth === 640 && video.videoHeight === 360 && !video.error && video.textTracks[0]?.cues?.length === 2", in: tab.webView)
            let fullscreen = try await tab.webView.evaluateJavaScript("document.fullscreenEnabled") as? Bool
            XCTAssertEqual(fullscreen, true)
        }
    }

    func testMutedVideoPlaybackSeekingCaptionsAndTabPreservation() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        defer { session.tabs.forEach { $0.close() } }
        let tab = try XCTUnwrap(session.selectedTab)
        let window = mediaWindow(for: tab.webView)
        defer { window.close() }
        tab.navigate(to: URL(string: "http://127.0.0.1:8768/media?autoplay=muted")!)
        try await waitUntil("Media fixture loads") { tab.title == "Media compatibility check" && !tab.isLoading }
        let view = tab.webView
        try await requireVisibleMediaWindow(window, view: view)
        _ = try await view.evaluateJavaScript("video.play(); true")
        try await waitForScript("window.mediaState?.().time > 0.2 && !video.paused && video.videoWidth > 0 && window.mediaState().presentedFrames > 0", in: view)
        let fullscreen = try await view.evaluateJavaScript("document.fullscreenEnabled") as? Bool
        XCTAssertEqual(fullscreen, true)
        try await waitForScript("video.textTracks[0]?.cues?.length === 2", in: view)
        _ = try await view.evaluateJavaScript("video.pause(); video.currentTime = 5; video.playbackRate = 2")
        try await waitForScript("!video.seeking && video.currentTime >= 4.9 && video.currentTime <= 5.2", in: view)
        session.addTab()
        window.contentView = session.selectedTab?.webView
        session.selectTab(tab.id)
        window.contentView = view
        XCTAssertTrue(tab.webView === view, "Switching tabs must preserve the media element and decoder state")
        let playbackRate = try await view.evaluateJavaScript("video.playbackRate") as? Double
        XCTAssertEqual(playbackRate, 2)
        _ = try await view.evaluateJavaScript("video.play(); true")
        try await waitForScript("video.currentTime > 5.4 && !video.paused", in: view)
        let capabilities = try await view.callAsyncJavaScript("return await window.probeCapabilities()", arguments: [:], in: nil, contentWorld: .page)
        let attachment = XCTAttachment(string: String(describing: capabilities))
        attachment.name = "Runtime media capabilities (reported, not service certification)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAudibleAutoplayRequiresUserGesture() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        let window = mediaWindow(for: tab.webView)
        defer { window.close() }
        tab.navigate(to: URL(string: "http://127.0.0.1:8768/media?autoplay=audible")!)
        try await waitUntil("Audible autoplay fixture loads") { tab.title == "Media compatibility check" && !tab.isLoading }
        try await waitForScript("window.autoplayResult === 'NotAllowedError' && video.paused", in: tab.webView)
    }

    func testHEVCPlaybackOnThisRuntime() async throws {
        let tab = BrowserTab(dataStore: .nonPersistent())
        defer { tab.close() }
        let window = mediaWindow(for: tab.webView)
        defer { window.close() }
        tab.navigate(to: URL(string: "http://127.0.0.1:8768/media?codec=hevc&autoplay=muted")!)
        try await waitUntil("HEVC fixture loads") { tab.title == "Media compatibility check" && !tab.isLoading }
        try await requireVisibleMediaWindow(window, view: tab.webView)
        _ = try await tab.webView.evaluateJavaScript("video.play(); true")
        try await waitForScript("video.currentTime > 0.2 && video.videoWidth === 640 && !video.paused && !video.error && window.mediaState().presentedFrames > 0", in: tab.webView)
    }

    func testNavigationHistoryAndDOMPreservation() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let tab = try XCTUnwrap(session.selectedTab)
        tab.navigate(to: base.appendingPathComponent("one"))
        try await waitUntil("Fixture loads through WebKit") { tab.title == "Browser foundation" && !tab.isLoading }
        XCTAssertNil(tab.errorMessage)
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('draft').value = 'Keep this draft'")
        session.addTab(url: base.appendingPathComponent("two"))
        try await waitUntil("Second tab loads") { session.selectedTab?.title == "Second page" }
        session.selectTab(tab.id)
        let draft = try await tab.webView.evaluateJavaScript("document.getElementById('draft').value") as? String
        XCTAssertEqual(draft, "Keep this draft")
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('next').click()")
        try await waitUntil("Link navigation succeeds") { tab.title == "Second page" && tab.canGoBack }
        tab.goBack()
        try await waitUntil("Back navigation restores the page") { tab.title == "Browser foundation" && tab.canGoForward }
        XCTAssertTrue(session.history.contains { $0.url.path == "/one" })
        XCTAssertTrue(session.history.contains { $0.url.path == "/two" })
        session.tabs.forEach { $0.close() }
    }

    func testPrivateTabsNeverEnterSnapshotOrHistoryAndDoNotShareCookies() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let regular = try XCTUnwrap(session.selectedTab)
        regular.navigate(to: base.appendingPathComponent("one"))
        try await waitUntil("Regular tab loads") { regular.title == "Browser foundation" }
        _ = try await regular.webView.evaluateJavaScript("document.cookie='regular_session=yes; path=/'")
        let privateTab = session.addTab(url: base.appendingPathComponent("two"), isPrivate: true)
        try await waitUntil("Private tab loads") { privateTab.title == "Second page" && !privateTab.isLoading }
        let cookies = try await privateTab.webView.evaluateJavaScript("document.cookie") as? String
        XCTAssertFalse(cookies?.contains("regular_session") ?? true)
        session.toggleBookmark()
        XCTAssertTrue(session.bookmarks.isEmpty)
        XCTAssertFalse(session.history.contains { $0.url.path == "/two" })
        XCTAssertFalse(session.snapshot().tabs.contains { $0.id == privateTab.id })
        XCTAssertEqual(session.snapshot().selectedTabID, regular.id)
        session.closeTab(privateTab.id)
        XCTAssertFalse(session.canReopenTab)
        session.tabs.forEach { $0.close() }
    }

    func testRestoredTabsAreLazyAndReopenKeepsURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionFileStore(fileURL: directory.appendingPathComponent("session.json"))
        let a = TabRecord(title: "First", url: base.appendingPathComponent("one"))
        let b = TabRecord(title: "Second", url: base.appendingPathComponent("two"))
        try store.save(BrowserSnapshot(tabs: [a, b], selectedTabID: b.id))
        let session = BrowserSession(store: store, dataStore: .nonPersistent())
        XCTAssertEqual(session.selectedTabID, b.id)
        XCTAssertFalse(session.tabs.contains(where: \.isInstantiated))
        session.activateSelectedTab()
        XCTAssertFalse(session.tabs[0].isInstantiated)
        XCTAssertTrue(session.tabs[1].isInstantiated)
        session.closeTab(b.id)
        session.reopenClosedTab()
        XCTAssertEqual(session.selectedTab?.url, b.url)
        XCTAssertNotEqual(session.selectedTabID, b.id)
        session.tabs.forEach { $0.close() }
    }

    func testTargetBlankCreatesTabUsingOriginalConfiguration() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        var delegates: [MacWebUIDelegate] = []
        session.configureWebView = { view, tab in
            let delegate = MacWebUIDelegate(session: session, tab: tab)
            delegates.append(delegate)
            view.uiDelegate = delegate
        }
        let tab = try XCTUnwrap(session.selectedTab)
        tab.navigate(to: base.appendingPathComponent("one"))
        try await waitUntil("Fixture loads") { tab.title == "Browser foundation" }
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('popup').click()")
        try await waitUntil("Popup becomes a browser tab") { session.tabs.count == 2 && session.selectedTab?.title == "Second page" }
        XCTAssertTrue(session.selectedTab?.webView.configuration.websiteDataStore === tab.webView.configuration.websiteDataStore)
        session.tabs.forEach { $0.close() }
        session.configureWebView = nil
        _ = delegates
    }

    func testClearingHistoryRemovesRecoverableHistoryBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionFileStore(fileURL: directory.appendingPathComponent("session.json"))
        try store.save(BrowserSnapshot(history: [HistoryEntry(title: "Private to me", url: base)]))
        let session = BrowserSession(store: store, dataStore: .nonPersistent())
        session.saveNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupURL.path))
        session.clearHistory()
        XCTAssertTrue(try XCTUnwrap(store.load().snapshot).history.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
    }

    func testLocalDocumentDoesNotKeepPreviousAddressOrEnterSavedSession() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let tab = try XCTUnwrap(session.selectedTab)
        tab.navigate(to: base.appendingPathComponent("one"))
        try await waitUntil("Fixture loads") { tab.title == "Browser foundation" }
        tab.webView.loadHTMLString("<title>Generated content</title><p>Local document</p>", baseURL: nil)
        try await waitUntil("Local document loads") { tab.title == "Generated content" && !tab.isLoading }
        XCTAssertEqual(tab.url?.scheme, "about")
        XCTAssertFalse(tab.isSecure)
        XCTAssertNil(tab.record.url)
        tab.close()
    }
}
