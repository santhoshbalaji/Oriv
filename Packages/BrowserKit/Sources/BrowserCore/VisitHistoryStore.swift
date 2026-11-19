import Foundation
import SQLite3

/// A single SQLite connection protected by a lock. The session writes and pages
/// on the main actor; the suggestion actor reads and consumes its own change set.
public final class VisitHistoryStore: @unchecked Sendable {
    public static let maximumVisits = 50_000
    public static let sharedLimit = 500

    private let lock = NSLock()
    private let db: OpaquePointer
    private let limit: Int
    private var suggestionChanges: Set<URL> = []
    private var suggestionsSeeded = false

    public init(fileURL: URL? = nil, limit: Int = maximumVisits) throws {
        self.limit = max(1, limit)
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var connection: OpaquePointer?
        let result = sqlite3_open(fileURL?.path ?? ":memory:", &connection)
        guard result == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw Failure()
        }
        db = connection
        try run("PRAGMA secure_delete = ON")
        let version = try query("PRAGMA user_version") { sqlite3_column_int($0, 0) }.first
        guard version == 0 || version == 1 else { throw Failure() }
        try run("""
            CREATE TABLE IF NOT EXISTS visits (
                id TEXT PRIMARY KEY NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL,
                date REAL NOT NULL, visits INTEGER NOT NULL, typed INTEGER NOT NULL,
                local INTEGER NOT NULL, shared INTEGER NOT NULL,
                search TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS history_date ON visits(date DESC, id);
            CREATE INDEX IF NOT EXISTS history_url ON visits(url, date DESC, id);
            CREATE INDEX IF NOT EXISTS history_shared ON visits(date DESC, id) WHERE shared = 1;
            CREATE TABLE IF NOT EXISTS migration (id INTEGER PRIMARY KEY);
            PRAGMA user_version = 1;
            """)
        if let fileURL {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    deinit { sqlite3_close(db) }

    public func migrate(_ entries: [HistoryEntry]) throws {
        try write(prune: true) {
            guard try query("SELECT id FROM migration WHERE id = 1", row: { sqlite3_column_int($0, 0) }).isEmpty else { return [] }
            var shared = Set<URL>()
            for entry in entries.sorted(by: { $0.visitedAt > $1.visitedAt }) where AddressResolver.isWebURL(entry.url) {
                let share = shared.count < Self.sharedLimit && shared.insert(entry.url).inserted
                try insert(entry, local: true, shared: share)
            }
            try run("INSERT INTO migration VALUES (1)")
            return entries.map(\.url)
        }
    }

    public func record(_ entry: HistoryEntry, shared: Bool) throws {
        guard AddressResolver.isWebURL(entry.url) else { return }
        try write(prune: true) {
            if shared { _ = try demoteShared(where: "url = ?", [.text(entry.url.absoluteString)]) }
            try insert(entry, local: true, shared: shared)
            return [entry.url]
        }
    }

    @discardableResult public func updateTitle(id: UUID, url: URL, title: String) throws -> Bool {
        var updated = false
        try write {
            let urls = try query("""
                UPDATE visits SET title = ?, search = ?
                WHERE id = ? AND url = ? AND title != ? RETURNING url
                """, [.text(title), .text(Self.fold(title + " " + url.absoluteString)), .text(id.uuidString), .text(url.absoluteString), .text(title)], row: readURL)
            updated = !urls.isEmpty
            return urls
        }
        return updated
    }

    public func remove(_ id: UUID) throws {
        try write { try delete(where: "id = ?", [.text(id.uuidString)]) }
    }

    public func clear(since: Date) throws {
        try write { try delete(where: "date >= ?", [.real(since.timeIntervalSinceReferenceDate)]) }
    }

    public var count: Int {
        get throws { try lock.withLock { try countRows() } }
    }

    public func page(search: String = "", offset: Int = 0, limit: Int = 100) throws -> [HistoryEntry] {
        try lock.withLock {
            if search.isEmpty {
                return try query("SELECT \(columns) FROM visits ORDER BY date DESC, id LIMIT ? OFFSET ?",
                                 [.int(limit), .int(offset)], row: readEntry)
            }
            return try query("SELECT \(columns) FROM visits WHERE instr(search, ?) > 0 ORDER BY date DESC, id LIMIT ? OFFSET ?",
                             [.text(Self.fold(search)), .int(limit), .int(offset)], row: readEntry)
        }
    }

    public func recentDistinct(limit: Int) throws -> [HistoryEntry] {
        try lock.withLock {
            try query("""
                SELECT \(columns) FROM visits AS candidate
                WHERE id = (SELECT id FROM visits WHERE url = candidate.url ORDER BY date DESC, id LIMIT 1)
                ORDER BY date DESC, id LIMIT ?
                """, [.int(limit)], row: readEntry)
        }
    }

    public func sharedHistory() throws -> [HistoryEntry] {
        try lock.withLock {
            try query("SELECT \(columns) FROM visits WHERE shared = 1 ORDER BY date DESC, id", row: readEntry)
        }
    }

    /// The continuity journal retries this operation if either store fails.
    public func applyShared(_ entries: [HistoryEntry], prunedIDs: Set<UUID>, removedIDs: Set<UUID>,
                            clearRanges: [ClosedRange<Date>], saveSession: () throws -> Void) throws {
        try write(prune: true) {
            var changed = Set<URL>()
            let incoming = Set(entries.map(\.id))
            let previous = try query("SELECT \(columns) FROM visits WHERE shared = 1", row: readEntry)
            for entry in previous where !incoming.contains(entry.id) {
                let id = Binding.text(entry.id.uuidString)
                if prunedIDs.contains(entry.id) {
                    _ = try demoteShared(where: "id = ?", [id])
                    changed.insert(entry.url)
                } else {
                    changed.formUnion(try delete(where: "id = ?", [id]))
                }
            }
            for id in removedIDs { changed.formUnion(try delete(where: "id = ?", [.text(id.uuidString)])) }
            let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            for entry in entries where entry != previousByID[entry.id] && AddressResolver.isWebURL(entry.url) {
                try insert(entry, local: false, shared: true)
                changed.insert(entry.url)
            }
            for range in clearRanges {
                changed.formUnion(try delete(where: "date BETWEEN ? AND ?", [
                    .real(range.lowerBound.timeIntervalSinceReferenceDate), .real(range.upperBound.timeIntervalSinceReferenceDate)
                ]))
            }
            try saveSession()
            return Array(changed)
        }
    }

    /// The first read returns all URL aggregates. Subsequent reads include
    /// only changed URLs, including those that no longer have any visits.
    public func suggestionDelta() throws -> (entries: [HistoryEntry], changed: Set<URL>) {
        try lock.withLock {
            let entries: [HistoryEntry]
            if suggestionsSeeded {
                entries = try suggestionChanges.flatMap { url in
                    try query("""
                        SELECT latest.id, latest.url, latest.title, latest.date, counts.visits, counts.typed
                        FROM (SELECT \(columns) FROM visits WHERE url = ? ORDER BY date DESC, id LIMIT 1) AS latest
                        CROSS JOIN (SELECT min(1000000, sum(visits)) AS visits, min(1000000, sum(typed)) AS typed
                                    FROM visits WHERE url = ?) AS counts
                        """, [.text(url.absoluteString), .text(url.absoluteString)], row: readEntry)
                }
            } else {
                // SQLite's single max() selects the associated visit's title and ID.
                entries = try query("""
                    SELECT id, url, title, max(date), min(1000000, sum(visits)), min(1000000, sum(typed))
                    FROM visits GROUP BY url
                    """, row: readEntry)
                suggestionsSeeded = true
            }
            let changed = suggestionChanges
            suggestionChanges.removeAll()
            return (entries, changed)
        }
    }

    private func write(prune: Bool = false, _ changes: () throws -> [URL]) throws {
        try lock.withLock {
            try run("BEGIN IMMEDIATE")
            do {
                let changed = try changes()
                var evicted: [URL] = []
                if prune {
                    if try countRows() > limit {
                        evicted = try delete(where: "id IN (SELECT id FROM visits ORDER BY date DESC, id LIMIT -1 OFFSET ?)", [.int(limit)])
                    }
                    let extraShared = try query("SELECT id FROM visits WHERE shared = 1 ORDER BY date DESC, id LIMIT -1 OFFSET ?",
                                                [.int(Self.sharedLimit)]) { string($0, 0) }
                    for id in extraShared { evicted += try demoteShared(where: "id = ?", [.text(id)]) }
                }
                try run("COMMIT")
                if suggestionsSeeded {
                    suggestionChanges.formUnion(changed)
                    suggestionChanges.formUnion(evicted)
                }
            } catch {
                try? run("ROLLBACK")
                throw error
            }
        }
    }

    private let columns = "id, url, title, date, visits, typed"

    private func insert(_ entry: HistoryEntry, local: Bool, shared: Bool) throws {
        try execute("""
            INSERT INTO visits VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, search = excluded.search, shared = excluded.shared
            """, [.text(entry.id.uuidString), .text(entry.url.absoluteString), .text(entry.title),
                  .real(entry.visitedAt.timeIntervalSinceReferenceDate), .int(entry.visitCount), .int(entry.typedCount),
                  .int(local ? 1 : 0), .int(shared ? 1 : 0), .text(Self.fold(entry.title + " " + entry.url.absoluteString))])
    }

    private func demoteShared(where predicate: String, _ values: [Binding]) throws -> [URL] {
        try execute("UPDATE visits SET shared = 0 WHERE shared = 1 AND (\(predicate))", values)
        // Received visits are only a projection until this device visits them itself.
        return try delete(where: "local = 0 AND shared = 0 AND (\(predicate))", values)
    }

    private func delete(where predicate: String, _ values: [Binding]) throws -> [URL] {
        try query("DELETE FROM visits WHERE \(predicate) RETURNING url", values, row: readURL)
    }

    private func countRows() throws -> Int {
        try query("SELECT count(*) FROM visits") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func readEntry(_ statement: OpaquePointer) throws -> HistoryEntry {
        guard let id = UUID(uuidString: string(statement, 0)), let url = URL(string: string(statement, 1)) else { throw Failure() }
        return HistoryEntry(id: id, title: string(statement, 2), url: url,
                            visitedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3)),
                            visitCount: Int(sqlite3_column_int64(statement, 4)), typedCount: Int(sqlite3_column_int64(statement, 5)))
    }

    private func readURL(_ statement: OpaquePointer) throws -> URL {
        guard let url = URL(string: string(statement, 0)) else { throw Failure() }
        return url
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    private enum Binding { case text(String), int(Int), real(Double) }
    private struct Failure: LocalizedError {
        var errorDescription: String? { "The browsing history database could not be read or saved." }
    }

    private func run(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure() }
    }

    private func execute(_ sql: String, _ values: [Binding]) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func query<T>(_ sql: String, _ values: [Binding] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        var prepared: OpaquePointer?
        defer { sqlite3_finalize(prepared) }
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw Failure() }
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString {
                    sqlite3_bind_text(prepared, slot, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .int(let value): result = sqlite3_bind_int64(prepared, slot, Int64(value))
            case .real(let value): result = sqlite3_bind_double(prepared, slot, value)
            }
            guard result == SQLITE_OK else { throw Failure() }
        }
        var rows: [T] = []
        var status = sqlite3_step(prepared)
        while status == SQLITE_ROW {
            rows.append(try row(prepared))
            status = sqlite3_step(prepared)
        }
        guard status == SQLITE_DONE else { throw Failure() }
        return rows
    }
}
