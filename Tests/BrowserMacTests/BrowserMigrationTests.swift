import CoreData
import WebKit
import XCTest
@testable import BrowserCore
import BrowserEngine

@MainActor final class BrowserMigrationTests: XCTestCase {
    func testSavedLinksUpgradeOnceAndUserDeletionSurvivesRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("workspace.sqlite")
        let saved = Bookmark(title: "Retained link", url: URL(string: "https://example.test/kept")!), trashed = Bookmark(title: "Trashed", url: URL(string: "https://example.test/trashed")!)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LegacyBookmarkReader.legacyModel())
        let persistent = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: oldURL, options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
        for bookmark in [saved, trashed] {
            let record = NSEntityDescription.insertNewObject(forEntityName: "SavedItem", into: context)
            record.setValue(bookmark.id, forKey: "id"); record.setValue(bookmark.title, forKey: "title")
            record.setValue(bookmark.url.absoluteString, forKey: "url"); record.setValue(bookmark.createdAt, forKey: "createdAt")
            if bookmark.id == trashed.id { record.setValue(Date.now, forKey: "deletedAt") }
        }
        try context.save(); try coordinator.remove(persistent)
        let original = try Data(contentsOf: oldURL)
        let file = SessionFileStore(fileURL: root.appendingPathComponent("session.json"))
        try file.save(BrowserSnapshot(bookmarks: [trashed]))
        let first = BrowserSession(store: file, dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        await first.importLegacyBookmarks(from: oldURL)
        XCTAssertEqual(first.bookmarks, [saved]); XCTAssertTrue(first.snapshot().legacyBookmarksImported == true)
        first.removeBookmark(saved.id); first.shutdown()
        let second = BrowserSession(store: file, dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        defer { second.shutdown() }
        await second.importLegacyBookmarks(from: oldURL)
        XCTAssertTrue(second.bookmarks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: oldURL), original)
    }
    func testPrivatePageCannotCreateBookmarkAndImportDeduplicates() throws {
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        defer { session.shutdown() }
        let url = URL(string: "https://example.test/page")!
        session.addTab(url: url, isPrivate: true, load: false)
        session.toggleBookmark(); XCTAssertTrue(session.bookmarks.isEmpty)
        session.addTab(url: url, load: false); session.toggleBookmark()
        XCTAssertEqual(session.bookmarks.count, 1)
        XCTAssertEqual(session.importBookmarks([Bookmark(title: "Duplicate", url: url)]), 0)
        XCTAssertEqual(session.bookmarks.count, 1)
    }
    func testRetiredAlertCleanupCannotMatchUnrelatedNotifications() {
        XCTAssertTrue(BrowserUpgradeCleanup.isRetiredAlert("oriv.action.\(UUID()).due"))
        XCTAssertTrue(BrowserUpgradeCleanup.isRetiredAlert("oriv.profile.\(UUID()).action.\(UUID()).early"))
        XCTAssertFalse(BrowserUpgradeCleanup.isRetiredAlert("website.notification.123"))
        XCTAssertFalse(BrowserUpgradeCleanup.isRetiredAlert("oriv.profile.not-a-profile.action.123"))
        XCTAssertFalse(BrowserUpgradeCleanup.isRetiredAlert("oriv.profile.\(UUID()).download.123"))
    }
}
