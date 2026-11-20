#if DEBUG
import CloudKit
import SwiftUI

/// An explicitly launched experiment in a disposable private zone. It shares
/// neither records nor reconciliation with browser continuity.
@MainActor enum SyncTimingProbe {
    static let trials = 20
    static let flag = "--oriv-sync-timing"
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    #if os(macOS)
    static let role = "mac"
    static let peer = "iphone"
    #else
    static let role = "iphone"
    static let peer = "mac"
    #endif

    @MainActor struct Configuration {
        let run: UUID
        let container: String
        let cleanupOnly: Bool
        var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: "OrivSyncTiming-\(run.uuidString)") }
        var log: URL { FileManager.default.temporaryDirectory.appendingPathComponent("oriv-sync-\(run.uuidString)-\(role).jsonl") }

        init() throws {
            let process = ProcessInfo.processInfo
            let args = process.arguments
            guard let flagIndex = args.firstIndex(of: flag), args.indices.contains(flagIndex + 1),
                  let run = UUID(uuidString: args[flagIndex + 1]),
                  process.environment["BROWSER_TESTING"] == "1", AppIdentity.isDevelopment,
                  Bundle.main.object(forInfoDictionaryKey: "OrivPushEnvironment") as? String == "development",
                  let container = Bundle.main.object(forInfoDictionaryKey: "OrivContinuityContainer") as? String,
                  !container.isEmpty else { throw ProbeError.configuration }
            #if os(macOS)
            guard process.environment["ORIV_BACKGROUND_UI"] == "1",
                  process.environment["ORIV_FOREGROUND_UI"] != "1" else { throw ProbeError.configuration }
            #endif
            self.run = run
            self.container = container
            cleanupOnly = role == "mac" && args.contains("--oriv-sync-timing-cleanup")
        }
    }

    enum ProbeError: Error {
        case configuration, account, deadline, malformedRecord
    }

    struct Event: Encodable {
        let run: UUID
        let role: String
        let event: String
        let trial: Int?
        let unixSeconds: TimeInterval
    }

    static func run(_ config: Configuration, progress: (String) -> Void) async throws {
        let container = CKContainer(identifier: config.container)
        guard try await container.accountStatus() == .available else { throw ProbeError.account }
        let database = container.privateCloudDatabase
        if config.cleanupOnly {
            try await cleanup(config, database: database)
            progress("Disposable zone cleaned up.")
            return
        }

        // Fail on accidental reuse, preserving any earlier log for analysis.
        try Data().write(to: config.log, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: config.log)
        defer { try? output.close() }
        func log(_ event: String, trial: Int? = nil, at time: Date = .now) throws {
            let row = Event(run: config.run, role: role, event: event, trial: trial, unixSeconds: time.timeIntervalSince1970)
            var data = try JSONEncoder().encode(row)
            data.append(0x0A)
            try output.write(contentsOf: data)
            print("ORIV_SYNC_TIMING \(String(decoding: data.dropLast(), as: UTF8.self))")
        }

        do {
            if role == "mac" { _ = try await database.save(CKRecordZone(zoneID: config.zoneID)) }
            for trial in 1...trials {
                progress("Trial \(trial) of \(trials)")
                if role == "mac" {
                    try await send(config, database: database, trial: trial, log: log)
                    try log("received", trial: trial, at: await receive(config, database: database, trial: trial))
                } else {
                    try log("received", trial: trial, at: await receive(config, database: database, trial: trial))
                    try await send(config, database: database, trial: trial, log: log)
                }
            }
        } catch {
            if role == "mac" {
                do { try await cleanup(config, database: database); try log("cleaned") }
                catch { try log("cleanup-failed") }
            }
            throw error
        }
        if role == "mac" {
            try await cleanup(config, database: database)
            try log("cleaned")
        }
        try log("complete")
        progress("20 trials complete.")
    }

    private static func send(_ config: Configuration, database: CKDatabase, trial: Int,
                             log: (String, Int?, Date) throws -> Void) async throws {
        let id = CKRecord.ID(recordName: "\(role)-\(trial)", zoneID: config.zoneID)
        let record = CKRecord(recordType: "OrivSyncTimingV1", recordID: id)
        record["trial"] = trial
        try log("sent", trial, .now)
        _ = try await database.save(record)
    }

    private static func receive(_ config: Configuration, database: CKDatabase, trial: Int) async throws -> Date {
        let id = CKRecord.ID(recordName: "\(peer)-\(trial)", zoneID: config.zoneID)
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            do {
                let record = try await database.record(for: id)
                let receivedAt = Date.now
                guard record.recordType == "OrivSyncTimingV1", record["trial"] as? Int == trial else {
                    throw ProbeError.malformedRecord
                }
                return receivedAt
            } catch let error as CKError {
                switch error.code {
                case .unknownItem, .zoneNotFound:
                    try await Task.sleep(for: .seconds(1))
                case .requestRateLimited, .serviceUnavailable, .zoneBusy:
                    let delay = max(1, error.retryAfterSeconds ?? 1)
                    guard ContinuousClock.now + .seconds(delay) < deadline else { throw ProbeError.deadline }
                    try await Task.sleep(for: .seconds(delay))
                default: throw error
                }
            }
        }
        throw ProbeError.deadline
    }

    private static func cleanup(_ config: Configuration, database: CKDatabase) async throws {
        do { _ = try await database.deleteRecordZone(withID: config.zoneID) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {}
    }

    static func failure(_ error: Error) -> String {
        if let error = error as? CKError { return "CloudKit error \(error.errorCode)" }
        if let error = error as? ProbeError { return "Timing probe error: \(error)" }
        return "Timing probe could not complete (\((error as NSError).code))."
    }
}

#if os(iOS)
struct SyncTimingProbeScreen: View {
    @State private var status = "Ready"
    @State private var log: URL?
    @State private var started = false

    var body: some View {
        VStack(spacing: 20) {
            Text("CloudKit Timing").font(.headline)
            Text(status)
            Button("Start 20 Trials") { started = true }.disabled(started)
            if let log { ShareLink(item: log) { Label("Export Timing Log", systemImage: "square.and.arrow.up") } }
        }
        .padding(24)
        .task(id: started) {
            guard started else { return }
            do {
                let config = try SyncTimingProbe.Configuration()
                do { try await SyncTimingProbe.run(config) { status = $0 } }
                catch { status = SyncTimingProbe.failure(error) }
                if FileManager.default.fileExists(atPath: config.log.path) { log = config.log }
            } catch { status = SyncTimingProbe.failure(error) }
        }
    }
}
#endif
#endif
