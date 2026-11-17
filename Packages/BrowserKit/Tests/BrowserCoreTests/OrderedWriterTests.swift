import Foundation
import Testing
@testable import BrowserCore

struct OrderedWriterTests {
    @Test func rapidSavesAndDurabilityBarrierLeaveTheLastSnapshot() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkerCheckingStore(disk: SessionFileStore(fileURL: root.appendingPathComponent("session.json")))
        let writer = OrderedSessionWriter(store: store)
        for index in 0..<100 { writer.enqueue(BrowserSnapshot(tabs: [TabRecord(title: "Snapshot \(index)")])) }
        let final = BrowserSnapshot(tabs: [TabRecord(title: "Final receipt")], appliedOpenRequests: [UUID()])
        try writer.saveAndWait(final)
        try writer.flush()
        #expect(try store.disk.load().snapshot == final.sanitized())
        #expect(writer.takeCompletions().count == 100)
    }
    @Test func queuedFailureIsReportedAtFlushAndDoesNotReorderLaterWork() throws {
        let writer = OrderedFileWriter()
        writer.enqueue { throw URLError(.cannotWriteToFile) }
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        writer.enqueue { try Data("latest".utf8).write(to: root, options: .atomic) }
        #expect(throws: URLError.self) { try writer.flush() }
        try writer.flush()
        #expect(try String(contentsOf: root, encoding: .utf8) == "latest")
    }
    @Test func backupRotatesOnlyOncePerStoreLaunchAndErasureDoesNotReturn() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionFileStore(fileURL: root.appendingPathComponent("session.json"))
        let first = BrowserSnapshot(tabs: [TabRecord(title: "First")])
        try store.save(first)
        try store.save(BrowserSnapshot(tabs: [TabRecord(title: "Second")]))
        let backup = try Data(contentsOf: store.backupURL)
        let third = BrowserSnapshot(tabs: [TabRecord(title: "Third")])
        try store.save(third)
        #expect(try Data(contentsOf: store.backupURL) == backup)
        let nextLaunch = SessionFileStore(fileURL: store.fileURL)
        _ = try nextLaunch.load()
        try nextLaunch.save(BrowserSnapshot(tabs: [TabRecord(title: "Fourth")]))
        #expect(try JSONDecoder().decode(BrowserSnapshot.self, from: Data(contentsOf: store.backupURL)) == third.sanitized())
        try nextLaunch.save(BrowserSnapshot(), discardPrevious: true)
        try nextLaunch.save(BrowserSnapshot(tabs: [TabRecord(title: "After erasure")]))
        #expect(!FileManager.default.fileExists(atPath: store.backupURL.path))
    }
    @Test func dirtyKeysSurvivePersistenceAndAcknowledgmentPreservesNewerEdits() throws {
        var state = ContinuityReplica(deviceName: "Test device")
        let bookmark = Bookmark(title: "First", url: URL(string: "https://example.test")!)
        let key = ContinuityRecord.bookmarkKey(BrowserProfile.personalID, bookmark.id)
        try state.put(key, .bookmark(BrowserProfile.personalID, bookmark))
        let submitted = state.dirtyRecords
        var edited = bookmark; edited.title = "Later"
        try state.put(key, .bookmark(BrowserProfile.personalID, edited))
        state.acknowledge(submitted)
        #expect(state.dirtyKeys == [key])
        let decoded = try JSONDecoder().decode(ContinuityReplica.self, from: JSONEncoder().encode(state))
        #expect(decoded.dirtyKeys == [key])
        state.acknowledge(state.dirtyRecords); #expect(state.dirtyKeys.isEmpty)
        try state.put(key, nil); #expect(state.dirtyKeys == [key])
        let deletion = state.dirtyRecords
        try state.merge(deletion); #expect(state.dirtyKeys.isEmpty)
    }
    @Test func legacyReplicaRetriesRecordsAndRemoteWinnerClearsDirtyKey() throws {
        var state = ContinuityReplica(deviceName: "Test device")
        let key = ContinuityRecord.deviceKey(state.deviceID)
        try state.put(key, .device(ContinuityDevice(id: state.deviceID, name: "Test device")))
        state.acknowledge(state.dirtyRecords)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        legacy.removeValue(forKey: "dirtyRecordKeys")
        state = try JSONDecoder().decode(ContinuityReplica.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(state.dirtyKeys == [key])
        var remote = try #require(state.records[key]); remote.counter += 1
        try state.merge([remote]); #expect(state.dirtyKeys.isEmpty)
    }
}

private struct WorkerCheckingStore: BrowserSessionStore, Sendable {
    let disk: SessionFileStore
    func load() throws -> SessionLoadResult { try disk.load() }
    func save(_ snapshot: BrowserSnapshot, discardPrevious: Bool) throws -> Bool {
        #expect(!Thread.isMainThread)
        // Delay early writes so the barrier is exercised with a real backlog.
        if snapshot.tabs.first?.title == "Snapshot 0" { Thread.sleep(forTimeInterval: 0.01) }
        return try disk.save(snapshot, discardPrevious: discardPrevious)
    }
}
