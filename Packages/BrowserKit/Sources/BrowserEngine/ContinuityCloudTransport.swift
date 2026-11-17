import BrowserCore
import Foundation
@preconcurrency import CloudKit

@MainActor public protocol ContinuityTransport: AnyObject {
    func cancel()
    func watchAccountChanges(_ handler: @escaping @MainActor () -> Void)
    func accountIdentifier() async throws -> String
    /// Returns only changes since the last successfully fetched server token.
    func fetch(allowZoneCreation: Bool) async throws -> [ContinuityRecord]
    func push(_ records: [ContinuityRecord]) async throws -> [ContinuityRecord]
    func ensurePushSubscription(accountID: String) async throws -> Bool
    func invalidatePushSubscription()
}

public extension ContinuityTransport {
    func cancel() {}
    func watchAccountChanges(_ handler: @escaping @MainActor () -> Void) {}
    func ensurePushSubscription(accountID: String) async throws -> Bool { false }
    func invalidatePushSubscription() {}
}

/// The only CloudKit client in Oriv. Constructed after the user enables browser continuity.
@MainActor public final class ContinuityCloudTransport: ContinuityTransport {
    private let container: CKContainer
    private let zone = CKRecordZone.ID(zoneName: "BrowserContinuityV1", ownerName: CKCurrentUserDefaultName)
    private var cancelled = false
    private var accountObserver: (any NSObjectProtocol)?
    public func watchAccountChanges(_ handler: @escaping @MainActor () -> Void) {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
    public func cancel() {
        cancelled = true
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver); self.accountObserver = nil }
    }
    private func checkCancellation() throws { if cancelled { throw CancellationError() }; try Task.checkCancellation() }
    private var zoneVerified = false
    private var token: CKServerChangeToken?
    private var server: [String: CKRecord] = [:]
    private var unknownKeys: Set<String> = []
    private var account: String?
    private lazy var subscription = ContinuityPushSubscription(
        namespace: "\(container.containerIdentifier ?? "")|\(Bundle.main.bundleIdentifier ?? "")|\(Bundle.main.object(forInfoDictionaryKey: "OrivPushEnvironment") as? String ?? "")|\(zone.zoneName)",
        defaults: .standard,
        exists: { [database, zone] id in
            do {
                let saved = try await database.subscription(for: id)
                guard let info = saved.notificationInfo else { return false }
                return (saved as? CKRecordZoneSubscription)?.zoneID == zone && info.shouldSendContentAvailable &&
                    !info.shouldBadge && info.alertBody == nil && info.alertLocalizationKey == nil && info.soundName == nil && info.desiredKeys == nil
            } catch let error as CKError where error.code == .unknownItem { return false }
        },
        save: { [database, zone] id in
            _ = try await database.save(Self.makePushSubscription(zoneID: zone, subscriptionID: id))
        })
    static func makePushSubscription(zoneID: CKRecordZone.ID, subscriptionID: String = ContinuityPushSubscription.id) -> CKRecordZoneSubscription {
        let value = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        value.notificationInfo = info
        return value
    }
    public func ensurePushSubscription(accountID: String) async throws -> Bool {
        try checkCancellation()
        guard zoneVerified, account == accountID else { return false }
        try await subscription.ensure(account: accountID)
        try checkCancellation()
        return true
    }
    public func invalidatePushSubscription() { subscription.invalidate() }
    static func continuityNotification(_ userInfo: [AnyHashable: Any], containerIdentifier: String) -> ContinuityPushEnvelope? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKRecordZoneNotification,
              notification.containerIdentifier == containerIdentifier, notification.subscriptionID == ContinuityPushSubscription.id,
              notification.databaseScope == .private, notification.recordZoneID?.zoneName == "BrowserContinuityV1" else { return nil }
        return ContinuityPushEnvelope(accountID: notification.subscriptionOwnerUserRecordID?.recordName)
    }
    public init(containerIdentifier: String) { container = CKContainer(identifier: containerIdentifier) }
    private var database: CKDatabase { container.privateCloudDatabase }
    public func accountIdentifier() async throws -> String {
        try checkCancellation()
        guard try await container.accountStatus() == .available else { throw ContinuityError.noAccount }
        let identifier = try await container.userRecordID().recordName
        try checkCancellation()
        if let account, account != identifier {
            invalidatePushSubscription(); zoneVerified = false; token = nil; server = [:]; unknownKeys = []
        }
        account = identifier
        return identifier
    }
    public func fetch(allowZoneCreation: Bool) async throws -> [ContinuityRecord] {
        try checkCancellation()
        if !zoneVerified {
            do { _ = try await database.recordZone(for: zone) }
            catch let error as CKError where error.code == .zoneNotFound {
                invalidatePushSubscription()
                guard allowZoneCreation, error.userInfo[CKErrorUserDidResetEncryptedDataKey] == nil else { throw ContinuityError.remoteReset }
                _ = try await database.save(CKRecordZone(zoneID: zone))
            }
            zoneVerified = true
        }
        var changes: [ContinuityRecord] = []
        var next = server, nextToken = token
        var nextUnknown = unknownKeys
        do {
            repeat {
                try checkCancellation()
                let page = try await database.recordZoneChanges(inZoneWith: zone, since: nextToken, resultsLimit: 200)
                // Physical deletion indicates a server-side reset. Application deletions use tombstone records.
                guard page.deletions.isEmpty else { throw ContinuityError.remoteReset }
                for (_, result) in page.modificationResultsByID {
                    let record = try result.get().record
                    if let value = try decode(record) {
                        changes.append(value); nextUnknown.remove(record.recordID.recordName)
                    } else { nextUnknown.insert(record.recordID.recordName) }
                    next[record.recordID.recordName] = record
                }
                guard next.count <= 100_000 else { throw ContinuityError.storageFull }
                nextToken = page.changeToken
                if !page.moreComing { break }
            } while true
        } catch let error as CKError where error.code == .changeTokenExpired {
            token = nil; server = [:]; unknownKeys = []
            return try await fetch(allowZoneCreation: false)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            zoneVerified = false; invalidatePushSubscription()
            throw ContinuityError.remoteReset
        }
        // Keep the old cache/token if any page fails. A partial download must never look like deletion.
        server = next; token = nextToken; unknownKeys = nextUnknown
        return changes
    }
    public func push(_ values: [ContinuityRecord]) async throws -> [ContinuityRecord] {
        do { return try await pushDirty(values) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            zoneVerified = false; invalidatePushSubscription(); throw ContinuityError.remoteReset
        }
    }
    private func pushDirty(_ values: [ContinuityRecord]) async throws -> [ContinuityRecord] {
        try checkCancellation()
        var changes: [CKRecord] = []
        for value in values {
            guard !unknownKeys.contains(value.id) else { throw ContinuityError.newerFormat }
            let record = server[value.id]?.copy() as? CKRecord ?? CKRecord(recordType: "BrowserRecordV1", recordID: CKRecord.ID(recordName: value.id, zoneID: zone))
            let data = try JSONEncoder().encode(try value.validated())
            guard data.count < 200_000 else { throw ContinuityError.storageFull }
            record.encryptedValues["body"] = data
            changes.append(record)
        }
        var conflicts: [ContinuityRecord] = []
        for start in stride(from: 0, to: changes.count, by: 100) {
            try checkCancellation()
            let batch = Array(changes[start..<min(start + 100, changes.count)])
            let result = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            for submitted in batch {
                guard let outcome = result.saveResults[submitted.recordID] else { throw ContinuityError.invalidData }
                switch outcome {
                case .success(let saved): server[saved.recordID.recordName] = saved
                case .failure(let error):
                    if let cloud = error as? CKError, cloud.code == .serverRecordChanged,
                       let current = cloud.serverRecord {
                        server[current.recordID.recordName] = current
                        guard let decoded = try decode(current) else {
                            unknownKeys.insert(current.recordID.recordName); throw ContinuityError.newerFormat
                        }
                        conflicts.append(decoded)
                    } else {
                        if let cloud = error as? CKError, cloud.code == .zoneNotFound || cloud.code == .userDeletedZone {
                            zoneVerified = false; invalidatePushSubscription(); throw ContinuityError.remoteReset
                        }
                        throw error
                    }
                }
            }
        }
        return conflicts
    }
    private func decode(_ record: CKRecord) throws -> ContinuityRecord? {
        guard record.recordType == "BrowserRecordV1", let data = record.encryptedValues["body"] as? Data,
              data.count < 200_000 else { throw ContinuityError.invalidData }
        guard let value = try ContinuityRecord.decodeIfKnown(from: data) else { return nil }
        guard value.id == record.recordID.recordName else { throw ContinuityError.invalidData }
        return value
    }
}
