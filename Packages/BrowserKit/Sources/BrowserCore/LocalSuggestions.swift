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
        var key: String
        var title: String
        var historyTitle: String?
        var text: String
        var foldedTitle: String
        var host: String
        var visits: Int
        var typed: Int
        var date: Date
        var bookmarked: Bool
        var rank: Double

        var suggestion: BrowserSuggestion? {
            URL(string: key).map { BrowserSuggestion(title: title, url: $0,
                source: bookmarked ? .bookmark : .history) }
        }
    }
    private struct RankedKey: Sendable {
        var key: String
        var date: Date
        var rank: Double

        static func precedes(_ a: Self, _ b: Self) -> Bool {
            if a.rank != b.rank { return a.rank > b.rank }
            if a.date != b.date { return a.date > b.date }
            return a.key < b.key
        }
    }
    private var entries: [String: Entry] = [:]
    private var ordered: [RankedKey] = []
    private let rankingDate = Date()

    // Broad terms use the ranked scan. Small postings retain exact candidates;
    // a broad posting can keep its count without holding thousands of addresses.
    private struct Posting: Sendable {
        var count = 0
        var single: String?
        var others: Set<String>?

        mutating func insert(_ key: String, cap: Int) {
            count += 1
            switch count {
            case 1: single = key
            case cap:
                single = nil
                others = nil
            case 2..<cap:
                if let single {
                    others = [single, key]
                    self.single = nil
                } else { others?.insert(key) }
            default: break
            }
        }

        mutating func remove(_ key: String) {
            count -= 1
            if single == key { single = nil }
            others?.remove(key)
        }

        var candidates: Set<String>? {
            if let single { return [single] }
            return others
        }
    }

    private var hostWords: [String: Posting] = [:]
    private var titleWords: [String: Posting] = [:]
    private var hostKeys: [String] = []
    private var titleKeys: [String] = []
    private var grams: [UInt32: Posting] = [:]
    private var shortGrams: [UInt32: Int] = [:]

    private static func gramKeys(_ text: String) -> (short: Set<UInt32>, long: Set<UInt32>) {
        var short = Set<UInt32>(), long = Set<UInt32>()
        var pair: UInt32 = 0
        var count = 0
        for byte in text.utf8 {
            let gram = pair << 8 | UInt32(byte)
            short.insert(UInt32(byte))
            if count >= 1 { short.insert(0x10000 | gram & 0xffff) }
            if count >= 2 { long.insert(gram) }
            pair = gram & 0xffff
            count += 1
        }
        return (short, long)
    }

    private static func contains(_ text: String, bytes: [UInt8]) -> Bool {
        var text = text
        return text.withUTF8 { text in
            bytes.withUnsafeBufferPointer { query in
                memmem(text.baseAddress, text.count, query.baseAddress, query.count) != nil
            }
        }
    }

    private var savedBookmarks: [String: Bookmark] = [:]
    public init() {}
    private static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 128 }) { return text.lowercased() }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public mutating func update(history: [HistoryEntry], bookmarks: [Bookmark]) {
        updateVisits(history, changed: Set(entries.keys))
        updateBookmarks(bookmarks)
    }

    public mutating func replaceVisits(_ history: [VisitHistoryStore.SuggestionVisit]) {
        var replacement = Self()
        replacement.savedBookmarks = savedBookmarks
        replacement.applyVisits(history, changed: Set(savedBookmarks.keys))
        self = replacement
    }

    public mutating func applyVisitDelta(_ history: [VisitHistoryStore.SuggestionVisit], changed: Set<URL>) {
        applyVisits(history, changed: Set(changed.map(\.absoluteString)))
    }

    public mutating func updateVisits(_ history: [HistoryEntry], changed: Set<URL>) {
        updateVisits(history, changed: Set(changed.map(\.absoluteString)))
    }

    private mutating func updateVisits(_ history: [HistoryEntry], changed: Set<String>) {
        let latest = Dictionary(history.map { ($0.url.absoluteString, $0) }, uniquingKeysWith: {
            $0.visitedAt > $1.visitedAt ? $0 : $1
        })
        let visits = latest.map { key, visit in
            VisitHistoryStore.SuggestionVisit(id: visit.id, address: key, title: visit.title,
                visitedAt: visit.visitedAt, visitCount: visit.visitCount, typedCount: visit.typedCount)
        }
        applyVisits(visits, changed: changed)
    }

    private mutating func applyVisits(_ visits: [VisitHistoryStore.SuggestionVisit], changed: Set<String>) {
        let batch = visits.count + changed.count > 64
        entries.reserveCapacity(max(entries.count, visits.count))
        var removals = changed
        for visit in visits {
            let key = visit.address
            removals.remove(key)
            let title = savedBookmarks[key]?.title ?? visit.title
            let entry = makeEntry(key: key, title: title, historyTitle: visit.title,
                host: entries[key]?.host ?? URL(string: key)?.host ?? "", visits: visit.visitCount,
                typed: visit.typedCount, date: visit.visitedAt, bookmarked: savedBookmarks[key] != nil)
            setEntry(entry, key: key, batch: batch)
        }
        for key in removals {
            let entry = savedBookmarks[key].map { bookmark in
                makeEntry(key: key, title: bookmark.title, host: bookmark.url.host ?? "", bookmarked: true)
            }
            setEntry(entry, key: key, batch: batch)
        }
        if batch { finishBatch() }
    }

    public mutating func updateBookmarks(_ bookmarks: [Bookmark]) {
        let latest = Dictionary(bookmarks.map { ($0.url.absoluteString, $0) }, uniquingKeysWith: { a, _ in a })
        let changes = Set(savedBookmarks.keys).union(latest.keys).filter { savedBookmarks[$0] != latest[$0] }
        savedBookmarks = latest
        let batch = changes.count > 64
        for key in changes {
            let old = entries[key], bookmark = latest[key]
            let title = bookmark?.title ?? old?.historyTitle
            let entry = title.map { title in
                makeEntry(key: key, title: title, historyTitle: old?.historyTitle,
                    host: old?.host ?? bookmark?.url.host ?? "", visits: old?.visits ?? 0,
                    typed: old?.typed ?? 0, date: old?.date ?? .distantPast, bookmarked: bookmark != nil)
            }
            setEntry(entry, key: key, batch: batch)
        }
        if batch { finishBatch() }
    }

    private static func updatePosting<Key>(_ map: inout [Key: Posting], term: Key, key: String, cap: Int, adding: Bool) {
        if adding { map[term, default: Posting()].insert(key, cap: cap) }
        else {
            map[term]?.remove(key)
            if map[term]?.count == 0 { map[term] = nil }
        }
    }

    private mutating func index(_ entry: Entry, adding: Bool, batch: Bool) {
        for token in Set(entry.host.split(separator: ".").map(String.init) + [entry.host]) {
            Self.updatePosting(&hostWords, term: token, key: entry.key, cap: 65, adding: adding)
            if !batch { Self.updateKey(token, keys: &hostKeys, exists: hostWords[token] != nil) }
        }
        for token in Set(entry.foldedTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)) {
            Self.updatePosting(&titleWords, term: token, key: entry.key, cap: 65, adding: adding)
            if !batch { Self.updateKey(token, keys: &titleKeys, exists: titleWords[token] != nil) }
        }
        let terms = Self.gramKeys(entry.text)
        for gram in terms.short {
            let count = shortGrams[gram, default: 0] + (adding ? 1 : -1)
            shortGrams[gram] = count == 0 ? nil : count
        }
        for gram in terms.long {
            Self.updatePosting(&grams, term: gram, key: entry.key, cap: 128, adding: adding)
        }
    }

    private static func updateKey(_ key: String, keys: inout [String], exists: Bool) {
        let position = lowerBound(keys) { $0 < key }
        let present = position < keys.count && keys[position] == key
        if present && !exists { keys.remove(at: position) }
        if !present && exists { keys.insert(key, at: position) }
    }

    private mutating func setEntry(_ entry: Entry?, key: String, batch: Bool) {
        let old = entries[key]
        if !batch, let old {
            let ranked = rankedKey(old)
            ordered.remove(at: Self.lowerBound(ordered) { RankedKey.precedes($0, ranked) })
        }
        if old?.text != entry?.text {
            if let old { index(old, adding: false, batch: batch) }
            if let entry { index(entry, adding: true, batch: batch) }
        }
        entries[key] = entry
        if !batch, let entry {
            let ranked = rankedKey(entry)
            ordered.insert(ranked, at: Self.lowerBound(ordered) { RankedKey.precedes($0, ranked) })
        }
    }

    private mutating func finishBatch() {
        ordered = entries.values.map(rankedKey)
        ordered.sort(by: RankedKey.precedes)
        hostKeys = hostWords.keys.sorted()
        titleKeys = titleWords.keys.sorted()
    }

    private func rankedKey(_ entry: Entry) -> RankedKey {
        RankedKey(key: entry.key, date: entry.date, rank: entry.rank)
    }

    private static func lowerBound<T>(_ values: [T], before: (T) -> Bool) -> Int {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) / 2
            if before(values[mid]) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func makeEntry(key: String, title: String, historyTitle: String? = nil, host: String, visits: Int = 0,
                           typed: Int = 0, date: Date = .distantPast, bookmarked: Bool = false) -> Entry {
        let indexedTitle = historyTitle.map { $0 == title ? title : title + "\n" + $0 } ?? title
        let foldedTitle = Self.fold(indexedTitle)
        var host = Self.fold(host)
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return Entry(key: key, title: title, historyTitle: historyTitle, text: Self.fold(key) + " " + foldedTitle, foldedTitle: foldedTitle,
                     host: host, visits: visits, typed: typed, date: date, bookmarked: bookmarked,
                     rank: Self.score(visits: visits, typed: typed, date: date, bookmarked: bookmarked, now: rankingDate))
    }

    public func matches(_ query: String, tabs: [BrowserSuggestion] = [], limit: Int = 7, now: Date = Date()) -> [BrowserSuggestion] {
        let query = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty, limit > 0 else { return [] }
        let hostQuery = query.hasPrefix("www.") ? String(query.dropFirst(4)) : query
        var open: [String: Entry] = [:]
        var openSuggestions: [String: BrowserSuggestion] = [:]
        for tab in tabs.sorted(by: { ($0.tabID?.uuidString ?? "") < ($1.tabID?.uuidString ?? "") }) {
            let key = tab.url.absoluteString
            let title = Self.fold(tab.title)
            if var duplicate = open[key] {
                duplicate.text += "\n" + title
                duplicate.foldedTitle += "\n" + title
                open[key] = duplicate
                continue
            }
            var entry = entries[key] ?? makeEntry(key: key, title: tab.title, host: tab.url.host ?? "")
            if entries[key] != nil {
                entry.text += " " + title
                entry.foldedTitle += "\n" + title
            }
            open[key] = entry
            openSuggestions[key] = tab
        }
        var result: [BrowserSuggestion] = []
        var used: Set<String> = []
        func append(_ entry: Entry) {
            guard result.count < limit, used.insert(entry.key).inserted,
                  let suggestion = openSuggestions[entry.key] ?? entry.suggestion else { return }
            result.append(suggestion)
        }
        func hasHostPrefix(_ entry: Entry) -> Bool {
            !hostQuery.isEmpty && (entry.host.hasPrefix(hostQuery)
                || entry.host.split(separator: ".").contains { $0.hasPrefix(hostQuery) })
        }
        func hasTitlePrefix(_ entry: Entry) -> Bool {
            entry.foldedTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(query) }
        }
        let openRanked = open.values.sorted { better($0, $1, now: now) }
        for entry in openRanked where hasHostPrefix(entry) || hasTitlePrefix(entry) || Self.fold(entry.key).hasPrefix(query) {
            append(entry)
        }
        func prefixCandidates(_ prefix: String, keys: [String], words: [String: Posting]) -> Set<String>? {
            guard !prefix.isEmpty else { return [] }
            var position = Self.lowerBound(keys) { $0 < prefix }
            var candidates = Set<String>()
            while position < keys.count && keys[position].hasPrefix(prefix) {
                guard let posting = words[keys[position]]?.candidates else { return nil }
                candidates.formUnion(posting)
                if candidates.count > 64 { return nil }
                position += 1
            }
            return candidates
        }
        func addTier(_ candidates: Set<String>?, predicate: (Entry) -> Bool) {
            guard result.count < limit else { return }
            if let candidates {
                for entry in candidates.compactMap({ entries[$0] }).sorted(by: { better($0, $1, now: now) }) {
                    if predicate(entry) { append(entry) }
                }
            } else {
                for candidate in ordered {
                    guard let entry = entries[candidate.key], predicate(entry) else { continue }
                    append(entry)
                    if result.count == limit { break }
                }
            }
        }
        addTier(prefixCandidates(hostQuery, keys: hostKeys, words: hostWords), predicate: hasHostPrefix)
        addTier(prefixCandidates(query, keys: titleKeys, words: titleWords), predicate: hasTitlePrefix)
        if result.count < limit {
            let bytes = Array(query.utf8)
            let terms = Self.gramKeys(query)
            let absent = bytes.count < 3
                ? terms.short.contains { shortGrams[$0] == nil }
                : terms.long.contains { grams[$0] == nil }
            if !absent {
                let rarest = terms.long.compactMap { grams[$0]?.candidates }.min { $0.count < $1.count }
                addTier(rarest) { Self.contains($0.text, bytes: bytes) }
            }
            for entry in openRanked where Self.contains(entry.text, bytes: bytes) { append(entry) }
        }
        return result
    }
    private static func score(visits: Int, typed: Int, date: Date, bookmarked: Bool, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return (bookmarked ? 20 : 0) + log2(Double(visits) + 1) * 3 + log2(Double(typed) + 1) * 6 + 10 / (1 + days / 7)
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
