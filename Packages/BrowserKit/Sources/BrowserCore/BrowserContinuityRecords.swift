import Foundation

/// Explicit allowlist of browser metadata. Website stores, private tabs and form values never enter this model.
public enum ContinuityPayload: Codable, Equatable, Sendable {
    case profile(ContinuityProfile)
    case bookmark(UUID, Bookmark)
    case history(UUID, HistoryEntry)
    case historyClear(UUID, since: Date, through: Date)
    case preference(UUID, key: String, value: String)
    case tab(UUID, device: UUID, tab: TabRecord, position: Int)
    case device(ContinuityDevice)
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

public struct ContinuityRecord: Codable, Equatable, Sendable, Identifiable {
    public var version = 1
    public var id: String
    public var counter: Int64
    public var writer: UUID
    public var payload: ContinuityPayload?
    public init(id: String, counter: Int64, writer: UUID, payload: ContinuityPayload?) {
        self.id = id; self.counter = counter; self.writer = writer; self.payload = payload
    }
    /// Logical clocks preserve causal ordering without depending on device wall-clock agreement.
    public func supersedes(_ other: Self) -> Bool {
        if counter != other.counter { return counter > other.counter }
        if (payload == nil) != (other.payload == nil) { return payload == nil }
        return writer.uuidString > other.writer.uuidString
    }
    public func validated() throws -> Self {
        guard version == 1 else { throw ContinuityError.newerFormat }
        guard id.count <= 240, counter > 0, counter < Int64.max - 100_000 else { throw ContinuityError.invalidData }
        let parts = id.split(separator: ".")
        let sizes = ["profile": 2, "bookmark": 3, "history": 3, "clear": 3, "preference": 3, "tab": 4, "device": 2]
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
        case .preference(let profile, let key, let value):
            guard Self.preferenceKeys.contains(key), id == Self.preferenceKey(profile, key), value.utf8.count <= 100_000 else { throw ContinuityError.invalidData }
        case .tab(let profile, let device, let tab, let position):
            guard id == Self.tabKey(profile, device, tab.id), tab.content == .web,
                  tab.url.map(Self.safeURL) == true, tab.title.count <= 4_000, (0..<100_000).contains(position) else { throw ContinuityError.invalidData }
        case .device(let value):
            guard id == Self.deviceKey(value.id), !value.name.isEmpty, value.name.count <= 80,
                  value.updatedAt.timeIntervalSince1970.isFinite else { throw ContinuityError.invalidData }
        case nil: break
        }
        return self
    }
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
        case .invalidData: "Continuity data could not be read safely. Sync is paused; your local browsing data is preserved."
        case .newerFormat: "Continuity needs a newer Oriv version. Sync is paused to protect your data."
        case .accountChanged: "The iCloud account changed. Sync is paused to prevent moving browsing data to a different account. Sign back in to the original account."
        case .unavailable: "iCloud continuity needs the signed Continuity build. Local browsing remains available."
        case .noAccount: "Sign in to iCloud in system Settings to use continuity."
        case .remoteReset: "The iCloud continuity store was removed or reset. Sync is paused; local data is preserved."
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
    public init(deviceName: String) { self.deviceName = deviceName }
    public mutating func bindAccount(_ id: String) throws {
        guard accountID == nil || accountID == id else { throw ContinuityError.accountChanged }
        accountID = id
    }
    public mutating func put(_ id: String, _ payload: ContinuityPayload?, seed: Bool = false) throws {
        if let current = records[id], current.payload == payload { return }
        guard records.count < 100_000 || records[id] != nil else { throw ContinuityError.storageFull }
        if seed && records[id] == nil { seedKeys.insert(id) } else { seedKeys.remove(id) }
        guard counter < Int64.max - 100_001 else { throw ContinuityError.storageFull }
        counter += 1
        records[id] = try ContinuityRecord(id: id, counter: counter, writer: deviceID, payload: payload).validated()
    }
    public mutating func merge(_ incoming: [ContinuityRecord]) throws {
        // Validate the complete batch before mutation: unknown/corrupt data must not cause partial imports.
        let valid = try incoming.map { try $0.validated() }
        guard Set(records.keys).union(valid.map(\.id)).count <= 100_000 else { throw ContinuityError.storageFull }
        for record in valid {
            counter = max(counter, record.counter)
            if seedKeys.remove(record.id) != nil || records[record.id].map({ record.supersedes($0) }) ?? true { records[record.id] = record }
        }
        try redactClearedHistory(); try pruneHistory()
    }
    public mutating func capture(profile: BrowserProfile, bookmarks: [Bookmark], history: [HistoryEntry], regularTabs: [TabRecord], preferences: [String: String]) throws {
        try put(ContinuityRecord.profileKey(profile.id), .profile(ContinuityProfile(profile)), seed: true)
        let present = Set(bookmarks.map(\.id))
        for removed in observedBookmarks[profile.id, default: []] where !present.contains(removed.id) {
            // The same link may have been saved independently on two devices. Removing it removes all known copies.
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
            if records[key] == nil || previouslyVisible[bookmark.id] != bookmark { try put(key, .bookmark(profile.id, bookmark), seed: previouslyVisible[bookmark.id] == nil) }
        }
        observedBookmarks[profile.id] = bookmarks
        for entry in history where ContinuityRecord.safeURL(entry.url) && !historyWasCleared(profile.id, entry.visitedAt) {
            let key = ContinuityRecord.historyKey(profile.id, entry.id)
            if records[key] == nil { try put(key, .history(profile.id, entry), seed: true) }
        }
        try pruneHistory()
        let tabKeys = Set(regularTabs.filter { $0.url.map(ContinuityRecord.safeURL) == true }.map { ContinuityRecord.tabKey(profile.id, deviceID, $0.id) })
        let oldKeys = records.values.compactMap { record -> String? in
            if case .tab(let owner, let device, _, _) = record.payload, owner == profile.id, device == deviceID { return record.id }
            return nil
        }
        for key in oldKeys where !tabKeys.contains(key) { try put(key, nil) }
        for (position, tab) in regularTabs.enumerated() where tab.url.map(ContinuityRecord.safeURL) == true { try put(ContinuityRecord.tabKey(profile.id, deviceID, tab.id), .tab(profile.id, device: deviceID, tab: tab, position: position)) }
        for (key, value) in preferences where ContinuityRecord.preferenceKeys.contains(key) { try put(ContinuityRecord.preferenceKey(profile.id, key), .preference(profile.id, key: key, value: value), seed: true) }
    }
    public mutating func clearHistory(profile: UUID, since: Date, through: Date = .now) throws {
        try put("clear.\(profile).\(UUID())", .historyClear(profile, since: since, through: through))
        try redactClearedHistory()
    }
    private mutating func redactClearedHistory() throws {
        let erased = records.values.compactMap { record -> String? in
            if case .history(let profile, let value) = record.payload, historyWasCleared(profile, value.visitedAt) { return record.id }; return nil
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
                else { try put(ContinuityRecord.historyKey(profile, entry.id), nil) }
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
        return Array(records.values.compactMap { record -> HistoryEntry? in
            if case .history(let owner, let value) = record.payload, owner == profile, !historyWasCleared(profile, value.visitedAt) { return value }; return nil
        }.sorted { $0.visitedAt == $1.visitedAt ? $0.id.uuidString < $1.id.uuidString : $0.visitedAt > $1.visitedAt }.filter { urls.insert($0.url).inserted }.prefix(500))
    }
    public func preferences(for profile: UUID) -> [String: String] {
        Dictionary(records.values.compactMap { record in
            if case .preference(let owner, let key, let value) = record.payload, owner == profile { return (key, value) }; return nil
        }, uniquingKeysWith: { a, _ in a })
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
        for (key, record) in records { guard key == record.id, record.counter <= counter else { throw ContinuityError.invalidData }; _ = try record.validated() }
        return self
    }
}

public struct ContinuityStore: Sendable {
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
