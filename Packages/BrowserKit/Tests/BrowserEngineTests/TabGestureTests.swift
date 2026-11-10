import XCTest
import BrowserCore
@testable import BrowserEngine
import WebKit
#if os(macOS)
import AppKit
#endif

@MainActor final class TabGestureTests: XCTestCase {
    private func session(store: SessionFileStore? = nil, external: Bool = false) -> BrowserSession {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        return BrowserSession(store: store, dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil), externalPrivate: external)
    }
    func testBoundedSwipeNeverWrapsAndSkipsOtherModeAndProfile() throws {
        let a = session(), b = session(); defer { a.shutdown(); b.shutdown() }
        let first = try XCTUnwrap(a.selectedTab)
        let privateTab = a.addTab(isPrivate: true, load: false)
        let second = a.addTab(load: false)
        a.selectTab(first.id)
        XCTAssertEqual(a.tabSwipeTarget(-1), .boundary)
        XCTAssertEqual(a.tabSwipeTarget(1), .tab(second.id))
        a.commitTabSwipe(-1, from: first.id); XCTAssertEqual(a.selectedTabID, first.id)
        a.commitTabSwipe(1, from: first.id); XCTAssertEqual(a.selectedTabID, second.id)
        XCTAssertEqual(a.tabSwipeTarget(1), .newTab)
        a.selectTab(privateTab.id)
        XCTAssertEqual(a.tabSwipeTarget(-1), .boundary)
        XCTAssertEqual(a.tabSwipeTarget(1), .newTab)
        XCTAssertFalse(a.tabsInSelectedMode.contains { $0.id == b.selectedTabID })
        XCTAssertEqual(a.tabSwipeTarget(0), .boundary)
        XCTAssertEqual(a.tabSwipeTarget(2), .boundary)
    }
    func testSwipePastEndCreatesSameModeTabAndStaleSourceCannotCommit() throws {
        let s = session(); defer { s.shutdown() }
        let regular = try XCTUnwrap(s.selectedTab)
        s.commitTabSwipe(1, from: regular.id)
        XCTAssertEqual(s.tabs.count, 2); XCTAssertFalse(try XCTUnwrap(s.selectedTab).isPrivate)
        s.commitTabSwipe(1, from: regular.id); XCTAssertEqual(s.tabs.count, 2)
        let privateTab = s.addTab(isPrivate: true, load: false)
        s.commitTabSwipe(1, from: privateTab.id)
        XCTAssertEqual(s.tabs.filter(\.isPrivate).count, 2)
        XCTAssertTrue(try XCTUnwrap(s.selectedTab).isPrivate)
        XCTAssertFalse(s.snapshot().tabs.contains { $0.id == s.selectedTabID })
    }
    func testSwipeFollowsPinnedDisplayOrder() throws {
        let s = session(); defer { s.shutdown() }
        let first = try XCTUnwrap(s.selectedTab)
        let pinned = s.addTab(load: false); s.togglePinned(pinned.id)
        s.selectTab(pinned.id)
        XCTAssertEqual(s.tabSwipeTarget(-1), .boundary)
        XCTAssertEqual(s.tabSwipeTarget(1), .tab(first.id))
    }
    func testInactiveProfileCannotCommitAnInterruptedSwipe() throws {
        let s = session(); defer { s.shutdown() }
        let first = try XCTUnwrap(s.selectedTab)
        s.setProfileActive(false)
        s.commitTabSwipe(1, from: first.id)
        XCTAssertEqual(s.tabs.count, 1)
        XCTAssertEqual(s.selectedTabID, first.id)
        s.setProfileActive(true)
        s.commitTabSwipe(1, from: first.id)
        XCTAssertEqual(s.tabs.count, 2)
    }
    func testRecentlyClosedIsNewestFirstBoundedAndNeverPrivate() throws {
        let s = session(); defer { s.shutdown() }
        for i in 0..<25 {
            let t = s.addTab(url: URL(string: "https://example.test/\(i)"), select: false, load: false)
            s.closeTab(t.id)
            let p = s.addTab(url: URL(string: "https://example.test/private-\(i)"), isPrivate: true, select: false, load: false)
            s.closeTab(p.id)
        }
        XCTAssertEqual(s.recentlyClosedTabs.count, 20)
        XCTAssertEqual(s.recentlyClosedTabs.first?.url?.lastPathComponent, "24")
        XCTAssertEqual(s.recentlyClosedTabs.last?.url?.lastPathComponent, "5")
        let chosen = s.recentlyClosedTabs[5]
        s.reopenClosedTab(chosen.id)
        XCTAssertEqual(s.selectedTab?.url, chosen.url); XCTAssertNotEqual(s.selectedTabID, chosen.id)
        XCTAssertFalse(try XCTUnwrap(s.selectedTab).isPrivate)
        XCTAssertEqual(s.recentlyClosedTabs.count, 19)
        s.reopenClosedTab(chosen.id); XCTAssertEqual(s.recentlyClosedTabs.count, 19)
        s.clearHistory(); XCTAssertTrue(s.recentlyClosedTabs.isEmpty)
    }
    func testReorderIsInsertionAndCannotCrossPinOrPrivacySections() throws {
        let s = session(); defer { s.shutdown() }
        let a = try XCTUnwrap(s.selectedTab), b = s.addTab(load: false), c = s.addTab(load: false)
        let pinned = s.addTab(load: false); s.togglePinned(pinned.id)
        let privateTab = s.addTab(isPrivate: true, load: false)
        s.moveTab(c.id, to: a.id)
        XCTAssertEqual(s.orderedTabs.map(\.id), [pinned.id, c.id, a.id, b.id, privateTab.id])
        s.moveTab(c.id, to: pinned.id); s.moveTab(c.id, to: privateTab.id)
        XCTAssertEqual(s.orderedTabs.map(\.id), [pinned.id, c.id, a.id, b.id, privateTab.id])
        s.moveTab(c.id, offset: 2)
        XCTAssertEqual(s.orderedTabs.map(\.id), [pinned.id, a.id, b.id, c.id, privateTab.id])
    }
    func testReorderAndPinPersistWithoutPrivateRecordsOrRecentlyClosed() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionFileStore(fileURL: root.appendingPathComponent("session.json"))
        let s = session(store: store); defer { s.shutdown() }
        let a = try XCTUnwrap(s.selectedTab), b = s.addTab(load: false), c = s.addTab(load: false)
        s.togglePinned(b.id); s.moveTab(c.id, to: a.id)
        let privateTab = s.addTab(isPrivate: true, load: false)
        s.selectTab(c.id); s.saveNow()
        let restored = session(store: store); defer { restored.shutdown() }
        XCTAssertEqual(restored.orderedTabs.map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(restored.selectedTabID, c.id)
        XCTAssertFalse(restored.tabs.contains { $0.id == privateTab.id })
        XCTAssertTrue(restored.recentlyClosedTabs.isEmpty)
    }
    func testSuppliedConfigurationCannotEscapeSessionDataStores() throws {
        let s = session(), other = session(); defer { s.shutdown(); other.shutdown() }
        let regular = try XCTUnwrap(s.selectedTab)
        let privateTab = s.addTab(isPrivate: true, load: false)
        let injected = WKWebViewConfiguration(); injected.websiteDataStore = regular.webView.configuration.websiteDataStore
        let popup = s.addTab(isPrivate: true, configuration: injected, select: false, load: false)
        XCTAssertTrue(popup.webView.configuration.websiteDataStore === privateTab.webView.configuration.websiteDataStore)
        XCTAssertFalse(popup.webView.configuration.websiteDataStore === regular.webView.configuration.websiteDataStore)
        XCTAssertFalse(popup.webView.configuration.websiteDataStore === other.addTab(isPrivate: true, load: false).webView.configuration.websiteDataStore)
        s.closeTab(popup.id); s.closeTab(privateTab.id)
        let freshPrivate = s.addTab(isPrivate: true, load: false)
        XCTAssertFalse(freshPrivate.webView.configuration.websiteDataStore === injected.websiteDataStore)
    }
    func testExternalPrivateEndSwipeNeverCreatesRegularOrReopenRecords() throws {
        let s = session(external: true); defer { s.shutdown() }
        let first = try XCTUnwrap(s.selectedTab)
        s.commitTabSwipe(1, from: first.id)
        XCTAssertTrue(s.tabs.allSatisfy(\.isPrivate))
        s.closeTab(first.id)
        XCTAssertTrue(s.recentlyClosedTabs.isEmpty); XCTAssertTrue(s.snapshot().tabs.isEmpty)
    }
}
