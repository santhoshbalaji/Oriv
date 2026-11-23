import Foundation

/// Explicit allowlist of browser metadata. Website stores, private tabs and form values never enter this model.
public enum ContinuityPayload: Codable, Equatable, Sendable {
    case profile(ContinuityProfile)
    case bookmark(UUID, Bookmark)
    case history(UUID, HistoryEntry)
    case historyClear(UUID, since: Date, through: Date)
    case siteHistoryClear(UUID, domain: String, through: Date)
    case preference(UUID, key: String, value: String)
    case tab(UUID, device: UUID, tab: TabRecord, position: Int)
    case device(ContinuityDevice)
    case openRequest(ContinuityOpenRequest)
}

public struct ContinuityProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: ProfileColor
    public var symbol: ProfileSymbol
    public init(_ profile: BrowserProfile) { id = profile.id; name = profile.name; color = profile.color; symbol = profile.symbol }
    public var browserProfile: BrowserProfile { BrowserProfile(id: id, name: name, color: color, symbol: symbol) }
}

public struct ContinuityDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var updatedAt: Date
    public init(id: UUID, name: String, updatedAt: Date = .now) { self.id = id; self.name = name; self.updatedAt = updatedAt }
}

/// A one-shot request. Its identity is also the receiver's durable application receipt.
public struct ContinuityOpenRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var targetDeviceID: UUID
    public var sourceDeviceID: UUID
    public var sourceDeviceName: String
    public var url: URL
    public var title: String
    public var profileID: UUID
    public var createdAt: Date
    public init(id: UUID = UUID(), targetDeviceID: UUID, sourceDeviceID: UUID, sourceDeviceName: String,
                url: URL, title: String, profileID: UUID, createdAt: Date = .now) {
        self.id = id; self.targetDeviceID = targetDeviceID; self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceName = sourceDeviceName; self.url = url; self.title = title; self.profileID = profileID; self.createdAt = createdAt
    }
    public func isExpired(at now: Date = .now) -> Bool { now.timeIntervalSince(createdAt) >= 7 * 24 * 60 * 60 }
    public func targets(_ device: UUID, at now: Date = .now) -> Bool { targetDeviceID == device && !isExpired(at: now) }
    public func validated() throws -> Self {
        guard targetDeviceID != sourceDeviceID, ContinuityRecord.safeURL(url), title.count <= 4_000,
              !sourceDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceDeviceName.count <= 80, sourceDeviceName.rangeOfCharacter(from: .controlCharacters) == nil,
              createdAt.timeIntervalSince1970.isFinite else { throw ContinuityError.invalidData }
        return self
    }
}

public struct ContinuityRecord: Codable, Equatable, Sendable, Identifiable {
    public var version = 1
    public var id: String
    public var counter: Int64
    public var writer: UUID
    public var payload: ContinuityPayload?
    public var historyPruned: Bool?
    public init(id: String, counter: Int64, writer: UUID, payload: ContinuityPayload?) {
        self.id = id; self.counter = counter; self.writer = writer; self.payload = payload
    }
    /// Logical clocks preserve causal ordering without depending on device wall-clock agreement.
    public func supersedes(_ other: Self) -> Bool {
        // Profile deletion is permanent, even against a newer offline rename.
        if isProfileDeletion != other.isProfileDeletion { return isProfileDeletion }
        if counter != other.counter { return counter > other.counter }
        if (payload == nil) != (other.payload == nil) { return payload == nil }
        return writer.uuidString > other.writer.uuidString
    }
    public var isProfileDeletion: Bool {
        payload == nil && id.hasPrefix("profile.") && profileID != BrowserProfile.personalID
    }
    var profileID: UUID? {
        if case .openRequest(let request) = payload { return request.profileID }
        let parts = id.split(separator: ".")
        guard parts.count >= 2, parts[0] != "open", parts[0] != "device" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }
    public func validated() throws -> Self {
        guard version == 1 else { throw ContinuityError.newerFormat }
        guard id.count <= 240, counter > 0, counter < Int64.max - 100_000 else { throw ContinuityError.invalidData }
        let parts = id.split(separator: ".")
        let sizes = ["profile": 2, "bookmark": 3, "history": 3, "clear": 3, "preference": 3, "tab": 4, "device": 2, "open": 2]
        guard let first = parts.first, sizes[String(first)] == parts.count,
              UUID(uuidString: String(parts[1])) != nil else { throw ContinuityError.invalidData }
        if first != "preference", parts.count > 2 {
            guard parts.dropFirst(2).allSatisfy({ UUID(uuidString: String($0)) != nil }) else { throw ContinuityError.invalidData }
        }
        switch payload {
        case .profile(let value):
            guard id == Self.profileKey(value.id), ProfileRegistry.validName(value.name) else { throw ContinuityError.invalidData }
        case .bookmark(let profile, let value):
            guard id == Self.bookmarkKey(profile, value.id), Self.safeURL(value.url), value.title.count <= 4_000 else { throw ContinuityError.invalidData }
        case .history(let profile, let value):
            guard id == Self.historyKey(profile, value.id), Self.safeURL(value.url), value.title.count <= 4_000, value.visitedAt.timeIntervalSince1970.isFinite else { throw ContinuityError.invalidData }
        case .historyClear(let profile, let since, let through):
            guard first == "clear", String(parts[1]) == profile.uuidString, since <= through,
                  since.timeIntervalSince1970.isFinite, through.timeIntervalSince1970.isFinite else { throw ContinuityError.invalidData }
        case .siteHistoryClear(let profile, let domain, let through):
            guard first == "clear", String(parts[1]) == profile.uuidString, domain.utf8.count <= 253,
                  BrowserSite(host: domain)?.domain == domain,
                  through.timeIntervalSince1970.isFinite else { throw ContinuityError.invalidData }
        case .preference(let profile, let key, let value):
            guard Self.preferenceKeys.contains(key), id == Self.preferenceKey(profile, key), value.utf8.count <= 100_000 else { throw ContinuityError.invalidData }
        case .tab(let profile, let device, let tab, let position):
            guard id == Self.tabKey(profile, device, tab.id), tab.content == .web,
                  tab.url.map(Self.safeURL) == true, tab.title.count <= 4_000, (0..<100_000).contains(position) else { throw ContinuityError.invalidData }
        case .device(let value):
            guard id == Self.deviceKey(value.id), !value.name.isEmpty, value.name.count <= 80,
                  value.updatedAt.timeIntervalSince1970.isFinite else { throw ContinuityError.invalidData }
        case .openRequest(let value):
            guard id == Self.openRequestKey(value.id), writer == value.sourceDeviceID else { throw ContinuityError.invalidData }
            _ = try value.validated()
        case nil: break
        }
        return self
    }
    /// Inspect the encrypted body before decoding the closed Swift enum. Unknown kinds are ignored,
    /// while malformed known records still reject the complete batch. Never turn an unknown body into a tombstone.
    public static func decodeIfKnown(from data: Data) throws -> Self? {
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        struct Kind: Decodable {
            let name: String
            init(from decoder: Decoder) throws {
                let keys = try decoder.container(keyedBy: Key.self).allKeys
                guard keys.count == 1, let key = keys.first else { throw ContinuityError.invalidData }
                name = key.stringValue
            }
        }
        struct Header: Decodable { let id: String; let version: Int; let payload: Kind? }
        let header = try JSONDecoder().decode(Header.self, from: data)
        let prefixes: Set<String> = ["profile", "bookmark", "history", "clear", "preference", "tab", "device", "open"]
        let kinds: Set<String> = ["profile", "bookmark", "history", "historyClear", "siteHistoryClear", "preference", "tab", "device", "openRequest"]
        guard let prefix = header.id.split(separator: ".").first, prefixes.contains(String(prefix)),
              header.payload.map({ kinds.contains($0.name) }) ?? true else { return nil }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
    public static func openRequestKey(_ id: UUID) -> String { "open.\(id)" }
    public static let preferenceKeys: Set<String> = ["appearance", "searchEngine", "restoreTabs", "defaultZoom", "adBlockingMode", "adBlockingExceptions", "siteRules"]
    public static func safeURL(_ url: URL) -> Bool { AddressResolver.isWebURL(url) && url.absoluteString.utf8.count <= 16_384 }
    public static func profileKey(_ id: UUID) -> String { "profile.\(id)" }
    public static func bookmarkKey(_ profile: UUID, _ id: UUID) -> String { "bookmark.\(profile).\(id)" }
    public static func historyKey(_ profile: UUID, _ id: UUID) -> String { "history.\(profile).\(id)" }
    public static func preferenceKey(_ profile: UUID, _ key: String) -> String { "preference.\(profile).\(key)" }
    public static func tabKey(_ profile: UUID, _ device: UUID, _ id: UUID) -> String { "tab.\(profile).\(device).\(id)" }
    public static func deviceKey(_ device: UUID) -> String { "device.\(device)" }
}

public enum ContinuityError: LocalizedError {
    case invalidData, newerFormat, accountChanged, unavailable, noAccount, remoteReset, storageFull
    public var errorDescription: String? {
        switch self {
        case .invalidData: "Oriv couldn’t read the synced data. Sync is paused and your local browsing data is safe."
        case .newerFormat: "Sync needs a newer Oriv version. Sync is paused to protect your data."
        case .accountChanged: "The iCloud account changed. Sync is paused to prevent moving browsing data to a different account. Sign back in to the original account."
        case .unavailable: "Sync is unavailable in this version of Oriv."
        case .noAccount: "Sign in to iCloud in system Settings to use continuity."
        case .remoteReset: "Your synced browser data was removed or reset in iCloud. Sync is paused; local data is preserved."
        case .storageFull: "The continuity safety limit was reached. Sync is paused; local browsing remains available."
        }
    }
}

public struct ContinuityReplica: Codable, Sendable {
    public var version = 1
    public var deviceID = UUID()
    public var deviceName: String
    public var enabled = false
    public var handoffEnabled = true
    public var accountID: String?
    public var lastSync: Date?
    public private(set) var counter: Int64 = 0
    public private(set) var records: [String: ContinuityRecord] = [:]
    public var observedBookmarks: [UUID: [Bookmark]] = [:]
    /// Persisted before applying incoming changes. A crash cannot mistake an unapplied remote addition for a local deletion.
    public var pendingApplication = false
    public var seedKeys: Set<String> = []
    // Optional so a version-1 local replica from an older build safely retries all records once.
    private var dirtyRecordKeys: Set<String>? = []
    public var dirtyKeys: Set<String> { dirtyRecordKeys ?? Set(records.keys) }
    public var dirtyRecords: [ContinuityRecord] {
        let dirty = dirtyKeys.compactMap { records[$0] }
        return dirty.filter(\.isProfileDeletion) + dirty.filter { !$0.isProfileDeletion }
    }
    public func isProfileDeleted(_ id: UUID) -> Bool {
        records[ContinuityRecord.profileKey(id)]?.isProfileDeletion == true
    }
    public mutating func deleteProfile(_ id: UUID) throws {
        guard id != BrowserProfile.personalID else { throw ProfileError.protectedProfile }
        try put(ContinuityRecord.profileKey(id), nil)
        try redactDeletedProfiles([id])
    }
    private mutating func redactDeletedProfiles(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        for record in records.values where record.payload != nil && record.profileID.map(ids.contains) == true {
            try put(record.id, nil)
        }
        for id in ids { observedBookmarks.removeValue(forKey: id) }
    }
    public mutating func acknowledge(_ uploaded: [ContinuityRecord]) {
        if dirtyRecordKeys == nil { dirtyRecordKeys = Set(records.keys) }
        for record in uploaded where records[record.id] == record { dirtyRecordKeys?.remove(record.id) }
    }
    public init(deviceName: String) { self.deviceName = deviceName }
    public mutating func bindAccount(_ id: String) throws {
        guard accountID == nil || accountID == id else { throw ContinuityError.accountChanged }
        accountID = id
    }
    public mutating func put(_ id: String, _ payload: ContinuityPayload?, seed: Bool = false, historyPruned: Bool? = nil) throws {
        if let current = records[id], current.payload == payload, current.historyPruned == historyPruned { return }
        guard records.count < 100_000 || records[id] != nil else { throw ContinuityError.storageFull }
        guard counter < Int64.max - 100_001 else { throw ContinuityError.storageFull }
        var record = ContinuityRecord(id: id, counter: counter + 1, writer: deviceID, payload: payload)
        record.historyPruned = historyPruned
        _ = try record.validated()
        if seed && records[id] == nil { seedKeys.insert(id) } else { seedKeys.remove(id) }
        if dirtyRecordKeys == nil { dirtyRecordKeys = Set(records.keys) }
        dirtyRecordKeys?.insert(id)
        counter += 1
        records[id] = record
    }
    public mutating func merge(_ incoming: [ContinuityRecord]) throws {
        // Validate the complete batch before mutation: unknown/corrupt data must not cause partial imports.
        let valid = try incoming.map { try $0.validated() }
        guard Set(records.keys).union(valid.map(\.id)).count <= 100_000 else { throw ContinuityError.storageFull }
        if dirtyRecordKeys == nil { dirtyRecordKeys = Set(records.keys) }
        for record in valid {
            counter = max(counter, record.counter)
            if (seedKeys.remove(record.id) != nil && records[record.id]?.isProfileDeletion != true) || records[record.id].map({ record.supersedes($0) }) ?? true {
                records[record.id] = record; dirtyRecordKeys?.remove(record.id)
            } else if records[record.id] == record { dirtyRecordKeys?.remove(record.id) }
            else { dirtyRecordKeys?.insert(record.id) }
        }
        let deleted = Set(valid.compactMap(\.profileID).filter(isProfileDeleted))
        try redactDeletedProfiles(deleted)
        try redactClearedHistory(); try pruneHistory()
    }
    public mutating func capture(profile: BrowserProfile, bookmarks: [Bookmark], history: [HistoryEntry], regularTabs: [TabRecord],
                                 preferences: [String: String], previous: BrowserSnapshot? = nil,
                                 previousPreferences: [String: String]? = nil) throws {
        guard !isProfileDeleted(profile.id) else { return }
        try put(ContinuityRecord.profileKey(profile.id), .profile(ContinuityProfile(profile)), seed: true)
        if previous?.bookmarks != bookmarks {
            let present = Set(bookmarks.map(\.id))
            for removed in observedBookmarks[profile.id, default: []] where !present.contains(removed.id) {
                // Independently saved copies of the same link are deleted together.
                let keys = records.values.compactMap { record -> String? in
                    if case .bookmark(let owner, let value) = record.payload, owner == profile.id, value.url == removed.url { return record.id }
                    return nil
                }
                for key in keys { try put(key, nil) }
            }
            let previouslyVisible = Dictionary(observedBookmarks[profile.id, default: []].map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for bookmark in bookmarks where ContinuityRecord.safeURL(bookmark.url) {
                let key = ContinuityRecord.bookmarkKey(profile.id, bookmark.id)
                // An unchanged local copy must not resurrect a remotely deleted bookmark.
                if records[key] == nil || previouslyVisible[bookmark.id] != bookmark {
                    try put(key, .bookmark(profile.id, bookmark), seed: previouslyVisible[bookmark.id] == nil)
                }
            }
            observedBookmarks[profile.id] = bookmarks
        }
        if previous?.history != history {
            let oldHistory = Dictionary((previous?.history ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let cutoffs = SiteHistoryDeletion.cutoffs(siteHistoryDeletions(for: profile.id))
            for entry in history where oldHistory[entry.id] != entry && ContinuityRecord.safeURL(entry.url)
                && !historyWasCleared(profile.id, entry.visitedAt) && !Self.matchesSiteDeletion(entry, cutoffs: cutoffs) {
                let key = ContinuityRecord.historyKey(profile.id, entry.id)
                if records[key] == nil { try put(key, .history(profile.id, entry), seed: true) }
                else if case .history = records[key]?.payload {
                    // Late titles update the same visit, never a deletion tombstone.
                    try put(key, .history(profile.id, entry))
                }
            }
            try pruneHistory()
        }
        if previous?.tabs != regularTabs {
            let tabKeys = Set(regularTabs.filter { $0.url.map(ContinuityRecord.safeURL) == true }.map { ContinuityRecord.tabKey(profile.id, deviceID, $0.id) })
            let oldKeys: [String]
            if let previous {
                oldKeys = previous.tabs.filter { $0.url.map(ContinuityRecord.safeURL) == true }
                    .map { ContinuityRecord.tabKey(profile.id, deviceID, $0.id) }
            } else {
                oldKeys = records.values.compactMap { record -> String? in
                    if case .tab(let owner, let device, _, _) = record.payload, owner == profile.id, device == deviceID { return record.id }
                    return nil
                }
            }
            for key in oldKeys where !tabKeys.contains(key) { try put(key, nil) }
            for (position, tab) in regularTabs.enumerated() where tab.url.map(ContinuityRecord.safeURL) == true {
                var shared = tab
                shared.url = tab.url.map(URLCleaner.clean)
                try put(ContinuityRecord.tabKey(profile.id, deviceID, tab.id), .tab(profile.id, device: deviceID, tab: shared, position: position))
            }
        }
        if previousPreferences != preferences {
            for (key, value) in preferences where ContinuityRecord.preferenceKeys.contains(key) {
                try put(ContinuityRecord.preferenceKey(profile.id, key), .preference(profile.id, key: key, value: value), seed: true)
            }
        }
    }
    public mutating func clearHistory(profile: UUID, since: Date, through: Date = .now) throws {
        try put("clear.\(profile).\(UUID())", .historyClear(profile, since: since, through: through))
        try redactClearedHistory()
    }
    public mutating func captureSiteHistoryDeletions(profile: UUID, deletions: [UUID: SiteHistoryDeletion]) throws {
        guard !isProfileDeleted(profile) else { return }
        let previous = counter
        for (id, deletion) in deletions {
            let key = "clear.\(profile).\(id)"
            if case .siteHistoryClear(_, _, let through) = records[key]?.payload, through >= deletion.through { continue }
            try put(key, .siteHistoryClear(profile, domain: deletion.site.domain, through: deletion.through))
        }
        if counter != previous { try redactClearedHistory() }
    }

    public func siteHistoryDeletions(for profile: UUID) -> Set<SiteHistoryDeletion> {
        Set(records.values.compactMap { record in
            guard case .siteHistoryClear(let owner, let domain, let through) = record.payload,
                  owner == profile, let site = BrowserSite(host: domain) else { return nil }
            return SiteHistoryDeletion(site: site, through: through)
        })
    }

    private static func matchesSiteDeletion(_ entry: HistoryEntry, cutoffs: [BrowserSite: Date]) -> Bool {
        guard !cutoffs.isEmpty, let site = BrowserSite(url: entry.url), let through = cutoffs[site] else { return false }
        return entry.visitedAt <= through
    }

    private mutating func redactClearedHistory() throws {
        var siteDeletions: [UUID: [SiteHistoryDeletion]] = [:]
        for record in records.values {
            if case .siteHistoryClear(let profile, let domain, let through) = record.payload,
               let site = BrowserSite(host: domain) {
                siteDeletions[profile, default: []].append(SiteHistoryDeletion(site: site, through: through))
            }
        }
        let cutoffs = siteDeletions.mapValues { SiteHistoryDeletion.cutoffs($0) }
        let erased = records.values.compactMap { record -> String? in
            guard case .history(let profile, let value) = record.payload else { return nil }
            return historyWasCleared(profile, value.visitedAt) || Self.matchesSiteDeletion(value, cutoffs: cutoffs[profile] ?? [:]) ? record.id : nil
        }
        for key in erased { try put(key, nil) }
    }
    /// Match the browser's 500 most recent distinct pages per profile. Retain tombstones so offline copies cannot restore evicted URLs.
    private mutating func pruneHistory() throws {
        var byProfile: [UUID: [HistoryEntry]] = [:]
        for record in records.values {
            if case .history(let profile, let entry) = record.payload { byProfile[profile, default: []].append(entry) }
        }
        for (profile, entries) in byProfile {
            var urls = Set<URL>(), kept = 0
            for entry in entries.sorted(by: { $0.visitedAt == $1.visitedAt ? $0.id.uuidString < $1.id.uuidString : $0.visitedAt > $1.visitedAt }) {
                if kept < 500 && urls.insert(entry.url).inserted { kept += 1 }
                else { try put(ContinuityRecord.historyKey(profile, entry.id), nil, historyPruned: true) }
            }
        }
    }
    public mutating func removeHistory(profile: UUID, id: UUID) throws {
        let key = ContinuityRecord.historyKey(profile, id)
        if case .history(_, let entry) = records[key]?.payload {
            let keys = records.values.compactMap { record -> String? in
                if case .history(let owner, let value) = record.payload, owner == profile, value.url == entry.url { return record.id }; return nil
            }
            for key in keys { try put(key, nil) }
        } else { try put(key, nil) }
    }
    public func historyChanges(for profile: UUID) -> (removed: Set<UUID>, cleared: [ClosedRange<Date>]) {
        var removed = Set<UUID>(), cleared: [ClosedRange<Date>] = []
        let prefix = "history.\(profile)."
        for record in records.values {
            if case .historyClear(let owner, let since, let through) = record.payload, owner == profile {
                cleared.append(since...through)
            } else if record.payload == nil, record.historyPruned != true, record.id.hasPrefix(prefix),
                      let id = UUID(uuidString: String(record.id.dropFirst(prefix.count))) {
                removed.insert(id)
            }
        }
        return (removed, cleared)
    }
    public func historyWasCleared(_ profile: UUID, _ date: Date) -> Bool {
        records.values.contains { record in
            if case .historyClear(let owner, let since, let through) = record.payload { return owner == profile && (since...through).contains(date) }
            return false
        }
    }
    public func bookmarks(for profile: UUID) -> [Bookmark] {
        var urls = Set<URL>()
        return records.values.compactMap { record in
            if case .bookmark(let owner, let value) = record.payload, owner == profile { return value }; return nil
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }.filter { urls.insert($0.url).inserted }
    }
    public func history(for profile: UUID) -> [HistoryEntry] {
        var urls = Set<URL>()
        let cutoffs = SiteHistoryDeletion.cutoffs(siteHistoryDeletions(for: profile))
        return Array(records.values.compactMap { record -> HistoryEntry? in
            if case .history(let owner, let value) = record.payload, owner == profile,
               !historyWasCleared(profile, value.visitedAt), !Self.matchesSiteDeletion(value, cutoffs: cutoffs) { return value }; return nil
        }.sorted { $0.visitedAt == $1.visitedAt ? $0.id.uuidString < $1.id.uuidString : $0.visitedAt > $1.visitedAt }.filter { urls.insert($0.url).inserted }.prefix(500))
    }
    public func preferences(for profile: UUID) -> [String: String] {
        Dictionary(records.values.compactMap { record in
            if case .preference(let owner, let key, let value) = record.payload, owner == profile { return (key, value) }; return nil
        }, uniquingKeysWith: { a, _ in a })
    }
    public func openRequests(targeting device: UUID, at now: Date = .now) -> [ContinuityOpenRequest] {
        records.values.compactMap { record in
            if case .openRequest(let request) = record.payload, request.targets(device, at: now) { return request }
            return nil
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    public mutating func expireOpenRequests(at now: Date = .now) throws {
        let expired = records.values.compactMap { record -> String? in
            if case .openRequest(let request) = record.payload, request.isExpired(at: now) { return record.id }
            return nil
        }
        for key in expired { try put(key, nil) }
    }
    public var profiles: [ContinuityProfile] { records.values.compactMap { if case .profile(let value) = $0.payload { return value }; return nil }.sorted { $0.id.uuidString < $1.id.uuidString } }
    public var devices: [ContinuityDevice] { records.values.compactMap { if case .device(let value) = $0.payload { return value }; return nil }.sorted { $0.name < $1.name } }
    public func tabs(for profile: UUID, device: UUID) -> [TabRecord] {
        records.values.compactMap { record -> (TabRecord, Int)? in
            if case .tab(let owner, let source, let tab, let position) = record.payload, owner == profile, source == device { return (tab, position) }; return nil
        }.sorted {
            if $0.0.isPinned != $1.0.isPinned { return $0.0.isPinned }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.map { $0.0 }
    }
    public func validated() throws -> Self {
        guard version == 1 else { throw ContinuityError.newerFormat }
        guard records.count <= 100_000, counter >= 0, counter < Int64.max - 100_000, !deviceName.isEmpty, deviceName.count <= 80 else { throw ContinuityError.invalidData }
        guard dirtyRecordKeys?.allSatisfy({ records[$0] != nil }) ?? true else { throw ContinuityError.invalidData }
        for (key, record) in records { guard key == record.id, record.counter <= counter else { throw ContinuityError.invalidData }; _ = try record.validated() }
        return self
    }
}

public protocol ContinuityReplicaStore: Sendable {
    func load() throws -> ContinuityReplica?
    func save(_ state: ContinuityReplica) throws
}

public struct ContinuityStore: ContinuityReplicaStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> ContinuityReplica? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 100_000_000 else { throw ContinuityError.storageFull }
        return try JSONDecoder().decode(ContinuityReplica.self, from: Data(contentsOf: url)).validated()
    }
    public func save(_ state: ContinuityReplica) throws {
        _ = try state.validated()
        let data = try JSONEncoder().encode(state)
        guard data.count < 100_000_000 else { throw ContinuityError.storageFull }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
