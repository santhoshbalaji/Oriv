import Foundation
import XCTest
import BrowserCore
import CloudKit
@testable import BrowserEngine

@MainActor final class ContinuityPushTests: XCTestCase {
    func testZoneSubscriptionContainsNoUserFacingNotificationOrRecordContent() throws {
        let zone = CKRecordZone.ID(zoneName: "BrowserContinuityV1", ownerName: CKCurrentUserDefaultName)
        let subscription = ContinuityCloudTransport.makePushSubscription(zoneID: zone)
        let info = try XCTUnwrap(subscription.notificationInfo)
        XCTAssertEqual(subscription.zoneID, zone)
        XCTAssertEqual(subscription.subscriptionID, ContinuityPushSubscription.id)
        XCTAssertTrue(info.shouldSendContentAvailable)
        XCTAssertFalse(info.shouldBadge)
        XCTAssertNil(info.alertBody); XCTAssertNil(info.alertLocalizationKey); XCTAssertNil(info.soundName)
        XCTAssertNil(info.desiredKeys)
    }
    func testSubscriptionSavedOnceAndRememberedAcrossTransportLifetimes() async throws {
        let suite = "ContinuityPushTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = SubscriptionServer()
        let first = server.manager(defaults: defaults)
        try await first.ensure(account: "account-a"); try await first.ensure(account: "account-a")
        XCTAssertEqual(server.saves, 1); XCTAssertEqual(server.reads, 0)
        let relaunched = server.manager(defaults: defaults)
        try await relaunched.ensure(account: "account-a")
        XCTAssertEqual(server.saves, 1); XCTAssertEqual(server.reads, 1)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("OrivContinuityPush.") })
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.contains("account-a") })
    }

    func testSubscriptionRecreatedAfterZoneResetAccountChangeAndUnknownSubscription() async throws {
        let suite = "ContinuityPushTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = SubscriptionServer()
        let subscription = server.manager(defaults: defaults)
        try await subscription.ensure(account: "account-a")
        server.saved = false; subscription.invalidate() // zone reset
        try await subscription.ensure(account: "account-a")
        XCTAssertEqual(server.saves, 2)
        try await subscription.ensure(account: "account-b")
        XCTAssertEqual(server.saves, 3)
        server.saved = false // CloudKit's unknownItem is mapped to exists == false.
        let relaunched = server.manager(defaults: defaults)
        try await relaunched.ensure(account: "account-b")
        XCTAssertEqual(server.saves, 4)
    }

    func testSubscriptionFailureDoesNotCacheSuccessAndRetries() async throws {
        let server = SubscriptionServer()
        server.fail = true
        let subscription = server.manager(defaults: nil)
        do { try await subscription.ensure(account: "account-a"); XCTFail("Expected failure") } catch {}
        server.fail = false
        try await subscription.ensure(account: "account-a")
        XCTAssertEqual(server.saves, 2)
    }

    func testAccountChangeWhileSavingCannotPersistStaleSubscriptionSuccess() async throws {
        let server = SubscriptionServer()
        let subscription = server.manager(defaults: nil)
        server.duringSave = { subscription.invalidate() }
        do { try await subscription.ensure(account: "account-a"); XCTFail("Expected invalidation") } catch is CancellationError {}
        server.duringSave = nil
        try await subscription.ensure(account: "account-a")
        XCTAssertEqual(server.saves, 2)
    }

    func testHealthRequiresAllThreeSignalsAndExpiresAtTwentyFourHours() {
        var health = ContinuityPushHealth()
        let date = Date(timeIntervalSince1970: 1_000)
        health.bind("account-a"); health.registration(true); health.subscription(true)
        XCTAssertEqual(health.pollInterval(at: date), 30)
        health.receivedPush(account: "account-b", at: date)
        XCTAssertFalse(health.isHealthy(at: date))
        health.receivedPush(account: "account-a", at: date)
        XCTAssertEqual(health.pollInterval(at: date), 300)
        XCTAssertEqual(health.nextPollDelay(at: date.addingTimeInterval(86_399)), 1)
        XCTAssertEqual(health.pollInterval(at: date.addingTimeInterval(86_400)), 30)
        XCTAssertFalse(health.isHealthy(at: date.addingTimeInterval(-1)))
    }

    func testHealthFailsClosedForRegistrationSubscriptionAndAccountChanges() {
        let date = Date(timeIntervalSince1970: 1_000)
        var health = ContinuityPushHealth()
        health.bind("account-a"); health.registration(true); health.subscription(true)
        health.receivedPush(account: "account-a", at: date)
        health.registration(false); XCTAssertEqual(health.pollInterval(at: date), 30)
        health.registration(true); XCTAssertFalse(health.isHealthy(at: date))
        health.receivedPush(account: "account-a", at: date)
        health.subscription(false); XCTAssertFalse(health.isHealthy(at: date))
        health.subscription(true); health.receivedPush(account: "account-a", at: date)
        health.bind(nil); health.bind("account-b")
        XCTAssertFalse(health.isHealthy(at: date)); XCTAssertNil(health.lastPush)
    }

    func testPollDetectsUnannouncedChangesButInitialFetchAndEchoesDoNotInvalidateHealth() {
        let date = Date(timeIntervalSince1970: 1_000)
        var health = ContinuityPushHealth()
        health.bind("account-a"); health.registration(true); health.subscription(true)
        health.receivedPush(account: "account-a", at: date)
        XCTAssertFalse(health.fetched(remoteChanges: true, polling: true, at: date))
        XCTAssertFalse(health.fetched(remoteChanges: false, polling: true, at: date.addingTimeInterval(300)))
        XCTAssertTrue(health.isHealthy(at: date.addingTimeInterval(300)))
        XCTAssertTrue(health.fetched(remoteChanges: true, polling: true, at: date.addingTimeInterval(600)))
        XCTAssertEqual(health.pollInterval(at: date.addingTimeInterval(600)), 30)
        health.subscription(true)
        XCTAssertFalse(health.isHealthy(at: date.addingTimeInterval(600)))
    }

    func testPushBypassesDebounceAndCoalescesBurstIntoOneDeltaFetch() async throws {
        let cloud = PushTransport()
        // Use the same factory for all cycles, including registration-triggered work.
        let coordinator = makeSync(cloud)
        defer { coordinator.shutdown() }
        coordinator.setEnabled(true); await coordinator.syncNow()
        let before = cloud.fetches
        var results: [ContinuityPushFetchResult] = []
        for _ in 0..<20 { coordinator.receiveContinuityPush { results.append($0) } }
        try await wait { results.count == 20 }
        XCTAssertEqual(cloud.fetches - before, 1)
        XCTAssertEqual(results, Array(repeating: .noData, count: 20))
    }

    func testPushDuringFetchCoalescesIntoOneImmediateFollowUpAndCompletesAfterThatFetch() async throws {
        let cloud = PushTransport(), sync = makeSync(cloud)
        defer { sync.shutdown() }
        sync.setEnabled(true); await sync.syncNow()
        let before = cloud.fetches
        var results: [ContinuityPushFetchResult] = []
        cloud.duringFetch = {
            cloud.duringFetch = nil
            for _ in 0..<10 { sync.receiveContinuityPush { results.append($0) } }
            XCTAssertTrue(results.isEmpty)
        }
        await sync.syncNow()
        try await wait { results.count == 10 }
        XCTAssertEqual(cloud.fetches - before, 2)
    }

    func testCoordinatorSwitchesPollIntervalsAndRechecksSubscriptionAfterMissedPush() async throws {
        let cloud = PushTransport()
        var date = Date(timeIntervalSince1970: 1_000)
        let sync = BrowserContinuity(root: nil, deviceName: "Test", transportFactory: { cloud }, now: { date })
        defer { sync.shutdown() }
        sync.setEnabled(true); sync.remoteNotificationRegistration(succeeded: true); await sync.syncNow()
        XCTAssertEqual(sync.foregroundPollInterval, 30)
        sync.receiveContinuityPush(accountID: cloud.account); await sync.syncNow()
        XCTAssertTrue(sync.isPushHealthy); XCTAssertEqual(sync.foregroundPollInterval, 300)
        date.addTimeInterval(300)
        cloud.incoming = [remoteBookmark()]
        await sync.pollNow()
        XCTAssertEqual(cloud.invalidations, 1); XCTAssertEqual(sync.foregroundPollInterval, 30)
        sync.receiveContinuityPush(accountID: cloud.account); await sync.syncNow()
        XCTAssertEqual(sync.foregroundPollInterval, 300)
        date.addTimeInterval(86_400)
        XCTAssertEqual(sync.foregroundPollInterval, 30)
        await sync.pollNow()
        XCTAssertEqual(sync.foregroundPollInterval, 30)
    }

    func testNoEntitlementRegistrationFailureAndSubscriptionErrorPreservePollingAndUploads() async throws {
        let cloud = PushTransport(), sync = makeSync(cloud)
        defer { sync.shutdown() }
        var registrations = 0
        sync.configurePushRegistration { registrations += 1; sync.remoteNotificationRegistration(succeeded: false) }
        XCTAssertEqual(registrations, 0)
        cloud.failSubscription = true
        sync.setEnabled(true); await sync.syncNow()
        XCTAssertEqual(registrations, 1); XCTAssertTrue(sync.accountVerified)
        XCTAssertNotNil(sync.state.lastSync); XCTAssertGreaterThan(cloud.pushes, 0)
        XCTAssertEqual(sync.foregroundPollInterval, 30)
        cloud.failSubscription = false
        sync.setForeground(true); await sync.syncNow()
        XCTAssertEqual(registrations, 2); XCTAssertEqual(sync.foregroundPollInterval, 30)
    }

    func testPushWithoutAnOwnerOrFromAnotherAccountFetchesButCannotProveHealth() async {
        let cloud = PushTransport(), sync = makeSync(cloud)
        defer { sync.shutdown() }
        sync.setEnabled(true); sync.remoteNotificationRegistration(succeeded: true); await sync.syncNow()
        let before = cloud.fetches
        sync.receiveContinuityPush(); await sync.syncNow()
        XCTAssertFalse(sync.isPushHealthy)
        sync.receiveContinuityPush(accountID: "another-account"); await sync.syncNow()
        XCTAssertFalse(sync.isPushHealthy); XCTAssertEqual(cloud.fetches, before + 2)
        sync.receiveContinuityPush(accountID: cloud.account); await sync.syncNow()
        XCTAssertTrue(sync.isPushHealthy)
    }

    func testPushCompletionReportsNewDataFailureUnrelatedAndOptOutExactlyOnce() async throws {
        let cloud = PushTransport(), sync = makeSync(cloud)
        defer { sync.shutdown() }
        var results: [ContinuityPushFetchResult] = []
        XCTAssertFalse(sync.receiveRemoteNotification(["aps": ["content-available": 1]]) { results.append($0) })
        XCTAssertFalse(sync.receiveContinuityPush { results.append($0) })
        XCTAssertEqual(results, [.noData, .noData])
        sync.setEnabled(true); await sync.syncNow()
        cloud.incoming = [remoteBookmark()]
        sync.receiveContinuityPush { results.append($0) }; await sync.syncNow()
        XCTAssertEqual(results.last, .newData)
        cloud.failFetch = true
        sync.receiveContinuityPush { results.append($0) }; await sync.syncNow()
        XCTAssertEqual(results.last, .failed)
        sync.shutdown(); XCTAssertEqual(results.count, 4)
    }

    func testBackgroundDeadlineCompletesOnceAndRejectsLateFetchBeforeUpload() async throws {
        let cloud = PushTransport()
        let sync = BrowserContinuity(root: nil, deviceName: "Test", transportFactory: { cloud }, pushCompletionTimeout: .milliseconds(30))
        defer { sync.shutdown() }
        sync.setEnabled(true); await sync.syncNow()
        let pushes = cloud.pushes
        cloud.suspendFetch = true
        var results: [ContinuityPushFetchResult] = []
        sync.receiveContinuityPush { results.append($0) }
        try await wait { sync.isSyncing }
        sync.requestSync(immediate: true) // Queued work must not escape the expired opportunity.
        try await wait { results.count == 1 }
        XCTAssertEqual(results, [.failed]); XCTAssertTrue(cloud.cancelled)
        cloud.resumeFetch()
        try await wait { !sync.isSyncing }
        XCTAssertEqual(results.count, 1); XCTAssertEqual(cloud.pushes, pushes)
        XCTAssertFalse(sync.accountVerified)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(cloud.fetches, 2)
    }

    func testAccountChangeInvalidatesPushProofAndDoesNotUploadAnotherAccountsData() async throws {
        let cloud = PushTransport(), sync = makeSync(cloud)
        defer { sync.shutdown() }
        sync.setEnabled(true); sync.remoteNotificationRegistration(succeeded: true); await sync.syncNow()
        sync.receiveContinuityPush(accountID: cloud.account); await sync.syncNow()
        XCTAssertTrue(sync.isPushHealthy)
        let pushes = cloud.pushes
        cloud.account = "account-b"; cloud.accountChanged?()
        await sync.syncNow()
        XCTAssertEqual(sync.foregroundPollInterval, 30); XCTAssertFalse(sync.accountVerified)
        XCTAssertEqual(cloud.pushes, pushes); XCTAssertGreaterThan(cloud.invalidations, 0)
    }

    func testSubscriptionErrorAndRemoteResetDropHealthWithoutBlockingLocalBrowsing() async throws {
        let cloud = PushTransport(), sync = makeSync(cloud)
        defer { sync.shutdown() }
        sync.setEnabled(true); sync.remoteNotificationRegistration(succeeded: true); await sync.syncNow()
        sync.receiveContinuityPush(accountID: cloud.account); await sync.syncNow()
        XCTAssertTrue(sync.isPushHealthy)
        cloud.failSubscription = true; await sync.syncNow()
        XCTAssertFalse(sync.isPushHealthy); XCTAssertTrue(sync.accountVerified)
        cloud.failSubscription = false; sync.receiveContinuityPush(accountID: cloud.account); await sync.syncNow()
        XCTAssertTrue(sync.isPushHealthy)
        cloud.resetZone = true; await sync.syncNow()
        XCTAssertEqual(sync.foregroundPollInterval, 30); XCTAssertFalse(sync.accountVerified)
        XCTAssertGreaterThan(cloud.invalidations, 0)
    }

    private func makeSync(_ cloud: PushTransport = PushTransport()) -> BrowserContinuity {
        BrowserContinuity(root: nil, deviceName: "Test", transportFactory: { cloud })
    }
    private func remoteBookmark() -> ContinuityRecord {
        let bookmark = Bookmark(title: "Remote", url: URL(string: "https://example.test/remote")!)
        return ContinuityRecord(id: ContinuityRecord.bookmarkKey(BrowserProfile.personalID, bookmark.id), counter: 10, writer: UUID(), payload: .bookmark(BrowserProfile.personalID, bookmark))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(predicate(), "Push work should bypass the two-second debounce")
    }
}

@MainActor private final class SubscriptionServer {
    var saved = false, fail = false
    var saves = 0, reads = 0
    var duringSave: (() -> Void)?
    func manager(defaults: UserDefaults?) -> ContinuityPushSubscription {
        ContinuityPushSubscription(namespace: "synthetic-container|development|zone", defaults: defaults, exists: { _ in
            self.reads += 1; return self.saved
        }, save: { id in
            XCTAssertEqual(id, ContinuityPushSubscription.id)
            self.saves += 1; self.duringSave?()
            if self.fail { throw URLError(.notConnectedToInternet) }
            self.saved = true
        })
    }
}

@MainActor private final class PushTransport: ContinuityTransport {
    var account = "account-a"
    var incoming: [ContinuityRecord] = []
    var fetches = 0, pushes = 0, invalidations = 0
    var failSubscription = false, failFetch = false, resetZone = false, cancelled = false
    var duringFetch: (() -> Void)?
    var accountChanged: (@MainActor () -> Void)?
    var suspendFetch = false
    private var continuation: CheckedContinuation<Void, Never>?
    func watchAccountChanges(_ handler: @escaping @MainActor () -> Void) { accountChanged = handler }
    func accountIdentifier() async throws -> String { account }
    func cancel() { cancelled = true }
    func invalidatePushSubscription() { invalidations += 1 }
    func ensurePushSubscription(accountID: String) async throws -> Bool {
        if failSubscription { throw URLError(.notConnectedToInternet) }
        return true
    }
    func fetch(allowZoneCreation: Bool) async throws -> [ContinuityRecord] {
        fetches += 1; duringFetch?()
        if suspendFetch { await withCheckedContinuation { continuation = $0 } }
        if resetZone { throw ContinuityError.remoteReset }
        if failFetch { throw URLError(.notConnectedToInternet) }
        defer { incoming = [] }
        return incoming
    }
    func resumeFetch() { continuation?.resume(); continuation = nil; suspendFetch = false }
    func push(_ records: [ContinuityRecord]) async throws -> [ContinuityRecord] { pushes += 1; return [] }
}
