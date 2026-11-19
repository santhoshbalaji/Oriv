import BrowserCore
import Foundation
import Testing

@Suite struct VisitHistoryStoreTests {
    @Test func retentionPagingAndIncrementalAggregates() throws {
        let store = try VisitHistoryStore(limit: 3)
        let repeated = URL(string: "https://docs.example.test/guide")!
        let other = URL(string: "https://other.example.test")!
        let now = Date()
        let first = HistoryEntry(title: "First", url: repeated, visitedAt: now.addingTimeInterval(-3))
        let typed = HistoryEntry(title: "Café Guide", url: repeated, visitedAt: now.addingTimeInterval(-2), typedCount: 1)
        let third = HistoryEntry(title: "Notes", url: other, visitedAt: now.addingTimeInterval(-1))
        let fourth = HistoryEntry(title: "Current", url: repeated, visitedAt: now)
        try store.migrate([first])
        try store.record(typed, shared: true)
        let initial = try #require(store.suggestionDelta().entries.first)
        #expect(initial.id == typed.id)
        #expect(initial.visitCount == 2)
        #expect(initial.typedCount == 1)
        try store.record(third, shared: false)
        try store.record(fourth, shared: false)
        #expect(try store.count == 3)
        #expect(try store.page(limit: 2) == [fourth, third])
        #expect(try store.page(offset: 2, limit: 2) == [typed])
        #expect(try store.page(search: "cafe") == [typed])
        let update = try store.suggestionDelta()
        #expect(update.changed == [repeated, other])
        #expect(update.entries.first { $0.url == repeated }?.visitCount == 2)
        #expect(try store.sharedHistory() == [typed])
        try store.clear(since: now.addingTimeInterval(-1))
        #expect(try store.page() == [typed])
        try store.clear(since: .distantPast)
        #expect(try store.page().isEmpty)
        #expect(try store.suggestionDelta().entries.isEmpty)
    }

    @Test func continuityEvictionPreservesLocalVisitsAndClearErasesThem() throws {
        let store = try VisitHistoryStore()
        let local = HistoryEntry(title: "Local", url: URL(string: "https://local.example.test")!)
        let remote = HistoryEntry(title: "Remote", url: URL(string: "https://remote.example.test")!)
        try store.record(local, shared: true)
        try store.applyShared([remote], removedIDs: [], clearRanges: [], saveSession: {})
        #expect(Set(try store.page().map(\.id)) == [remote.id, local.id])
        #expect(try store.sharedHistory() == [remote])
        try store.applyShared([], removedIDs: [remote.id],
                              clearRanges: [.distantPast...Date()], saveSession: {})
        #expect(try store.page().isEmpty)
    }
}
