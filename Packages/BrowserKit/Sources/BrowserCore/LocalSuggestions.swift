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
        var date: Date
        var bookmarked: Bool
    }
    private var entries: [URL: Entry] = [:]
    private var ordered: [Entry] = []
    private var hostWords: [String: Set<URL>] = [:]
    private var titleWords: [String: Set<URL>] = [:]
    private var hostKeys: [String] = []
    private var titleKeys: [String] = []
    private var grams: [UInt32: Set<URL>] = [:]
    private static func trigrams(_ text: String) -> Set<UInt32> {
        let bytes = Array(text.utf8)
        guard bytes.count >= 3 else { return [] }
        return Set((0..<(bytes.count - 2)).map { UInt32(bytes[$0]) << 16 | UInt32(bytes[$0+1]) << 8 | UInt32(bytes[$0+2]) })
    }
    private mutating func index(_ entry: Entry, adding: Bool) {
        let url = entry.suggestion.url
        for word in Set(entry.host.split(separator: ".").map(String.init) + [entry.host]) {
            if adding { hostWords[word, default: []].insert(url) }
            else { hostWords[word]?.remove(url); if hostWords[word]?.isEmpty == true { hostWords[word] = nil } }
        }
        for word in Set(entry.words.map(String.init)) {
            if adding { titleWords[word, default: []].insert(url) }
            else { titleWords[word]?.remove(url); if titleWords[word]?.isEmpty == true { titleWords[word] = nil } }
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
        let history = Dictionary(history.map { ($0.url, $0) }, uniquingKeysWith: { a, b in a.visitedAt > b.visitedAt ? a : b })
        let bookmarks = Dictionary(bookmarks.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let urls = Set(savedHistory.keys).union(history.keys).union(savedBookmarks.keys).union(bookmarks.keys)
        for url in urls where savedHistory[url] != history[url] || savedBookmarks[url] != bookmarks[url] {
            if let old = entries[url] { index(old, adding: false) }
            guard let title = bookmarks[url]?.title ?? history[url]?.title else { entries[url] = nil; continue }
            entries[url] = makeEntry(BrowserSuggestion(title: title, url: url, source: bookmarks[url] == nil ? .history : .bookmark),
                titles: [title, history[url]?.title ?? ""], visits: history[url]?.visitCount ?? 0,
                date: history[url]?.visitedAt ?? .distantPast, bookmarked: bookmarks[url] != nil)
            if let entry = entries[url] { index(entry, adding: true) }
        }
        savedHistory = history; savedBookmarks = bookmarks
        hostKeys = hostWords.keys.sorted(); titleKeys = titleWords.keys.sorted()
        let now = Date()
        ordered = entries.values.sorted { better($0, $1, now: now) }
    }
    private func makeEntry(_ suggestion: BrowserSuggestion, titles: [String], visits: Int = 0, date: Date = .distantPast, bookmarked: Bool = false) -> Entry {
        let text = Self.fold(titles.joined(separator: "\n"))
        var host = Self.fold(suggestion.url.host ?? "")
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return Entry(suggestion: suggestion, text: Self.fold(suggestion.url.absoluteString) + " " + text,
                     words: text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }), address: Self.fold(suggestion.url.absoluteString), host: host,
                     visits: visits, date: date, bookmarked: bookmarked)
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
            var low = 0, high = keys.count
            while low < high { let mid = (low + high) / 2; if keys[mid] < prefix { low = mid + 1 } else { high = mid } }
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
                    if candidates?.contains(entry.suggestion.url) == true || ((candidates == nil || entry.suggestion.tabID != nil) && predicate(entry)) { append(entry) }
                    if result.count == limit { break }
                }
            }
        }
        addTier(hostMatches) { $0.host.hasPrefix(hostQuery) || $0.host.split(separator: ".").contains { $0.hasPrefix(hostQuery) } }
        addTier(titleMatches) { $0.words.contains { $0.hasPrefix(query) } }
        if result.count < limit {
            let queryGrams = Self.trigrams(query)
            let absent = queryGrams.contains { grams[$0] == nil }
            let rarest = queryGrams.compactMap { grams[$0] }.min { $0.count < $1.count }
            if !absent {
                let candidates: [Entry]
                if let rarest, rarest.count < 128 {
                    candidates = rarest.compactMap { open[$0] ?? entries[$0] }.sorted { better($0, $1, now: now) }
                } else { candidates = merged }
                for entry in candidates {
                    if entry.text.contains(query) { append(entry) }
                    if result.count == limit { break }
                }
            }
            // Private / unsaved open-tab text is absent from the regular index.
            for entry in open.values.sorted(by: { better($0, $1, now: now) }) {
                if entry.text.contains(query) { append(entry) }
            }
        }
        return result
    }
    private func better(_ a: Entry, _ b: Entry, now: Date) -> Bool {
        func score(_ e: Entry) -> Double {
            let days = max(0, now.timeIntervalSince(e.date) / 86_400)
            return (e.bookmarked ? 20 : 0) + log2(Double(max(0, e.visits)) + 1) * 3 + 10 / (1 + days / 7)
        }
        let aScore = score(a), bScore = score(b)
        if aScore != bScore { return aScore > bScore }
        if a.date != b.date { return a.date > b.date }
        return a.suggestion.url.absoluteString < b.suggestion.url.absoluteString
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
