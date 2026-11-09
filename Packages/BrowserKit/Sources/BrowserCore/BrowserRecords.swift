import Foundation

public enum TabContent: Codable, Hashable, Sendable {
    case home, web
    public var symbol: String { self == .home ? "safari" : "globe" }
}

public struct TabRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL?
    public var isPinned: Bool
    public var content: TabContent
    var retiredDestination = false

    public init(id: UUID = UUID(), title: String = "New tab", url: URL? = nil, isPinned: Bool = false, content: TabContent? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.isPinned = isPinned
        self.content = content ?? (url == nil ? .home : .web)
    }

    private struct LegacyContentKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private enum CodingKeys: String, CodingKey { case id, title, url, isPinned, content }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        url = try values.decodeIfPresent(URL.self, forKey: .url)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        if values.contains(.content) {
            let kind = try values.nestedContainer(keyedBy: LegacyContentKey.self, forKey: .content)
            if kind.allKeys.count == 1, let key = kind.allKeys.first, ["workspace", "dashboard", "conversation"].contains(key.stringValue) {
                retiredDestination = true; content = .home; url = nil
            } else { content = try values.decode(TabContent.self, forKey: .content) }
        } else { content = url == nil ? .home : .web }
    }
}

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, url: URL, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
    }
}

public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var visitedAt: Date

    public init(id: UUID = UUID(), title: String, url: URL, visitedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.visitedAt = visitedAt
    }
}

public struct BrowserSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var tabs: [TabRecord]
    public var selectedTabID: UUID?
    public var bookmarks: [Bookmark]
    public var history: [HistoryEntry]
    public var legacyBookmarksImported: Bool?
    public var appliedOpenRequests: Set<UUID>?

    public init(tabs: [TabRecord] = [], selectedTabID: UUID? = nil,
                bookmarks: [Bookmark] = [], history: [HistoryEntry] = [], legacyBookmarksImported: Bool = false, appliedOpenRequests: Set<UUID> = []) {
        version = 3
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.bookmarks = bookmarks
        self.history = history
        self.legacyBookmarksImported = legacyBookmarksImported
        self.appliedOpenRequests = appliedOpenRequests
    }

    public func sanitized() -> BrowserSnapshot {
        var result = self
        var identifiers = Set<UUID>()
        result.tabs = tabs.filter { record in
            guard !record.retiredDestination, identifiers.insert(record.id).inserted else { return false }
            return record.url.map(AddressResolver.isWebURL) ?? true
        }
        if !result.tabs.contains(where: { $0.id == selectedTabID }) {
            result.selectedTabID = result.tabs.first?.id
        }
        result.bookmarks = bookmarks.filter { AddressResolver.isWebURL($0.url) }
        result.history = Array(history.filter { AddressResolver.isWebURL($0.url) }.prefix(500))
        return result
    }
}
