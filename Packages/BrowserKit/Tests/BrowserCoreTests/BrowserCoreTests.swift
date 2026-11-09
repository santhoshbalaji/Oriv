import Foundation
import Testing
@testable import BrowserCore

@Suite("Address interpretation")
struct AddressTests {
    @Test func resolvesWebsitesAndLocalDevelopment() throws {
        #expect(try AddressResolver.resolve(" example.com/docs ").absoluteString == "https://example.com/docs")
        #expect(try AddressResolver.resolve("http://example.com").scheme == "http")
        #expect(try AddressResolver.resolve("localhost:8080/hello").absoluteString == "http://localhost:8080/hello")
        #expect(try AddressResolver.resolve("127.0.0.1:8090").scheme == "http")
        #expect(try AddressResolver.resolve("[::1]:8080").scheme == "http")
    }

    @Test func encodesSearchWithoutInjectingParameters() throws {
        let result = try AddressResolver.resolve("swift & webkit #tabs")
        let parts = try #require(URLComponents(url: result, resolvingAgainstBaseURL: false))
        #expect(parts.host == "duckduckgo.com")
        #expect(parts.queryItems == [URLQueryItem(name: "q", value: "swift & webkit #tabs")])
        #expect(try AddressResolver.resolve("SwiftUI 26.0 features").host == "duckduckgo.com")
    }

    @Test(arguments: ["javascript:alert(1)", "data:text/html,hello", "file:///etc/passwd", "ftp://example.com", "about:config"])
    func rejectsExecutableAndLocalSchemes(_ input: String) {
        #expect(throws: AddressError.unsupportedScheme) { try AddressResolver.resolve(input) }
    }

    @Test func rejectsAmbiguousCredentialsAndMalformedURLs() {
        #expect(throws: AddressError.invalidURL) { try AddressResolver.resolve("https://user:password@example.com") }
        #expect(throws: AddressError.invalidURL) { try AddressResolver.resolve("https://") }
        #expect(throws: AddressError.invalidURL) { try AddressResolver.resolve("https://example.com:99999") }
        #expect(throws: AddressError.empty) { try AddressResolver.resolve(" \n ") }
    }
}

@Suite("Session durability")
struct SessionTests {
    private func inTemporaryStore(_ body: (SessionFileStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(SessionFileStore(fileURL: directory.appendingPathComponent("session.json")))
    }

    @Test func roundTripsSelectionAndBookmarks() throws {
        try inTemporaryStore { store in
            let a = TabRecord(url: URL(string: "https://example.com"))
            let b = TabRecord(url: URL(string: "https://apple.com"))
            let saved = BrowserSnapshot(tabs: [a, b], selectedTabID: b.id,
                                        bookmarks: [Bookmark(title: "Example", url: a.url!)])
            try store.save(saved)
            #expect(try store.load().snapshot == saved)
            let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
        }
    }

    @Test func recoversLastValidSessionAfterTruncatedWrite() throws {
        try inTemporaryStore { store in
            let first = BrowserSnapshot(tabs: [TabRecord(title: "First")])
            try store.save(first)
            try store.save(BrowserSnapshot(tabs: [TabRecord(title: "Second")]))
            try Data("{broken".utf8).write(to: store.fileURL)
            let result = try store.load()
            #expect(result.recoveredFromBackup)
            #expect(result.snapshot?.tabs.first?.title == "First")
        }
    }

    @Test func preservesFutureSessionFormats() throws {
        try inTemporaryStore { store in
            try store.save(BrowserSnapshot())
            var future = BrowserSnapshot()
            future.version = 99
            let data = try JSONEncoder().encode(future)
            try data.write(to: store.fileURL)
            #expect(throws: SessionFileError.self) { try store.load() }
            #expect(try Data(contentsOf: store.fileURL) == data)
        }
    }

    @Test func sanitizesRestoredNavigationAndSelection() {
        let id = UUID()
        let good = TabRecord(id: id, url: URL(string: "https://example.com"))
        let bad = TabRecord(url: URL(string: "file:///private/file"))
        let input = BrowserSnapshot(tabs: [good, good, bad], selectedTabID: bad.id)
        let result = input.sanitized()
        #expect(result.tabs == [good])
        #expect(result.selectedTabID == id)
    }
}

@Suite("Native tab durability")
struct NativeTabRecordTests {
    @Test func migratesLegacyTabsWithoutInventingNativeDestinations() throws {
        let a = UUID(), b = UUID()
        let data = Data("""
        {"version":1,"tabs":[{"id":"\(a)","title":"Start"},{"id":"\(b)","title":"Page","url":"https://example.com","isPinned":true}],"selectedTabID":"\(b)","bookmarks":[],"history":[]}
        """.utf8)
        let legacy = try JSONDecoder().decode(BrowserSnapshot.self, from: data)
        #expect(legacy.tabs[0].content == .home)
        #expect(legacy.tabs[1].content == .web)
        #expect(legacy.tabs[1].isPinned)
        #expect(legacy.selectedTabID == b)
    }
    @Test func removesRetiredDestinationsAndPreservesWebTabsAndBookmarks() throws {
        let webID = UUID(), removedID = UUID(), bookmark = Bookmark(title: "Saved", url: URL(string: "https://example.com")!)
        let original = BrowserSnapshot(tabs: [TabRecord(id: webID, title: "Page", url: bookmark.url, isPinned: true)], bookmarks: [bookmark])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var tabs = try #require(json["tabs"] as? [[String: Any]])
        for kind in ["workspace", "dashboard", "conversation"] {
            tabs.append(["id": removedID.uuidString, "title": "Retired", "content": [kind: [:]]])
        }
        json["tabs"] = tabs; json["version"] = 2; json["selectedTabID"] = removedID.uuidString; json.removeValue(forKey: "legacyBookmarksImported")
        let decoded = try JSONDecoder().decode(BrowserSnapshot.self, from: JSONSerialization.data(withJSONObject: json)).sanitized()
        #expect(decoded.tabs.count == 1)
        #expect(decoded.tabs[0].id == webID)
        #expect(decoded.tabs[0].isPinned)
        #expect(decoded.selectedTabID == webID)
        #expect(decoded.bookmarks == [bookmark])
        #expect(decoded.legacyBookmarksImported == nil)
    }
    @Test func futureDestinationFormatCannotSilentlyRollBackToBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionFileStore(fileURL: root.appendingPathComponent("session.json"))
        try store.save(BrowserSnapshot(tabs: [TabRecord()]))
        try store.save(BrowserSnapshot(tabs: [TabRecord(title: "Page", url: URL(string: "https://example.com"))]))
        let future = Data("{\"version\":99,\"tabs\":[{\"content\":{\"unknownFutureType\":{}}}]}".utf8)
        try future.write(to: store.fileURL)
        #expect(throws: SessionFileError.self) { try store.load() }
        #expect(try Data(contentsOf: store.fileURL) == future)
    }
}
