import BrowserCore
import Foundation
import Observation

@MainActor public final class ContinuitySource {
    public let session: BrowserSession
    public let preferences: () -> [String: String]
    public let applyPreferences: ([String: String]) -> Void
    public init(session: BrowserSession, preferences: @escaping () -> [String: String], applyPreferences: @escaping ([String: String]) -> Void) {
        self.session = session; self.preferences = preferences; self.applyPreferences = applyPreferences
    }
}

@MainActor @Observable public final class BrowserContinuity {
    public private(set) var state: ContinuityReplica
    public private(set) var status = "Continuity is off on this device."
    public private(set) var isSyncing = false
    public private(set) var canSave = true
    public private(set) var accountVerified = false
    public let isConfigured: Bool
    public let activityType: String
    public private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored public var didOpenRequest: ((UUID, UUID) -> Void)?
    @ObservationIgnored private let store: ContinuityStore?
    @ObservationIgnored private let transportFactory: () -> any ContinuityTransport
    @ObservationIgnored private var transport: (any ContinuityTransport)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var sources: [UUID: ContinuitySource] = [:]
    @ObservationIgnored private var getProfiles: () -> [BrowserProfile] = { [] }
    @ObservationIgnored private var obtainSource: (BrowserProfile) throws -> ContinuitySource? = { _ in nil }
    @ObservationIgnored private var importProfiles: ([ContinuityProfile]) throws -> Void = { _ in }
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var needsSync = false
    @ObservationIgnored private var immediateSyncNeeded = false
    @ObservationIgnored private var observedSources: Set<UUID> = []
    public init(root: URL?, deviceName: String, containerIdentifier: String? = nil, activityType: String = "com.santhoshbalaji.oriv.dev.browsing",
                transportFactory: (() -> any ContinuityTransport)? = nil) {
        store = root.map { ContinuityStore(url: $0.appendingPathComponent("continuity/replica.json")) }
        let identifier = containerIdentifier ?? Bundle.main.object(forInfoDictionaryKey: "OrivContinuityContainer") as? String ?? ""
        isConfigured = !identifier.isEmpty || transportFactory != nil
        self.activityType = activityType
        self.transportFactory = transportFactory ?? { ContinuityCloudTransport(containerIdentifier: identifier) }
        var initial = ContinuityReplica(deviceName: deviceName)
        do { if let saved = try store?.load() { initial = saved } }
        catch { canSave = false; status = error.localizedDescription }
        state = initial
        if canSave && !isConfigured { status = ContinuityError.unavailable.localizedDescription }
    }
    public func configure(profiles: @escaping () -> [BrowserProfile], source: @escaping (BrowserProfile) throws -> ContinuitySource?, importProfiles: @escaping ([ContinuityProfile]) throws -> Void) {
        getProfiles = profiles; obtainSource = source; self.importProfiles = importProfiles
    }
    public func setEnabled(_ enabled: Bool) {
        guard canSave, !enabled || isConfigured else { return }
        generation += 1; task?.cancel(); task = nil
        state.enabled = enabled
        if !enabled { accountVerified = false; transport?.cancel(); transport = nil }
        perform {
            try persist()
            if enabled { try prepareSources(); requestSync() }
            else { status = "Sync paused on this device. Local and iCloud copies are retained." }
        }
    }
    public func setHandoff(_ enabled: Bool) { guard canSave else { return }; state.handoffEnabled = enabled; perform { try persist() } }
    public func setDeviceName(_ value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave, !name.isEmpty, name.count <= 80, name.rangeOfCharacter(from: .controlCharacters) == nil else { return }
        state.deviceName = name; perform { try persist() }; refreshLocal(); requestSync()
    }
    public func setForeground(_ active: Bool) {
        foreground = active; timer?.cancel(); timer = nil
        if active {
            if state.enabled { requestSync() }
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.foreground else { return }
                    if self.state.enabled { await self.syncNow() }
                }
            }
        } else { refreshLocal() }
    }
    public var otherDevices: [ContinuityDevice] { state.devices.filter { $0.id != state.deviceID } }
    public var canSendPage: Bool { state.enabled && isConfigured && canSave && accountVerified && !otherDevices.isEmpty }
    @discardableResult public func sendPage(_ page: ContinuityPage, to deviceID: UUID) -> Bool {
        guard canSendPage, getProfiles().contains(where: { $0.id == page.profile.id }),
              let device = otherDevices.first(where: { $0.id == deviceID }) else { return false }
        do {
            let request = ContinuityOpenRequest(targetDeviceID: deviceID, sourceDeviceID: state.deviceID,
                sourceDeviceName: state.deviceName, url: page.url, title: page.title, profileID: page.profile.id)
            try state.put(ContinuityRecord.openRequestKey(request.id), .openRequest(request)); try persist()
            showNotice("Sent to \(device.name)")
            // A send bypasses the normal two-second local-edit debounce.
            if isSyncing { needsSync = true; immediateSyncNeeded = true }
            else { task?.cancel(); task = Task { [weak self] in await self?.syncNow() } }
            return true
        } catch { status = error.localizedDescription; return false }
    }
    private func showNotice(_ text: String) {
        notice = text; noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.notice = nil
        }
    }
    public func requestSync() {
        guard state.enabled, canSave, isConfigured else { return }
        if isSyncing { needsSync = true; return }
        task?.cancel()
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await self?.syncNow()
        }
    }
    public func profilesChanged() {
        guard !applying else { return }
        refreshLocal(); requestSync()
    }
    public func refreshLocal() {
        guard !applying, canSave, state.enabled || state.accountID != nil else { return }
        perform { try prepareSources(); try captureAll(); try persist() }
    }
    private func prepareSources() throws {
        let active = Set(getProfiles().map(\.id))
        for id in Array(sources.keys) where !active.contains(id) {
            if let source = sources.removeValue(forKey: id) {
                source.session.onContinuityChange = nil; source.session.onContinuityHistoryRemoved = nil; source.session.onContinuityHistoryCleared = nil
            }
            observedSources.remove(id)
            let keys = state.records.values.compactMap { record -> String? in
                if case .tab(let profile, let device, _, _) = record.payload, profile == id, device == state.deviceID { return record.id }; return nil
            }
            for key in keys { try state.put(key, nil) }
        }
        for profile in getProfiles() where sources[profile.id] == nil {
            guard let source = try obtainSource(profile) else { continue }
            sources[profile.id] = source
            source.session.onContinuityChange = { [weak self] in self?.localChanged() }
            source.session.onContinuityHistoryRemoved = { [weak self] id in
                guard let self, !self.applying else { return }
                self.perform { try self.state.removeHistory(profile: profile.id, id: id); try self.persist() }
            }
            source.session.onContinuityHistoryCleared = { [weak self] since in
                guard let self, !self.applying else { return }
                self.perform { try self.state.clearHistory(profile: profile.id, since: since); try self.persist() }
            }
            if observedSources.insert(profile.id).inserted { observePreferences(profile.id) }
        }
        if state.pendingApplication { try applyIncoming() }
    }
    private func observePreferences(_ profile: UUID) {
        guard let source = sources[profile] else { return }
        withObservationTracking { _ = source.preferences() } onChange: { [weak self] in
            Task { @MainActor in self?.localChanged(); self?.observePreferences(profile) }
        }
    }
    private func localChanged() { refreshLocal(); if !applying { requestSync() } }
    private func captureAll() throws {
        for profile in getProfiles() {
            guard let source = sources[profile.id] else { continue }
            guard source.session.canPersist else { throw ContinuityError.invalidData }
            let snapshot = source.session.snapshot() // This is the same privacy filter used for durable sessions.
            try state.capture(profile: profile, bookmarks: snapshot.bookmarks, history: snapshot.history,
                              regularTabs: snapshot.tabs, preferences: source.preferences())
        }
        let device = state.devices.first { $0.id == state.deviceID }
        if device?.name != state.deviceName || Date.now.timeIntervalSince(device?.updatedAt ?? .distantPast) > 300 {
            try state.put(ContinuityRecord.deviceKey(state.deviceID), .device(ContinuityDevice(id: state.deviceID, name: state.deviceName)))
        }
    }
    public func syncNow() async {
        guard state.enabled, canSave, isConfigured, !isSyncing else { return }
        isSyncing = true; needsSync = false
        defer {
            isSyncing = false
            if needsSync {
                if immediateSyncNeeded {
                    immediateSyncNeeded = false
                    task = Task { [weak self] in await self?.syncNow() }
                } else { requestSync() }
            }
        }
        let epoch = generation
        status = "Syncing with iCloud…"
        do {
            try prepareSources(); try captureAll(); try persist()
            if transport == nil {
                let created = transportFactory()
                created.watchAccountChanges { [weak self] in
                    guard let self else { return }
                    self.accountVerified = false; self.generation += 1; self.task?.cancel()
                    self.transport?.cancel(); self.transport = nil
                    self.status = "Checking the iCloud account…"; self.requestSync()
                }
                transport = created
            }
            guard let transport else { return }
            let account = try await transport.accountIdentifier()
            guard state.enabled, generation == epoch else { return }
            try state.bindAccount(account); accountVerified = true; try persist()
            let remote = try await transport.fetch(allowZoneCreation: state.lastSync == nil)
            // The account may change while a fetch is in flight. Validate before importing its data.
            let fetchedAccount = try await transport.accountIdentifier()
            guard state.enabled, generation == epoch else { return }
            try state.bindAccount(fetchedAccount)
            // Capture edits made while awaiting the server before merging its response.
            try captureAll(); try state.merge(remote); try state.expireOpenRequests()
            state.pendingApplication = true; try persist(); try applyIncoming(allowOpenRequests: true)
            // Check the account again immediately before uploading.
            try state.bindAccount(try await transport.accountIdentifier())
            guard state.enabled, generation == epoch else { return }
            let conflicts = try await transport.push(Array(state.records.values))
            guard state.enabled, generation == epoch else { return }
            if !conflicts.isEmpty {
                try captureAll(); try state.merge(conflicts); try state.expireOpenRequests(); state.pendingApplication = true; try persist(); try applyIncoming(allowOpenRequests: true)
                status = "Changes merged. Finishing sync…"; requestSync(); return
            }
            state.seedKeys = []; state.lastSync = .now; try persist(); status = needsSync ? "Local changes waiting to sync…" : "Up to date"
        } catch {
            guard generation == epoch else { return }
            status = error.localizedDescription
            accountVerified = false
            if case ContinuityError.accountChanged = error { transport?.cancel(); transport = nil }
        }
    }
    private func applyIncoming(allowOpenRequests: Bool = false) throws {
        guard !applying else { return }
        applying = true; defer { applying = false }
        try importProfiles(state.profiles)
        for profile in getProfiles() {
            if sources[profile.id] == nil, let source = try obtainSource(profile) { sources[profile.id] = source }
            guard let source = sources[profile.id] else { continue }
            guard source.session.canPersist else { throw ContinuityError.invalidData }
            try source.session.applyContinuity(bookmarks: state.bookmarks(for: profile.id), history: state.history(for: profile.id))
            source.applyPreferences(state.preferences(for: profile.id))
            state.observedBookmarks[profile.id] = source.session.bookmarks
        }
        // Requests are only applied after this sync has verified the bound account. A recovered
        // metadata journal may be replayed earlier, but must not navigate before verification.
        if allowOpenRequests && accountVerified && state.enabled {
            try state.expireOpenRequests()
            for request in state.openRequests(targeting: state.deviceID) {
                // Same rule as Other Devices: import missing identities from synced profiles;
                // an archived profile stays archived, with delivery pending until restored/expired.
                guard getProfiles().contains(where: { $0.id == request.profileID }),
                      let source = sources[request.profileID] else { continue }
                let opened = try source.session.applyOpenRequest(request)
                try state.put(ContinuityRecord.openRequestKey(request.id), nil)
                try persist()
                if opened, let tabID = source.session.selectedTabID { didOpenRequest?(request.profileID, tabID); showNotice("Opened from \(request.sourceDeviceName)") }
            }
        }
        state.pendingApplication = false; try persist()
        // Newly received profiles get normal local-change observers after the transaction.
        for profile in getProfiles() {
            guard let source = sources[profile.id] else { continue }
            if observedSources.insert(profile.id).inserted { observePreferences(profile.id) }
            source.session.onContinuityChange = { [weak self] in self?.localChanged() }
            source.session.onContinuityHistoryRemoved = { [weak self] id in self?.perform { guard let self else { return }; try self.state.removeHistory(profile: profile.id, id: id); try self.persist() } }
            source.session.onContinuityHistoryCleared = { [weak self] since in self?.perform { guard let self else { return }; try self.state.clearHistory(profile: profile.id, since: since); try self.persist() } }
        }
    }
    private func persist() throws { try store?.save(state) }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { status = error.localizedDescription }
    }
    public func shutdown() {
        generation += 1; task?.cancel(); timer?.cancel(); noticeTask?.cancel(); task = nil; timer = nil; transport?.cancel(); transport = nil
        for source in sources.values {
            source.session.onContinuityChange = nil; source.session.onContinuityHistoryRemoved = nil; source.session.onContinuityHistoryCleared = nil
        }
    }
    public var canHandoff: Bool { state.enabled && state.handoffEnabled && isConfigured && canSave && accountVerified }
}
