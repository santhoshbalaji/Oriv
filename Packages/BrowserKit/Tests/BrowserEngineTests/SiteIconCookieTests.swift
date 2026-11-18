import Foundation
@testable import BrowserEngine
import XCTest

@MainActor final class SiteIconCookieTests: XCTestCase {
    func testIconTransportDoesNotCopyOtherSitesProfileCookies() throws {
        func cookie(_ name: String, domain: String) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie(properties: [.name: name, .value: "fixture", .domain: domain, .path: "/"]))
        }
        let host = try cookie("host", domain: "page.example.test")
        let parent = try cookie("parent", domain: ".example.test")
        let other = try cookie("other", domain: "bank.test")
        let sibling = try cookie("sibling", domain: "account.example.test")
        let cookies = [host, parent, other, sibling]
        let filtered = SiteIconStore.firstPartyCookies(cookies, pageURL: URL(string: "https://page.example.test/article")!)
        XCTAssertEqual(Set(filtered.map(\.name)), ["host", "parent"])
        XCTAssertTrue(SiteIconStore.firstPartyCookies(cookies, pageURL: URL(string: "https://notexample.test")!).isEmpty)
    }
}
