import BrowserCore
import Foundation
@preconcurrency import CloudKit

@MainActor public protocol ContinuityTransport: AnyObject {
    func cancel()
    func watchAccountChanges(_ handler: @escaping @MainActor () -> Void)
    func accountIdentifier() async throws -> String
    func fetch(allowZoneCreation: Bool) async throws -> [ContinuityRecord]
    func push(_ records: [ContinuityRecord]) async throws -> [ContinuityRecord]
}

public extension ContinuityTransport {
    func cancel() {}
    func watchAccountChanges(_ handler: @escaping @MainActor () -> Void) {}
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
            Task { @MainActor in handler() }
        }
    }
    public func cancel() {
        cancelled = true
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver); self.accountObserver = nil }
    }
    private func checkCancellation() throws { if cancelled { throw CancellationError() }; try Task.checkCancellation() }
    private var token: CKServerChangeToken?
    private var server: [String: CKRecord] = [:]
    public init(containerIdentifier: String) { container = CKContainer(identifier: containerIdentifier) }
    private var database: CKDatabase { container.privateCloudDatabase }
    public func accountIdentifier() async throws -> String {
        try checkCancellation()
        guard try await container.accountStatus() == .available else { throw ContinuityError.noAccount }
        return try await container.userRecordID().recordName
    }
    public func fetch(allowZoneCreation: Bool) async throws -> [ContinuityRecord] {
        try checkCancellation()
        do { _ = try await database.recordZone(for: zone) }
        catch let error as CKError where error.code == .zoneNotFound {
            guard allowZoneCreation, error.userInfo[CKErrorUserDidResetEncryptedDataKey] == nil else { throw ContinuityError.remoteReset }
            _ = try await database.save(CKRecordZone(zoneID: zone))
        }
        var next = server, nextToken = token
        do {
            repeat {
                try checkCancellation()
                let page = try await database.recordZoneChanges(inZoneWith: zone, since: nextToken, resultsLimit: 200)
                // Physical deletion indicates a server-side reset. Application deletions use tombstone records.
                guard page.deletions.isEmpty else { throw ContinuityError.remoteReset }
                for (_, result) in page.modificationResultsByID {
                    let record = try result.get().record
                    _ = try decode(record)
                    next[record.recordID.recordName] = record
                }
                guard next.count <= 100_000 else { throw ContinuityError.storageFull }
                nextToken = page.changeToken
                if !page.moreComing { break }
            } while true
        } catch let error as CKError where error.code == .changeTokenExpired {
            token = nil; server = [:]
            return try await fetch(allowZoneCreation: false)
        }
        // Keep the old cache/token if any page fails. A partial download must never look like deletion.
        let decoded = try next.values.compactMap(decode)
        server = next; token = nextToken
        return decoded
    }
    public func push(_ values: [ContinuityRecord]) async throws -> [ContinuityRecord] {
        var changes: [CKRecord] = []
        for value in values {
            if let existing = server[value.id] {
                guard let remote = try decode(existing) else { continue }
                if remote == value || remote.supersedes(value) { continue }
            }
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
                        if let decoded = try decode(current) { conflicts.append(decoded) }; server[current.recordID.recordName] = current
                    } else { throw error }
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
