import BrowserCore
import CoreData
import XCTest
@testable import ProductivityKit

@MainActor final class WorkspaceTests: XCTestCase {
    func testMigrationIsIdempotentAndPreservesDatesAndDoesNotResurrectTrash() throws {
        let store = try WorkspaceStore()
        let bookmark = Bookmark(title: "Research", url: URL(string: "https://example.com")!, createdAt: Date(timeIntervalSince1970: 100))
        try store.migrateBookmarks([bookmark])
        XCTAssertEqual(store.items.first?.id, bookmark.id)
        XCTAssertEqual(store.items.first?.createdAt, bookmark.createdAt)
        try store.setDeleted(bookmark.id, deleted: true)
        try store.migrateBookmarks([bookmark])
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNotNil(store.items.first?.deletedAt)
    }

    func testSnapshotsAndNoteRevisionsSurviveReopeningSQLite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspace.sqlite")
        let id: UUID
        do {
            let store = try WorkspaceStore(url: url)
            let page = PageCapture(url: URL(string: "https://example.com/article")!, title: "Research", text: "Original source", kind: .readable)
            id = try store.save(page, purpose: "Compare approaches", kind: .readable)
            try store.addNote(to: id, body: "First finding")
            let oldID = try XCTUnwrap(store.notes.first?.id)
            try store.addNote(to: id, body: "Revised finding", replacing: oldID)
            let next = PageCapture(url: page.url, title: "Research updated", text: "Updated source", kind: .readable)
            try store.save(next, purpose: "", kind: .readable, existingID: id)
        }
        let reopened = try WorkspaceStore(url: url)
        XCTAssertEqual(reopened.sources(for: id).count, 2)
        XCTAssertEqual(Set(reopened.sources(for: id).map(\.text)), ["Original source", "Updated source"])
        XCTAssertEqual(reopened.currentNotes(for: id).map(\.body), ["Revised finding"])
        XCTAssertEqual(reopened.notes.count, 2)
        XCTAssertTrue(reopened.matches(try XCTUnwrap(reopened.item(id)), query: "Original source"))
    }

    func testActionLifecycleAndArchiveTrashCancelRemindersWithoutLosingHistory() throws {
        let store = try WorkspaceStore()
        let id = try store.createItem(title: "Application", purpose: "Submit this week")
        let due = Date.now.addingTimeInterval(7200), alert = Date.now.addingTimeInterval(3600)
        let action = try store.saveAction(itemID: id, title: "Prepare portfolio", dueAt: due, reminderAt: alert)
        XCTAssertEqual(store.reminderDeliveries().count, 1)
        XCTAssertEqual(store.actions.first?.dueAt, due)
        try store.completeAction(action, completed: true)
        XCTAssertTrue(store.reminderDeliveries().isEmpty)
        try store.completeAction(action, completed: false)
        XCTAssertEqual(store.reminderDeliveries().count, 1)
        try store.setArchived(id, archived: true)
        XCTAssertTrue(store.reminderDeliveries().isEmpty)
        try store.setArchived(id, archived: false)
        try store.setDeleted(id, deleted: true)
        XCTAssertTrue(store.reminderDeliveries().isEmpty)
        try store.setDeleted(id, deleted: false)
        XCTAssertEqual(store.reminderDeliveries().count, 1)
        XCTAssertTrue(store.activity.contains { $0.text.contains("Completed action") })
    }

    func testInvalidWritesDoNotPartiallyPersistAndLinkOnlyDropsContent() throws {
        let store = try WorkspaceStore()
        let page = PageCapture(url: URL(string: "https://example.com")!, title: "Link", text: "Private passage", selection: "Selected", kind: .readable)
        let id = try store.save(page, purpose: "", kind: .link)
        XCTAssertEqual(store.sources(for: id).first?.text, "")
        XCTAssertEqual(store.sources(for: id).first?.selection, "")
        XCTAssertThrowsError(try store.saveAction(itemID: UUID(), title: "Missing item", dueAt: nil, reminderAt: nil))
        XCTAssertThrowsError(try store.saveAction(itemID: id, title: "Past alert", dueAt: nil, reminderAt: .distantPast))
        XCTAssertTrue(store.actions.isEmpty)
        XCTAssertEqual(store.items.count, 1)
    }

    func testSchemaHasNoUniqueConstraintsAndProtectsContentBeforeFutureCloudDeployment() throws {
        for entity in WorkspaceStore.makeModel().entities {
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
            for attribute in entity.attributesByName.values { XCTAssertTrue(attribute.isOptional) }
        }
        let snapshot = try XCTUnwrap(WorkspaceStore.makeModel().entitiesByName["SourceSnapshot"])
        XCTAssertTrue(try XCTUnwrap(snapshot.attributesByName["body"]).allowsCloudEncryption)
    }

    func testReminderReconciliationIsStableAndPermissionDenialKeepsTasks() async throws {
        let transport = FakeTransport()
        let reminders = WorkspaceReminders(transport: transport)
        let delivery = ReminderDelivery(itemID: UUID(), actionID: UUID(), title: "Check response", date: .now.addingTimeInterval(3600))
        await reminders.reconcile([delivery])
        XCTAssertEqual(transport.scheduled.count, 1)
        await reminders.reconcile([delivery])
        XCTAssertEqual(transport.calls, 1)
        await reminders.reconcile([])
        XCTAssertTrue(transport.scheduled.isEmpty)
        transport.delivered = [delivery.id]
        await reminders.reconcile([])
        XCTAssertEqual(reminders.deliveredIDs, [delivery.id])
        await reminders.reconcile([], retiringIDs: [delivery.id])
        XCTAssertTrue(transport.delivered.isEmpty)
        XCTAssertTrue(reminders.deliveredIDs.isEmpty)
        transport.authorization = .denied
        await reminders.reconcile([delivery], requestPermission: true)
        XCTAssertTrue(transport.scheduled.isEmpty)
        XCTAssertNotNil(reminders.message)
    }

    func testCompletionDuringSchedulingCannotResurrectAlert() async {
        let transport = FakeTransport()
        let reminders = WorkspaceReminders(transport: transport)
        let delivery = ReminderDelivery(itemID: UUID(), actionID: UUID(), title: "Finish", date: .now.addingTimeInterval(3600))
        transport.onSchedule = { await reminders.reconcile([]) }
        await reminders.reconcile([delivery])
        XCTAssertTrue(transport.scheduled.isEmpty)
    }
}

@MainActor private final class FakeTransport: ReminderTransport {
    var authorization: ReminderPermission = .allowed
    var scheduled: [String: ReminderDelivery] = [:]
    var delivered: Set<String> = []
    var calls = 0
    var onSchedule: (() async -> Void)?
    func permission(request: Bool) async throws -> ReminderPermission { authorization }
    func pendingIDs() async -> Set<String> { Set(scheduled.keys) }
    func deliveredIDs() async -> Set<String> { delivered }
    func schedule(_ delivery: ReminderDelivery) async throws {
        calls += 1; await onSchedule?(); scheduled[delivery.id] = delivery
    }
    func cancel(_ ids: [String]) { for id in ids { scheduled.removeValue(forKey: id); delivered.remove(id) } }
}
