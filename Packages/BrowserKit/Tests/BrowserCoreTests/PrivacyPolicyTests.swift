import Foundation
import Testing
@testable import BrowserCore

@Suite struct PrivacyPolicyTests {
    @Test func cleanerTableAndIdempotence() throws {
        let rows: [(String, String)] = [
            ("https://example.com/a?utm_source=x&id=2&fbclid=abc#keep", "https://example.com/a?id=2#keep"),
            ("https://example.com/?%75tm_medium=a&gclid=x&x=%2f%2F&x=hello+world", "https://example.com/?x=%2f%2F&x=hello+world"),
            ("https://example.com/?utm_A=a&utm_a=b", "https://example.com/"),
            ("https://example.com/?ref=x&source=y&id=3&si=z", "https://example.com/?ref=x&source=y&id=3&si=z"),
            ("https://youtu.be/abc?si=tracking&t=30", "https://youtu.be/abc?t=30"),
            ("https://youtube.com/watch?v=abc&si=tracking", "https://youtube.com/watch?v=abc"),
            ("https://example.com/?a=&utm_x=x&&a=%23#utm_x=keep", "https://example.com/?a=&&a=%23#utm_x=keep"),
            ("https://example.com/?target=https%3A%2F%2Fx.test%3Futm_source%3Da&utm_campaign=z", "https://example.com/?target=https%3A%2F%2Fx.test%3Futm_source%3Da"),
            ("https://example.com/?UTM_SOURCE=x&mc_cid=a&_hsenc=z&gbraid=1&wbraid=2&ttclid=3", "https://example.com/"),
            ("https://example.com/#utm_source=keep", "https://example.com/#utm_source=keep"),
            ("file:///tmp/test?utm_source=x", "file:///tmp/test?utm_source=x")
        ]
        for (raw, expected) in rows {
            let cleaned = URLCleaner.clean(try #require(URL(string: raw)))
            #expect(cleaned.absoluteString == expected)
            #expect(URLCleaner.clean(cleaned) == cleaned)
        }
        for key in URLCleaner.trackingKeys {
            #expect(URLCleaner.clean(URL(string: "https://example.com/?\(key)=x")!).query == nil)
        }
    }
    @Test func sensitiveLinksRemainByteIdentical() {
        let paths = ["/oauth", "/oauth2/callback", "/login", "/checkout", "/payment", "/reset-password", "/magic-link", "/%6co%67in"]
        let keys = ["signature", "sig", "X-Amz-Signature", "X-Amz-Credential", "X-Goog-Algorithm", "token", "state", "code", "SAMLRequest", "RelayState", "client_secret", "expires", "access_token", "redirect_uri"]
        for path in paths { let url = URL(string: "https://example.com\(path)?utm_source=x&x=%2f+%2F")!; #expect(URLCleaner.clean(url) == url) }
        for key in keys { let url = URL(string: "https://example.com/?\(key)=secret&utm_source=x&x=%2f+%2F")!; #expect(URLCleaner.clean(url) == url) }
        let credentials = URL(string: "https://user:pass@example.com/?utm_source=x")!
        #expect(URLCleaner.clean(credentials) == credentials)
    }
    @Test func navigationEligibilityAndLoops() {
        let source = URL(string: "https://source.test/page")!
        let dirty = URL(string: "https://other.test/page?utm_source=x")!
        var request = URLRequest(url: dirty)
        func replace(_ main: Bool = true, _ kind: PrivacyNavigationKind = .newNavigation, _ enabled: Bool = true) -> URL? {
            NavigationCleaningPolicy.replacement(for: request, source: source, isMainFrame: main, kind: kind, enabled: enabled)
        }
        #expect(replace() == URL(string: "https://other.test/page"))
        #expect(NavigationCleaningPolicy.replacement(for: request, source: nil, isMainFrame: true, kind: .newNavigation, enabled: true) == URLCleaner.clean(dirty))
        #expect(replace(false) == nil); #expect(replace(true, .backForward) == nil); #expect(replace(true, .reload) == nil); #expect(replace(true, .newNavigation, false) == nil)
        request.url = replace(); #expect(replace() == nil)
        request.url = dirty; request.httpMethod = "POST"; request.httpBody = Data("form=value".utf8); #expect(replace() == nil)
        request.httpMethod = "GET"; #expect(replace() == nil)
        request.httpBody = nil; request.url = source.appending(queryItems: [URLQueryItem(name: "utm_source", value: "x")]); #expect(replace() == nil)
        #expect(NavigationCleaningPolicy.sameDocument(source, URL(string: source.absoluteString + "#anchor")!))
    }
    @Test func httpsExemptions() {
        for host in ["localhost", "a.localhost", "printer.local", "intranet", "127.0.0.1", "10.0.0.5", "172.16.0.1", "172.31.255.1", "192.168.1.1", "169.254.12.2", "100.64.1.2", "[::1]", "[fc00::1]", "[fd00::1]", "[fe80::1]", "[fe80::1%25en0]", "[febf::1]", "[0:0:0:0:0:0:0:1]", "[::ffff:c0a8:1]"] {
            #expect(HTTPSUpgradePolicy.isExempt(URL(string: "http://\(host)/")!), "\(host)")
        }
        for host in ["example.com", "8.8.8.8", "172.32.0.1", "192.169.1.1", "[2001:4860::8888]"] {
            #expect(!HTTPSUpgradePolicy.isExempt(URL(string: "http://\(host)/")!), "\(host)")
        }
        #expect(HTTPSUpgradePolicy.isExempt(URL(string: "http://captive.apple.com/hotspot-detect.html")!))
        #expect(!HTTPSUpgradePolicy.isExempt(URL(string: "http://captive.apple.com/other")!))
    }
}
