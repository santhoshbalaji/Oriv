import XCTest
import BrowserCore
@testable import BrowserEngine
import WebKit

@MainActor private final class MemoryContinuityTransport: ContinuityTransport {
    var account = "synthetic-account"
    var records: [String: ContinuityRecord] = [:]
    var pushes = 0, fetches = 0, accountChecks = 0
    var failFetch = false, failPush = false, changeAccountBeforePush = false
    private var accountChanged: (@MainActor () -> Void)?
    func watchAccountChanges(_ handler: @escaping @MainActor () -> Void) { accountChanged = handler }
    func accountIdentifier() async throws -> String {
        accountChecks += 1
        return account
    }
    func fetch(allowZoneCreation: Bool) async throws -> [ContinuityRecord] {
        fetches += 1
        if failFetch { throw URLError(.notConnectedToInternet) }
        if changeAccountBeforePush { accountChanged?() }
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
    func testDeletedProfileRedactsLateOfflineRecordsAndSurvivesJournalReload() async throws {
        let transport = MemoryContinuityTransport(), local = session()
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); local.shutdown() }
        let sync = continuity(transport, session: local, root: root)
        defer { sync.shutdown() }
        let profile = BrowserProfile(name: "Work")
        let url = URL(string: "https://work.example/synthetic")!
        let saved = Bookmark(title: "Work", url: url)
        var offline = ContinuityReplica(deviceName: "Offline fixture")
        let tab = TabRecord(title: "Work", url: url)
        try offline.capture(profile: profile, bookmarks: [saved], history: [HistoryEntry(title: "Work", url: url, visitedAt: .now)],
                            regularTabs: [tab], preferences: ["searchEngine": "Brave"])
        let request = ContinuityOpenRequest(targetDeviceID: sync.state.deviceID, sourceDeviceID: offline.deviceID,
                                            sourceDeviceName: "Offline fixture", url: url, title: "Work", profileID: profile.id)
        try offline.put(ContinuityRecord.openRequestKey(request.id), .openRequest(request))
        let oldRecords = Array(offline.records.values)
        sync.setEnabled(true)
        await sync.syncNow()
        sync.setEnabled(false)
        try sync.deleteProfile(profile.id)
        let journal = ContinuityStore(url: root.appendingPathComponent("continuity/replica.json"))
        let savedReplica = try XCTUnwrap(journal.load())
        XCTAssertTrue(savedReplica.isProfileDeleted(profile.id))
        XCTAssertFalse(savedReplica.dirtyRecords.isEmpty)
        for record in oldRecords { transport.records[record.id] = record }
        sync.setEnabled(true)
        await sync.syncNow()
        XCTAssertTrue(sync.state.isProfileDeleted(profile.id))
        XCTAssertNotNil(transport.records[ContinuityRecord.profileKey(BrowserProfile.personalID)]?.payload)
        for record in oldRecords {
            XCTAssertNotNil(transport.records[record.id])
            XCTAssertNil(transport.records[record.id]?.payload)
        }
        var edited = profile; edited.name = "Offline rename"
        let staleProfile = ContinuityRecord(id: ContinuityRecord.profileKey(profile.id), counter: offline.counter + 100,
                                           writer: offline.deviceID, payload: .profile(ContinuityProfile(edited)))
        transport.records[staleProfile.id] = staleProfile
        await sync.syncNow()
        XCTAssertTrue(sync.state.isProfileDeleted(profile.id))
        XCTAssertNil(transport.records[staleProfile.id]?.payload)
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
    func testHistoryTitleCorrectionSyncsAsSameVisitWithoutDuplicatesOrResurrection() async throws {
        let transport = MemoryContinuityTransport(), mac = session(), phone = session()
        let first = continuity(transport, session: mac), second = continuity(transport, session: phone)
        defer { first.shutdown(); second.shutdown(); mac.shutdown(); phone.shutdown() }
        let tab = mac.addTab(url: URL(string: "https://example.test/late-title")!, load: false)
        tab.recordHistoryVisit?(HistoryEntry(title: "example.test", url: tab.url!), true)
        let visit = try XCTUnwrap(mac.history.first)
        first.setEnabled(true); await first.syncNow(); second.setEnabled(true); await second.syncNow()
        XCTAssertEqual(phone.history, [visit])
        tab.correctHistoryTitle?(visit.id, tab.url!, "Final page title")
        await first.syncNow(); await second.syncNow(); await first.syncNow()
        XCTAssertEqual(phone.history.count, 1); XCTAssertEqual(phone.history[0].title, "Final page title")
        XCTAssertEqual(phone.history[0].id, visit.id); XCTAssertEqual(phone.history[0].visitedAt, visit.visitedAt)
        XCTAssertEqual(mac.history, phone.history)
        phone.removeHistory(visit.id); await second.syncNow(); await first.syncNow()
        tab.correctHistoryTitle?(visit.id, tab.url!, "After removal")
        await first.syncNow(); await second.syncNow()
        XCTAssertTrue(mac.history.isEmpty); XCTAssertTrue(phone.history.isEmpty)
    }
    func testOptInAppearanceSyncUsesEachProfileSourceIndependently() async throws {
        let transport = MemoryContinuityTransport(), work = BrowserProfile(name: "Work")
        let profiles: [BrowserProfile] = [.personal, work]
        let mac = [BrowserProfile.personalID: session(), work.id: session()]
        let phone = [BrowserProfile.personalID: session(), work.id: session()]
        var macAppearance = [BrowserProfile.personalID: "Light", work.id: "Dark"]
        var phoneAppearance = [BrowserProfile.personalID: "T3 Code", work.id: "System"]
        let first = BrowserContinuity(root: nil, deviceName: "Mac", transportFactory: { transport })
        let second = BrowserContinuity(root: nil, deviceName: "Phone", transportFactory: { transport })
        defer { first.shutdown(); second.shutdown(); mac.values.forEach { $0.shutdown() }; phone.values.forEach { $0.shutdown() } }
        first.configure(profiles: { profiles }, source: { profile in
            let session = mac[profile.id]!
            return ContinuitySource(session: session, preferences: { ContinuityPreferences.snapshot(session: session, appearance: macAppearance[profile.id]!) }, applyPreferences: { values in
                ContinuityPreferences.apply(values, session: session) { macAppearance[profile.id] = $0 }
            })
        }, importProfiles: { _ in })
        second.configure(profiles: { profiles }, source: { profile in
            let session = phone[profile.id]!
            return ContinuitySource(session: session, preferences: { ContinuityPreferences.snapshot(session: session, appearance: phoneAppearance[profile.id]!) }, applyPreferences: { values in
                ContinuityPreferences.apply(values, session: session) { phoneAppearance[profile.id] = $0 }
            })
        }, importProfiles: { _ in })
        await first.syncNow(); await second.syncNow()
        XCTAssertEqual(transport.fetches, 0); XCTAssertEqual(phoneAppearance[work.id], "System")
        first.setEnabled(true); await first.syncNow(); second.setEnabled(true); await second.syncNow()
        XCTAssertEqual(phoneAppearance, macAppearance)
        macAppearance[work.id] = "T3 Code"
        // This synthetic dictionary is not observable; notify the changed source explicitly.
        first.refreshLocal(profileID: work.id)
        await first.syncNow(); await second.syncNow()
        XCTAssertEqual(phoneAppearance[work.id], "T3 Code"); XCTAssertEqual(phoneAppearance[BrowserProfile.personalID], "Light")
        XCTAssertEqual(second.state.preferences(for: work.id)["appearance"], "T3 Code")
    }

}
