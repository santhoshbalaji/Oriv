import BrowserCore
import Foundation
@testable import BrowserEngine
import WebKit
import XCTest
#if os(macOS)
import AppKit
#endif

@MainActor final class TabReclamationTests: XCTestCase {
    private func session() -> BrowserSession {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        return BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
    }

    func testDiscardPolicyExcludesEveryProtectedCategory() {
        let safe = TabDiscardPolicy(committedMethod: "GET")
        XCTAssertTrue(safe.allowsDiscard)
        for key in [\TabDiscardPolicy.isSelected, \.isPinned, \.isPrivate, \.hasEditedFields,
                    \.isLoading, \.isCapturing, \.hasDownloads, \.hasTerminated, \.hasRequestBody] {
            var policy = safe; policy[keyPath: key] = true
            XCTAssertFalse(policy.allowsDiscard, "Exclusion: \(key)")
        }
        for method in [nil, "POST", "PUT", "HEAD"] {
            var policy = safe; policy.committedMethod = method
            XCTAssertFalse(policy.allowsDiscard)
        }
        var pending = safe; pending.pendingMethod = "POST"
        XCTAssertFalse(pending.allowsDiscard)
    }

    func testIdleAndPressurePreserveRecentUseAndRejectClockRollback() {
        XCTAssertFalse(TabDiscardPolicy.isOldEnough(lastUsed: 0, now: 599, underMemoryPressure: false))
        XCTAssertTrue(TabDiscardPolicy.isOldEnough(lastUsed: 0, now: 600, underMemoryPressure: false))
        XCTAssertFalse(TabDiscardPolicy.isOldEnough(lastUsed: 0, now: 59, underMemoryPressure: true))
        XCTAssertTrue(TabDiscardPolicy.isOldEnough(lastUsed: 0, now: 60, underMemoryPressure: true))
        XCTAssertFalse(TabDiscardPolicy.isOldEnough(lastUsed: 100, now: 99, underMemoryPressure: true))
    }

    func testBackgroundCrashReloadsOnlyAfterSelectionAndGuardsCrashLoop() throws {
        let session = session(); defer { session.shutdown() }
        let tab = session.addTab(select: false, load: false)
        let view = fixture(tab)
        var now = 100.0; tab.recoveryClock = { now }
        tab.webViewWebContentProcessDidTerminate(view)
        XCTAssertEqual(view.reloadCount, 0)
        session.selectTab(tab.id)
        XCTAssertEqual(view.reloadCount, 1); XCTAssertNil(tab.errorMessage)
        tab.webViewWebContentProcessDidTerminate(view)
        session.selectTab(tab.id); tab.activate()
        XCTAssertEqual(view.reloadCount, 1)
        XCTAssertNotNil(tab.errorMessage)
        now += 31; tab.activate()
        XCTAssertEqual(view.reloadCount, 2)
    }

    func testRecoveryNeverReplaysUnsafeOrEditedDocuments() throws {
        let session = session(); defer { session.shutdown() }
        for method in ["POST", "PUT", "UNKNOWN", "EDITED", "PENDING_POST", "GET_BODY", "GET_STREAM"] {
            let tab = session.addTab(load: false)
            let view = fixture(tab, method: method == "UNKNOWN" ? nil : ["EDITED", "PENDING_POST", "GET_BODY", "GET_STREAM"].contains(method) ? "GET" : method)
            if method == "EDITED" { tab.recordFieldEdit() }
            if method == "PENDING_POST" {
                var request = URLRequest(url: view.fixtureURL); request.httpMethod = "POST"
                tab.recordAllowedMainFrameNavigation(request)
            }
            if ["GET_BODY", "GET_STREAM"].contains(method) {
                var request = URLRequest(url: view.fixtureURL)
                if method == "GET_BODY" { request.httpBody = Data("field=value".utf8) }
                else { request.httpBodyStream = InputStream(data: Data("field=value".utf8)) }
                tab.recordAllowedMainFrameNavigation(request)
                tab.webView(view, didCommit: nil)
            }
            tab.webViewWebContentProcessDidTerminate(view)
            XCTAssertEqual(view.reloadCount, 0, method)
            XCTAssertNotNil(tab.errorMessage)
        }
    }

    func testStaleAndClosedViewsCannotTriggerRecovery() throws {
        let session = session(); defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab), view = fixture(tab)
        let stale = ReclamationWebView(frame: .zero, configuration: WKWebViewConfiguration())
        tab.webViewWebContentProcessDidTerminate(stale)
        XCTAssertEqual(view.reloadCount, 0)
        XCTAssertNil(tab.errorMessage)
        tab.close(); tab.webViewWebContentProcessDidTerminate(view)
        XCTAssertEqual(view.reloadCount, 0)
    }

    func testPopupDerivedConfigurationsDoNotMultiplyLifecycleScripts() {
        var tabs: [BrowserTab] = []
        defer { tabs.forEach { $0.close() } }
        var scripts: [WKUserScript] = []
        var originalCount = 0
        for generation in 0..<5 {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            scripts.forEach(configuration.userContentController.addUserScript)
            let tab = BrowserTab(configuration: configuration)
            tabs.append(tab)
            scripts = tab.webView.configuration.userContentController.userScripts
            if generation == 0 { originalCount = scripts.count }
            XCTAssertEqual(scripts.count, originalCount, "A popup inherits scripts before the new tab installs its handlers")
            XCTAssertEqual(scripts.filter { $0.source.contains("window.orivEditTracking") }.count, 1)
            #if os(macOS)
            XCTAssertEqual(scripts.filter { $0.source.contains("displayCaptureRequested") }.count, 1)
            XCTAssertEqual(scripts.filter { $0.source.hasPrefix("// Oriv tab audio\n") }.count, 1)
            #endif
        }
    }

    func testDiscardRevalidatesSelectionAfterMediaReply() async throws {
        let session = session(); defer { session.shutdown() }
        let tab = session.addTab(select: false, load: false), view = fixture(tab)
        view.deferMediaReply = true
        var result: Bool?
        tab.discardBackgroundWebView { result = $0 }
        session.selectTab(tab.id)
        view.mediaReply?(.none)
        for _ in 0..<50 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(result, false)
        XCTAssertTrue(tab.isInstantiated)
    }

    func testDiscardMediaTimeoutDoesNotReleasePageOrApplyLateReply() async throws {
        let session = session(); defer { session.shutdown() }
        let tab = session.addTab(select: false, load: false), view = fixture(tab)
        view.deferMediaReply = true; tab.discardTimeout = .milliseconds(30)
        var completions = 0, result: Bool?
        tab.discardBackgroundWebView { result = $0; completions += 1 }
        for _ in 0..<50 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(result, false)
        view.mediaReply?(.none)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(completions, 1); XCTAssertTrue(tab.isInstantiated)
    }

    func testPlayingPausedAndSuspendedMediaRemainResident() async throws {
        let session = session(); defer { session.shutdown() }
        for state in [WKMediaPlaybackState.playing, .paused, .suspended] {
            let tab = session.addTab(select: false, load: false), view = fixture(tab)
            view.playbackState = state
            var result: Bool?
            tab.discardBackgroundWebView { result = $0 }
            for _ in 0..<50 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(result, false); XCTAssertTrue(tab.isInstantiated)
        }
    }

    func testRecentUseDownloadEditAndNavigationAreRecheckedAfterIPC() async throws {
        let session = session(); defer { session.shutdown() }
        for change in ["recent", "download", "edit", "navigation", "display"] {
            let tab = session.addTab(select: false, load: false), view = fixture(tab)
            view.deferMediaReply = true
            tab.recoveryClock = { 1000 }; tab.lastSelectedTime = 0
            var result: Bool?
            tab.discardBackgroundWebView(minimumIdle: 600) { result = $0 }
            switch change {
            case "recent":
                session.selectTab(tab.id); session.addTab(load: false)
            case "download": tab.hasActiveDownloads = { true }
            case "edit": tab.recordFieldEdit()
            case "display": tab.recordDisplayCaptureRequest()
            default: tab.webView(view, didStartProvisionalNavigation: nil)
            }
            view.mediaReply?(.none)
            for _ in 0..<50 where result == nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(result, false, change); XCTAssertTrue(tab.isInstantiated)
        }
    }

    #if os(macOS)
    func testInjectedWarningAndCriticalUseTheSamePressurePathAsDispatchSource() {
        var events: [Bool] = []
        let monitor = TabReclamationMonitor(startSources: false) { events.append($0) }
        monitor.receive([])
        monitor.receive(.warning)
        monitor.receive(.critical)
        XCTAssertEqual(events, [true, true])
        monitor.poll()
        XCTAssertEqual(events.last, true, "Pressure remains active for a later recent-use retry")
        monitor.receive(.normal); monitor.poll()
        XCTAssertEqual(events.last, false)
        monitor.stop(); monitor.receive(.critical)
        XCTAssertEqual(events.count, 4)
    }
    func testCoalescedNormalEventDoesNotLatchPressureDeadline() {
        var events: [Bool] = []
        let monitor = TabReclamationMonitor(startSources: false) { events.append($0) }
        monitor.receive([.warning, .normal]); monitor.poll()
        XCTAssertEqual(events, [true, false])
        monitor.stop()
    }
    #endif

    private func fixture(_ tab: BrowserTab, method: String? = "GET") -> ReclamationWebView {
        tab.createWebView = { ReclamationWebView(frame: .zero, configuration: $0) }
        let view = tab.webView as! ReclamationWebView
        if let method {
            var request = URLRequest(url: view.fixtureURL); request.httpMethod = method
            tab.recordAllowedMainFrameNavigation(request)
        }
        tab.webView(view, didStartProvisionalNavigation: nil)
        tab.webView(view, didCommit: nil)
        return view
    }
}

@MainActor private final class ReclamationWebView: WKWebView {
    let fixtureURL = URL(string: "https://fixture.invalid/reclamation")!
    var reloadCount = 0
    var deferMediaReply = false
    var playbackState: WKMediaPlaybackState = .none
    var mediaReply: (@MainActor @Sendable (WKMediaPlaybackState) -> Void)?
    override var url: URL? { fixtureURL }
    override var isLoading: Bool { false }
    override func reload() -> WKNavigation? { reloadCount += 1; return nil }
    override func load(_ request: URLRequest) -> WKNavigation? { nil }
    override func requestMediaPlaybackState(completionHandler: @escaping @MainActor @Sendable (WKMediaPlaybackState) -> Void) {
        if deferMediaReply { mediaReply = completionHandler } else { completionHandler(playbackState) }
    }
}
