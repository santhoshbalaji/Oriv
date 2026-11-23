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
    public private(set) var status = "Sync is off on this device."
    public private(set) var isSyncing = false
    public private(set) var canSave = true
    public private(set) var accountVerified = false
    public let isConfigured: Bool
    public let activityType: String
    public private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored public var didOpenRequest: ((UUID, UUID) -> Void)?
    @ObservationIgnored private let store: (any ContinuityReplicaStore)?
    @ObservationIgnored private let writer = OrderedFileWriter()
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var replicaTouched = false
    @ObservationIgnored private var cyclePersisted = false
    @ObservationIgnored private var pendingProfiles: Set<UUID> = []
    @ObservationIgnored private var captured: [UUID: BrowserSnapshot] = [:]
    @ObservationIgnored private var capturedPreferences: [UUID: [String: String]] = [:]
    @ObservationIgnored private var nextHeartbeat = Date.distantPast
    @ObservationIgnored private var pendingDeliveryProfiles: Set<UUID> = []
    @ObservationIgnored private var nextExpiry: Date?
    @ObservationIgnored private let transportFactory: () -> any ContinuityTransport
    @ObservationIgnored private var transport: (any ContinuityTransport)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var sourcesPrepared = false
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
    @ObservationIgnored private let containerIdentifier: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let pushCompletionTimeout: Duration
    @ObservationIgnored private var pushHealth = ContinuityPushHealth()
    @ObservationIgnored private var registerForPush: (() -> Void)?
    @ObservationIgnored private var registrationRequested = false
    @ObservationIgnored private var scheduledImmediate = false
    @ObservationIgnored private var pendingPushProof: (account: String, date: Date)?
    @ObservationIgnored private var pushCompletions: [UUID: (ContinuityPushFetchResult) -> Void] = [:]
    @ObservationIgnored private var pushDeadlines: [UUID: Task<Void, Never>] = [:]
    public init(root: URL?, deviceName: String, containerIdentifier: String? = nil, activityType: String = "com.santhoshbalaji.oriv.dev.browsing",
                transportFactory: (() -> any ContinuityTransport)? = nil, replicaStore: (any ContinuityReplicaStore)? = nil,
                now: @escaping () -> Date = { .now }, pushCompletionTimeout: Duration = .seconds(25)) {
        store = replicaStore ?? root.map { ContinuityStore(url: $0.appendingPathComponent("continuity/replica.json")) }
        let identifier = containerIdentifier ?? Bundle.main.object(forInfoDictionaryKey: "OrivContinuityContainer") as? String ?? ""
        isConfigured = !identifier.isEmpty || transportFactory != nil
        self.containerIdentifier = identifier; self.now = now; self.pushCompletionTimeout = pushCompletionTimeout
        self.activityType = activityType
        self.transportFactory = transportFactory ?? { ContinuityCloudTransport(containerIdentifier: identifier) }
        var initial = ContinuityReplica(deviceName: deviceName)
        do { if let saved = try store?.load() { initial = saved; replicaTouched = true } }
        catch { canSave = false; status = error.localizedDescription }
        state = initial
        updateMaintenance()
        if canSave && !isConfigured { status = ContinuityError.unavailable.localizedDescription }
    }
    public func configure(profiles: @escaping () -> [BrowserProfile], source: @escaping (BrowserProfile) throws -> ContinuitySource?, importProfiles: @escaping ([ContinuityProfile]) throws -> Void) {
        getProfiles = profiles; obtainSource = source; self.importProfiles = importProfiles
    }
    public func setEnabled(_ enabled: Bool) {
        guard canSave, !enabled || isConfigured else { return }
        generation += 1; task?.cancel(); task = nil; scheduledImmediate = false
        state.enabled = enabled
        if !enabled {
            accountVerified = false; transport?.cancel(); transport = nil
            pushHealth.bind(nil); pendingPushProof = nil; finishPushes(Set(pushCompletions.keys), result: .noData)
        }
        perform {
            try persist()
            if enabled { requestPushRegistration(); refreshLocal(); requestSync() }
            else { try writer.flush(); status = "Sync paused on this device. Local and iCloud copies are retained." }
        }
        scheduleForegroundPoll()
    }
    public func setHandoff(_ enabled: Bool) { guard canSave else { return }; state.handoffEnabled = enabled; perform { try persist() } }
    public func setDeviceName(_ value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave, !name.isEmpty, name.count <= 80, name.rangeOfCharacter(from: .controlCharacters) == nil else { return }
        state.deviceName = name; nextHeartbeat = .distantPast; perform { try persist() }; refreshLocal(); requestSync()
    }
    public func setForeground(_ active: Bool) {
        foreground = active; timer?.cancel(); timer = nil
        if active {
            if state.enabled { requestPushRegistration(); requestSync(immediate: true) }
            scheduleForegroundPoll()
        } else {
            for source in sources.values { source.session.saveNow(); source.session.flushPersistence() }
            refreshLocal(); flushPersistence()
        }
    }
    public var isPushHealthy: Bool { state.enabled && accountVerified && pushHealth.isHealthy(at: now()) }
    public var isForeground: Bool { foreground }
    public var foregroundPollInterval: TimeInterval { isPushHealthy ? 300 : 30 }
    private func scheduleForegroundPoll() {
        timer?.cancel(); timer = nil
        guard foreground, state.enabled else { return }
        let delay = isPushHealthy ? pushHealth.nextPollDelay(at: now()) : 30
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.foreground, self.state.enabled else { return }
            self.timer = nil
            await self.pollNow()
        }
    }
    /// The app supplies the platform registration call only after launch. No alert authorization.
    public func configurePushRegistration(_ register: @escaping () -> Void) {
        registerForPush = register; requestPushRegistration()
    }
    private func requestPushRegistration() {
        guard state.enabled, isConfigured, !registrationRequested, let registerForPush else { return }
        registrationRequested = true; registerForPush()
    }
    public func remoteNotificationRegistration(succeeded: Bool) {
        registrationRequested = succeeded; pushHealth.registration(succeeded); scheduleForegroundPoll()
        if succeeded { requestSync(immediate: true) }
    }
    /// Returns false for another app/container/database/zone/subscription, or when opted out.
    @discardableResult public func receiveRemoteNotification(_ userInfo: [AnyHashable: Any],
        completion: @escaping (ContinuityPushFetchResult) -> Void = { _ in }) -> Bool {
        guard let push = ContinuityCloudTransport.continuityNotification(userInfo, containerIdentifier: containerIdentifier) else { completion(.noData); return false }
        return receiveContinuityPush(accountID: push.accountID, completion: completion)
    }
    @discardableResult func receiveContinuityPush(accountID: String? = nil, completion: @escaping (ContinuityPushFetchResult) -> Void = { _ in }) -> Bool {
        guard state.enabled, canSave, isConfigured else { completion(.noData); return false }
        // A cold-start push can prove delivery only after verifying its persisted account binding.
        if let accountID { pendingPushProof = (accountID, now()) }
        let id = UUID()
        pushCompletions[id] = completion
        pushDeadlines[id] = Task { [weak self, pushCompletionTimeout] in
            do { try await Task.sleep(for: pushCompletionTimeout) } catch { return }
            guard let self, self.pushCompletions[id] != nil else { return }
            self.finishPushes([id], result: .failed)
            if !self.foreground {
                // Invalidate responses after the bounded background opportunity expires.
                self.generation += 1; self.task?.cancel(); self.task = nil; self.scheduledImmediate = false
                self.needsSync = false; self.immediateSyncNeeded = false
                self.transport?.cancel(); self.transport = nil
                self.accountVerified = false; self.pendingPushProof = nil
                self.finishPushes(Set(self.pushCompletions.keys), result: .failed)
            }
        }
        requestSync(immediate: true)
        return true
    }
    private func finishPushes(_ ids: Set<UUID>, result: ContinuityPushFetchResult) {
        for id in ids {
            pushDeadlines.removeValue(forKey: id)?.cancel()
            pushCompletions.removeValue(forKey: id)?(result)
        }
    }
    public var otherDevices: [ContinuityDevice] { state.devices.filter { $0.id != state.deviceID } }
    public var canSendPage: Bool { state.enabled && isConfigured && canSave && accountVerified && !otherDevices.isEmpty }
    @discardableResult public func sendPage(_ page: ContinuityPage, to deviceID: UUID) -> Bool {
        guard !state.isProfileDeleted(page.profile.id) else { return false }
        guard canSendPage, getProfiles().contains(where: { $0.id == page.profile.id }),
              let device = otherDevices.first(where: { $0.id == deviceID }) else { return false }
        do {
            let request = ContinuityOpenRequest(targetDeviceID: deviceID, sourceDeviceID: state.deviceID,
                sourceDeviceName: state.deviceName, url: page.url, title: page.title, profileID: page.profile.id)
            try state.put(ContinuityRecord.openRequestKey(request.id), .openRequest(request)); updateMaintenance(); try persist()
            showNotice("Sent to \(device.name)")
            // A send bypasses the normal two-second local-edit debounce.
            requestSync(immediate: true)
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
    public func requestSync(immediate: Bool = false) {
        guard state.enabled, canSave, isConfigured else { return }
        if isSyncing { needsSync = true; immediateSyncNeeded = immediateSyncNeeded || immediate; return }
        if scheduledImmediate { return }
        task?.cancel()
        scheduledImmediate = immediate
        task = Task { [weak self] in
            if !immediate { do { try await Task.sleep(for: .seconds(2)) } catch { return } }
            guard let self else { return }
            self.task = nil; self.scheduledImmediate = false
            await self.syncNow()
        }
    }
    public func deleteProfile(_ id: UUID) throws {
        guard canSave else { throw ContinuityError.invalidData }
        let previous = state
        do {
            try state.deleteProfile(id)
            try persistPrivacyChange()
        } catch {
            state = previous
            throw error
        }
        detachSource(id)
        requestSync(immediate: true)
    }

    private func detachSource(_ id: UUID) {
        if let source = sources.removeValue(forKey: id) {
            source.session.onContinuitySnapshotChange = nil
            source.session.onContinuityChange = nil
            source.session.onContinuityHistoryRemoved = nil
            source.session.onContinuityHistoryCleared = nil
        }
        pendingProfiles.remove(id)
        observedSources.remove(id)
        captured.removeValue(forKey: id)
        capturedPreferences.removeValue(forKey: id)
    }

    public func profilesChanged() {
        guard !applying, canSave, state.enabled || state.accountID != nil else { return }
        perform { try prepareSources() }
        refreshLocal(); requestSync()
    }
    /// Explicit notification for non-observable preference providers and profile-local edits.
    public func refreshLocal(profileID: UUID) { localChanged(profileID, preferencesChanged: true) }
    public func refreshLocal() {
        guard !applying, canSave, state.enabled || state.accountID != nil else { return }
        perform {
            if !sourcesPrepared { try prepareSources() }
            for profile in getProfiles() where pendingProfiles.contains(profile.id) ||
                state.records[ContinuityRecord.profileKey(profile.id)]?.payload != .profile(ContinuityProfile(profile)) { try capture(profile) }
            try captureHeartbeat()
            schedulePersistence()
        }
    }
    private func prepareSources() throws {
        sourcesPrepared = true
        let profiles = getProfiles()
        let active = Set(profiles.map(\.id))
        for id in Array(sources.keys) where !active.contains(id) {
            detachSource(id)
            let keys = state.records.values.compactMap { record -> String? in
                if case .tab(let profile, let device, _, _) = record.payload, profile == id, device == state.deviceID { return record.id }
                return nil
            }
            for key in keys { try state.put(key, nil) }
        }
        for profile in profiles where sources[profile.id] == nil {
            guard let source = try obtainSource(profile) else { continue }
            sources[profile.id] = source
            pendingProfiles.insert(profile.id)
            observeSource(profile.id)
        }
        if state.pendingApplication { try applyIncoming() }
    }
    private func observePreferences(_ profile: UUID) {
        guard let source = sources[profile] else { return }
        withObservationTracking { _ = source.preferences() } onChange: { [weak self] in
            Task { @MainActor in self?.localChanged(profile, preferencesChanged: true); self?.observePreferences(profile) }
        }
    }
    private func observeSource(_ id: UUID) {
        guard let source = sources[id] else { return }
        source.session.onContinuitySnapshotChange = { [weak self] in self?.localChanged(id) }
        source.session.onContinuityChange = { [weak self] in self?.localChanged(id) }
        source.session.onContinuityHistoryRemoved = { [weak self] entry in
            guard let self, !self.applying else { return }
            self.perform { try self.state.removeHistory(profile: id, id: entry); try self.persistPrivacyChange(); self.requestSync() }
        }
        source.session.onContinuityHistoryCleared = { [weak self] since in
            guard let self, !self.applying else { return }
            self.perform { try self.state.clearHistory(profile: id, since: since); try self.persistPrivacyChange(); self.requestSync() }
        }
        if observedSources.insert(id).inserted { observePreferences(id) }
    }
    private func localChanged(_ id: UUID, preferencesChanged: Bool = false) {
        guard !applying, canSave, state.enabled || state.accountID != nil, let profile = getProfiles().first(where: { $0.id == id }) else { return }
        perform {
            let before = state.counter
            try capture(profile, readPreferences: preferencesChanged)
            if state.counter != before { schedulePersistence(); requestSync() }
        }
    }
    private func capture(_ profile: BrowserProfile, readPreferences: Bool = true) throws {
        guard let source = sources[profile.id] else { return }
        guard source.session.canPersist else { throw ContinuityError.invalidData }
        try state.captureSiteHistoryDeletions(profile: profile.id, deletions: source.session.siteHistoryDeletions)
        let snapshot = source.session.continuitySnapshot()
        let preferences = readPreferences ? source.preferences() : (capturedPreferences[profile.id] ?? source.preferences())
        // Selection and receipt changes are local-only and do not dirty continuity records.
        let previous = captured[profile.id]
        if previous?.tabs == snapshot.tabs, previous?.bookmarks == snapshot.bookmarks,
           previous?.history == snapshot.history, capturedPreferences[profile.id] == preferences,
           state.records[ContinuityRecord.profileKey(profile.id)]?.payload == .profile(ContinuityProfile(profile)) { return }
        try state.capture(profile: profile, bookmarks: snapshot.bookmarks, history: snapshot.history,
                          regularTabs: snapshot.tabs, preferences: preferences, previous: previous,
                          previousPreferences: capturedPreferences[profile.id])
        captured[profile.id] = snapshot; capturedPreferences[profile.id] = preferences
        pendingProfiles.remove(profile.id)
    }
    private func captureHeartbeat() throws {
        if Date.now >= nextHeartbeat {
            try state.put(ContinuityRecord.deviceKey(state.deviceID), .device(ContinuityDevice(id: state.deviceID, name: state.deviceName)))
            updateMaintenance()
        }
    }
    private func updateMaintenance() {
        if case .device(let device) = state.records[ContinuityRecord.deviceKey(state.deviceID)]?.payload,
           device.name == state.deviceName { nextHeartbeat = device.updatedAt.addingTimeInterval(300) }
        else { nextHeartbeat = .distantPast }
        pendingDeliveryProfiles = Set(state.openRequests(targeting: state.deviceID).map(\.profileID))
        nextExpiry = state.records.values.compactMap { record -> Date? in
            if case .openRequest(let request) = record.payload { return request.createdAt.addingTimeInterval(7 * 24 * 60 * 60) }
            return nil
        }.min()
    }
    private var hasReadyOpenRequests: Bool {
        getProfiles().contains { pendingDeliveryProfiles.contains($0.id) && sources[$0.id] != nil }
    }
    public func syncNow() async { await syncNow(polling: false) }
    func pollNow() async { await syncNow(polling: true) }
    private func syncNow(polling: Bool) async {
        guard state.enabled, canSave, isConfigured, !isSyncing else { return }
        task?.cancel(); task = nil; scheduledImmediate = false
        let pushBatch = Set(pushCompletions.keys)
        let pushProof = pendingPushProof; pendingPushProof = nil
        var pushResult = ContinuityPushFetchResult.failed
        isSyncing = true; needsSync = false
        defer {
            isSyncing = false
            finishPushes(pushBatch, result: pushResult)
            scheduleForegroundPoll()
            if needsSync {
                let immediate = immediateSyncNeeded; immediateSyncNeeded = false
                requestSync(immediate: immediate)
            }
        }
        let epoch = generation
        cyclePersisted = false
        status = "Syncing with iCloud…"
        do {
            persistenceTask?.cancel(); persistenceTask = nil
            if !sourcesPrepared { try prepareSources(); for profile in getProfiles() { try capture(profile) } }
            if transport == nil {
                let created = transportFactory()
                created.watchAccountChanges { [weak self] in
                    guard let self else { return }
                    self.accountVerified = false; self.generation += 1; self.task?.cancel(); self.task = nil; self.scheduledImmediate = false
                    self.pushHealth.bind(nil); self.pendingPushProof = nil; self.transport?.invalidatePushSubscription()
                    self.finishPushes(Set(self.pushCompletions.keys), result: .failed); self.scheduleForegroundPoll()
                    self.transport?.cancel(); self.transport = nil
                    self.status = ContinuityError.accountChanged.localizedDescription; self.requestSync()
                }
                transport = created
            }
            guard let transport else { return }
            // No-change cycles need only this lookup; validate again before importing or uploading.
            let account = try await transport.accountIdentifier()
            guard state.enabled, generation == epoch else { return }
            let bindingChanged = state.accountID == nil
            try state.bindAccount(account); accountVerified = true
            pushHealth.bind(account)
            if let pushProof, pushProof.account == account { pushHealth.receivedPush(account: account, at: pushProof.date) }
            let remote = try await transport.fetch(allowZoneCreation: state.lastSync == nil)
            guard state.enabled, generation == epoch else { return }
            let changedRemote = remote.contains { state.records[$0.id] != $0 }
            if pushHealth.fetched(remoteChanges: changedRemote, polling: polling, at: now()) { transport.invalidatePushSubscription() }
            // Subscription failures never block ordinary reconciliation or uploads.
            let subscriptionSaved: Bool
            do { subscriptionSaved = try await transport.ensurePushSubscription(accountID: account) }
            catch { subscriptionSaved = false }
            guard state.enabled, generation == epoch else { return }
            pushHealth.subscription(subscriptionSaved)
            guard !remote.isEmpty || !state.dirtyKeys.isEmpty || state.pendingApplication || bindingChanged || hasReadyOpenRequests ||
                    Date.now >= nextHeartbeat || nextExpiry.map({ Date.now >= $0 }) == true else {
                state.lastSync = .now; status = "Up to date"; pushResult = .noData; return
            }
            if !remote.isEmpty {
                // The account may change while a fetch is in flight. Validate before importing its data.
                let fetchedAccount = try await transport.accountIdentifier()
                guard state.enabled, generation == epoch else { return }
                try state.bindAccount(fetchedAccount)
                try state.merge(remote)
            }
            try captureHeartbeat(); try state.expireOpenRequests()
            var shouldApply = !remote.isEmpty || state.pendingApplication || hasReadyOpenRequests
            state.pendingApplication = shouldApply
            let uploaded = state.dirtyRecords
            var uploadError: (any Error)?
            var conflicts: [ContinuityRecord] = []
            if !uploaded.isEmpty {
                // Check the account again immediately before uploading.
                let uploadAccount = try await transport.accountIdentifier()
                guard state.enabled, generation == epoch else { return }
                try state.bindAccount(uploadAccount)
                do { conflicts = try await transport.push(uploaded) }
                catch { uploadError = error }
                guard state.enabled, generation == epoch else { return }
                if uploadError == nil {
                    let conflictedKeys = Set(conflicts.map(\.id))
                    state.acknowledge(uploaded.filter { !conflictedKeys.contains($0.id) })
                }
            }
            if !conflicts.isEmpty {
                try state.merge(conflicts); try state.expireOpenRequests(); shouldApply = true
            }
            if uploadError == nil, conflicts.isEmpty { state.seedKeys = []; state.lastSync = .now }
            // Keep this journal durable before any session application. It intentionally remains
            // pending on disk until the next write: replay is idempotent, including open receipts.
            state.pendingApplication = shouldApply
            try persistCycle()
            guard state.enabled, generation == epoch else { return }
            if shouldApply { try applyIncoming(allowOpenRequests: true) }
            updateMaintenance()
            if !state.dirtyKeys.isEmpty { needsSync = true }
            if let uploadError { throw uploadError }
            status = conflicts.isEmpty ? (needsSync ? "Local changes waiting to sync…" : "Up to date") : "Changes merged. Finishing sync…"
            pushResult = changedRemote ? .newData : .noData

        } catch {
            guard generation == epoch else { return }
            if !cyclePersisted { do { try persistCycle() } catch { status = error.localizedDescription; accountVerified = false; return } }
            status = error.localizedDescription
            accountVerified = false
            if case ContinuityError.accountChanged = error {
                pushHealth.bind(nil); transport?.invalidatePushSubscription(); transport?.cancel(); transport = nil
            }
            if case ContinuityError.remoteReset = error { pushHealth.subscription(false); transport?.invalidatePushSubscription() }
        }
    }
    private func applyIncoming(allowOpenRequests: Bool = false) throws {
        guard !applying else { return }
        applying = true; defer { applying = false }
        for id in Array(sources.keys) where state.isProfileDeleted(id) { detachSource(id) }
        try importProfiles(state.profiles)
        for profile in getProfiles() {
            if sources[profile.id] == nil, let source = try obtainSource(profile) { sources[profile.id] = source }
            guard let source = sources[profile.id] else { continue }
            guard source.session.canPersist else { throw ContinuityError.invalidData }
            let changes = state.historyChanges(for: profile.id)
            try source.session.applyContinuity(bookmarks: state.bookmarks(for: profile.id), history: state.history(for: profile.id),
                                               removedIDs: changes.removed, clearRanges: changes.cleared,
                                               siteDeletions: state.siteHistoryDeletions(for: profile.id))
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
                if opened, let tabID = source.session.selectedTabID { didOpenRequest?(request.profileID, tabID); showNotice("Opened from \(request.sourceDeviceName)") }
            }
        }
        state.pendingApplication = false
        // Newly received profiles get normal observers and a baseline for incremental capture.
        for profile in getProfiles() {
            guard let source = sources[profile.id] else { continue }
            let snapshot = source.session.continuitySnapshot()
            let previous = captured[profile.id]
            captured[profile.id] = snapshot
            if allowOpenRequests, previous?.tabs != snapshot.tabs {
                try state.capture(profile: profile, bookmarks: snapshot.bookmarks, history: snapshot.history,
                                  regularTabs: snapshot.tabs, preferences: source.preferences(), previous: previous,
                                  previousPreferences: capturedPreferences[profile.id])
            }
            capturedPreferences[profile.id] = source.preferences()
            observeSource(profile.id)
        }
    }
    private func persist() throws {
        // Explicit controls and sends are independent transactions, including in-flight sync.
        replicaTouched = true
        guard let store else { return }
        let snapshot = state
        writer.enqueue { try store.save(snapshot) }
    }
    private func schedulePersistence() {
        guard !isSyncing, !state.enabled else { return }
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            if self.state.enabled { self.requestSync() }
            else { self.perform { try self.persist() } }
        }
    }
    private func persistPrivacyChange() throws {
        // The session is about to erase its history. Journal the deletion first so a
        // crash during the debounce cannot restore the old cloud history on relaunch.
        replicaTouched = true
        guard let store else { return }
        let snapshot = state
        try writer.writeAndWait { try store.save(snapshot) }
    }
    private func persistCycle() throws {
        replicaTouched = true
        cyclePersisted = true
        guard let store else { return }
        let snapshot = state
        // Incoming application is a transaction: do not admit local edits between the
        // durable journal and application. Encoding and IO run on the worker, as do receipts.
        try writer.writeAndWait { try store.save(snapshot) }
    }
    public func flushPersistence() {
        guard canSave, replicaTouched || state.enabled || state.accountID != nil else { return }
        persistenceTask?.cancel(); persistenceTask = nil
        perform {
            // Also commit post-application tombstones and the completed journal marker.
            if let store { let snapshot = state; try writer.writeAndWait { try store.save(snapshot) } }
            else { try writer.flush() }
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { status = error.localizedDescription }
    }
    public func shutdown() {
        refreshLocal(); flushPersistence()
        generation += 1; task?.cancel(); timer?.cancel(); noticeTask?.cancel(); task = nil; timer = nil; transport?.cancel(); transport = nil
        pushHealth.bind(nil); pendingPushProof = nil; finishPushes(Set(pushCompletions.keys), result: .failed)
        for source in sources.values {
            source.session.onContinuitySnapshotChange = nil; source.session.onContinuityChange = nil; source.session.onContinuityHistoryRemoved = nil; source.session.onContinuityHistoryCleared = nil
        }
    }
    public var canHandoff: Bool { state.enabled && state.handoffEnabled && isConfigured && canSave && accountVerified }
}
