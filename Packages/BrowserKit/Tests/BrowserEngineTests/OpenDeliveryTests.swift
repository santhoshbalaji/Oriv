import AppKit
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

@MainActor final class OpenDeliveryTests: XCTestCase {
    private func session(store: (any BrowserSessionStore)? = nil, privateOnly: Bool = false) -> BrowserSession {
        _ = NSApplication.shared
        let value = BrowserSession(store: store, dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil), externalPrivate: privateOnly)
        value.setProfileActive(false); return value
    }
    private func coordinator(_ transport: MemoryContinuityTransport, session: BrowserSession, profile: BrowserProfile = .personal, root: URL? = nil) -> BrowserContinuity {
        let sync = BrowserContinuity(root: root, deviceName: "Test device", transportFactory: { transport })
        sync.configure(profiles: { [profile] }, source: { _ in ContinuitySource(session: session, preferences: { [:] }, applyPreferences: { _ in }) }, importProfiles: { _ in })
        return sync
    }
    func testTwoDevicesTargetOnceAndPreserveExistingRegularAndPrivateTabs() async throws {
        let cloud = MemoryContinuityTransport(), mac = session(), phone = session(), thirdSession = session()
        let first = coordinator(cloud, session: mac), second = coordinator(cloud, session: phone), third = coordinator(cloud, session: thirdSession)
        defer { [first, second, third].forEach { $0.shutdown() }; [mac, phone, thirdSession].forEach { $0.shutdown() } }
        let regular = phone.addTab(url: URL(string: "https://example.test/edited"), load: false)
        let privateTab = phone.addTab(isPrivate: true, load: false)
        first.setEnabled(true); second.setEnabled(true); third.setEnabled(true)
        await first.syncNow(); await second.syncNow(); await third.syncNow(); await first.syncNow()
        let page = try XCTUnwrap(ContinuityPage(url: URL(string: "https://example.test/sent"), title: "Sent page", profile: .personal, isPrivate: false))
        var focus: UUID?
        second.didOpenRequest = { profile, tab in XCTAssertEqual(profile, BrowserProfile.personalID); focus = tab }
        XCTAssertTrue(first.sendPage(page, to: second.state.deviceID))
        await first.syncNow(); await third.syncNow(); await second.syncNow()
        XCTAssertTrue(thirdSession.tabs.allSatisfy { $0.url != page.url })
        XCTAssertEqual(phone.tabs.filter { $0.url == page.url }.count, 1)
        XCTAssertEqual(phone.selectedTabID, focus)
        XCTAssertTrue(phone.tabs.contains { $0 === regular }); XCTAssertTrue(phone.tabs.contains { $0 === privateTab })
        let count = phone.tabs.count
        await second.syncNow(); await first.syncNow(); await second.syncNow()
        XCTAssertEqual(phone.tabs.count, count)
        XCTAssertTrue(second.state.openRequests(targeting: second.state.deviceID).isEmpty)
        XCTAssertEqual(second.notice, "Opened from Test device")
    }
    func testSendRequiresVerifiedAccountKnownTargetAndRegularPage() async throws {
        let cloud = MemoryContinuityTransport(), local = session()
        let sync = coordinator(cloud, session: local)
        defer { sync.shutdown(); local.shutdown() }
        let page = try XCTUnwrap(ContinuityPage(url: URL(string: "https://example.test"), title: "Page", profile: .personal, isPrivate: false))
        XCTAssertFalse(sync.sendPage(page, to: UUID()))
        sync.setEnabled(true); await sync.syncNow()
        XCTAssertFalse(sync.canSendPage); XCTAssertFalse(sync.sendPage(page, to: UUID()))
        XCTAssertNil(ContinuityPage(url: page.url, title: page.title, profile: .personal, isPrivate: true))
        XCTAssertNil(ContinuityPage(url: URL(string: "file:///tmp/page"), title: "File", profile: .personal, isPrivate: false))
        sync.setEnabled(false); XCTAssertFalse(sync.canSendPage)
    }
    func testDurableReceiptPreventsReopenAfterClosedTabRelaunchAndFailedUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = SessionFileStore(fileURL: root.appendingPathComponent("session.json"))
        let cloud = MemoryContinuityTransport(), local = session(store: disk)
        let sync = coordinator(cloud, session: local, root: root)
        sync.setEnabled(true); await sync.syncNow()
        let request = ContinuityOpenRequest(targetDeviceID: sync.state.deviceID, sourceDeviceID: UUID(), sourceDeviceName: "Test Mac", url: URL(string: "https://example.test/once")!, title: "Once", profileID: BrowserProfile.personalID)
        let record = ContinuityRecord(id: ContinuityRecord.openRequestKey(request.id), counter: 500, writer: request.sourceDeviceID, payload: .openRequest(request))
        cloud.records[record.id] = record; cloud.failPush = true
        await sync.syncNow()
        XCTAssertEqual(local.tabs.filter { $0.id == request.id }.count, 1)
        // Simulate interruption before the replica's tombstone became durable, by restoring its
        // already-journaled incoming record while preserving the session's atomic receipt.
        var interrupted = sync.state; try interrupted.merge([ContinuityRecord(id: record.id, counter: 900, writer: request.sourceDeviceID, payload: record.payload)])
        interrupted.pendingApplication = true
        local.closeTab(request.id); local.saveNow(); sync.shutdown(); local.shutdown()
        try ContinuityStore(url: root.appendingPathComponent("continuity/replica.json")).save(interrupted)
        let reopened = session(store: disk), recovered = coordinator(cloud, session: reopened, root: root)
        defer { reopened.shutdown(); recovered.shutdown() }
        cloud.failPush = false; await recovered.syncNow(); await recovered.syncNow()
        XCTAssertTrue(reopened.tabs.allSatisfy { $0.url != request.url })
        XCTAssertNil(recovered.state.records[record.id]?.payload)
    }
    func testArchivedOrMissingProfileWaitsWithoutFallbackAndExpires() async throws {
        let cloud = MemoryContinuityTransport(), local = session()
        let sync = coordinator(cloud, session: local)
        defer { sync.shutdown(); local.shutdown() }
        sync.setEnabled(true); await sync.syncNow()
        var request = ContinuityOpenRequest(targetDeviceID: sync.state.deviceID, sourceDeviceID: UUID(), sourceDeviceName: "Test Mac", url: URL(string: "https://example.test/work")!, title: "Work", profileID: UUID())
        let key = ContinuityRecord.openRequestKey(request.id)
        cloud.records[key] = ContinuityRecord(id: key, counter: 500, writer: request.sourceDeviceID, payload: .openRequest(request))
        let count = local.tabs.count
        await sync.syncNow()
        XCTAssertEqual(local.tabs.count, count); XCTAssertEqual(sync.state.openRequests(targeting: sync.state.deviceID).count, 1)
        request.createdAt = .now.addingTimeInterval(-8 * 24 * 60 * 60)
        cloud.records[key] = ContinuityRecord(id: key, counter: 900, writer: request.sourceDeviceID, payload: .openRequest(request))
        await sync.syncNow()
        XCTAssertEqual(local.tabs.count, count); XCTAssertNil(sync.state.records[key]?.payload)
    }
    func testMatchingNonPersonalProfileReceivesWithoutChangingOtherSession() async throws {
        let cloud = MemoryContinuityTransport(), personal = session(), workSession = session(), work = BrowserProfile(name: "Work")
        let sync = BrowserContinuity(root: nil, deviceName: "Phone", transportFactory: { cloud })
        sync.configure(profiles: { [.personal, work] }, source: { profile in
            ContinuitySource(session: profile.id == work.id ? workSession : personal, preferences: { [:] }, applyPreferences: { _ in })
        }, importProfiles: { _ in })
        defer { sync.shutdown(); personal.shutdown(); workSession.shutdown() }
        sync.setEnabled(true); await sync.syncNow()
        let request = ContinuityOpenRequest(targetDeviceID: sync.state.deviceID, sourceDeviceID: UUID(), sourceDeviceName: "Test Mac", url: URL(string: "https://example.test/work")!, title: "Work", profileID: work.id)
        let key = ContinuityRecord.openRequestKey(request.id)
        cloud.records[key] = ContinuityRecord(id: key, counter: 500, writer: request.sourceDeviceID, payload: .openRequest(request))
        await sync.syncNow()
        XCTAssertEqual(workSession.selectedTab?.url, request.url)
        XCTAssertNil(personal.selectedTab?.url)
    }
    func testAccountMismatchDoesNotApplyJournaledRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var replica = ContinuityReplica(deviceName: "Phone"); replica.enabled = true; replica.pendingApplication = true
        try replica.bindAccount("original-account")
        let request = ContinuityOpenRequest(targetDeviceID: replica.deviceID, sourceDeviceID: UUID(), sourceDeviceName: "Test Mac", url: URL(string: "https://example.test/wrong-account")!, title: "Page", profileID: BrowserProfile.personalID)
        try replica.merge([ContinuityRecord(id: ContinuityRecord.openRequestKey(request.id), counter: 50, writer: request.sourceDeviceID, payload: .openRequest(request))])
        try ContinuityStore(url: root.appendingPathComponent("continuity/replica.json")).save(replica)
        let cloud = MemoryContinuityTransport(), local = session(), sync = coordinator(cloud, session: local, root: root)
        defer { sync.shutdown(); local.shutdown() }
        await sync.syncNow()
        XCTAssertFalse(sync.accountVerified); XCTAssertNil(local.selectedTab?.url); XCTAssertEqual(cloud.pushes, 0)
    }
    func testExternalPrivateEnforcesIsolationAndResetsStoreAfterLastTab() throws {
        let regular = session(), external = session(privateOnly: true)
        defer { regular.shutdown(); external.shutdown() }
        let regularPrivate = regular.addTab(isPrivate: true, load: false)
        let first = external.addTab(url: URL(string: "https://example.test/external"), load: false)
        let second = external.addTab(load: false)
        XCTAssertTrue(external.tabs.allSatisfy(\.isPrivate))
        XCTAssertFalse(first.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(first.webView.configuration.websiteDataStore === second.webView.configuration.websiteDataStore)
        XCTAssertFalse(first.webView.configuration.websiteDataStore === regularPrivate.webView.configuration.websiteDataStore)
        first.onVisit?(first.url!, "External")
        XCTAssertTrue(external.history.isEmpty); XCTAssertTrue(external.snapshot().tabs.isEmpty)
        let store = first.webView.configuration.websiteDataStore
        for tab in external.tabs { external.closeTab(tab.id) }
        XCTAssertTrue(external.tabs.isEmpty)
        let fresh = external.addTab(load: false)
        XCTAssertFalse(fresh.webView.configuration.websiteDataStore === store)
    }
    func testRequestIdentityCollisionAppendsWithoutReplacingExistingTab() throws {
        let local = session()
        defer { local.shutdown() }
        let existing = try XCTUnwrap(local.selectedTab)
        let request = ContinuityOpenRequest(id: existing.id, targetDeviceID: UUID(), sourceDeviceID: UUID(), sourceDeviceName: "Test Mac", url: URL(string: "https://example.test/collision")!, title: "Page", profileID: BrowserProfile.personalID)
        XCTAssertTrue(try local.applyOpenRequest(request))
        XCTAssertEqual(local.tabs.count, 2)
        XCTAssertTrue(local.tabs.first === existing); XCTAssertNil(existing.url)
        XCTAssertNotEqual(local.selectedTabID, existing.id); XCTAssertEqual(local.selectedTab?.url, request.url)
        XCTAssertFalse(try local.applyOpenRequest(request))
    }
    func testFailedSessionWriteLeavesNoReceiptAndRetriesSafely() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FailingDeliveryStore(url: root.appendingPathComponent("session.json")), local = session(store: nil)
        local.shutdown()
        let target = session(store: store)
        defer { target.shutdown() }
        let request = ContinuityOpenRequest(targetDeviceID: UUID(), sourceDeviceID: UUID(), sourceDeviceName: "Test Mac", url: URL(string: "https://example.test/retry")!, title: "Retry", profileID: BrowserProfile.personalID)
        let before = target.tabs.map(\.id)
        XCTAssertThrowsError(try target.applyOpenRequest(request)); XCTAssertEqual(target.tabs.map(\.id), before)
        store.fail = false
        XCTAssertTrue(try target.applyOpenRequest(request)); XCTAssertFalse(try target.applyOpenRequest(request))
        XCTAssertEqual(try store.disk.load().snapshot?.appliedOpenRequests, [request.id])
    }
}

private final class FailingDeliveryStore: BrowserSessionStore {
    let disk: SessionFileStore
    var fail = true
    init(url: URL) { disk = SessionFileStore(fileURL: url) }
    func load() throws -> SessionLoadResult { try disk.load() }
    func save(_ snapshot: BrowserSnapshot, discardPrevious: Bool) throws -> Bool {
        if fail { throw URLError(.cannotWriteToFile) }
        return try disk.save(snapshot, discardPrevious: discardPrevious)
    }
}
