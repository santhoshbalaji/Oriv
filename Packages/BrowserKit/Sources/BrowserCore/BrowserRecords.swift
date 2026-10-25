import Foundation

public struct TabRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL?

    public init(id: UUID = UUID(), title: String = "New tab", url: URL? = nil) {
        self.id = id
        self.title = title
        self.url = url
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

    public init(tabs: [TabRecord] = [], selectedTabID: UUID? = nil,
                bookmarks: [Bookmark] = [], history: [HistoryEntry] = []) {
        version = 1
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.bookmarks = bookmarks
        self.history = history
    }

    public func sanitized() -> BrowserSnapshot {
        var result = self
        var identifiers = Set<UUID>()
        result.tabs = tabs.filter { record in
            identifiers.insert(record.id).inserted && (record.url.map(AddressResolver.isWebURL) ?? true)
        }
        if !result.tabs.contains(where: { $0.id == selectedTabID }) {
            result.selectedTabID = result.tabs.first?.id
        }
        result.bookmarks = bookmarks.filter { AddressResolver.isWebURL($0.url) }
        result.history = Array(history.filter { AddressResolver.isWebURL($0.url) }.prefix(500))
        return result
    }
}
