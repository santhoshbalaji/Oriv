import AppKit
import BrowserCore
@testable import BrowserEngine
import WebKit
import XCTest
import SwiftUI
@testable import PersonalBrowser

/// Repeatable local setup measurements, not page-load or WebKit subprocess benchmarks.
@MainActor final class BrowserPerformanceTests: BackgroundUITestCase {
    func testRestoreOneTabBaseline() throws { try measureRestoration(count: 1) }
    func testRestoreTenTabsBaseline() throws { try measureRestoration(count: 10) }
    func testRestoreThirtyTabsBaseline() throws { try measureRestoration(count: 30) }

    private func measureRestoration(count: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SessionFileStore(fileURL: directory.appendingPathComponent("session.json"))
        let tabs = (0..<count).map { TabRecord(title: "Page \($0)", url: URL(string: "https://example.test/\($0)")) }
        try file.save(BrowserSnapshot(tabs: tabs, selectedTabID: tabs.first?.id, legacyBookmarksImported: true))
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            autoreleasepool {
                let session = BrowserSession(store: file, dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
                XCTAssertEqual(session.tabs.count, count)
                XCTAssertTrue(session.tabs.allSatisfy { !$0.isInstantiated }, "Restoration must not create hidden web views or load background pages")
                session.shutdown()
            }
        }
    }

    func testBrowserStartupDoesNotCreateOptionalServiceStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = BrowserController(rootDirectory: root, testing: true)
        defer { controller.shutdown() }
        await controller.session.importLegacyBookmarks(from: root.appendingPathComponent("workspace.sqlite"))
        XCTAssertTrue(controller.session.tabs.allSatisfy { !$0.isInstantiated })
        controller.session.flushPersistence()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(Set(names).isSubset(of: ["session.json", "session.json.backup"]))
        XCTAssertTrue(controller.savedBookmarks.isEmpty)
    }
}

@MainActor final class TabReclamationIntegrationTests: BackgroundUITestCase {
    private let base = URL(string: "http://127.0.0.1:8768")!

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition())
    }

    func testDiscardedTabRestoresOnSelectionWithBackForwardAndScroll() async throws {
        let controller = BrowserController(testing: true)
        defer { controller.shutdown() }
        let session = controller.session, tab = try XCTUnwrap(session.selectedTab)
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        var original: WKWebView? = tab.webView
        window.contentView = original
        BackgroundUIMode.show(window, key: false)
        for path in ["one", "tab-memory-history", "two"] {
            tab.navigate(to: base.appendingPathComponent(path))
            try await wait { !tab.isLoading && tab.url?.path == "/\(path)" }
        }
        tab.goBack()
        try await wait { !tab.isLoading && tab.url?.path == "/tab-memory-history" }
        _ = try await original!.evaluateJavaScript("scrollTo(0,1200)")
        let back = original!.backForwardList.backList.map(\.url)
        let forward = original!.backForwardList.forwardList.map(\.url)
        XCTAssertFalse(back.isEmpty); XCTAssertFalse(forward.isEmpty)
        let scripts = original!.configuration.userContentController.userScripts.count
        weak var released = original
        window.contentView = nil
        session.addTab(load: false)
        original = nil
        tab.lastSelectedTime -= 601
        let reclaimed = await session.reclaimBackgroundTabs()
        XCTAssertEqual(reclaimed, 1); XCTAssertFalse(tab.isInstantiated)
        try await wait { released == nil }
        session.selectTab(tab.id)
        XCTAssertTrue(tab.isInstantiated, "Selecting a discarded tab must instantiate its saved interaction state")
        window.contentView = tab.webView
        try await wait { !tab.isLoading && !tab.isRestoringWebView && tab.url?.path == "/tab-memory-history" }
        XCTAssertEqual(tab.webView.backForwardList.backList.map(\.url), back)
        XCTAssertEqual(tab.webView.backForwardList.forwardList.map(\.url), forward)
        XCTAssertTrue(tab.canGoBack); XCTAssertTrue(tab.canGoForward)
        let y = try await tab.webView.evaluateJavaScript("scrollY") as? Double ?? -1
        XCTAssertEqual(y, 1200, accuracy: 3)
        XCTAssertEqual(tab.webView.configuration.userContentController.userScripts.count, scripts, "Adapter scripts must not accumulate across restoration")
        tab.goForward()
        try await wait { !tab.isLoading && tab.url?.path == "/two" }
        tab.goBack()
        try await wait { !tab.isLoading && tab.url?.path == "/tab-memory-history" }
    }

    func testInjectedMemoryPressureReclaimsOlderTabButProtectsRecentPinnedPrivateAndDownload() async throws {
        let controller = BrowserController(testing: true)
        defer { controller.shutdown() }
        let session = controller.session
        session.tabReclamationMonitor?.stopSources()
        var pages: [BrowserTab] = []
        for _ in 0..<5 {
            let tab = session.addTab(load: false)
            tab.navigate(to: base.appendingPathComponent("two"))
            try await wait { !tab.isLoading && tab.title == "Second page" }
            pages.append(tab)
        }
        session.addTab(load: false)
        for tab in pages { tab.lastSelectedTime -= 120 }
        session.togglePinned(pages[1].id)
        pages[2].lastSelectedTime = ProcessInfo.processInfo.systemUptime
        pages[3].hasActiveDownloads = { true }
        pages[4].recordDisplayCaptureRequest()
        let privateTab = session.addTab(url: base.appendingPathComponent("two"), isPrivate: true)
        try await wait { !privateTab.isLoading && privateTab.title == "Second page" }
        session.addTab(load: false); privateTab.lastSelectedTime -= 601
        let ordinary = await session.reclaimBackgroundTabs()
        XCTAssertEqual(ordinary, 0, "Two-minute-old pages are younger than the ordinary idle deadline")
        session.tabReclamationMonitor?.receive(.warning)
        try await wait { !pages[0].isInstantiated }
        XCTAssertTrue(pages.dropFirst().allSatisfy(\.isInstantiated))
        XCTAssertTrue(privateTab.isInstantiated)
        XCTAssertFalse(session.snapshot().tabs.contains { $0.id == privateTab.id })
        session.selectTab(pages[0].id)
        try await wait { !pages[0].isLoading && !pages[0].isRestoringWebView }
        XCTAssertEqual(pages[0].title, "Second page")
    }

    func testClosedTabsViewsAndAdaptersReleaseAcrossRepeatedBatches() async throws {
        var objects: [WeakReclamationObject] = []
        for _ in 0..<3 {
            autoreleasepool {
                let controller = BrowserController(testing: true)
                objects.append(WeakReclamationObject(controller))
                objects.append(WeakReclamationObject(controller.session))
                for _ in 0..<10 {
                    let tab = controller.session.addTab(load: false)
                    objects.append(WeakReclamationObject(tab))
                    objects.append(WeakReclamationObject(tab.webView))
                    if let adapter = tab.webView.uiDelegate { objects.append(WeakReclamationObject(adapter)) }
                    let chrome = PageChrome(); chrome.observe(tab.webView)
                    objects.append(WeakReclamationObject(chrome))
                    objects.append(WeakReclamationObject(chrome.observerLifetime))
                    controller.session.closeTab(tab.id)
                }
                controller.shutdown()
            }
        }
        try await wait { objects.allSatisfy { $0.value == nil } }
        XCTAssertTrue(objects.allSatisfy { $0.value == nil }, "Closed tabs, views, adapters, controllers and sessions must all release")
        print("TAB_RECLAMATION_LIFETIMES checked=\(objects.count) alive=\(objects.filter { $0.value != nil }.count)")
    }

    func testActualDownloadOwnerProtectsItsTabUntilDestinationCancellation() async throws {
        let controller = BrowserController(testing: true)
        defer { controller.shutdown() }
        let tab = try XCTUnwrap(controller.session.selectedTab)
        tab.navigate(to: base.appendingPathComponent("two"))
        try await wait { !tab.isLoading && tab.title == "Second page" }
        var destination: CheckedContinuation<URL?, Never>?
        controller.downloads.chooseDestination = { _ in
            await withCheckedContinuation { destination = $0 }
        }
        defer { destination?.resume(returning: nil); destination = nil }
        tab.webView.startDownload(using: URLRequest(url: base.appendingPathComponent("large-download"))) { [weak tab] download in tab?.onDownload?(download) }
        try await wait { destination != nil && controller.downloads.hasActiveDownloads }
        controller.session.addTab(load: false); tab.lastSelectedTime -= 601
        let protected = await controller.session.reclaimBackgroundTabs()
        XCTAssertEqual(protected, 0); XCTAssertTrue(tab.isInstantiated)
        destination?.resume(returning: nil); destination = nil
        try await wait { !controller.downloads.hasActiveDownloads }
        let reclaimed = await controller.session.reclaimBackgroundTabs()
        XCTAssertEqual(reclaimed, 1)
    }

    func testPlaybackStartingDuringScrollReadPreventsDiscard() async throws {
        let controller = BrowserController(testing: true)
        defer { controller.shutdown() }
        let tab = try XCTUnwrap(controller.session.selectedTab)
        tab.createWebView = { FinalPlaybackWebView(frame: .zero, configuration: $0) }
        let view = try XCTUnwrap(tab.webView as? FinalPlaybackWebView)
        tab.navigate(to: base.appendingPathComponent("two"))
        try await wait { !tab.isLoading && tab.title == "Second page" }
        controller.session.addTab(load: false)
        var result: Bool?
        tab.discardBackgroundWebView { result = $0 }
        try await wait { result != nil }
        XCTAssertEqual(view.queries, 2)
        XCTAssertEqual(result, false); XCTAssertTrue(tab.isInstantiated)
    }

    func testRealBrowserWindowDetachesBackgroundViewForReclamation() async throws {
        let controller = BrowserController(testing: true)
        defer { controller.shutdown() }
        let tab = try XCTUnwrap(controller.session.selectedTab)
        tab.navigate(to: base.appendingPathComponent("two"))
        try await wait { !tab.isLoading && tab.title == "Second page" }
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserWindow(controller: controller).browserAppearance(.t3Code, followsPage: true))
        BackgroundUIMode.show(window, key: false)
        defer { window.contentView = nil; window.close() }
        try await wait { tab.webView.window === window }
        weak var oldView = tab.webView
        controller.session.addTab(load: false)
        try await wait { oldView?.superview == nil && oldView?.window == nil }
        tab.lastSelectedTime -= 601
        let reclaimed = await controller.session.reclaimBackgroundTabs()
        XCTAssertEqual(reclaimed, 1)
        try await wait { oldView == nil }
        controller.session.selectTab(tab.id)
        try await wait { tab.webView.window === window && !tab.isLoading && !tab.isRestoringWebView }
        XCTAssertEqual(tab.title, "Second page")
    }
}

@MainActor private final class WeakReclamationObject {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}

@MainActor private final class FinalPlaybackWebView: WKWebView {
    var queries = 0
    override func requestMediaPlaybackState(completionHandler: @escaping @MainActor @Sendable (WKMediaPlaybackState) -> Void) {
        queries += 1
        completionHandler(queries == 1 ? .none : .playing)
    }
}
