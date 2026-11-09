import Foundation
import Testing
@testable import BrowserCore

@Suite("Address display")
struct URLDisplayTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func titledRowShowsHostWithoutWWW() {
        // A title that already names the site shows the path rather than repeating it.
        #expect(URLDisplay.secondaryLine(title: "Swift.org", url: url("https://www.swift.org/documentation/")) == "swift.org/documentation/")
        #expect(URLDisplay.secondaryLine(title: "Apple Developer", url: url("https://developer.apple.com/documentation/")) == "developer.apple.com")
        #expect(URLDisplay.secondaryLine(title: "Mail", url: url("https://www.example.com/")) == "example.com")
        // Only a leading www. is removed.
        #expect(URLDisplay.site(url("https://docs.www.example.com/")) == "docs.www.example.com")
    }

    @Test func sameTitlesAddPathThenQueryThenFragment() {
        let rows: [(title: String, url: URL)] = [
            ("Docs", url("https://docs.example.com/guide/install")),
            ("Docs", url("https://docs.example.com/guide/upgrade")),
            ("Docs", url("https://docs.example.com/search?q=tabs")),
            ("Docs", url("https://docs.example.com/search?q=privacy")),
            ("Docs", url("https://docs.example.com/search?q=privacy#results"))
        ]
        let lines = rows.map { URLDisplay.secondaryLine(title: $0.title, url: $0.url, peers: rows) }
        #expect(lines[0] == "docs.example.com/guide/install")
        #expect(lines[1] == "docs.example.com/guide/upgrade")
        #expect(lines[2] == "docs.example.com/search?q=tabs")
        #expect(lines[3] == "docs.example.com/search?q=privacy")
        #expect(lines[4] == "docs.example.com/search?q=privacy#results")
        #expect(Set(lines.compactMap { $0 }).count == rows.count)
    }

    @Test func differentHostsWithSameTitleStayShort() {
        let rows: [(title: String, url: URL)] = [("Home", url("https://a.example/one")), ("Home", url("https://b.example/two"))]
        #expect(URLDisplay.secondaryLine(title: "Home", url: rows[0].url, peers: rows) == "a.example")
    }

    @Test func titleMatchingTheHostShowsOnlyMeaningfulDetail() {
        #expect(URLDisplay.secondaryLine(title: "example.com", url: url("https://example.com/")) == nil)
        #expect(URLDisplay.secondaryLine(title: "", url: url("https://example.com/")) == nil)
        #expect(URLDisplay.secondaryLine(title: "", url: url("https://example.com/a/b")) == "example.com/a/b")
        #expect(URLDisplay.secondaryLine(title: "127.0.0.1", url: url("http://127.0.0.1:8791/li")) == "127.0.0.1:8791/li")
        #expect(URLDisplay.secondaryLine(title: "", url: url("http://localhost:3000/")) == "localhost:3000")
        #expect(URLDisplay.secondaryLine(title: "", url: url("http://localhost:4000/")) == "localhost:4000")
    }

    @Test func portsAreShownOnlyWhenNotDefault() {
        #expect(URLDisplay.site(url("https://example.com:443/")) == "example.com")
        #expect(URLDisplay.site(url("http://example.com:80/")) == "example.com")
        #expect(URLDisplay.site(url("https://example.com:8443/")) == "example.com:8443")
        let rows: [(title: String, url: URL)] = [("App", url("http://localhost:3000/")), ("App", url("http://localhost:4000/"))]
        #expect(URLDisplay.secondaryLine(title: "App", url: rows[0].url, peers: rows) == "localhost:3000")
    }

    @Test func addressActionSaysWhereReturnGoes() {
        #expect(AddressAction.title(for: "  swift tabs ", engine: .duckDuckGo) == "Search DuckDuckGo for “swift tabs”")
        #expect(AddressAction.title(for: "swift tabs", engine: .duckDuckGo, compact: true) == "Search “swift tabs”")
        #expect(AddressAction.symbol(for: "swift tabs", engine: .duckDuckGo) == "magnifyingglass")
        #expect(AddressAction.title(for: "www.example.com/docs", engine: .duckDuckGo) == "Go to www.example.com/docs")
        #expect(AddressAction.title(for: "localhost:8080", engine: .google) == "Go to localhost:8080")
        #expect(AddressAction.symbol(for: "example.com", engine: .duckDuckGo) == "arrow.up.right")
    }

    @Test func hostnameTitlesKeepDifferentRootPorts() {
        let rows: [(title: String, url: URL)] = [("localhost", url("http://localhost:3000/")), ("localhost", url("http://localhost:4000/"))]
        #expect(rows.map { URLDisplay.secondaryLine(title: $0.title, url: $0.url, peers: rows) } == ["localhost:3000", "localhost:4000"])
    }

    @Test func hostnameTitleKeepsSameRootPort() {
        let rows: [(title: String, url: URL)] = [("localhost", url("http://localhost:3000/")), ("localhost", url("http://localhost:3000/"))]
        #expect(rows.allSatisfy { URLDisplay.secondaryLine(title: $0.title, url: $0.url, peers: rows) == "localhost:3000" })
    }

    @Test func titleContainingPortSuppressesOnlyDuplicateDetail() {
        #expect(URLDisplay.secondaryLine(title: "localhost:3000", url: url("http://localhost:3000/")) == nil)
        #expect(URLDisplay.secondaryLine(title: "localhost:3000", url: url("http://localhost:3000/docs")) == "localhost:3000/docs")
    }
}
