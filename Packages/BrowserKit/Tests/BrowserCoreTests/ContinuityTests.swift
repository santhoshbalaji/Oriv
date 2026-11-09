import Foundation
import Testing
@testable import BrowserCore

struct ContinuityTests {
    private let profile = BrowserProfile.personal
    private func bookmark(_ path: String) -> Bookmark { Bookmark(title: path, url: URL(string: "https://example.test/\(path)")!) }
    private func capture(_ state: inout ContinuityReplica, _ bookmarks: [Bookmark], history: [HistoryEntry] = [], preferences: [String: String] = [:]) throws {
        try state.capture(profile: profile, bookmarks: bookmarks, history: history, regularTabs: [], preferences: preferences)
    }
    @Test func independentChangesAndConcurrentPreferencesConverge() throws {
        var mac = ContinuityReplica(deviceName: "Mac"), phone = ContinuityReplica(deviceName: "iPhone")
        let a = bookmark("a"), b = bookmark("b")
        try capture(&mac, [a], preferences: ["searchEngine": "Google"])
        try phone.merge(Array(mac.records.values)); phone.observedBookmarks[profile.id] = [a]
        mac.seedKeys = []; phone.seedKeys = []
        try capture(&mac, [a], preferences: ["searchEngine": "Brave"])
        try capture(&phone, [a, b], preferences: ["searchEngine": "Google", "defaultZoom": "1.25"])
        let left = Array(mac.records.values), right = Array(phone.records.values)
        try mac.merge(right); try phone.merge(left)
        #expect(mac.records == phone.records)
        #expect(Set(mac.bookmarks(for: profile.id).map(\.id)) == [a.id, b.id])
        #expect(mac.preferences(for: profile.id)["searchEngine"] == "Brave")
        #expect(mac.preferences(for: profile.id)["defaultZoom"] == "1.25")
    }
    @Test func joiningDeviceDefaultsCannotOverwriteEstablishedSettings() throws {
        var cloud = ContinuityReplica(deviceName: "Mac"), joining = ContinuityReplica(deviceName: "iPhone")
        try capture(&cloud, [], preferences: ["appearance": "Light", "searchEngine": "Brave"])
        try capture(&joining, (0..<200).map { bookmark("\($0)") }, preferences: ["appearance": "Dark", "searchEngine": "DuckDuckGo"])
        #expect(joining.counter > cloud.counter)
        try joining.merge(Array(cloud.records.values))
        #expect(joining.preferences(for: profile.id) == cloud.preferences(for: profile.id))
    }
    @Test func offlineBookmarkDeletionAndExplicitUndo() throws {
        let saved = bookmark("keep")
        var first = ContinuityReplica(deviceName: "Mac"), offline = ContinuityReplica(deviceName: "iPhone")
        try capture(&first, [saved]); try offline.merge(Array(first.records.values))
        offline.observedBookmarks[profile.id] = [saved]; first.seedKeys = []; offline.seedKeys = []
        try capture(&first, [])
        try capture(&offline, [saved] + (0..<100).map { bookmark("new\($0)") })
        try offline.merge(Array(first.records.values))
        #expect(!offline.bookmarks(for: profile.id).contains(saved))
        try first.merge(Array(offline.records.values))
        first.observedBookmarks[profile.id] = first.bookmarks(for: profile.id)
        try capture(&first, first.bookmarks(for: profile.id) + [saved])
        try offline.merge(Array(first.records.values))
        #expect(offline.bookmarks(for: profile.id).contains(saved))
    }
    @Test func historyClearRedactsUnseenOfflineVisitsButKeepsLaterVisits() throws {
        var first = ContinuityReplica(deviceName: "Mac"), offline = ContinuityReplica(deviceName: "iPhone")
        let old = HistoryEntry(title: "Old secret", url: URL(string: "https://example.test/secret")!, visitedAt: Date(timeIntervalSince1970: 100))
        let new = HistoryEntry(title: "New", url: URL(string: "https://example.test/new")!, visitedAt: Date(timeIntervalSince1970: 300))
        try capture(&offline, [], history: [old, new])
        try first.clearHistory(profile: profile.id, since: .distantPast, through: Date(timeIntervalSince1970: 200))
        try first.merge(Array(offline.records.values)); try offline.merge(Array(first.records.values))
        #expect(first.history(for: profile.id) == [new])
        #expect(offline.history(for: profile.id) == [new])
        let text = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(!text.contains("Old secret")); #expect(!text.contains("example.test/secret"))
        try capture(&first, [], history: [old, new])
        #expect(first.history(for: profile.id) == [new])
    }
    @Test func mergeRejectsWholeUnknownBatchAndStoreFailsClosed() throws {
        var state = ContinuityReplica(deviceName: "Mac")
        let saved = bookmark("saved")
        try capture(&state, [saved])
        let original = state.records
        var future = ContinuityRecord(id: ContinuityRecord.bookmarkKey(profile.id, UUID()), counter: 100, writer: UUID(), payload: nil)
        future.version = 2
        #expect(throws: ContinuityError.self) { try state.merge([ContinuityRecord(id: ContinuityRecord.bookmarkKey(profile.id, saved.id), counter: 99, writer: UUID(), payload: nil), future]) }
        #expect(state.records == original)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ContinuityStore(url: root.appendingPathComponent("continuity.json"))
        state.pendingApplication = true; try store.save(state)
        #expect(try store.load()?.pendingApplication == true)
        try Data("invalid".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "invalid")
    }
    @Test func regularTabOrderAndClosureAreOwnedByTheirDevice() throws {
        var mac = ContinuityReplica(deviceName: "Mac"), phone = ContinuityReplica(deviceName: "Phone")
        let first = TabRecord(title: "First", url: URL(string: "https://example.test/first")!)
        let second = TabRecord(title: "Second", url: URL(string: "https://example.test/second")!)
        try mac.capture(profile: profile, bookmarks: [], history: [], regularTabs: [second, first], preferences: [:])
        try phone.capture(profile: profile, bookmarks: [], history: [], regularTabs: [first], preferences: [:])
        try phone.merge(Array(mac.records.values)); try mac.merge(Array(phone.records.values))
        #expect(phone.tabs(for: profile.id, device: mac.deviceID).map(\.id) == [second.id, first.id])
        try mac.capture(profile: profile, bookmarks: [], history: [], regularTabs: [second], preferences: [:])
        try phone.merge(Array(mac.records.values))
        #expect(phone.tabs(for: profile.id, device: mac.deviceID).map(\.id) == [second.id])
        #expect(phone.tabs(for: profile.id, device: phone.deviceID).map(\.id) == [first.id])
    }
    @Test func historyRetentionRedactsSupersededAndEvictedURLs() throws {
        var state = ContinuityReplica(deviceName: "Mac")
        let entries = (0..<505).map { index in
            HistoryEntry(title: "Page \(index)", url: URL(string: "https://example.test/page/\(index)")!, visitedAt: Date(timeIntervalSince1970: Double(index)))
        }
        try capture(&state, [], history: entries)
        #expect(state.history(for: profile.id).count == 500)
        #expect(state.records[ContinuityRecord.historyKey(profile.id, entries[0].id)]?.payload == nil)
        try capture(&state, [], history: entries)
        #expect(state.history(for: profile.id).count == 500)
        let newer = HistoryEntry(title: "New visit", url: entries.last!.url, visitedAt: Date(timeIntervalSince1970: 600))
        try capture(&state, [], history: [newer])
        #expect(state.records[ContinuityRecord.historyKey(profile.id, entries.last!.id)]?.payload == nil)
        #expect(state.history(for: profile.id).first == newer)
    }
    @Test func accountBindingNeverMovesDataBetweenAccounts() throws {
        var state = ContinuityReplica(deviceName: "Mac")
        try state.bindAccount("one"); try state.bindAccount("one")
        #expect(throws: ContinuityError.self) { try state.bindAccount("two") }
        #expect(state.accountID == "one")
    }
    @Test func profileCollisionsPreserveIdentitySelectionAndArchive() throws {
        let first = BrowserProfile(name: "Research"), second = BrowserProfile(name: "Research")
        var archived = BrowserProfile(name: "Archived"); archived.archivedAt = .now
        let local = ProfileRegistry(profiles: [profile, first, archived], activeID: first.id)
        let imported = try local.importingContinuity([ContinuityProfile(second), ContinuityProfile(archived)])
        #expect(imported.profiles.count == 4)
        #expect(Set(imported.profiles.map(\.name)).count == 4)
        #expect(imported.activeID == first.id)
        #expect(imported.profiles.first { $0.id == archived.id }?.archivedAt == archived.archivedAt)
        #expect(try imported.importingContinuity([ContinuityProfile(second)]) == imported)
    }
    @Test func handoffRejectsPrivateAndExecutableURLsAndPreservesProfile() throws {
        let url = URL(string: "https://example.test/page")!
        #expect(ContinuityPage(url: url, title: "Private", profile: profile, isPrivate: true) == nil)
        #expect(ContinuityPage(url: URL(string: "javascript:alert(1)"), title: "Script", profile: profile, isPrivate: false) == nil)
        let page = try #require(ContinuityPage(url: url, title: "Page", profile: profile, isPrivate: false))
        #expect(ContinuityPage(userInfo: page.userInfo) == page)
        var bad = page.userInfo; bad["profileID"] = "broken"
        #expect(ContinuityPage(userInfo: bad) == nil)
        #expect(!page.userInfo.keys.contains("cookies")); #expect(!page.userInfo.keys.contains("form"))
    }
}
