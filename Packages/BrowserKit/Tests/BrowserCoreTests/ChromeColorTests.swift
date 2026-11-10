import XCTest
@testable import BrowserCore

final class ChromeColorTests: XCTestCase {
    private let white = ChromeColor(1, 1, 1), purple = ChromeColor(0.4, 0, 0.9), neutral = ChromeColor(0.92, 0.92, 0.92)
    func testConstrainedEdgeWins() {
        XCTAssertEqual(ChromeColorSelection.select(edge: purple, body: white, html: white, underPage: white, neutral: neutral), purple)
    }
    func testBodyHtmlUnderPageFallbacks() {
        XCTAssertEqual(ChromeColorSelection.select(edge: nil, body: purple, html: white, underPage: white, neutral: neutral), purple)
        XCTAssertEqual(ChromeColorSelection.select(edge: nil, body: nil, html: purple, underPage: white, neutral: neutral), purple)
        XCTAssertEqual(ChromeColorSelection.select(edge: nil, body: nil, html: nil, underPage: purple, neutral: neutral), purple)
        XCTAssertEqual(ChromeColorSelection.select(edge: nil, body: nil, html: nil, underPage: nil, neutral: neutral), neutral)
    }
    func testAlphaThresholdAndAppleHeader() {
        let apple = ChromeColor(22.0/255, 22.0/255, 23.0/255, alpha: 0.8)
        XCTAssertEqual(ChromeColorSelection.select(edge: apple, body: white, html: nil, underPage: nil, neutral: neutral), ChromeColor(22.0/255,22.0/255,23.0/255))
        XCTAssertEqual(ChromeColorSelection.select(edge: ChromeColor(0,0,0,alpha:0.75), body: white, html:nil, underPage:nil, neutral:neutral), ChromeColor(0,0,0))
        XCTAssertEqual(ChromeColorSelection.select(edge: ChromeColor(0,0,0,alpha:0.5), body:white, html:nil, underPage:nil, neutral:neutral), ChromeColor(0.5,0.5,0.5))
    }
    func testDimmingOverlayAlwaysComposites() {
        XCTAssertEqual(ChromeColorSelection.select(edge:ChromeColor(0,0,0,alpha:0.8), body:white, html:nil, isDimming:true, underPage:nil, neutral:neutral).red, 0.2, accuracy: 0.0001)
    }
    func testTransparentAndInvalidColorsFallThrough() {
        for edge in [ChromeColor(0,0,0,alpha:0), ChromeColor(.nan,0,0)] {
            XCTAssertEqual(ChromeColorSelection.select(edge:edge, body:purple, html:white, underPage:white, neutral:neutral), purple)
        }
        XCTAssertEqual(ChromeColorSelection.select(edge:nil, body:ChromeColor(1,0,0,alpha:0.5), html:white, underPage:nil, neutral:neutral), ChromeColor(1,0.5,0.5))
    }
    func testForegroundContrastAcrossColorCube() {
        for r in stride(from: 0.0, through: 1, by: 0.1) {
            for g in stride(from: 0.0, through: 1, by: 0.1) {
                for b in stride(from: 0.0, through: 1, by: 0.1) { XCTAssertGreaterThanOrEqual(ChromeColor(r, g, b).foregroundContrast, 4.5) }
            }
        }
        XCTAssertTrue(purple.whiteForeground)
        XCTAssertFalse(white.whiteForeground)
    }
    func testPrivateIgnoresSiteColors() {
        XCTAssertEqual(ChromeColorSelection.select(edge:white, body:purple, html:white, underPage:white, neutral:neutral, isPrivate:true), neutral)
    }
}
