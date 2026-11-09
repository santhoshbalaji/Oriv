import CoreData
import Foundation

/// Read-only compatibility adapter. Does not migrate or write the retired database.
public enum LegacyBookmarkReader {
    public struct Result: Sendable {
        public let bookmarks: [Bookmark]
        public let knownIDs: Set<UUID>
        public let knownURLs: Set<URL>
    }
    public static func read(at url: URL) throws -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else { return Result(bookmarks: [], knownIDs: [], knownURLs: []) }
        let options: [AnyHashable: Any] = [NSReadOnlyPersistentStoreOption: true]
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: options)
        guard let model = [legacyModel(), legacyModel(includeWorkflows: false)].first(where: { $0.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) }) else { throw SessionFileError.unreadable }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: options)
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "SavedItem")
            request.fetchBatchSize = 200
            var bookmarks: [Bookmark] = [], ids = Set<UUID>(), urls = Set<URL>()
            for record in try context.fetch(request) {
                guard let id = record.value(forKey: "id") as? UUID,
                      (record.value(forKey: "schemaVersion") as? NSNumber)?.intValue == 1 else { throw SessionFileError.unreadable }
                ids.insert(id)
                guard let raw = record.value(forKey: "url") as? String, let url = URL(string: raw), AddressResolver.isWebURL(url) else { continue }
                urls.insert(url)
                guard record.value(forKey: "deletedAt") == nil, record.value(forKey: "archivedAt") == nil else { continue }
                guard let title = record.value(forKey: "title") as? String, let created = record.value(forKey: "createdAt") as? Date else { throw SessionFileError.unreadable }
                bookmarks.append(Bookmark(id: id, title: title, url: url, createdAt: created))
            }
            bookmarks.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
            return Result(bookmarks: bookmarks, knownIDs: ids, knownURLs: urls)
        }
    }
    static func legacyModel(includeWorkflows: Bool = true) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        typealias Field = (String, NSAttributeType, Bool)
        let common: [Field] = [("id", .UUIDAttributeType, false), ("createdAt", .dateAttributeType, false),
                               ("updatedAt", .dateAttributeType, false), ("schemaVersion", .integer64AttributeType, false)]
        let specs: [(String, [Field])] = [
            ("SavedItem", [("title", .stringAttributeType, true), ("url", .stringAttributeType, true),
                ("purpose", .stringAttributeType, true), ("state", .stringAttributeType, false),
                ("archivedAt", .dateAttributeType, false), ("deletedAt", .dateAttributeType, false)]),
            ("SourceSnapshot", [("itemID", .UUIDAttributeType, false), ("url", .stringAttributeType, true),
                ("title", .stringAttributeType, true), ("body", .stringAttributeType, true),
                ("selection", .stringAttributeType, true), ("kind", .stringAttributeType, false),
                ("explanation", .stringAttributeType, true), ("contentHash", .stringAttributeType, false)]),
            ("WorkspaceNote", [("itemID", .UUIDAttributeType, false), ("body", .stringAttributeType, true),
                ("supersedesID", .UUIDAttributeType, false)]),
            ("WorkspaceAction", [("itemID", .UUIDAttributeType, false), ("title", .stringAttributeType, true),
                ("dueAt", .dateAttributeType, false), ("reminderAt", .dateAttributeType, false),
                ("timeZoneID", .stringAttributeType, false), ("completedAt", .dateAttributeType, false)]),
            ("ActivityEntry", [("itemID", .UUIDAttributeType, false), ("body", .stringAttributeType, true)]),
            ("MigrationReceipt", [("name", .stringAttributeType, false)]),
            ("WorkspaceData", [("kind", .stringAttributeType, false), ("payload", .binaryDataAttributeType, true)])
        ]
        model.entities = specs.filter { includeWorkflows || $0.0 != "WorkspaceData" }.map { name, fields in
            let entity = NSEntityDescription(); entity.name = name; entity.managedObjectClassName = "NSManagedObject"
            entity.properties = (common + fields).map { name, type, encrypted in
                let attribute = NSAttributeDescription(); attribute.name = name; attribute.attributeType = type
                attribute.isOptional = true; attribute.allowsCloudEncryption = encrypted
                if name == "schemaVersion" { attribute.defaultValue = 1 }
                return attribute
            }
            // UUID references are resolved in the domain layer so partial/out-of-order imports remain representable.
            // Retained only to recognize historical store metadata; this model is never written.
            return entity
        }
        return model
    }

}
