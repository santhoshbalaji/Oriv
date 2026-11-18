import BrowserCore
@testable import BrowserEngine
import Foundation
import XCTest
import WebKit

@MainActor final class SiteIconAndSuggestionTests: XCTestCase {
    private func session(directory: URL? = nil) -> BrowserSession {
        BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil),
                       settings: BrowserSettings(defaults: nil), faviconDirectory: directory)
    }
    private func load(_ tab: BrowserTab) async throws {
        tab.navigate(to: URL(string: "http://127.0.0.1:18768/favicon-page")!)
        for _ in 0..<300 {
            if tab.webView.title == "Favicon fixture", !tab.webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Local favicon fixture did not finish")
    }
    func testSiteOwnedSVGUsesWebKitCookiesCoalescesAndPersistsRegularOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrivIcons-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = session(directory: root); defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        try await load(tab)
        let url = try XCTUnwrap(tab.url)
        async let one: Void = session.siteIcons.load(url, isPrivate: false)
        async let two: Void = session.siteIcons.load(url, isPrivate: false)
        _ = await (one, two)
        XCTAssertEqual(session.siteIcons.revision, 1, "Concurrent loads must publish only one decoded icon")
        let icon = try XCTUnwrap(session.siteIcons.icon(for: url, isPrivate: false))
        XCTAssertLessThanOrEqual(icon.image.width, 64); XCTAssertLessThanOrEqual(icon.image.height, 64)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].lastPathComponent.hasSuffix(".png")); XCTAssertFalse(files[0].lastPathComponent.contains("127"))
        let restored = SiteIconStore(directory: root)
        await restored.load(url, isPrivate: false)
        XCTAssertNotNil(restored.icon(for: url, isPrivate: false), "Disk cache needs no speculative page load")
        let privateTab = session.addTab(isPrivate: true)
        try await load(privateTab)
        await session.siteIcons.load(url, isPrivate: true)
        XCTAssertNotNil(session.siteIcons.icon(for: url, isPrivate: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil), files)
        session.closeTab(privateTab.id)
        XCTAssertNil(session.siteIcons.icon(for: url, isPrivate: true))
        XCTAssertNotNil(session.siteIcons.icon(for: url, isPrivate: false))
        await session.siteIcons.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testRegularDiskAndMemoryCachesRemainBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrivIconBounds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = session(); defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        try await load(tab)
        await session.siteIcons.load(try XCTUnwrap(tab.url), isPrivate: false)
        let icon = try XCTUnwrap(session.siteIcons.icon(for: tab.url, isPrivate: false))
        let disk = SiteIconDiskCache(directory: root)
        for index in 0..<260 { await disk.write(icon, key: "regular:https://host\(index).test") }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(files.count, SiteIconDiskCache.maximumEntries)
        let bytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, SiteIconDiskCache.maximumBytes)
        let cache = SiteIconStore(directory: root)
        for index in 130..<260 { await cache.load(URL(string: "https://host\(index).test")!, isPrivate: false) }
        let retained = (130..<260).filter { cache.icon(for: URL(string: "https://host\($0).test")!, isPrivate: false) != nil }.count
        XCTAssertEqual(retained, SiteIconStore.memoryLimit)
    }
    func testPrivateSessionLeavesNoIconDirectoryAndLazyLookupDoesNotWakeTabs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrivPrivateIcons-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = session(directory: root); defer { session.shutdown() }
        let sleepingURL = URL(string: "https://never-loaded.invalid")!
        let sleeping = session.addTab(url: sleepingURL, select: false, load: false)
        await session.siteIcons.load(sleepingURL, isPrivate: false)
        XCTAssertFalse(sleeping.isInstantiated)
        let tab = session.addTab(isPrivate: true)
        try await load(tab)
        await session.siteIcons.load(try XCTUnwrap(tab.url), isPrivate: true)
        XCTAssertNotNil(session.siteIcons.icon(for: tab.url, isPrivate: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(session.history.isEmpty)
        session.closeTab(tab.id)
        XCTAssertNil(session.siteIcons.icon(for: tab.url, isPrivate: true))
    }
    func testIndexedSuggestionsUpdateAndPrivateQueriesSeeOnlyTheirTabs() async throws {
        let pageCookie = try XCTUnwrap(HTTPCookie(properties: [.name: "page", .value: "fixture", .domain: "rank.test", .path: "/"]))
        let otherCookie = try XCTUnwrap(HTTPCookie(properties: [.name: "other", .value: "fixture", .domain: "other.test", .path: "/"]))
        let contextCookies = SiteIconStore.firstPartyCookies([pageCookie, otherCookie], pageURL: URL(string: "https://rank.test")!)
        XCTAssertEqual(contextCookies.map(\.name), ["page"])

        let session = session(), other = self.session(); defer { session.shutdown(); other.shutdown() }
        let url = URL(string: "https://rank.test/regular")!
        try session.applyContinuity(bookmarks: [Bookmark(title: "Rank bookmark", url: url)],
            history: [HistoryEntry(title: "Rank history", url: URL(string: "https://rank.test/history")!, visitCount: 30)])
        let privateTab = session.addTab(url: URL(string: "https://rank.test/private")!, isPrivate: true, load: false)
        let regular = await session.indexedSuggestions(for: "rank", isPrivate: false)
        XCTAssertEqual(regular.count, 2); XCTAssertFalse(regular.contains { $0.tabID == privateTab.id })
        let privateResults = await session.indexedSuggestions(for: "rank", isPrivate: true)
        XCTAssertEqual(privateResults.map(\.tabID), [privateTab.id])
        let otherResults = await other.indexedSuggestions(for: "rank", isPrivate: false)
        XCTAssertTrue(otherResults.isEmpty)
        session.clearHistory(); session.removeBookmark(session.bookmarks[0].id)
        let erased = await session.indexedSuggestions(for: "rank", isPrivate: false)
        XCTAssertTrue(erased.isEmpty)
    }
    func testIconDiscoveryWaitsForRestorationAndDestinationCoverWithoutCachingAMiss() async throws {
        let session = session(); defer { session.shutdown() }
        let tab = try XCTUnwrap(session.selectedTab)
        tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let presentation = NSObject()
        tab.switchPresentation = presentation
        try await load(tab)
        let url = try XCTUnwrap(tab.url)
        XCTAssertNil(session.siteIcons.document?(url, false))
        await session.siteIcons.load(url, isPrivate: false)
        XCTAssertNil(session.siteIcons.icon(for: url, isPrivate: false))
        session.addTab(load: false)
        let discarded = await withCheckedContinuation { reply in
            tab.discardBackgroundWebView { reply.resume(returning: $0) }
        }
        XCTAssertTrue(discarded)
        XCTAssertNil(session.siteIcons.document?(url, false))
        session.selectTab(tab.id)
        XCTAssertTrue(tab.isRestoringWebView)
        XCTAssertNil(session.siteIcons.document?(url, false))
        await session.siteIcons.load(url, isPrivate: false)
        XCTAssertNil(session.siteIcons.icon(for: url, isPrivate: false))
        for _ in 0..<300 {
            if !tab.isRestoringWebView && !tab.isLoading && tab.hasRenderedContent { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(tab.isRestoringWebView)
        XCTAssertNil(session.siteIcons.icon(for: url, isPrivate: false), "Restoration finishing must not discover under the destination cover")
        tab.switchPresentation = nil
        for _ in 0..<200 {
            if session.siteIcons.icon(for: url, isPrivate: false) != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(session.siteIcons.icon(for: url, isPrivate: false), "Blocked discovery must retry immediately after the handoff")
    }
}
