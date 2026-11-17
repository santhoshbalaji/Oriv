import AppKit
import XCTest
import BrowserCore
@testable import BrowserEngine

@MainActor final class ContinuityEfficiencyTests: XCTestCase {
    func testNoChangeCycleWithFiveThousandRecordsAndSessionSavePerformance() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = BrowserProfile.personalID
        let bookmarks = (0..<200).map { Bookmark(title: "Bookmark \($0)", url: URL(string: "https://example.test/bookmark/\($0)")!) }
        let history = (0..<500).map { HistoryEntry(title: "History \($0)", url: URL(string: "https://example.test/history/\($0)")!) }
        let disk = SessionFileStore(fileURL: root.appendingPathComponent("session.json"))
        try disk.save(BrowserSnapshot(tabs: (0..<20).map { _ in TabRecord() }, bookmarks: bookmarks, history: history))
        let session = BrowserSession(store: disk, dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        session.setProfileActive(false)
        let cloud = EfficiencyTransport()
        for b in bookmarks { let key = ContinuityRecord.bookmarkKey(profile, b.id); cloud.records[key] = ContinuityRecord(id: key, counter: 1, writer: UUID(), payload: .bookmark(profile, b)) }
        for h in history { let key = ContinuityRecord.historyKey(profile, h.id); cloud.records[key] = ContinuityRecord(id: key, counter: 1, writer: UUID(), payload: .history(profile, h)) }
        for _ in 0..<4300 { let key = ContinuityRecord.bookmarkKey(profile, UUID()); cloud.records[key] = ContinuityRecord(id: key, counter: 1, writer: UUID(), payload: nil) }
        let spy = EfficiencyReplicaStore(disk: ContinuityStore(url: root.appendingPathComponent("continuity/replica.json")))
        let sync = BrowserContinuity(root: root, deviceName: "Test device", transportFactory: { cloud }, replicaStore: spy)
        var applies = 0, captures = 0
        sync.configure(profiles: { [.personal] }, source: { _ in ContinuitySource(session: session, preferences: { captures += 1; return [:] }, applyPreferences: { _ in }) }, importProfiles: { _ in applies += 1 })
        defer { sync.shutdown(); session.shutdown() }
        sync.setEnabled(true); await sync.syncNow(); await sync.syncNow()
        XCTAssertTrue(sync.state.dirtyKeys.isEmpty)
        var cycles: [Double] = [], saves: [Double] = [], durableSaves: [Double] = [], unchanged: [Double] = []
        for i in 0..<7 {
            let fetches = cloud.fetches, pushes = cloud.pushes, accounts = cloud.accountChecks
            let persists = spy.saves, applied = applies, captured = captures
            var start = ContinuousClock.now
            await sync.syncNow()
            XCTAssertEqual(cloud.fetches - fetches, 1)
            XCTAssertEqual(cloud.accountChecks - accounts, 1)
            XCTAssertEqual(cloud.pushes - pushes, 0)
            XCTAssertEqual(spy.saves - persists, 0)
            XCTAssertEqual(applies - applied, 0)
            XCTAssertEqual(captures - captured, 0)
            cycles.append(milliseconds(start.duration(to: .now)))
            start = .now
            session.saveNow()
            unchanged.append(milliseconds(start.duration(to: .now)))
            session.selectTab(session.tabs[i % 2].id)
            start = .now
            session.saveNow()
            saves.append(milliseconds(start.duration(to: .now)))
            session.flushPersistence()
            durableSaves.append(milliseconds(start.duration(to: .now)))
        }
        XCTAssertLessThan(try XCTUnwrap(cycles.max()), 5, "No-change main-actor work must stay below 5 ms")
        session.flushPersistence()
        print("PHASE_A_MEASURE records=\(sync.state.records.count) tabs=20 bookmarks=200 history=500 median_cycle_ms=\(cycles.sorted()[3]) median_changed_save_ms=\(saves.sorted()[3]) median_unchanged_save_ms=\(unchanged.sorted()[3]) median_durable_save_ms=\(durableSaves.sorted()[3])")
    }
    func testOnlyChangedKeysAndDeletionTombstonesArePushed() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        session.setProfileActive(false)
        let cloud = EfficiencyTransport()
        let sync = BrowserContinuity(root: nil, deviceName: "Test device", transportFactory: { cloud })
        sync.configure(profiles: { [.personal] }, source: { _ in ContinuitySource(session: session, preferences: { [:] }, applyPreferences: { _ in }) }, importProfiles: { _ in })
        defer { sync.shutdown(); session.shutdown() }
        sync.setEnabled(true); await sync.syncNow()
        let bookmark = Bookmark(title: "Changed", url: URL(string: "https://example.test/changed")!)
        session.importBookmarks([bookmark])
        let key = ContinuityRecord.bookmarkKey(BrowserProfile.personalID, bookmark.id)
        XCTAssertEqual(sync.state.dirtyKeys, [key])
        cloud.failPush = true; await sync.syncNow()
        XCTAssertEqual(sync.state.dirtyKeys, [key])
        cloud.failPush = false; await sync.syncNow()
        XCTAssertEqual(cloud.lastPushed.map(\.id), [key]); XCTAssertTrue(sync.state.dirtyKeys.isEmpty)
        session.removeBookmark(bookmark.id); await sync.syncNow()
        XCTAssertEqual(cloud.lastPushed.map(\.id), [key]); XCTAssertNil(cloud.lastPushed.first?.payload)
        XCTAssertTrue(sync.state.dirtyKeys.isEmpty)
    }
    func testAccountNotificationDuringFetchPreventsImportAndUpload() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        session.setProfileActive(false)
        let cloud = EfficiencyTransport()
        let sync = BrowserContinuity(root: nil, deviceName: "Test device", transportFactory: { cloud })
        var applies = 0
        sync.configure(profiles: { [.personal] }, source: { _ in ContinuitySource(session: session, preferences: { [:] }, applyPreferences: { _ in }) }, importProfiles: { _ in applies += 1 })
        defer { sync.shutdown(); session.shutdown() }
        sync.setEnabled(true)
        cloud.duringFetch = { cloud.notifyAccountChanged() }
        await sync.syncNow()
        XCTAssertEqual(cloud.accountChecks, 1); XCTAssertEqual(cloud.pushes, 0)
        XCTAssertEqual(applies, 0); XCTAssertFalse(sync.accountVerified)
    }
    func testAccountSwitchDuringFetchWithoutNotificationPreventsMergeAndUpload() async throws {
        let cloud = EfficiencyTransport()
        let bookmark = Bookmark(title: "Other account", url: URL(string: "https://example.test/other-account")!)
        let key = ContinuityRecord.bookmarkKey(BrowserProfile.personalID, bookmark.id)
        cloud.records[key] = ContinuityRecord(id: key, counter: 1, writer: UUID(), payload: .bookmark(BrowserProfile.personalID, bookmark))
        let sync = BrowserContinuity(root: nil, deviceName: "Test device", transportFactory: { cloud })
        var applies = 0
        sync.configure(profiles: { [] }, source: { _ in nil }, importProfiles: { _ in applies += 1 })
        defer { sync.shutdown() }
        sync.setEnabled(true)
        let records = sync.state.records
        cloud.duringFetch = { cloud.accountID = "other-account" }
        await sync.syncNow()
        XCTAssertEqual(cloud.accountChecks, 2); XCTAssertEqual(cloud.fetches, 1)
        XCTAssertEqual(sync.state.records, records); XCTAssertEqual(applies, 0)
        XCTAssertEqual(cloud.pushes, 0); XCTAssertTrue(cloud.lastPushed.isEmpty)
        XCTAssertEqual(sync.state.accountID, "synthetic-account")
        XCTAssertEqual(sync.status, ContinuityError.accountChanged.localizedDescription)
        XCTAssertFalse(sync.accountVerified); XCTAssertNil(sync.state.lastSync)
    }
    func testAccountSwitchBeforePushWithoutNotificationRetainsDirtyRecords() async throws {
        let cloud = EfficiencyTransport()
        let device = ContinuityDevice(id: UUID(), name: "Remote device")
        let key = ContinuityRecord.deviceKey(device.id)
        cloud.records[key] = ContinuityRecord(id: key, counter: 1, writer: device.id, payload: .device(device))
        let sync = BrowserContinuity(root: nil, deviceName: "Test device", transportFactory: { cloud })
        var applies = 0
        sync.configure(profiles: { [] }, source: { _ in nil }, importProfiles: { _ in applies += 1 })
        defer { sync.shutdown() }
        sync.setEnabled(true)
        let dirtyKeys = sync.state.dirtyKeys
        XCTAssertFalse(dirtyKeys.isEmpty)
        cloud.duringAccountCheck = { if cloud.accountChecks == 3 { cloud.accountID = "other-account" } }
        await sync.syncNow()
        XCTAssertEqual(cloud.accountChecks, 3); XCTAssertEqual(cloud.fetches, 1)
        XCTAssertEqual(sync.state.records[key], cloud.records[key])
        XCTAssertEqual(cloud.pushes, 0); XCTAssertTrue(cloud.lastPushed.isEmpty)
        XCTAssertEqual(sync.state.dirtyKeys, dirtyKeys); XCTAssertEqual(applies, 0)
        XCTAssertEqual(sync.state.accountID, "synthetic-account")
        XCTAssertEqual(sync.status, ContinuityError.accountChanged.localizedDescription)
        XCTAssertFalse(sync.accountVerified); XCTAssertNil(sync.state.lastSync)
    }
    func testLocalChangeReadsOnlyItsProfileAndDoesNotObtainAnotherSource() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        session.setProfileActive(false)
        let cloud = EfficiencyTransport(), unloaded = BrowserProfile(name: "Unloaded")
        let sync = BrowserContinuity(root: nil, deviceName: "Test device", transportFactory: { cloud })
        var obtains = 0, reads = 0
        sync.configure(profiles: { [.personal, unloaded] }, source: { profile in
            obtains += 1
            guard profile.isPersonal else { return nil }
            return ContinuitySource(session: session, preferences: { reads += 1; return [:] }, applyPreferences: { _ in })
        }, importProfiles: { _ in })
        defer { sync.shutdown(); session.shutdown() }
        sync.setEnabled(true); await sync.syncNow()
        let before = obtains
        session.importBookmarks([Bookmark(title: "Changed", url: URL(string: "https://example.test/local")!)])
        XCTAssertEqual(obtains, before)
        let captured = reads
        sync.refreshLocal()
        XCTAssertEqual(obtains, before); XCTAssertEqual(reads, captured)
    }
    func testPendingRequestDeliversAfterProfileRestorationWithoutRemoteChanges() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        session.setProfileActive(false)
        let cloud = EfficiencyTransport(), work = BrowserProfile(name: "Work")
        var profiles: [BrowserProfile] = [.personal]
        let sync = BrowserContinuity(root: nil, deviceName: "Test device", transportFactory: { cloud })
        sync.configure(profiles: { profiles }, source: { _ in ContinuitySource(session: session, preferences: { [:] }, applyPreferences: { _ in }) }, importProfiles: { _ in })
        defer { sync.shutdown(); session.shutdown() }
        sync.setEnabled(true); await sync.syncNow()
        let request = ContinuityOpenRequest(targetDeviceID: sync.state.deviceID, sourceDeviceID: UUID(), sourceDeviceName: "Test source", url: URL(string: "https://example.test/pending")!, title: "Pending", profileID: work.id)
        cloud.incoming = [ContinuityRecord(id: ContinuityRecord.openRequestKey(request.id), counter: 500, writer: request.sourceDeviceID, payload: .openRequest(request))]
        await sync.syncNow()
        XCTAssertNil(session.selectedTab?.url)
        profiles = [work]; sync.profilesChanged()
        await sync.syncNow()
        XCTAssertEqual(session.selectedTab?.url, request.url)
        XCTAssertNil(sync.state.records[ContinuityRecord.openRequestKey(request.id)]?.payload)
    }
    func testSendPageBypassesTheTwoSecondDebounce() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        session.setProfileActive(false)
        let cloud = EfficiencyTransport()
        let target = ContinuityDevice(id: UUID(), name: "Test target")
        let key = ContinuityRecord.deviceKey(target.id)
        cloud.records[key] = ContinuityRecord(id: key, counter: 1, writer: target.id, payload: .device(target))
        let sync = BrowserContinuity(root: nil, deviceName: "Test device", transportFactory: { cloud })
        sync.configure(profiles: { [.personal] }, source: { _ in ContinuitySource(session: session, preferences: { [:] }, applyPreferences: { _ in }) }, importProfiles: { _ in })
        defer { sync.shutdown(); session.shutdown() }
        sync.setEnabled(true); await sync.syncNow()
        let page = try XCTUnwrap(ContinuityPage(url: URL(string: "https://example.test/immediate"), title: "Immediate", profile: .personal, isPrivate: false))
        let before = cloud.pushes, start = ContinuousClock.now
        XCTAssertTrue(sync.sendPage(page, to: target.id))
        while cloud.pushes == before, start.duration(to: .now) < .seconds(1) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(cloud.pushes, before)
        XCTAssertLessThan(milliseconds(start.duration(to: .now)), 1000)
        XCTAssertTrue(cloud.lastPushed.contains { if case .openRequest = $0.payload { return true }; return false })
    }
    func testReplicaPersistsOnceForAChangedCycleAndOffStateDoesNotCreateAStore() async throws {
        _ = NSApplication.shared
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ContinuityStore(url: root.appendingPathComponent("continuity/replica.json"))
        let spy = EfficiencyReplicaStore(disk: disk), cloud = EfficiencyTransport()
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        session.setProfileActive(false)
        let off = BrowserContinuity(root: root, deviceName: "Test device", transportFactory: { cloud })
        var obtains = 0
        off.configure(profiles: { [.personal] }, source: { _ in obtains += 1; return nil }, importProfiles: { _ in })
        off.profilesChanged(); off.setForeground(false); off.shutdown()
        XCTAssertEqual(obtains, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.url.path))
        let sync = BrowserContinuity(root: root, deviceName: "Test device", transportFactory: { cloud }, replicaStore: spy)
        sync.configure(profiles: { [.personal] }, source: { _ in ContinuitySource(session: session, preferences: { [:] }, applyPreferences: { _ in }) }, importProfiles: { _ in })
        defer { sync.shutdown(); session.shutdown() }
        sync.setEnabled(true); await sync.syncNow()
        let before = spy.saves
        session.importBookmarks([Bookmark(title: "Changed", url: URL(string: "https://example.test/one-write")!)])
        await sync.syncNow()
        XCTAssertEqual(spy.saves - before, 1)
    }
    func testHistoryDeletionJournalIsDurableBeforeTheNextSync() async throws {
        _ = NSApplication.shared
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ContinuityStore(url: root.appendingPathComponent("continuity/replica.json"))
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        session.setProfileActive(false)
        let cloud = EfficiencyTransport()
        let history = HistoryEntry(title: "Erase", url: URL(string: "https://example.test/erase")!)
        let key = ContinuityRecord.historyKey(BrowserProfile.personalID, history.id)
        cloud.records[key] = ContinuityRecord(id: key, counter: 1, writer: UUID(), payload: .history(BrowserProfile.personalID, history))
        let sync = BrowserContinuity(root: root, deviceName: "Test device", transportFactory: { cloud })
        sync.configure(profiles: { [.personal] }, source: { _ in ContinuitySource(session: session, preferences: { [:] }, applyPreferences: { _ in }) }, importProfiles: { _ in })
        defer { sync.shutdown(); session.shutdown() }
        sync.setEnabled(true); await sync.syncNow()
        XCTAssertEqual(session.history, [history])
        session.clearHistory()
        let durable = try XCTUnwrap(disk.load())
        XCTAssertNil(durable.records[key]?.payload)
        XCTAssertTrue(durable.historyWasCleared(BrowserProfile.personalID, history.visitedAt))
        XCTAssertTrue(durable.dirtyKeys.contains(key))
    }
    func testPausingDuringFetchPersistsTheOptOutBeforeReturning() async throws {
        _ = NSApplication.shared
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ContinuityStore(url: root.appendingPathComponent("continuity/replica.json"))
        let cloud = EfficiencyTransport()
        let sync = BrowserContinuity(root: root, deviceName: "Test device", transportFactory: { cloud })
        defer { sync.shutdown() }
        sync.setEnabled(true); await sync.syncNow()
        let pushes = cloud.pushes
        cloud.duringFetch = { sync.setEnabled(false) }
        await sync.syncNow()
        XCTAssertFalse(try XCTUnwrap(disk.load()).enabled)
        XCTAssertEqual(cloud.pushes, pushes)
    }
    private func milliseconds(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
}

@MainActor private final class EfficiencyTransport: ContinuityTransport {
    var records: [String: ContinuityRecord] = [:]
    var incoming: [ContinuityRecord] = []
    var fetches = 0, pushes = 0, accountChecks = 0
    var lastPushed: [ContinuityRecord] = []
    var failPush = false
    var accountID = "synthetic-account"
    var duringAccountCheck: (() -> Void)?
    var duringFetch: (() -> Void)?
    private var accountChanged: (@MainActor () -> Void)?
    func watchAccountChanges(_ handler: @escaping @MainActor () -> Void) { accountChanged = handler }
    func notifyAccountChanged() { accountChanged?() }
    func accountIdentifier() async throws -> String {
        accountChecks += 1; duringAccountCheck?(); return accountID
    }
    private var fetched = false
    func fetch(allowZoneCreation: Bool) async throws -> [ContinuityRecord] {
        fetches += 1
        duringFetch?()
        defer { fetched = true; incoming = [] }
        return fetched ? incoming : Array(records.values)
    }
    func push(_ values: [ContinuityRecord]) async throws -> [ContinuityRecord] {
        pushes += 1; lastPushed = values
        if failPush { throw URLError(.networkConnectionLost) }
        for value in values { records[value.id] = value }
        return []
    }
}

private final class EfficiencyReplicaStore: ContinuityReplicaStore, @unchecked Sendable {
    let disk: ContinuityStore
    private let lock = NSLock()
    private var count = 0
    var saves: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(disk: ContinuityStore) { self.disk = disk }
    func load() throws -> ContinuityReplica? { try disk.load() }
    func save(_ state: ContinuityReplica) throws {
        XCTAssertFalse(Thread.isMainThread)
        try disk.save(state)
        lock.lock(); count += 1; lock.unlock()
    }
}
