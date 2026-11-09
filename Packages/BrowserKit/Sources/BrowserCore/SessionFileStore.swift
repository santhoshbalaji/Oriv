import Foundation

public struct SessionLoadResult: Sendable {
    public var snapshot: BrowserSnapshot?
    public var recoveredFromBackup: Bool
}

/// A synchronous durability boundary, also usable by isolated counting/failing stores.
public protocol BrowserSessionStore {
    func load() throws -> SessionLoadResult
    /// Returns true only when the primary was written. Discard still removes the backup on a no-op.
    @discardableResult func save(_ snapshot: BrowserSnapshot, discardPrevious: Bool) throws -> Bool
}

public enum SessionFileError: LocalizedError {
    case unsupportedVersion(Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "This session was saved by a newer app (format \(version)). It has been left unchanged."
        case .unreadable: "The saved session could not be read. Its files have been left unchanged."
        }
    }
}

/// Platform-independent storage. Only non-private records may be passed here.
public struct SessionFileStore: Sendable, BrowserSessionStore {
    public let fileURL: URL
    public var backupURL: URL { fileURL.appendingPathExtension("backup") }

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> SessionLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                return SessionLoadResult(snapshot: try decode(backupURL), recoveredFromBackup: true)
            }
            return SessionLoadResult(snapshot: nil, recoveredFromBackup: false)
        }
        do {
            return SessionLoadResult(snapshot: try decode(fileURL), recoveredFromBackup: false)
        } catch let error as SessionFileError {
            if case .unsupportedVersion = error { throw error }
            throw error
        } catch {
            if let backup = try? decode(backupURL) {
                return SessionLoadResult(snapshot: backup, recoveredFromBackup: true)
            }
            throw SessionFileError.unreadable
        }
    }

    public static func encodedSnapshot(_ snapshot: BrowserSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot.sanitized())
    }

    @discardableResult public func save(_ snapshot: BrowserSnapshot, discardPrevious: Bool = false) throws -> Bool {
        let data = try Self.encodedSnapshot(snapshot)
        let oldData = try? Data(contentsOf: fileURL)
        // Protect a newer format even if it appeared after the session was loaded.
        struct Header: Decodable { let version: Int }
        if let oldData, let header = try? JSONDecoder().decode(Header.self, from: oldData),
           !(1...3).contains(header.version) { throw SessionFileError.unsupportedVersion(header.version) }
        if oldData == data {
            if discardPrevious { try discardBackup() }
            return false
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the last valid session; a damaged primary never replaces the backup.
        if !discardPrevious, let oldData,
           let old = try? JSONDecoder().decode(BrowserSnapshot.self, from: oldData), (1...3).contains(old.version) {
            try oldData.write(to: backupURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        if discardPrevious { try discardBackup() }
        return true
    }

    private func discardBackup() throws {
        if FileManager.default.fileExists(atPath: backupURL.path) { try FileManager.default.removeItem(at: backupURL) }
    }

    private func decode(_ url: URL) throws -> BrowserSnapshot {
        let data = try Data(contentsOf: url)
        // Inspect the version before decoding destinations unknown to this build. A newer
        // valid session must not silently fall back to an older backup.
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        guard (1...3).contains(version) else { throw SessionFileError.unsupportedVersion(version) }
        let snapshot = try JSONDecoder().decode(BrowserSnapshot.self, from: data)
        return snapshot.sanitized()
    }
}
