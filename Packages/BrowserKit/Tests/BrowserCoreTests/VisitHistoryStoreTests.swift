import BrowserCore
import Foundation
import Testing

@Suite struct VisitHistoryStoreTests {
    @Test func registrableSitesMatchAtLabelBoundaries() throws {
        let site = try #require(BrowserSite(host: "WWW.News.Example.CO.UK."))
        #expect(site.domain == "example.co.uk")
        #expect(site.contains(host: ".other.example.co.uk"))
        #expect(!site.contains(host: "notexample.co.uk"))
        #expect(!site.contains(host: "example.co.uk.attacker.test"))
        #expect(BrowserSite(host: "a.foo.github.io")?.domain == "foo.github.io")
        #expect(BrowserSite(host: "foo.github.io") != BrowserSite(host: "bar.github.io"))
        #expect(BrowserSite(host: "a.b.ck")?.domain == "a.b.ck")
        #expect(BrowserSite(host: "a.www.ck")?.domain == "www.ck")
        #expect(BrowserSite(host: "a.食狮.公司.cn")?.domain == "xn--85x722f.xn--55qx5d.cn")
        #expect(BrowserSite(host: "127.1")?.domain == "127.0.0.1")
        #expect(BrowserSite(host: "128.0.0.1") != BrowserSite(host: "127.0.0.1"))
        #expect(BrowserSite(host: "[0:0::1]")?.domain == "::1")
        #expect(BrowserSite(host: "LOCALHOST.")?.domain == "localhost")
    }

    @Test func forgettingOneSitePersistsSyncMarkerAndInvalidatesHistoryDerivatives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("history.sqlite")
        let store = try VisitHistoryStore(fileURL: database)
        let old = HistoryEntry(title: "Old", url: URL(string: "https://a.example.co.uk/one")!, visitedAt: .distantPast)
        let remote = HistoryEntry(title: "Remote", url: URL(string: "http://b.example.co.uk:8080/two")!, visitedAt: .distantPast)
        let other = HistoryEntry(title: "Keep", url: URL(string: "https://notexample.co.uk")!)
        let site = try #require(BrowserSite(url: old.url))
        try store.migrate([old, other])
        try store.applyShared([old, remote, other], removedIDs: [], clearRanges: []) {}
        _ = try store.suggestionDelta()
        let markers = try store.forget(site)
        #expect(try store.page() == [other])
        #expect(try store.frequentDestinations(limit: 5) == [other])
        #expect(try store.suggestionDelta().changed == [old.url, remote.url])

        let reopened = try VisitHistoryStore(fileURL: database)
        #expect(try reopened.siteHistoryDeletions() == markers)
        try reopened.applyShared([other, old, remote], removedIDs: [], clearRanges: []) {}
        #expect(try reopened.page() == [other])
        let new = HistoryEntry(title: "New visit", url: old.url, visitedAt: .distantFuture)
        try reopened.applyShared([other, new], removedIDs: [], clearRanges: [], siteDeletions: Set(markers.values)) {}
        #expect(Set(try reopened.page().map(\.id)) == [new.id, other.id])

        let receivingDevice = try VisitHistoryStore()
        try receivingDevice.record(old, shared: false)
        try receivingDevice.applyShared([new, other], removedIDs: [], clearRanges: [], siteDeletions: Set(markers.values)) {}
        #expect(Set(try receivingDevice.page().map(\.id)) == [new.id, other.id])
    }
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
        let seed = try store.suggestionDelta()
        #expect(seed.replacesHistory)
        let initial = try #require(seed.entries.first)
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
        #expect(!update.replacesHistory)
        #expect(update.changed == [repeated, other])
        #expect(update.entries.first { $0.address == repeated.absoluteString }?.visitCount == 2)
        #expect(try store.sharedHistory() == [typed])
        try store.clear(since: now.addingTimeInterval(-1))
        #expect(try store.page() == [typed])
        let afterPartialClear = try store.suggestionDelta()
        #expect(afterPartialClear.replacesHistory)
        #expect(afterPartialClear.entries.map(\.id) == [typed.id])
        try store.clear(since: .distantPast)
        #expect(try store.page().isEmpty)
        #expect(try store.suggestionDelta().entries.isEmpty)
    }

    @Test func frequentDestinationsAggregateLocalVisitsAndUseNewestTitle() throws {
        let store = try VisitHistoryStore()
        let now = Date(timeIntervalSinceReferenceDate: 500)
        let frequent = URL(string: "https://often.example/guide")!
        let recent = HistoryEntry(title: "Recent", url: URL(string: "https://recent.example")!, visitedAt: now)
        let remote = HistoryEntry(title: "Remote", url: URL(string: "https://remote.example")!, visitedAt: now, visitCount: 50)
        try store.migrate([
            HistoryEntry(title: "Old title", url: frequent, visitedAt: now.addingTimeInterval(-10), visitCount: 3),
            HistoryEntry(title: "New title", url: frequent, visitedAt: now.addingTimeInterval(-5)),
            recent
        ])
        try store.applyShared([recent, remote], removedIDs: [], clearRanges: [], saveSession: {})
        let ranked = try store.frequentDestinations(limit: 2)
        #expect(ranked.map(\.url) == [frequent, recent.url])
        #expect(ranked.first?.visitCount == 4)
        #expect(ranked.first?.title == "New title")
        #expect(try store.frequentDestinations(limit: 1).map(\.url) == [frequent])
        try store.clear(since: .distantPast)
        #expect(try store.frequentDestinations(limit: 6).isEmpty)
    }

    @Test func bulkReplacementDropsErasedVisitsAndRetainsBookmarks() throws {
        let store = try VisitHistoryStore()
        let visits = (0...256).map { number in
            HistoryEntry(title: "Visit \(number)", url: URL(string: "https://example.test/\(number)")!)
        }
        try store.migrate(visits)
        var index = LocalSuggestionIndex()
        index.updateBookmarks([Bookmark(title: "Saved destination", url: visits[0].url)])
        index.replaceVisits(try store.suggestionDelta().entries)
        #expect(index.matches("visit").count == 7)
        for visit in visits { try store.remove(visit.id) }
        let replacement = try store.suggestionDelta()
        #expect(replacement.replacesHistory)
        index.replaceVisits(replacement.entries)
        #expect(index.matches("visit").isEmpty)
        #expect(index.matches("saved").map(\.url) == [visits[0].url])
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
