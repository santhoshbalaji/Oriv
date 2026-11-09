import XCTest
import BrowserCore
import BrowserEngine
import WebKit

@MainActor private final class MemoryContinuityTransport: ContinuityTransport {
    var account = "synthetic-account"
    var records: [String: ContinuityRecord] = [:]
    var pushes = 0, fetches = 0, accountChecks = 0
    var failFetch = false, failPush = false, changeAccountBeforePush = false
    func accountIdentifier() async throws -> String {
        accountChecks += 1
        if changeAccountBeforePush && accountChecks.isMultiple(of: 2) { return "different-account" }
        return account
    }
    func fetch(allowZoneCreation: Bool) async throws -> [ContinuityRecord] {
        fetches += 1
        if failFetch { throw URLError(.notConnectedToInternet) }
        return Array(records.values)
    }
    func push(_ incoming: [ContinuityRecord]) async throws -> [ContinuityRecord] {
        pushes += 1
        if failPush { throw URLError(.networkConnectionLost) }
        var conflicts: [ContinuityRecord] = []
        for value in incoming {
            if let current = records[value.id], current.supersedes(value) { conflicts.append(current) }
            else { records[value.id] = value }
        }
        return conflicts
    }
}

@MainActor final class ContinuityIntegrationTests: XCTestCase {
    private func session() -> BrowserSession {
        let result = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        result.setProfileActive(false); return result
    }
    private func continuity(_ transport: MemoryContinuityTransport, session: BrowserSession, root: URL? = nil) -> BrowserContinuity {
        let result = BrowserContinuity(root: root, deviceName: "Test device", transportFactory: { transport })
        result.configure(profiles: { [.personal] }, source: { _ in
            ContinuitySource(session: session, preferences: { ContinuityPreferences.snapshot(session: session, appearance: "t3Code") }, applyPreferences: {
                ContinuityPreferences.apply($0, session: session, appearance: { _ in })
            })
        }, importProfiles: { _ in })
        return result
    }
    func testNoCloudAccessUntilExplicitOptInAndPrivateTabsNeverLeaveDevice() async throws {
        let transport = MemoryContinuityTransport(), session = session()
        let sync = continuity(transport, session: session)
        defer { sync.shutdown(); session.shutdown() }
        let regular = session.addTab(url: URL(string: "https://example.test/regular")!, load: false)
        session.addTab(url: URL(string: "https://example.test/private-secret")!, isPrivate: true, load: false)
        sync.setForeground(true); sync.refreshLocal(); await sync.syncNow()
        XCTAssertEqual(transport.fetches, 0); XCTAssertEqual(transport.pushes, 0)
        sync.setEnabled(true); await sync.syncNow()
        XCTAssertEqual(transport.pushes, 1)
        XCTAssertEqual(sync.state.tabs(for: BrowserProfile.personalID, device: sync.state.deviceID).map(\.id), [regular.id])
        let encoded = String(decoding: try JSONEncoder().encode(Array(transport.records.values)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-secret")); XCTAssertFalse(encoded.contains("cookies")); XCTAssertFalse(encoded.contains("password"))
        sync.setEnabled(false)
        session.importBookmarks([Bookmark(title: "While paused", url: URL(string: "https://example.test/paused")!)])
        await sync.syncNow(); XCTAssertEqual(transport.pushes, 1)
        sync.setEnabled(true); await sync.syncNow(); XCTAssertEqual(transport.pushes, 2)
        XCTAssertEqual(sync.state.bookmarks(for: BrowserProfile.personalID).count, 1)
    }
    func testTwoDeviceMergeAndDeletionKeepLocalTabsAndPrivateOverrides() async throws {
        let transport = MemoryContinuityTransport(), mac = session(), phone = session()
        let first = continuity(transport, session: mac), second = continuity(transport, session: phone)
        defer { first.shutdown(); second.shutdown(); mac.shutdown(); phone.shutdown() }
        let bookmark = Bookmark(title: "Research", url: URL(string: "https://example.test/research")!)
        mac.importBookmarks([bookmark]); mac.settings.searchEngine = .brave
        let editedTab = phone.addTab(url: URL(string: "https://example.test/local-form")!, load: false)
        let privateTab = phone.addTab(url: URL(string: "https://example.test/private")!, isPrivate: true, load: false)
        let selected = phone.selectedTabID, tabIDs = phone.tabs.map(\.id)
        var privateRule = SiteRule(); privateRule.camera = .block
        phone.settings.setRule(privateRule, for: privateTab.url!, isPrivate: true)
        phone.adBlocker.setException(true, for: privateTab.url, isPrivate: true)
        first.setEnabled(true); await first.syncNow(); second.setEnabled(true); await second.syncNow()
        XCTAssertEqual(phone.bookmarks, [bookmark]); XCTAssertEqual(phone.settings.searchEngine, .brave)
        XCTAssertEqual(phone.tabs.map(\.id), tabIDs); XCTAssertEqual(phone.selectedTabID, selected)
        XCTAssertEqual(editedTab.url?.path, "/local-form")
        XCTAssertEqual(phone.settings.rule(for: privateTab.url, isPrivate: true).camera, .block)
        XCTAssertTrue(phone.adBlocker.isException(privateTab.url, isPrivate: true))
        mac.removeBookmark(bookmark.id); await first.syncNow(); await second.syncNow()
        XCTAssertTrue(phone.bookmarks.isEmpty)
        mac.undoBookmarkRemoval(); await first.syncNow(); await second.syncNow()
        XCTAssertEqual(phone.bookmarks, [bookmark])
        await first.syncNow()
        XCTAssertEqual(first.state.tabs(for: BrowserProfile.personalID, device: second.state.deviceID).map(\.id), [editedTab.id])
    }
    func testAccountSwitchBeforeUploadAndOfflineFailureRetainLocalChanges() async throws {
        let transport = MemoryContinuityTransport(), session = session()
        let sync = continuity(transport, session: session)
        defer { sync.shutdown(); session.shutdown() }
        let saved = Bookmark(title: "Saved", url: URL(string: "https://example.test/saved")!)
        let alien = Bookmark(title: "Different account", url: URL(string: "https://example.test/different-account")!)
        let alienRecord = ContinuityRecord(id: ContinuityRecord.bookmarkKey(BrowserProfile.personalID, alien.id), counter: 200, writer: UUID(), payload: .bookmark(BrowserProfile.personalID, alien))
        transport.records[alienRecord.id] = alienRecord
        session.importBookmarks([saved]); transport.changeAccountBeforePush = true
        sync.setEnabled(true); await sync.syncNow()
        XCTAssertEqual(transport.pushes, 0); XCTAssertTrue(sync.status.contains("account changed")); XCTAssertEqual(session.bookmarks, [saved])
        XCTAssertFalse(sync.canHandoff)
        transport.records = [:]
        transport.changeAccountBeforePush = false; transport.failFetch = true
        await sync.syncNow(); XCTAssertEqual(transport.pushes, 0); XCTAssertNil(sync.state.lastSync)
        transport.failFetch = false; transport.failPush = true
        await sync.syncNow(); XCTAssertNil(sync.state.lastSync); XCTAssertEqual(session.bookmarks, [saved])
        transport.failPush = false; await sync.syncNow()
        XCTAssertNotNil(sync.state.lastSync); XCTAssertEqual(sync.status, "Up to date")
    }
    func testPendingIncomingChangesAreAppliedBeforeLocalDeletionDetection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = ContinuityReplica(deviceName: "Recovered")
        state.enabled = true; state.pendingApplication = true
        let saved = Bookmark(title: "Remote", url: URL(string: "https://example.test/remote")!)
        try state.capture(profile: .personal, bookmarks: [saved], history: [], regularTabs: [], preferences: [:])
        try ContinuityStore(url: root.appendingPathComponent("continuity/replica.json")).save(state)
        let session = session(), transport = MemoryContinuityTransport()
        let sync = continuity(transport, session: session, root: root)
        defer { sync.shutdown(); session.shutdown() }
        await sync.syncNow()
        XCTAssertEqual(session.bookmarks, [saved]); XCTAssertFalse(sync.state.pendingApplication)
        XCTAssertEqual(sync.state.bookmarks(for: BrowserProfile.personalID), [saved])
    }
    func testHistoryClearPropagatesAndErasesOldPayloads() async throws {
        let transport = MemoryContinuityTransport(), mac = session(), phone = session()
        let first = continuity(transport, session: mac), second = continuity(transport, session: phone)
        defer { first.shutdown(); second.shutdown(); mac.shutdown(); phone.shutdown() }
        let old = HistoryEntry(title: "Old history", url: URL(string: "https://example.test/old-history")!)
        try mac.applyContinuity(bookmarks: [], history: [old])
        first.setEnabled(true); await first.syncNow(); second.setEnabled(true); await second.syncNow()
        XCTAssertEqual(phone.history, [old])
        phone.clearHistory(); await second.syncNow(); await first.syncNow()
        XCTAssertTrue(mac.history.isEmpty); XCTAssertTrue(phone.history.isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(Array(transport.records.values)), as: UTF8.self).contains("old-history"))
    }
}
