import XCTest
@testable import BrowserCore

final class ChromeScrollStateTests: XCTestCase {
    func testFractionalTopJitterNeverEntersScrolledMode() {
        var state = ChromeScrollState()
        for (i, y) in [0.0, 0.2, 1.2, 2, -8, 0, 9.9, 10, -0.5].enumerated() {
            state.update(offset: y, at: Double(i)); state.settle(at: Double(i) + 1)
            XCTAssertFalse(state.isScrolled)
        }
    }
    func testHysteresisAndDwellInBothDirections() {
        var state = ChromeScrollState()
        state.update(offset: 11, at: 0); state.settle(at: 0.07); XCTAssertFalse(state.isScrolled)
        state.settle(at: 0.09); XCTAssertTrue(state.isScrolled)
        for y in [9.0, 5, 2, 1.1] { state.update(offset: y, at: 1); XCTAssertTrue(state.isScrolled) }
        state.update(offset: 1, at: 2); state.settle(at: 2.07); XCTAssertTrue(state.isScrolled)
        state.settle(at: 2.09); XCTAssertFalse(state.isScrolled)
    }
    func testRapidCrossingsCoalesceAndPendingEntryIsCancelled() {
        var state = ChromeScrollState()
        for i in 0..<100 { state.update(offset: i.isMultiple(of: 2) ? 30 : 0, at: Double(i) * 0.01) }
        state.settle(at: 2); XCTAssertFalse(state.isScrolled); XCTAssertNil(state.deadline)
        state.update(offset: 20, at: 3); state.update(offset: 5, at: 3.04)
        state.settle(at: 4); XCTAssertFalse(state.isScrolled)
    }
    func testMomentumDoesNotRestartDwellAndBounceCannotLeaveScrolledMode() {
        var state = ChromeScrollState()
        state.update(offset: 12, at: 0); state.update(offset: 24, at: 0.03); state.update(offset: 80, at: 0.06)
        state.settle(at: 0.09); XCTAssertTrue(state.isScrolled)
        for y in [-1.0, -40, -.infinity, .nan] { state.update(offset: y, at: 1); state.settle(at: 2); XCTAssertTrue(state.isScrolled) }
        state.update(offset: 0, at: 3); state.update(offset: 8, at: 3.04)
        state.settle(at: 4); XCTAssertTrue(state.isScrolled)
    }
    func testStablePaintKeepsCacheThroughTransientHeaderAndCanvasResults() {
        var paint = ChromeStableValue<String>()
        XCTAssertTrue(paint.update("purple", at: 0))
        XCTAssertFalse(paint.update("white", at: 1)); XCTAssertEqual(paint.value, "purple")
        XCTAssertFalse(paint.update("purple", at: 1.05)); XCTAssertNil(paint.deadline)
        XCTAssertFalse(paint.update("white", at: 2))
        XCTAssertFalse(paint.update("white", at: 2.1))
        XCTAssertTrue(paint.update("white", at: 2.13)); XCTAssertEqual(paint.value, "white")
    }
    func testChangingStickyPaintMustRemainStableAndResetIsDocumentScoped() {
        var paint = ChromeStableValue<Int>()
        XCTAssertTrue(paint.update(1, at: 0))
        for i in 1...50 { XCTAssertFalse(paint.update(i.isMultiple(of: 2) ? 2 : 3, at: Double(i) * 0.01)) }
        XCTAssertEqual(paint.value, 1)
        XCTAssertTrue(paint.update(2, at: 0.7)); XCTAssertEqual(paint.value, 2)
        paint = ChromeStableValue(); XCTAssertTrue(paint.update(4, at: 1)); XCTAssertEqual(paint.value, 4)
    }
}
