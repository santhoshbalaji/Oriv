import Foundation
import Testing
@testable import BrowserCore

struct ProfileTests {
    @Test func personalKeepsLegacyPathsAndNewProfilesHaveDisjointNamespaces() {
        let root = URL(fileURLWithPath: "/synthetic/Oriv"), personal = BrowserProfile.personal
        let work = BrowserProfile(name: "Work"), study = BrowserProfile(name: "Study")
        #expect(personal.directory(in: root) == root)
        #expect(personal.defaultsName(bundleID: "test.oriv") == nil)
        #expect(work.directory(in: root) != study.directory(in: root))
        #expect(work.defaultsName(bundleID: "test.oriv") != study.defaultsName(bundleID: "test.oriv"))
    }
    @Test func invalidRegistriesCannotSilentlySelectAnotherProfile() throws {
        var registry = ProfileRegistry()
        registry.activeID = UUID()
        #expect(throws: ProfileError.self) { try registry.validated() }
        registry = ProfileRegistry(); registry.profiles[0].archivedAt = .now
        #expect(throws: ProfileError.self) { try registry.validated() }
        registry = ProfileRegistry(); registry.profiles.append(registry.profiles[0])
        #expect(throws: ProfileError.self) { try registry.validated() }
        #expect(!ProfileRegistry.validName("Name\nother"))
        #expect(!ProfileRegistry.validName(String(repeating: "a", count: 41)))
    }
    @Test func registryRecoveryAndFutureFormatsPreserveOriginalData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileRegistryStore(fileURL: root.appendingPathComponent("profiles.json"))
        try store.save(ProfileRegistry())
        var next = ProfileRegistry(); next.profiles.append(BrowserProfile(name: "Research"))
        try store.save(next)
        try Data("broken".utf8).write(to: store.fileURL)
        #expect(try store.load().recovered)
        #expect(try store.load().registry.profiles.count == 1)
        next.version = 100
        let future = try JSONEncoder().encode(next)
        try future.write(to: store.fileURL)
        #expect(throws: ProfileError.self) { try store.load() }
        #expect(try Data(contentsOf: store.fileURL) == future)
    }
}
