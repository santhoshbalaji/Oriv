import Foundation

public enum ProfileColor: String, Codable, CaseIterable, Sendable {
    case mulberry, ocean, fern, amber, slate
}
public enum ProfileSymbol: String, Codable, CaseIterable, Sendable {
    case person = "person.crop.circle", work = "briefcase", study = "graduationcap", travel = "globe", creative = "paintbrush"
}
public struct BrowserProfile: Identifiable, Codable, Equatable, Sendable {
    public static let personalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public let id: UUID
    public var name: String
    public var color: ProfileColor
    public var symbol: ProfileSymbol
    public let createdAt: Date
    public var archivedAt: Date?
    public var isPersonal: Bool { id == Self.personalID }
    public init(id: UUID = UUID(), name: String, color: ProfileColor = .mulberry, symbol: ProfileSymbol = .person) {
        self.id = id; self.name = name; self.color = color; self.symbol = symbol; createdAt = .now
    }
    public static var personal: BrowserProfile { BrowserProfile(id: personalID, name: "Personal") }
    public func directory(in root: URL) -> URL {
        isPersonal ? root : root.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }
    public func defaultsName(bundleID: String) -> String? { isPersonal ? nil : "\(bundleID).profile.\(id.uuidString)" }

}

public struct ProfileRegistry: Codable, Equatable, Sendable {
    public var version = 1
    public var profiles: [BrowserProfile]
    public var activeID: UUID
    public init(profiles: [BrowserProfile] = [.personal], activeID: UUID = BrowserProfile.personalID) {
        self.profiles = profiles; self.activeID = activeID
    }
    public func validated() throws -> Self {
        guard version == 1 else { throw ProfileError.unsupportedVersion }
        guard !profiles.isEmpty, profiles.count <= 100,
              Set(profiles.map(\.id)).count == profiles.count,
              profiles.contains(where: { $0.isPersonal && $0.archivedAt == nil }),
              profiles.contains(where: { $0.id == activeID && $0.archivedAt == nil }),
              profiles.allSatisfy({ Self.validName($0.name) }),
              Set(profiles.map { $0.name.lowercased() }).count == profiles.count else { throw ProfileError.invalidRegistry }
        return self
    }
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
public enum ProfileError: LocalizedError {
    case invalidRegistry, unsupportedVersion, invalidName, duplicateName, missing, protectedProfile
    public var errorDescription: String? {
        switch self {
        case .invalidRegistry: "The profile list couldn’t be read. Its files have been preserved. Profile changes are paused."
        case .unsupportedVersion: "These profiles need a newer version of Oriv. Their files have been preserved."
        case .invalidName: "Use a profile name of 1–40 characters without line breaks."
        case .duplicateName: "A profile already uses this name. Choose another name, including archived profiles."
        case .missing: "This profile is unavailable. Restore it from Profiles if it is archived."
        case .protectedProfile: "Switch away from this profile before archiving it. The original Personal profile is always retained."
        }
    }
}

/// Only metadata is stored here. Existing Personal data stays at its legacy paths.
public struct ProfileRegistryStore: Sendable {
    public let fileURL: URL
    public var backupURL: URL { fileURL.appendingPathExtension("backup") }
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func load() throws -> (registry: ProfileRegistry, recovered: Bool) {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            if FileManager.default.fileExists(atPath: backupURL.path) { return (try read(backupURL), true) }
            return (ProfileRegistry(), false)
        }
        do { return (try read(fileURL), false) }
        catch ProfileError.unsupportedVersion { throw ProfileError.unsupportedVersion }
        catch {
            if let backup = try? read(backupURL) { return (backup, true) }
            throw ProfileError.invalidRegistry
        }
    }
    public func save(_ registry: ProfileRegistry) throws {
        _ = try registry.validated()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let old = try? read(fileURL) { try write(old, to: backupURL) }
        try write(registry, to: fileURL)
    }
    private func read(_ url: URL) throws -> ProfileRegistry {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_000_000 else { throw ProfileError.invalidRegistry }
        return try JSONDecoder().decode(ProfileRegistry.self, from: Data(contentsOf: url)).validated()
    }
    private func write(_ value: ProfileRegistry, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
