import CoreData
import Foundation
import Testing
@testable import BrowserCore

@Suite("Read-only bookmark upgrade")
struct LegacyBookmarkReaderTests {
    @Test(arguments: [true, false]) func readsBothHistoricalFormatsWithoutChangingTheirBytes(includeWorkflows: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.sqlite"), kept = UUID(), hidden = UUID(), trashed = UUID()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LegacyBookmarkReader.legacyModel(includeWorkflows: includeWorkflows))
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            for (id, state) in [(kept, "active"), (hidden, "archived"), (trashed, "deleted")] {
                let object = NSEntityDescription.insertNewObject(forEntityName: "SavedItem", into: context)
                object.setValue(id, forKey: "id"); object.setValue("Saved தமிழ்", forKey: "title")
                object.setValue("https://example.test/\(id)", forKey: "url"); object.setValue(Date(timeIntervalSince1970: 100), forKey: "createdAt")
                if state == "archived" { object.setValue(Date.now, forKey: "archivedAt") }
                if state == "deleted" { object.setValue(Date.now, forKey: "deletedAt") }
            }
            let note = NSEntityDescription.insertNewObject(forEntityName: "WorkspaceNote", into: context)
            note.setValue(UUID(), forKey: "id"); note.setValue("Retained private note", forKey: "body")
            try context.save()
        }
        try coordinator.remove(store)
        let original = try Data(contentsOf: url)
        let result = try LegacyBookmarkReader.read(at: url)
        #expect(result.bookmarks.map(\.id) == [kept])
        #expect(result.bookmarks.first?.title == "Saved தமிழ்")
        #expect(result.bookmarks.first?.createdAt == Date(timeIntervalSince1970: 100))
        #expect(result.knownIDs == [kept, hidden, trashed])
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func missingStoreIsNeverCreatedAndCorruptStoreIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.sqlite")
        #expect(try LegacyBookmarkReader.read(at: url).bookmarks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let corrupt = Data("original unreadable store".utf8); try corrupt.write(to: url)
        #expect(throws: (any Error).self) { try LegacyBookmarkReader.read(at: url) }
        #expect(try Data(contentsOf: url) == corrupt)
    }
}
