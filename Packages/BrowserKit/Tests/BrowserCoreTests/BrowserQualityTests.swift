import Foundation
import Testing
@testable import BrowserCore

@Suite("Browser quality contracts")
struct BrowserQualityTests {
    @Test func searchProvidersEncodeOnlyOneQueryParameter() throws {
        for engine in SearchEngine.allCases {
            let url = try AddressResolver.resolve("a & b #c + d", searchEngine: engine)
            #expect(url.scheme == "https")
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "q", value: "a & b #c + d")])
            #expect(try AddressResolver.resolve("example.com/path", searchEngine: engine).host == "example.com")
        }
    }
    @Test func permissionOriginsSeparatePortsSchemesAndHostnames() {
        let secure = SiteOrigin(URL(string: "https://EXAMPLE.com/path?q=1")!)
        #expect(secure == SiteOrigin(URL(string: "https://example.com:443/other")!))
        #expect(secure != SiteOrigin(URL(string: "http://example.com")!))
        #expect(secure != SiteOrigin(URL(string: "https://example.com:8443")!))
        #expect(secure != SiteOrigin(URL(string: "https://example.com.attacker.test")!))
        #expect(SiteOrigin(URL(string: "https://user:password@example.com")!) == nil)
        #expect(SiteOrigin(URL(string: "file:///tmp/test")!) == nil)
    }
    @Test func legacyTabsDecodeAndPinnedTabsRoundTrip() throws {
        let id = UUID()
        let legacy = Data("{\"id\":\"\(id)\",\"title\":\"Legacy\",\"url\":\"https://example.com\"}".utf8)
        var record = try JSONDecoder().decode(TabRecord.self, from: legacy)
        #expect(!record.isPinned)
        record.isPinned = true
        #expect(try JSONDecoder().decode(TabRecord.self, from: JSONEncoder().encode(record)) == record)
    }
    @Test func bookmarkImportIsInertBoundedAndDeduplicated() throws {
        let html = #"<DL><A HREF="https://example.com/?a=1&amp;b=2">A &amp; B &#x1F310;</A><A HREF='javascript:alert(1)'>Unsafe</A><A HREF='https://user:secret@example.com'>Credentials</A><A HREF='https://example.com/?a=1&amp;b=2'>Duplicate</A><A data-href='https://wrong.test'>Ignore</A></DL>"#
        let parsed = try BookmarkTransfer.parse(Data(html.utf8))
        #expect(parsed.bookmarks.count == 1)
        #expect(parsed.skipped == 4)
        #expect(parsed.bookmarks.first?.title == "A & B 🌐")
        #expect(parsed.bookmarks.first?.url.absoluteString == "https://example.com/?a=1&b=2")
        #expect(throws: BookmarkTransferError.self) { try BookmarkTransfer.parse(Data(repeating: 65, count: 5_000_001)) }
    }
    @Test func exportedBookmarksRoundTripWithoutActiveMarkup() throws {
        let item = Bookmark(title: #"<script>alert("x")</script> & 🌐"#, url: URL(string: "https://example.com/?q=%22x%22&a=1")!)
        let exported = BookmarkTransfer.export([item])
        #expect(!String(decoding: exported, as: UTF8.self).contains("<script>"))
        let restored = try BookmarkTransfer.parse(exported)
        #expect(restored.bookmarks.first?.title == item.title)
        #expect(restored.bookmarks.first?.url == item.url)
    }
}
