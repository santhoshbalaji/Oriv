import BrowserCore
import Foundation
import Testing

@Suite struct LocalSuggestionTests {
    @Test func frecencyPrefixBookmarksAndIncrementalErasure() {
        let now = Date()
        let old = HistoryEntry(title: "Guide", url: URL(string: "https://docs.test/old")!, visitedAt: now.addingTimeInterval(-86_400), visitCount: 30)
        let new = HistoryEntry(title: "Guide", url: URL(string: "https://docs.test/new")!, visitedAt: now, visitCount: 1)
        var index = LocalSuggestionIndex()
        index.update(history: [new, old], bookmarks: [])
        #expect(index.matches("docs", now: now).map(\.url) == [old.url, new.url])
        index.update(history: [new], bookmarks: [Bookmark(title: "Saved guide", url: old.url)])
        #expect(index.matches("guide", now: now).first?.source == .bookmark)
        index.update(history: [], bookmarks: [])
        #expect(index.matches("guide").isEmpty)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let aliases = [BrowserSuggestion(title: "First", url: old.url, tabID: firstID),
                       BrowserSuggestion(title: "Alternate Title", url: old.url, tabID: UUID())]
        #expect(index.matches("alternate", tabs: aliases).first?.tabID == firstID)
        #expect(index.matches("www.", tabs: aliases).isEmpty)
    }
    @Test func hostCompletionIsCaseInsensitiveAndDoesNotInventPaths() {
        let matches = [BrowserSuggestion(title: "Example", url: URL(string: "https://www.example.test/path")!)]
        #expect(LocalSuggestionIndex.completion(for: "Exa", matches: matches) == "Example.test")
        #expect(LocalSuggestionIndex.completion(for: "example.test/path", matches: matches) == nil)
        #expect(LocalSuggestionIndex.completion(for: "two words", matches: matches) == nil)
        #expect(LocalSuggestionIndex.completion(for: "www.ex", matches: matches) == "www.example.test")
        #expect(LocalSuggestionIndex.completion(for: "loc", matches: [BrowserSuggestion(title: "Local", url: URL(string: "http://localhost:8768/path")!)]) == "localhost:8768")
    }
    @Test func visitCountDecodesLegacyAndIsBounded() throws {
        let entry = HistoryEntry(title: "Old", url: URL(string: "https://old.test")!)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object.removeValue(forKey: "visitCount")
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.visitCount == 1)
        #expect(HistoryEntry(title: "Bad", url: entry.url, visitCount: .max).visitCount == 1_000_000)
    }
    @Test func typedHistoryOutranksAnOtherwiseMoreVisitedAddress() {
        let now = Date()
        let typed = HistoryEntry(title: "Typed", url: URL(string: "https://docs.test/typed")!, visitedAt: now, visitCount: 2, typedCount: 2)
        let visited = HistoryEntry(title: "Visited", url: URL(string: "https://docs.test/visited")!, visitedAt: now, visitCount: 5)
        var index = LocalSuggestionIndex()
        index.updateVisits([typed, visited], changed: [])
        #expect(index.matches("docs", now: now).map(\.url) == [typed.url, visited.url])
        index.updateVisits([], changed: [typed.url])
        #expect(index.matches("docs", now: now).map(\.url) == [visited.url])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORIV_HISTORY_BENCHMARK"] == "1"))
    func fiftyThousandHistoryKeystrokes() {
        let now = Date()
        let history = (0..<50_000).map { number in
            HistoryEntry(title: "Documentation guide \(number)",
                         url: URL(string: "https://host\(number % 1200).example.test/path/\(number)")!,
                         visitedAt: now.addingTimeInterval(Double(-number * 60)), visitCount: 1 + number % 30, typedCount: number % 5)
        }
        var index = LocalSuggestionIndex()
        index.updateVisits(history, changed: [])
        let tabs = [BrowserSuggestion(title: "Open Documentation", url: history[49_999].url, tabID: UUID())]
        let cases = ["h", "host", "docs", "documentation", "example", "/path/", "guide 49999",
                     "host1199", "guide doc", "zz", "not-found"]
        var worst: Double = 0
        for query in cases {
            var samples: [Double] = []
            for _ in 0..<30 {
                let start = ContinuousClock.now
                let matches = index.matches(query, tabs: tabs, now: now)
                let elapsed = start.duration(to: .now)
                samples.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
                #expect(matches.count <= 7)
            }
            samples.sort()
            worst = max(worst, samples[28])
            print("HISTORY_BENCHMARK query=\(query) median_ms=\(samples[15]) p95_ms=\(samples[28]) max_ms=\(samples[29])")
        }
        #expect(worst < 8, "50k indexed matching p95 must stay within half a frame")
    }

    @Test func tenThousandHistoryQueriesStayWithinFrameBudget() throws {
        let now = Date()
        let history = (0..<10_000).map { HistoryEntry(title: "Documentation guide \($0)", url: URL(string: "https://host\($0).example.test/path")!, visitedAt: now.addingTimeInterval(Double(-$0)), visitCount: 1 + $0 % 20) }
        var index = LocalSuggestionIndex()
        index.update(history: history, bookmarks: [])
        var samples: [Double] = []
        for query in ["host", "Documentation", "example", "path", "not-found", "host9999", "guide", "doc"] {
            let start = ContinuousClock.now
            let result = index.matches(query, tabs: [BrowserSuggestion(title: "Open Documentation", url: history[9999].url, tabID: UUID())], now: now)
            let elapsed = start.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
            samples.append(ms)
            print("SUGGESTION_QUERY query=\(query) ms=\(ms)")
            #expect(result.count <= 7)
        }
        print("SUGGESTION_PERF entries=10000 median_ms=\(samples.sorted()[samples.count/2]) max_ms=\(samples.max()!)")
        #expect(samples.max()! < 16, "10k indexed matching must stay under 16 ms")
    }
}
