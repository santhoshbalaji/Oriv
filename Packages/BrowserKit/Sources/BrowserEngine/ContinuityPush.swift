import Foundation
import CryptoKit

public enum ContinuityPushFetchResult: Sendable, Equatable { case newData, noData, failed }

struct ContinuityPushEnvelope { let accountID: String? }

/// Runtime evidence only: a previous installation's APNs registration is never trusted.
struct ContinuityPushHealth {
    private(set) var registered = false
    private(set) var subscriptionSaved = false
    private(set) var accountID: String?
    private(set) var lastPush: Date?
    private var lastFetch: Date?
    static let freshness: TimeInterval = 24 * 60 * 60

    mutating func registration(_ succeeded: Bool) {
        registered = succeeded
        if !succeeded { lastPush = nil }
    }
    mutating func bind(_ account: String?) {
        guard accountID != account else { return }
        accountID = account; subscriptionSaved = false; lastPush = nil; lastFetch = nil
    }
    mutating func subscription(_ saved: Bool) {
        subscriptionSaved = saved
        if !saved { lastPush = nil }
    }
    mutating func receivedPush(account: String, at date: Date) {
        guard accountID == account else { return }
        lastPush = date
    }
    /// An incremental poll finding a new remote revision without an intervening push
    /// also forces subscription verification (it may have been deleted server-side).
    @discardableResult mutating func fetched(remoteChanges: Bool, polling: Bool, at date: Date) -> Bool {
        let missed = polling && remoteChanges && lastFetch != nil && (lastPush == nil || lastPush! <= lastFetch!)
        if missed { subscription(false) }
        lastFetch = date
        return missed
    }
    func isHealthy(at date: Date) -> Bool {
        guard registered, subscriptionSaved, accountID != nil, let lastPush else { return false }
        return date >= lastPush && date.timeIntervalSince(lastPush) < Self.freshness
    }
    func pollInterval(at date: Date) -> TimeInterval { isHealthy(at: date) ? 300 : 30 }
    func nextPollDelay(at date: Date) -> TimeInterval {
        guard isHealthy(at: date), let lastPush else { return 30 }
        return min(300, lastPush.addingTimeInterval(Self.freshness).timeIntervalSince(date))
    }
}

/// Persists only subscription identity, scoped to app/container/environment/account/zone.
/// Revalidates a remembered subscription once per transport lifetime, without re-saving it.
@MainActor final class ContinuityPushSubscription {
    static let id = "BrowserContinuityV1.silent.v1"
    private let defaults: UserDefaults?
    private let namespace: String
    private let exists: (String) async throws -> Bool
    private let save: (String) async throws -> Void
    private var key: String?
    private var verified = false
    private var revision = 0

    init(namespace: String, defaults: UserDefaults?, exists: @escaping (String) async throws -> Bool,
         save: @escaping (String) async throws -> Void) {
        self.namespace = namespace; self.defaults = defaults; self.exists = exists; self.save = save
    }
    func invalidate() {
        revision += 1; verified = false
        if let key { defaults?.removeObject(forKey: key) }
    }
    func ensure(account: String) async throws {
        let digest = SHA256.hash(data: Data("\(namespace)|\(account)".utf8)).map { String(format: "%02x", $0) }.joined()
        let nextKey = "OrivContinuityPush.\(digest)"
        if key != nextKey { invalidate(); key = nextKey }
        guard !verified else { return }
        let epoch = revision
        do {
            let remembered = defaults?.string(forKey: nextKey) == Self.id
            let found = remembered ? try await exists(Self.id) : false
            guard revision == epoch else { throw CancellationError() }
            if !found { try await save(Self.id) }
            guard revision == epoch else { throw CancellationError() }
            defaults?.set(Self.id, forKey: nextKey); verified = true
        } catch {
            if revision == epoch { invalidate() }
            throw error
        }
    }
}
