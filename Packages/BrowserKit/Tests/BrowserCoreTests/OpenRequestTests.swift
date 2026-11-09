import Foundation
import Testing
@testable import BrowserCore

struct OpenRequestTests {
    private func request() -> ContinuityOpenRequest {
        ContinuityOpenRequest(targetDeviceID: UUID(), sourceDeviceID: UUID(), sourceDeviceName: "Test Mac",
            url: URL(string: "https://example.test/current")!, title: "Example", profileID: BrowserProfile.personalID)
    }
    @Test func roundTripAndIdentityValidation() throws {
        let value = request()
        let record = ContinuityRecord(id: ContinuityRecord.openRequestKey(value.id), counter: 1, writer: value.sourceDeviceID, payload: .openRequest(value))
        #expect(try ContinuityRecord.decodeIfKnown(from: JSONEncoder().encode(record)) == record)
        var wrong = record; wrong.id = ContinuityRecord.openRequestKey(UUID())
        #expect(throws: (any Error).self) { try wrong.validated() }
        wrong = record; wrong.writer = UUID()
        #expect(throws: (any Error).self) { try wrong.validated() }
    }
    @Test func invalidURLsAndMetadataAreRejected() throws {
        for address in ["file:///tmp/page", "javascript:alert(1)", "data:text/html,hello", "https://", "https://example.test/" + String(repeating: "a", count: 16_384)] {
            var value = request(); value.url = URL(string: address)!
            #expect(throws: (any Error).self) { try value.validated() }
        }
        var value = request(); value.targetDeviceID = value.sourceDeviceID
        #expect(throws: (any Error).self) { try value.validated() }
        value = request(); value.sourceDeviceName = "\n"
        #expect(throws: (any Error).self) { try value.validated() }
        value = request(); value.title = String(repeating: "a", count: 4_001)
        #expect(throws: (any Error).self) { try value.validated() }
    }
    @Test func targetingExpiryAndTombstonesDeduplicateStaleRequests() throws {
        var value = request()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        value.createdAt = now.addingTimeInterval(-7 * 24 * 60 * 60 + 1)
        var sender = ContinuityReplica(deviceName: "Sender"); sender.deviceID = value.sourceDeviceID
        let key = ContinuityRecord.openRequestKey(value.id)
        try sender.put(key, .openRequest(value))
        let stale = Array(sender.records.values)
        var receiver = ContinuityReplica(deviceName: "Receiver"); receiver.deviceID = value.targetDeviceID
        try receiver.merge(stale); try receiver.merge(stale)
        #expect(receiver.openRequests(targeting: receiver.deviceID, at: now) == [value])
        #expect(receiver.openRequests(targeting: UUID(), at: now).isEmpty)
        try receiver.expireOpenRequests(at: now.addingTimeInterval(1))
        #expect(receiver.records[key]?.payload == nil)
        try receiver.merge(stale)
        #expect(receiver.records[key]?.payload == nil)
    }
    @Test func unknownKindsAndTombstonesAreSkippedButCorruptKnownRecordsFail() throws {
        let value = request()
        let record = ContinuityRecord(id: ContinuityRecord.openRequestKey(value.id), counter: 1, writer: value.sourceDeviceID, payload: .openRequest(value))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["id"] = "future.\(UUID())"; json["payload"] = ["futureKind": ["value": "synthetic"]]
        #expect(try ContinuityRecord.decodeIfKnown(from: JSONSerialization.data(withJSONObject: json)) == nil)
        json["payload"] = NSNull()
        #expect(try ContinuityRecord.decodeIfKnown(from: JSONSerialization.data(withJSONObject: json)) == nil)
        json["id"] = record.id; json["payload"] = ["futureKind": [:]]
        #expect(try ContinuityRecord.decodeIfKnown(from: JSONSerialization.data(withJSONObject: json)) == nil)
        json["payload"] = ["openRequest": ["_0": [:]]]
        #expect(throws: (any Error).self) { try ContinuityRecord.decodeIfKnown(from: JSONSerialization.data(withJSONObject: json)) }
    }
    @Test func legacyDecoderCannotDecodeNewPayload() throws {
        // Mirrors 0.6.0's synthesized closed enum: unknown cases throw.
        enum LegacyPayload: Decodable { case device(ContinuityDevice) }
        let body = try JSONEncoder().encode(ContinuityPayload.openRequest(request()))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LegacyPayload.self, from: body) }
    }
    @Test func profileMatchingUsesIdentityAndKeepsLocalArchives() throws {
        let work = BrowserProfile(name: "Work")
        var registry = ProfileRegistry(); registry.profiles.append(work)
        registry.profiles[1].archivedAt = .now
        let different = BrowserProfile(name: "Work")
        let imported = try registry.importingContinuity([ContinuityProfile(work), ContinuityProfile(different)])
        #expect(imported.profiles.first { $0.id == work.id }?.archivedAt != nil)
        #expect(imported.profiles.contains { $0.id == different.id })
        #expect(imported.profiles.count == 3)
    }
    @Test func externalPolicyDefaultsPrivateAndAllowsOnlyWebMoves() {
        let name = "ExternalPolicyTest-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ExternalLinkRouting.opensPrivately(defaults: defaults))
        defaults.set(false, forKey: ExternalLinkRouting.defaultsKey)
        #expect(!ExternalLinkRouting.opensPrivately(defaults: defaults))
        #expect(ExternalLinkRouting.accepts(URL(string: "https://example.test")!))
        #expect(!ExternalLinkRouting.accepts(URL(string: "oriv:settings")!))
        #expect(ExternalLinkRouting.movableURL(URL(string: "file:///tmp/page")) == nil)
        #expect(ExternalLinkRouting.movableURL(nil) == nil)
    }
    @Test func receiptSurvivesSnapshotRoundTripAndLegacySnapshots() throws {
        let id = UUID()
        let snapshot = BrowserSnapshot(appliedOpenRequests: [id])
        #expect(try JSONDecoder().decode(BrowserSnapshot.self, from: JSONEncoder().encode(snapshot)).appliedOpenRequests == [id])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "appliedOpenRequests")
        #expect(try JSONDecoder().decode(BrowserSnapshot.self, from: JSONSerialization.data(withJSONObject: json)).appliedOpenRequests == nil)
    }
}
