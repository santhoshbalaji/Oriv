import Foundation
import Testing
@testable import BrowserCore

struct SessionWriteTests {
    private func withStore(_ body: (SessionFileStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(SessionFileStore(fileURL: root.appendingPathComponent("session.json")))
    }
    @Test func identicalSnapshotDoesNotWriteOrRotateBackup() throws {
        try withStore { store in
            let first = BrowserSnapshot(tabs: [TabRecord(title: "First")])
            let second = BrowserSnapshot(tabs: [TabRecord(title: "Second")])
            #expect(try store.save(first))
            #expect(try store.save(second))
            let backup = try Data(contentsOf: store.backupURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
            #expect(try !store.save(second))
            #expect(try Data(contentsOf: store.backupURL) == backup)
            #expect(try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date == attributes[.modificationDate] as? Date)
        }
    }
    @Test func identicalDiscardStillErasesBackupWithoutWritingPrimary() throws {
        try withStore { store in
            try store.save(BrowserSnapshot(tabs: [TabRecord(title: "Old")]))
            let current = BrowserSnapshot(tabs: [TabRecord(title: "Current")])
            try store.save(current)
            #expect(FileManager.default.fileExists(atPath: store.backupURL.path))
            #expect(try !store.save(current, discardPrevious: true))
            #expect(!FileManager.default.fileExists(atPath: store.backupURL.path))
            #expect(try store.load().snapshot == current.sanitized())
        }
    }
    @Test func corruptPrimaryNeverReplacesValidBackupOnSave() throws {
        try withStore { store in
            let valid = BrowserSnapshot(tabs: [TabRecord(title: "Known good")])
            try store.save(valid)
            try store.save(BrowserSnapshot(tabs: [TabRecord(title: "Later")]))
            let backup = try Data(contentsOf: store.backupURL)
            try Data("{broken".utf8).write(to: store.fileURL)
            #expect(try store.load().recoveredFromBackup)
            try store.save(BrowserSnapshot(tabs: [TabRecord(title: "Recovered")]))
            #expect(try Data(contentsOf: store.backupURL) == backup)
            try Data("{broken again".utf8).write(to: store.fileURL)
            #expect(try store.load().snapshot == valid.sanitized())
        }
    }
    @Test func saveRefusesFuturePrimaryEvenAfterEarlierSuccessfulWrite() throws {
        try withStore { store in
            try store.save(BrowserSnapshot(tabs: [TabRecord()]))
            try store.save(BrowserSnapshot(tabs: [TabRecord(title: "Current")]))
            let backup = try Data(contentsOf: store.backupURL)
            let future = Data("{\"version\":99,\"tabs\":[{\"content\":{\"future\":{}}}]}".utf8)
            try future.write(to: store.fileURL)
            #expect(throws: SessionFileError.self) { try store.save(BrowserSnapshot(), discardPrevious: true) }
            #expect(try Data(contentsOf: store.fileURL) == future)
            #expect(try Data(contentsOf: store.backupURL) == backup)
        }
    }
}
