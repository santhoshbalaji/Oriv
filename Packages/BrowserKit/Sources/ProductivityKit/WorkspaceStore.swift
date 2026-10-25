import BrowserCore
import CoreData
import Foundation
import Observation
import CryptoKit

/// Local-first repository. No UI framework, device notification IDs, or browser credentials enter this store.
/// Cloud mirroring is deliberately not enabled until signing, account partitioning and conflict handling ship.
@MainActor @Observable
public final class WorkspaceStore {
    public private(set) var items: [SavedItem] = []
    public private(set) var snapshots: [SourceSnapshot] = []
    public private(set) var notes: [WorkspaceNote] = []
    public private(set) var actions: [WorkspaceAction] = []
    public private(set) var activity: [ActivityEntry] = []
    public private(set) var revision = 0
    @ObservationIgnored private let container: NSPersistentContainer
    private var context: NSManagedObjectContext { container.viewContext }

    public init(url: URL? = nil) throws {
        container = NSPersistentContainer(name: "OrivWorkspace", managedObjectModel: Self.makeModel())
        let description = NSPersistentStoreDescription()
        description.shouldAddStoreAsynchronously = false
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            description.url = url
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        } else { description.type = NSInMemoryStoreType }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        // Loading is synchronous; failures never replace the existing store with an empty one.
        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        if let failure { throw failure }
        context.transactionAuthor = "Oriv.local"
        context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        try refresh()
    }

    public static func makeModel() -> NSManagedObjectModel {
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
            ("MigrationReceipt", [("name", .stringAttributeType, false)])
        ]
        model.entities = specs.map { name, fields in
            let entity = NSEntityDescription(); entity.name = name; entity.managedObjectClassName = "NSManagedObject"
            entity.properties = (common + fields).map { name, type, encrypted in
                let attribute = NSAttributeDescription(); attribute.name = name; attribute.attributeType = type
                attribute.isOptional = true; attribute.allowsCloudEncryption = encrypted
                if name == "schemaVersion" { attribute.defaultValue = 1 }
                return attribute
            }
            // UUID references are resolved in the domain layer so partial/out-of-order imports remain representable.
            // No unique constraints or cross-store relationships: compatible with a future private CloudKit schema.
            return entity
        }
        return model
    }

    public func item(_ id: UUID) -> SavedItem? { items.first { $0.id == id } }
    public func existingItem(for url: URL) -> SavedItem? {
        items.first { $0.url == url && $0.deletedAt == nil }
    }
    public func currentNotes(for id: UUID) -> [WorkspaceNote] {
        let superseded = Set(notes.compactMap(\.supersedesID))
        return notes.filter { $0.itemID == id && !superseded.contains($0.id) }
    }
    public func sources(for id: UUID) -> [SourceSnapshot] { snapshots.filter { $0.itemID == id } }
    public func steps(for id: UUID) -> [WorkspaceAction] { actions.filter { $0.itemID == id } }

    /// The receipt and imported records commit together. Preserve session.json as a recovery source.
    public func migrateBookmarks(_ bookmarks: [Bookmark]) throws {
        if try fetch("MigrationReceipt").contains(where: { $0.value(forKey: "name") as? String == "session-v1-bookmarks" }) { return }
        try transaction {
            for bookmark in bookmarks where !items.contains(where: { $0.id == bookmark.id }) {
                let object = insert("SavedItem", id: bookmark.id, date: bookmark.createdAt)
                object.setValue(bookmark.title, forKey: "title"); object.setValue(bookmark.url.absoluteString, forKey: "url")
                object.setValue("", forKey: "purpose"); object.setValue(ItemState.reference.rawValue, forKey: "state")
                addActivity(bookmark.id, "Imported bookmark. Original link and save date preserved.", date: bookmark.createdAt)
            }
            insert("MigrationReceipt").setValue("session-v1-bookmarks", forKey: "name")
        }
    }

    @discardableResult public func save(_ capture: PageCapture, purpose: String, kind: CaptureKind,
                                        existingID: UUID? = nil) throws -> UUID {
        guard AddressResolver.isWebURL(capture.url) else { throw WorkspaceError.invalidRecord }
        let title = capture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkspaceError.emptyText }
        let id = existingID ?? UUID()
        try transaction {
            let object: NSManagedObject
            if let existingID { object = try self.object("SavedItem", id: existingID) }
            else {
                object = insert("SavedItem", id: id)
                object.setValue(title, forKey: "title"); object.setValue(capture.url.absoluteString, forKey: "url")
                object.setValue(purpose, forKey: "purpose"); object.setValue(ItemState.reference.rawValue, forKey: "state")
            }
            object.setValue(Date.now, forKey: "updatedAt")
            let source = insert("SourceSnapshot", date: capture.capturedAt)
            source.setValue(id, forKey: "itemID"); source.setValue(capture.url.absoluteString, forKey: "url")
            source.setValue(title, forKey: "title"); source.setValue(kind.rawValue, forKey: "kind")
            let body = kind == .link ? "" : kind == .selection ? capture.selection : capture.text
            source.setValue(body, forKey: "body")
            source.setValue(SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined(), forKey: "contentHash")
            source.setValue(kind == .link ? "" : capture.selection, forKey: "selection")
            source.setValue(capture.explanation, forKey: "explanation")
            addActivity(id, existingID == nil ? "Saved with \(kind.rawValue.lowercased())." : "Added a new source snapshot.")
            if existingID != nil, !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let note = insert("WorkspaceNote"); note.setValue(id, forKey: "itemID"); note.setValue(purpose, forKey: "body")
                addActivity(id, "Added a note with the capture.")
            }
        }
        return id
    }

    @discardableResult public func createItem(title: String, purpose: String) throws -> UUID {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkspaceError.emptyText }
        let id = UUID()
        try transaction {
            let item = insert("SavedItem", id: id); item.setValue(title, forKey: "title")
            item.setValue(purpose, forKey: "purpose"); item.setValue(ItemState.reference.rawValue, forKey: "state")
            addActivity(id, "Created an item.")
        }
        return id
    }

    public func updateItem(_ id: UUID, title: String, purpose: String, state: ItemState) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceError.emptyText }
        try transaction {
            let item = try object("SavedItem", id: id)
            let old = item.value(forKey: "state") as? String
            item.setValue(title, forKey: "title"); item.setValue(purpose, forKey: "purpose")
            item.setValue(state.rawValue, forKey: "state"); item.setValue(Date.now, forKey: "updatedAt")
            addActivity(id, old == state.rawValue ? "Updated item details." : "Changed status to \(state.rawValue.lowercased()).")
        }
    }

    public func setArchived(_ id: UUID, archived: Bool) throws {
        try transaction {
            let item = try object("SavedItem", id: id)
            item.setValue(archived ? Date.now : nil, forKey: "archivedAt")
            item.setValue(Date.now, forKey: "updatedAt")
            addActivity(id, archived ? "Archived item. Reminders paused." : "Returned item to the library.")
        }
    }
    public func setDeleted(_ id: UUID, deleted: Bool) throws {
        try transaction {
            let item = try object("SavedItem", id: id)
            item.setValue(deleted ? Date.now : nil, forKey: "deletedAt")
            item.setValue(Date.now, forKey: "updatedAt")
            addActivity(id, deleted ? "Moved to Trash. Reminders cancelled." : "Restored from Trash.")
        }
    }

    public func addNote(to id: UUID, body: String, replacing: UUID? = nil) throws {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw WorkspaceError.emptyText }
        try transaction {
            _ = try object("SavedItem", id: id)
            if let replacing {
                let previous = try object("WorkspaceNote", id: replacing)
                guard previous.value(forKey: "itemID") as? UUID == id else { throw WorkspaceError.invalidRecord }
            }
            let note = insert("WorkspaceNote"); note.setValue(id, forKey: "itemID"); note.setValue(body, forKey: "body")
            note.setValue(replacing, forKey: "supersedesID")
            addActivity(id, replacing == nil ? "Added a note." : "Revised a note. Previous text retained in history.")
            try object("SavedItem", id: id).setValue(Date.now, forKey: "updatedAt")
        }
    }

    @discardableResult public func saveAction(itemID: UUID, actionID: UUID? = nil, title: String,
                                              dueAt: Date?, reminderAt: Date?) throws -> UUID {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceError.emptyText }
        if let reminderAt, reminderAt <= .now { throw WorkspaceError.invalidReminder }
        let id = actionID ?? UUID()
        try transaction {
            _ = try object("SavedItem", id: itemID)
            let action = try actionID.map { try object("WorkspaceAction", id: $0) } ?? insert("WorkspaceAction", id: id)
            if actionID != nil, action.value(forKey: "itemID") as? UUID != itemID { throw WorkspaceError.invalidRecord }
            action.setValue(itemID, forKey: "itemID"); action.setValue(title, forKey: "title")
            action.setValue(dueAt, forKey: "dueAt"); action.setValue(reminderAt, forKey: "reminderAt")
            action.setValue(TimeZone.current.identifier, forKey: "timeZoneID")
            action.setValue(Date.now, forKey: "updatedAt")
            addActivity(itemID, "\(actionID == nil ? "Added" : "Updated") action: \(title)")
            try object("SavedItem", id: itemID).setValue(Date.now, forKey: "updatedAt")
        }
        return id
    }

    public func completeAction(_ id: UUID, completed: Bool) throws {
        try transaction {
            let action = try object("WorkspaceAction", id: id)
            let itemID: UUID = try value(action, "itemID")
            action.setValue(completed ? Date.now : nil, forKey: "completedAt")
            action.setValue(Date.now, forKey: "updatedAt")
            let title: String = try value(action, "title")
            addActivity(itemID, "\(completed ? "Completed" : "Reopened") action: \(title)")
            try object("SavedItem", id: itemID).setValue(Date.now, forKey: "updatedAt")
        }
    }

    public func reminderDeliveries(now: Date = .now) -> [ReminderDelivery] {
        let active = Set(items.filter { $0.deletedAt == nil && $0.archivedAt == nil }.map(\.id))
        return actions.compactMap { action in
            guard active.contains(action.itemID), !action.isComplete, let date = action.reminderAt, date > now else { return nil }
            return ReminderDelivery(itemID: action.itemID, actionID: action.id, title: action.title, date: date)
        }.sorted { $0.date < $1.date }
    }

    public func matches(_ item: SavedItem, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return ([item.title, item.purpose, item.url?.absoluteString ?? ""]
            + sources(for: item.id).map(\.text) + currentNotes(for: item.id).map(\.body)
            + steps(for: item.id).map(\.title)).contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func transaction(_ work: () throws -> Void) throws {
        do { try work(); try context.save() }
        catch { context.rollback(); throw error }
        try refresh(); revision += 1
    }
    private func insert(_ entity: String, id: UUID = UUID(), date: Date = .now) -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        object.setValue(id, forKey: "id"); object.setValue(date, forKey: "createdAt"); object.setValue(date, forKey: "updatedAt")
        return object
    }
    private func addActivity(_ id: UUID, _ text: String, date: Date = .now) {
        let entry = insert("ActivityEntry", date: date); entry.setValue(id, forKey: "itemID"); entry.setValue(text, forKey: "body")
    }
    private func fetch(_ entity: String) throws -> [NSManagedObject] { try context.fetch(NSFetchRequest(entityName: entity)) }
    private func object(_ entity: String, id: UUID) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID); request.fetchLimit = 1
        guard let object = try context.fetch(request).first else { throw WorkspaceError.missingRecord }; return object
    }
    private func value<T>(_ object: NSManagedObject, _ key: String) throws -> T {
        guard let value = object.value(forKey: key) as? T else { throw WorkspaceError.invalidRecord }; return value
    }
    private func refresh() throws {
        let newItems: [SavedItem] = try fetch("SavedItem").map {
            guard let state = ItemState(rawValue: try value($0, "state")) else { throw WorkspaceError.invalidRecord }
            return SavedItem(id: try value($0,"id"), title: try value($0,"title"),
                url: ($0.value(forKey:"url") as? String).flatMap(URL.init(string:)), purpose: try value($0,"purpose"),
                state: state, createdAt: try value($0,"createdAt"), updatedAt: try value($0,"updatedAt"),
                archivedAt: $0.value(forKey:"archivedAt") as? Date, deletedAt: $0.value(forKey:"deletedAt") as? Date)
        }.sorted { $0.updatedAt > $1.updatedAt }
        let newSources: [SourceSnapshot] = try fetch("SourceSnapshot").map {
            guard let url = URL(string: try value($0,"url")), let kind = CaptureKind(rawValue: try value($0,"kind")) else { throw WorkspaceError.invalidRecord }
            return SourceSnapshot(id: try value($0,"id"), itemID: try value($0,"itemID"), url: url,
                title: try value($0,"title"), text: try value($0,"body"), selection: try value($0,"selection"),
                kind: kind, explanation: try value($0,"explanation"), capturedAt: try value($0,"createdAt"))
        }.sorted { $0.capturedAt > $1.capturedAt }
        let newNotes: [WorkspaceNote] = try fetch("WorkspaceNote").map {
            WorkspaceNote(id: try value($0,"id"), itemID: try value($0,"itemID"), body: try value($0,"body"),
                createdAt: try value($0,"createdAt"), supersedesID: $0.value(forKey:"supersedesID") as? UUID)
        }.sorted { $0.createdAt > $1.createdAt }
        let newActions: [WorkspaceAction] = try fetch("WorkspaceAction").map {
            WorkspaceAction(id: try value($0,"id"), itemID: try value($0,"itemID"), title: try value($0,"title"),
                dueAt: $0.value(forKey:"dueAt") as? Date, reminderAt: $0.value(forKey:"reminderAt") as? Date,
                timeZoneID: try value($0,"timeZoneID"), completedAt: $0.value(forKey:"completedAt") as? Date, createdAt: try value($0,"createdAt"))
        }.sorted { $0.createdAt < $1.createdAt }
        let newActivity: [ActivityEntry] = try fetch("ActivityEntry").map {
            ActivityEntry(id: try value($0,"id"), itemID: try value($0,"itemID"), text: try value($0,"body"), createdAt: try value($0,"createdAt"))
        }.sorted { $0.createdAt > $1.createdAt }
        items = newItems; snapshots = newSources; notes = newNotes; actions = newActions; activity = newActivity
    }
}
