import Testing
@testable import BrowserCore

@Suite("Site monograms")
struct SiteMonogramTests {
    @Test func ordinaryDomainsIgnoreSubdomains() {
        #expect(SiteMonogram.label(for: "developer.apple.com") == "apple")
        #expect(SiteMonogram.label(for: "en.wikipedia.org") == "wikipedia")
        #expect(SiteMonogram.label(for: "swift.org") == "swift")
    }

    @Test func commonMultipartSuffixesUseTheSiteLabel() {
        for suffix in ["co.uk", "com.au", "co.jp", "co.in", "com.br", "co.nz", "org.uk", "ac.uk", "gov.uk"] {
            #expect(SiteMonogram.label(for: "bbc.\(suffix)") == "bbc")
            #expect(SiteMonogram.label(for: "news.bbc.\(suffix)") == "bbc")
        }
    }

    @Test func normalizesCaseAndTrailingDot() {
        #expect(SiteMonogram.label(for: " WWW.BBC.CO.UK. ") == "bbc")
    }

    @Test func localNamesAndUnicodeRemainUsable() {
        #expect(SiteMonogram.label(for: "localhost") == "localhost")
        #expect(SiteMonogram.label(for: "தமிழ்.com") == "தமிழ்")
    }

    @Test func addressesAndEmptyNamesFallBackToGlobe() {
        for host: String? in [nil, "", " ", ".", "127.0.0.1", "[::1]", "2001:db8::1", "bad..example.com"] {
            #expect(SiteMonogram.label(for: host) == nil)
        }
    }

    @Test func suffixAloneHasNoSiteLabel() {
        #expect(SiteMonogram.label(for: "co.uk") == nil)
        #expect(SiteMonogram.label(for: "com.au") == nil)
    }

    @Test func unknownSuffixUsesTheDocumentedTwoLabelFallback() {
        #expect(SiteMonogram.label(for: "site.unknown.example") == "unknown")
        #expect(SiteMonogram.label(for: "example.uk") == "example")
    }
}
