import Darwin
import Foundation

public struct BrowserSuggestion: Identifiable, Equatable, Sendable {
    public enum Source: String, Sendable { case tab = "Switch to Tab", bookmark = "Bookmarks", history = "History", search = "Search" }
    public var title: String
    public var url: URL
    public var tabID: UUID?
    public var source: Source
    public var id: URL { url }
    public init(title: String, url: URL, tabID: UUID? = nil, source: Source = .history) {
        self.title = title; self.url = url; self.tabID = tabID; self.source = tabID == nil ? source : .tab
    }
}

/// Normalizes only changed records. Matching reads folded strings and retains
/// a bounded top-k rather than sorting the entire history on each keystroke.
public struct LocalSuggestionIndex: Sendable {
    private struct Entry: Sendable {
        var suggestion: BrowserSuggestion
        var text: String
        var words: [Substring]
        var address: String
        var host: String
        var visits: Int
        var typed: Int
        var date: Date
        var bookmarked: Bool
        var rank: Double
        var key: String
    }
    private var entries: [URL: Entry] = [:]
    private var ordered: [Entry] = []
    private var hostWords: [String: Set<URL>] = [:]
    private var titleWords: [String: Set<URL>] = [:]
    private var hostKeys: [String] = []
    private var titleKeys: [String] = []
    private var grams: [UInt32: Set<URL>] = [:]
    private var shortGramCounts: [UInt32: Int] = [:]
    private let rankingDate = Date()
    private static func trigrams(_ text: String) -> Set<UInt32> {
        let bytes = Array(text.utf8)
        guard bytes.count >= 3 else { return [] }
        var result = Set<UInt32>()
        for i in 0..<(bytes.count - 2) {
            let high = UInt32(bytes[i]) << 16
            let middle = UInt32(bytes[i + 1]) << 8
            let low = UInt32(bytes[i + 2])
            result.insert(high | middle | low)
        }
        return result
    }
    private static func shortGrams(_ bytes: [UInt8]) -> Set<UInt32> {
        var result = Set<UInt32>()
        for (index, byte) in bytes.enumerated() {
            result.insert(UInt32(byte))
            if index > 0 { result.insert(0x10000 | UInt32(bytes[index - 1]) << 8 | UInt32(byte)) }
        }
        return result
    }

    private static func contains(_ text: String, bytes: [UInt8]) -> Bool {
        var text = text
        return text.withUTF8 { text in
            bytes.withUnsafeBufferPointer { query in
                memmem(text.baseAddress, text.count, query.baseAddress, query.count) != nil
            }
        }
    }

    private mutating func index(_ entry: Entry, adding: Bool) {
        let url = entry.suggestion.url
        for word in Set(hostTokens(entry)) {
            if adding { hostWords[word, default: []].insert(url) }
            else { hostWords[word]?.remove(url); if hostWords[word]?.isEmpty == true { hostWords[word] = nil } }
        }
        for word in Set(entry.words.map(String.init)) {
            if adding { titleWords[word, default: []].insert(url) }
            else { titleWords[word]?.remove(url); if titleWords[word]?.isEmpty == true { titleWords[word] = nil } }
        }
        for gram in Self.shortGrams(Array(entry.text.utf8)) {
            let count = shortGramCounts[gram, default: 0] + (adding ? 1 : -1)
            shortGramCounts[gram] = count == 0 ? nil : count
        }
        for gram in Self.trigrams(entry.text) {
            if adding { grams[gram, default: []].insert(url) }
            else { grams[gram]?.remove(url); if grams[gram]?.isEmpty == true { grams[gram] = nil } }
        }
    }
    private var savedHistory: [URL: HistoryEntry] = [:]
    private var savedBookmarks: [URL: Bookmark] = [:]
    public init() {}
    private static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    public mutating func update(history: [HistoryEntry], bookmarks: [Bookmark]) {
        updateVisits(history, changed: Set(savedHistory.keys))
        updateBookmarks(bookmarks)
    }

    public mutating func updateVisits(_ history: [HistoryEntry], changed: Set<URL>) {
        let latest = Dictionary(history.map { ($0.url, $0) }, uniquingKeysWith: { a, b in a.visitedAt > b.visitedAt ? a : b })
        let changes = changed.union(latest.keys).filter { savedHistory[$0] != latest[$0] }
        for url in changes { savedHistory[url] = latest[url] }
        refresh(changes)
    }

    public mutating func updateBookmarks(_ bookmarks: [Bookmark]) {
        let latest = Dictionary(bookmarks.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let changes = Set(savedBookmarks.keys).union(latest.keys).filter { savedBookmarks[$0] != latest[$0] }
        savedBookmarks = latest
        refresh(changes)
    }

    private mutating func refresh(_ changes: Set<URL>) {
        guard !changes.isEmpty else { return }
        let batch = changes.count > 64
        var changedHosts = Set<String>(), changedTitles = Set<String>()
        for url in changes {
            let old = entries[url]
            let history = savedHistory[url], bookmark = savedBookmarks[url]
            let new = (bookmark?.title ?? history?.title).map { title in
                makeEntry(BrowserSuggestion(title: title, url: url, source: bookmark == nil ? .history : .bookmark),
                          titles: [title, history?.title ?? ""], visits: history?.visitCount ?? 0,
                          typed: history?.typedCount ?? 0, date: history?.visitedAt ?? .distantPast,
                          bookmarked: bookmark != nil)
            }
            if let old {
                if !batch { ordered.remove(at: Self.lowerBound(ordered) { Self.rankedBefore($0, old) }) }
                if new?.text != old.text { index(old, adding: false) }
                changedHosts.formUnion(hostTokens(old))
                changedTitles.formUnion(old.words.map(String.init))
            }
            entries[url] = new
            if let new {
                if !batch { ordered.insert(new, at: Self.lowerBound(ordered) { Self.rankedBefore($0, new) }) }
                if old?.text != new.text { index(new, adding: true) }
                changedHosts.formUnion(hostTokens(new))
                changedTitles.formUnion(new.words.map(String.init))
            }
        }
        if batch {
            ordered = entries.values.sorted(by: Self.rankedBefore)
            hostKeys = hostWords.keys.sorted()
            titleKeys = titleWords.keys.sorted()
        } else {
            Self.updateKeys(&hostKeys, changed: changedHosts) { hostWords[$0] != nil }
            Self.updateKeys(&titleKeys, changed: changedTitles) { titleWords[$0] != nil }
        }
    }

    private func hostTokens(_ entry: Entry) -> [String] {
        entry.host.split(separator: ".").map(String.init) + [entry.host]
    }

    private static func updateKeys(_ keys: inout [String], changed: Set<String>, exists: (String) -> Bool) {
        for key in changed {
            let position = lowerBound(keys) { $0 < key }
            let present = position < keys.count && keys[position] == key
            if present && !exists(key) { keys.remove(at: position) }
            if !present && exists(key) { keys.insert(key, at: position) }
        }
    }

    private static func lowerBound<T>(_ values: [T], before: (T) -> Bool) -> Int {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) / 2
            if before(values[mid]) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func makeEntry(_ suggestion: BrowserSuggestion, titles: [String], visits: Int = 0, typed: Int = 0,
                           date: Date = .distantPast, bookmarked: Bool = false) -> Entry {
        let text = Self.fold(titles.joined(separator: "\n"))
        let address = Self.fold(suggestion.url.absoluteString)
        var host = Self.fold(suggestion.url.host ?? "")
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return Entry(suggestion: suggestion, text: address + " " + text,
                     words: text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }), address: address, host: host,
                     visits: visits, typed: typed, date: date, bookmarked: bookmarked,
                     rank: Self.score(visits: visits, typed: typed, date: date, bookmarked: bookmarked, now: rankingDate),
                     key: suggestion.url.absoluteString)
    }
    public func matches(_ query: String, tabs: [BrowserSuggestion] = [], limit: Int = 7, now: Date = Date()) -> [BrowserSuggestion] {
        let query = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }
        let hostQuery = query.hasPrefix("www.") ? String(query.dropFirst(4)) : query
        var open: [URL: Entry] = [:]
        for tab in tabs.sorted(by: { ($0.tabID?.uuidString ?? "") < ($1.tabID?.uuidString ?? "") }) {
            if var duplicate = open[tab.url] {
                let title = Self.fold(tab.title)
                duplicate.text += "\n" + title
                duplicate.words += title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                open[tab.url] = duplicate
                continue
            }
            var entry = entries[tab.url] ?? makeEntry(tab, titles: [])
            entry.suggestion = tab
            let title = Self.fold(tab.title)
            entry.text += " " + title; entry.words += title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            open[tab.url] = entry
        }
        let merged = ordered
        var result: [BrowserSuggestion] = []
        var used: Set<URL> = []
        func append(_ entry: Entry) {
            guard result.count < limit, used.insert(entry.suggestion.url).inserted else { return }
            result.append(open[entry.suggestion.url]?.suggestion ?? entry.suggestion)
        }
        func prefixURLs(_ prefix: String, keys: [String], words: [String: Set<URL>]) -> Set<URL>? {
            guard !prefix.isEmpty else { return [] }
            var low = Self.lowerBound(keys) { $0 < prefix }
            var result: Set<URL> = []
            while low < keys.count && keys[low].hasPrefix(prefix) {
                let urls = words[keys[low]] ?? []
                if urls.count > 64 { return nil }
                result.formUnion(urls)
                if result.count > 64 { return nil }
                low += 1
            }
            return result
        }
        let hostMatches = prefixURLs(hostQuery, keys: hostKeys, words: hostWords)
        let titleMatches = prefixURLs(query, keys: titleKeys, words: titleWords)
        for entry in open.values.sorted(by: { better($0, $1, now: now) }) {
            if (!hostQuery.isEmpty && (entry.host.hasPrefix(hostQuery) || entry.host.split(separator: ".").contains(where: { $0.hasPrefix(hostQuery) })))
                || entry.words.contains(where: { $0.hasPrefix(query) }) || entry.address.hasPrefix(query) { append(entry) }
        }
        func addTier(_ candidates: Set<URL>?, predicate: (Entry) -> Bool) {
            guard result.count < limit else { return }
            if let candidates {
                for entry in candidates.compactMap({ entries[$0] }).sorted(by: { better($0, $1, now: now) }) { append(entry) }
            } else {
                for entry in merged {
                    if predicate(entry) { append(entry) }
                    if result.count == limit { break }
                }
            }
        }
        addTier(hostMatches) { $0.host.hasPrefix(hostQuery) || $0.host.split(separator: ".").contains { $0.hasPrefix(hostQuery) } }
        addTier(titleMatches) { $0.words.contains { $0.hasPrefix(query) } }
        if result.count < limit {
            let bytes = Array(query.utf8)
            let queryGrams = Self.trigrams(query)
            let absent = bytes.count < 3
                ? Self.shortGrams(bytes).contains { shortGramCounts[$0] == nil }
                : queryGrams.contains { grams[$0] == nil }
            let rarest = queryGrams.compactMap { grams[$0] }.min { $0.count < $1.count }
            if !absent {
                let candidates: [Entry]
                if let rarest, rarest.count < 128 {
                    candidates = rarest.compactMap { open[$0] ?? entries[$0] }.sorted { better($0, $1, now: now) }
                } else { candidates = merged }
                for entry in candidates {
                    if Self.contains(entry.text, bytes: bytes) { append(entry) }
                    if result.count == limit { break }
                }
            }
            // Private / unsaved open-tab text is absent from the regular index.
            for entry in open.values.sorted(by: { better($0, $1, now: now) }) {
                if Self.contains(entry.text, bytes: bytes) { append(entry) }
            }
        }
        return result
    }
    private static func score(visits: Int, typed: Int, date: Date, bookmarked: Bool, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return (bookmarked ? 20 : 0) + log2(Double(visits) + 1) * 3 + log2(Double(typed) + 1) * 6 + 10 / (1 + days / 7)
    }

    private static func rankedBefore(_ a: Entry, _ b: Entry) -> Bool {
        if a.rank != b.rank { return a.rank > b.rank }
        if a.date != b.date { return a.date > b.date }
        return a.key < b.key
    }

    private func better(_ a: Entry, _ b: Entry, now: Date) -> Bool {
        let aScore = Self.score(visits: a.visits, typed: a.typed, date: a.date, bookmarked: a.bookmarked, now: now)
        let bScore = Self.score(visits: b.visits, typed: b.typed, date: b.date, bookmarked: b.bookmarked, now: now)
        if aScore != bScore { return aScore > bScore }
        if a.date != b.date { return a.date > b.date }
        return a.key < b.key
    }
    /// Host-only completion keeps ports, never silently accepts a path or query.
    public static func completion(for query: String, matches: [BrowserSuggestion]) -> String? {
        guard query.count >= 1, !query.contains(where: { $0.isWhitespace }), !query.contains("/"), !query.contains(":") else { return nil }
        let hosts = matches.lazy.compactMap { match -> String? in
            guard var host = match.url.host else { return nil }
            if host.hasPrefix("www."), !query.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }
            let defaultPort = match.url.scheme == "https" ? 443 : 80
            if let port = match.url.port, port != defaultPort { host += ":\(port)" }
            return host
        }
        guard let host = hosts.first(where: { $0.lowercased().hasPrefix(query.lowercased()) && $0.count > query.count }) else { return nil }
        return query + host.dropFirst(query.count)
    }
}
