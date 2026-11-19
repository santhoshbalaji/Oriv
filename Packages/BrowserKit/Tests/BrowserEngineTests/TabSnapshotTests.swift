import XCTest
import BrowserCore
@testable import BrowserEngine
import WebKit
import CoreGraphics

@MainActor final class TabSnapshotTests: XCTestCase {
    func testBudgetChargesStoredBytesAndEvictsLeastRecentlyUsed() throws {
        let image = try snapshot(width:100,height:100)
        XCTAssertEqual(image.cost, image.jpeg.count + 256)
        let cache = TabSnapshotCache(byteLimit:image.cost*2)
        let a = UUID(), b = UUID(), c = UUID()
        cache.insert(image,for:a); cache.insert(image,for:b)
        XCTAssertNotNil(cache.snapshot(for:a))
        cache.insert(image,for:c)
        XCTAssertNil(cache.snapshot(for:b))
        XCTAssertNotNil(cache.snapshot(for:a)); XCTAssertNotNil(cache.snapshot(for:c))
        XCTAssertEqual(cache.cost,image.cost*2); XCTAssertEqual(cache.count,2)
        let oversized = TabSnapshotCache.Snapshot(jpeg:Data(count:1),width:641,height:1)
        cache.insert(oversized,for:a)
        XCTAssertNil(cache.snapshot(for:a)); XCTAssertLessThanOrEqual(cache.cost,cache.byteLimit)
        cache.removeAll(); XCTAssertEqual(cache.count,0); XCTAssertEqual(cache.cost,0)
    }
    func testDefaultBudgetRetainsTwentyDistinctViewportSnapshots() throws {
        let cache = TabSnapshotCache()
        let ids = (0..<24).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            let image = try snapshot(width: 1280, height: 960, variant: index)
            cache.insert(image, for: id)
        }
        XCTAssertEqual(cache.count, ids.count)
        XCTAssertTrue(ids.allSatisfy { cache.snapshot(for: $0) != nil })
        XCTAssertLessThanOrEqual(cache.cost, cache.byteLimit)
    }
    func testDownsamplingBoundsWideAndTallImages() throws {
        for (w,h) in [(2400,1800),(400,3200)] {
            let image = try snapshot(width:w,height:h)
            XCTAssertLessThanOrEqual(max(image.width,image.height),640)
            XCTAssertEqual(Double(image.width)/Double(image.height),Double(w)/Double(h),accuracy:0.01)
            XCTAssertLessThan(image.jpeg.count,image.width*image.height*4)
        }
    }
    func testUniformUnpaintedSurfacesAreNotCachedAsMeaningfulPages() throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:100,height:100,bitsPerComponent:8,bytesPerRow:400,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        for gray in [CGFloat(0),CGFloat(1)] {
            context.setFillColor(CGColor(gray:gray,alpha:1)); context.fill(CGRect(x:0,y:0,width:100,height:100))
            XCTAssertNil(TabSnapshotCache.compress(try XCTUnwrap(context.makeImage())))
        }
    }
    func testCompressionRetainsViewportPointsIndependentlyOfRetinaPixels() throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:1600,height:1200,bitsPerComponent:8,bytesPerRow:6400,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:1600,height:1200))
        context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:100,y:100,width:200,height:200))
        let snapshot = try XCTUnwrap(TabSnapshotCache.compress(try XCTUnwrap(context.makeImage()),pointSize:CGSize(width:800,height:600)))
        XCTAssertEqual(snapshot.pointSize,CGSize(width:800,height:600))
        XCTAssertEqual(snapshot.width,640); XCTAssertEqual(snapshot.height,480)
    }
    func testPrivateImagesAreNotSerializedAndCloseInvalidatesLateCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("session.json")
        let session = BrowserSession(store:SessionFileStore(fileURL:file),dataStore:.nonPersistent(),adBlocker:AdBlocker(defaults:nil),settings:BrowserSettings(defaults:nil))
        defer { session.shutdown() }
        let tab = session.addTab(url:URL(string:"https://private.invalid/secret")!,isPrivate:true,load:false)
        let image = try snapshot(width:100,height:100)
        session.tabSnapshots.insert(image,for:tab.id)
        XCTAssertNotNil(tab.switchSnapshot)
        session.saveNow(); session.flushPersistence()
        let persisted = try String(contentsOf:file,encoding:.utf8)
        XCTAssertFalse(persisted.contains("private.invalid")); XCTAssertFalse(persisted.contains("jpeg"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path).sorted(),["session.json"])
        session.closeTab(tab.id)
        XCTAssertNil(session.tabSnapshots.snapshot(for:tab.id)); XCTAssertNil(tab.switchSnapshot)
        let token = try XCTUnwrap(session.tabSnapshots.beginCapture())
        session.shutdown()
        XCTAssertFalse(session.tabSnapshots.finishCapture(token)); XCTAssertEqual(session.tabSnapshots.cost,0)
    }
    func testPressureInvalidatesInflightCaptureAndAllowsNextRequest() throws {
        let cache = TabSnapshotCache()
        let first = try XCTUnwrap(cache.beginCapture())
        XCTAssertNil(cache.beginCapture())
        cache.removeAll()
        let second = try XCTUnwrap(cache.beginCapture())
        XCTAssertFalse(cache.finishCapture(first)); XCTAssertTrue(cache.finishCapture(second))
    }
    func testCaptureDeadlineDoesNotBlockFutureSwitches() async throws {
        let cache = TabSnapshotCache()
        let first = try XCTUnwrap(cache.beginCapture())
        try await Task.sleep(for:.milliseconds(850))
        XCTAssertFalse(cache.finishCapture(first)); XCTAssertNotNil(cache.beginCapture())
        cache.removeAll()
    }
    func testNewDestinationInvalidatesPreviousSnapshotAndPaintMessagesDoNotReleaseIt() throws {
        let tab = BrowserTab(dataStore:.nonPersistent())
        defer { tab.close() }
        let cache = TabSnapshotCache(); tab.snapshotCache = cache
        cache.insert(try snapshot(width:100,height:100),for:tab.id)
        tab.navigate(to:URL(string:"https://example.invalid/new")!)
        XCTAssertNil(tab.switchSnapshot)
        tab.recordFirstPaint(1234)
        XCTAssertFalse(tab.hasRenderedContent,"An unidentified old document cannot release the cover")
        tab.close(); tab.recordFirstPaint(1234)
        XCTAssertFalse(tab.hasRenderedContent)
    }
    func testLiveReserveUsesSelectionRecencyAndDoesNotInstantiateDormantTabs() throws {
        let session = BrowserSession(dataStore:.nonPersistent(),adBlocker:AdBlocker(defaults:nil),settings:BrowserSettings(defaults:nil))
        defer { session.shutdown() }
        let tabs = (0..<5).map { _ in session.addTab(load:false) }
        for (index,tab) in tabs.enumerated() { _ = tab.webView; tab.lastSelectedTime = Double(index) }
        XCTAssertEqual(session.recentLiveTabIDs,Set(tabs.suffix(3).map(\.id)))
        tabs[0].recoveryClock = { 100 }
        session.selectTab(tabs[0].id)
        XCTAssertTrue(session.recentLiveTabIDs.contains(tabs[0].id))
        let dormant = session.addTab(select:false,load:false)
        XCTAssertFalse(session.recentLiveTabIDs.contains(dormant.id)); XCTAssertFalse(dormant.isInstantiated)
    }
    private func snapshot(width:Int,height:Int,variant:Int = 0) throws -> TabSnapshotCache.Snapshot {
        let context = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2 + Double(variant) / 100,green:0.7,blue:0.4,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:width/4,y:height/4,width:width/2,height:height/2))
        return try XCTUnwrap(TabSnapshotCache.compress(try XCTUnwrap(context.makeImage())))
    }
}
