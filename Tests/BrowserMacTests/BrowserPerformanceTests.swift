import BrowserCore
import BrowserEngine
import WebKit
import XCTest
@testable import PersonalBrowser

/// Repeatable local setup measurements, not page-load or WebKit subprocess benchmarks.
@MainActor final class BrowserPerformanceTests: XCTestCase {
    func testRestoreOneTabBaseline() throws { try measureRestoration(count: 1) }
    func testRestoreTenTabsBaseline() throws { try measureRestoration(count: 10) }
    func testRestoreThirtyTabsBaseline() throws { try measureRestoration(count: 30) }

    private func measureRestoration(count: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SessionFileStore(fileURL: directory.appendingPathComponent("session.json"))
        let tabs = (0..<count).map { TabRecord(title: "Page \($0)", url: URL(string: "https://example.test/\($0)")) }
        try file.save(BrowserSnapshot(tabs: tabs, selectedTabID: tabs.first?.id, legacyBookmarksImported: true))
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            autoreleasepool {
                let session = BrowserSession(store: file, dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
                XCTAssertEqual(session.tabs.count, count)
                XCTAssertTrue(session.tabs.allSatisfy { !$0.isInstantiated }, "Restoration must not create hidden web views or load background pages")
                session.shutdown()
            }
        }
    }

    func testBrowserStartupDoesNotCreateOptionalServiceStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = BrowserController(rootDirectory: root, testing: true)
        defer { controller.shutdown() }
        await controller.session.importLegacyBookmarks(from: root.appendingPathComponent("workspace.sqlite"))
        XCTAssertTrue(controller.session.tabs.allSatisfy { !$0.isInstantiated })
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(Set(names).isSubset(of: ["session.json", "session.json.backup"]))
        XCTAssertTrue(controller.savedBookmarks.isEmpty)
    }
}
