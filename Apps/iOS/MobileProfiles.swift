import Foundation
import Observation
import BrowserCore
import BrowserEngine

@MainActor @Observable final class MobileProfiles {
    let continuity: BrowserContinuity
    private(set) var current: MobileController
    private var storedProfiles: [BrowserProfile]
    var profiles: [BrowserProfile] { storedProfiles.filter { !continuity.state.isProfileDeleted($0.id) } }
    @ObservationIgnored private var deleting: Set<UUID> = []
    private(set) var externalPrivate: MobileController?
    private(set) var lastRegularProfileID: UUID
    var externalBannerVisible = true
    var externalMoveProfileID = BrowserProfile.personalID
    var openExternalLinksPrivately: Bool {
        didSet { if !isEphemeral { UserDefaults.standard.set(openExternalLinksPrivately, forKey: ExternalLinkRouting.defaultsKey) } }
    }
    @ObservationIgnored private let isEphemeral: Bool
    private let privateTabIsolation: PrivateTabIsolation
    @ObservationIgnored private var controllers: [UUID: MobileController] = [:]
    init(forceEphemeral: Bool = false) {
        #if DEBUG && targetEnvironment(simulator)
        let liveCapture = ChromeVisualFixture.liveURL != nil
        #else
        let liveCapture = false
        #endif
        let testing = forceEphemeral || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["BROWSER_TESTING"] == "1" || ChromeVisualFixture.mode != nil || liveCapture
        isEphemeral = testing
        privateTabIsolation = PrivateTabIsolation(defaults: testing ? nil : .standard)
        openExternalLinksPrivately = ExternalLinkRouting.opensPrivately(defaults: testing ? nil : .standard)
        continuity = BrowserContinuity(root: testing ? nil : URL.applicationSupportDirectory.appendingPathComponent("Oriv"), deviceName: "iPhone")
        // Compatibility with the earlier mobile profile-name list, without accessing any cloud service.
        struct LegacyProfile: Decodable { let id: UUID; let name: String }
        let stored = (testing ? nil : UserDefaults.standard.data(forKey: "OrivMobileProfiles")).flatMap { try? JSONDecoder().decode([BrowserProfile].self, from: $0) }
        let legacy = (testing ? nil : UserDefaults.standard.data(forKey: "OrivMobileLibraries")).flatMap { try? JSONDecoder().decode([LegacyProfile].self, from: $0) } ?? []
        let saved = stored ?? legacy.map { BrowserProfile(id: $0.id, name: $0.name) }
        var seen: Set<UUID> = [BrowserProfile.personalID]
        let personal = saved.first { $0.isPersonal } ?? .personal
        let known: [BrowserProfile] = [personal] + saved.filter { ProfileRegistry.validName($0.name) && seen.insert($0.id).inserted }
        let selected = (testing ? nil : (UserDefaults.standard.string(forKey: "BrowserProfileID") ?? UserDefaults.standard.string(forKey: "WorkspaceProfileID"))).flatMap(UUID.init(uuidString:))
        storedProfiles = ChromeVisualFixture.mode != nil ? [.personal, BrowserProfile(name: "Work")] : known
        let replica = continuity.state
        let initialProfile = known.first { $0.id == selected && $0.archivedAt == nil && !replica.isProfileDeleted($0.id) } ?? .personal
        lastRegularProfileID = initialProfile.id
        current = MobileController(profile: initialProfile, privateTabIsolation: privateTabIsolation, forceEphemeral: forceEphemeral)
        controllers[current.profileID!] = current
        current.profiles = self
        continuity.configure(profiles: { [weak self] in self?.profiles.filter { $0.archivedAt == nil } ?? [] }, source: { [weak self] profile in
            guard let self else { return nil }
            return self.obtain(profile).continuitySource
        }, importProfiles: { [weak self] incoming in
            guard let self else { return }
            self.finishDeletedProfiles()
            let registry = ProfileRegistry(profiles: self.storedProfiles, activeID: self.lastRegularProfileID)
            let updated = try registry.importingContinuity(incoming).profiles
            if updated != self.storedProfiles { self.storedProfiles = updated; self.persist() }
        })
        continuity.didOpenRequest = { [weak self] profileID, tabID in
            guard let self, self.continuity.isForeground, let profile = self.profiles.first(where: { $0.id == profileID }) else { return }
            self.current.sheet = nil; self.select(profile); self.current.session.selectTab(tabID)
        }
        finishDeletedProfiles()
    }
    private func finishDeletedProfiles() {
        if continuity.state.isProfileDeleted(lastRegularProfileID) { select(.personal) }
        for profile in storedProfiles where continuity.state.isProfileDeleted(profile.id) {
            controllers.removeValue(forKey: profile.id)?.shutdown()
            Task { [weak self] in
                guard let self else { return }
                do { try await self.eraseProfileData(profile) }
                catch { self.current.message = error.localizedDescription }
            }
        }
    }

    func delete(_ profile: BrowserProfile) async throws {
        guard !profile.isPersonal, profile.id != lastRegularProfileID,
              storedProfiles.contains(where: { $0.id == profile.id }) else { throw ProfileError.protectedProfile }
        guard (controllers[profile.id]?.downloads.activeCount ?? 0) == 0 else {
            throw MobileProfileError.activeDownloads
        }
        try continuity.deleteProfile(profile.id)
        controllers.removeValue(forKey: profile.id)?.shutdown()
        try await eraseProfileData(profile)
    }

    private func eraseProfileData(_ profile: BrowserProfile) async throws {
        guard deleting.insert(profile.id).inserted else { return }
        defer { deleting.remove(profile.id) }
        try await SessionFactory.removeProfileData(profile, bundleID: Bundle.main.bundleIdentifier ?? "OrivMobile", testing: isEphemeral)
        storedProfiles.removeAll { $0.id == profile.id }
        persist()
    }

    private func obtain(_ profile: BrowserProfile) -> MobileController {
        if let existing = controllers[profile.id] { return existing }
        let created = MobileController(profile: profile, privateTabIsolation: privateTabIsolation, forceEphemeral: isEphemeral); created.session.setProfileActive(false)
        created.profiles = self
        controllers[profile.id] = created; return created
    }
    func openContinuityPage(_ page: ContinuityPage) {
        current.perform {
            guard !continuity.state.isProfileDeleted(page.profile.id) else { throw ProfileError.missing }
            if !profiles.contains(where: { $0.id == page.profile.id }) {
                var registry = ProfileRegistry(); registry.profiles = storedProfiles; registry.activeID = lastRegularProfileID
                storedProfiles = try registry.importingContinuity([page.profile]).profiles; persist()
            }
            guard let profile = profiles.first(where: { $0.id == page.profile.id }), profile.archivedAt == nil else { throw ProfileError.protectedProfile }
            current.sheet = nil; select(profile); current.session.addTab(url: page.url)
        }
    }
    func select(_ profile: BrowserProfile) {
        guard profile.archivedAt == nil, !continuity.state.isProfileDeleted(profile.id) else { return }
        current.background(leavingProfile: current.profileID != profile.id)
        if !profiles.contains(where: { $0.id == profile.id }) { storedProfiles.append(profile) }
        let next = obtain(profile)
        controllers[profile.id] = next; current = next
        lastRegularProfileID = profile.id
        if !isEphemeral { UserDefaults.standard.set(profile.id.uuidString, forKey: "BrowserProfileID") }
        persist()
        current.foreground()
    }
    func saveName(_ input: String, for id: UUID?) throws {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProfileRegistry.validName(name) else { throw ProfileError.invalidName }
        guard !profiles.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw ProfileError.duplicateName }
        if let id {
            guard let index = storedProfiles.firstIndex(where: { $0.id == id }), !storedProfiles[index].isPersonal else { throw ProfileError.protectedProfile }
            storedProfiles[index].name = name; persist()
        } else {
            guard profiles.count < 100 else { throw ProfileError.invalidRegistry }
            select(BrowserProfile(name: name))
        }
    }
    func archive(_ id: UUID) throws {
        guard id != lastRegularProfileID, id != BrowserProfile.personalID else { throw ProfileError.protectedProfile }
        guard !continuity.state.isProfileDeleted(id),
              let index = storedProfiles.firstIndex(where: { $0.id == id && $0.archivedAt == nil }) else { throw ProfileError.missing }
        if let loaded = controllers[id],
           loaded.downloads.activeCount > 0 || loaded.session.tabs.contains(where: \.hasEditedFields) || loaded.pendingTabClose != nil {
            throw MobileProfileError.unfinishedWork
        }
        storedProfiles[index].archivedAt = .now
        persist()
        controllers.removeValue(forKey: id)?.shutdown()
    }
    func restore(_ id: UUID) {
        guard !continuity.state.isProfileDeleted(id), let index = storedProfiles.firstIndex(where: { $0.id == id }) else { return }
        storedProfiles[index].archivedAt = nil; persist()
    }
    private func persist() {
        guard !isEphemeral else { return }
        if let data = try? JSONEncoder().encode(storedProfiles) {
            UserDefaults.standard.set(data, forKey: "OrivMobileProfiles")
            UserDefaults.standard.removeObject(forKey: "OrivMobileLibraries")
        }
        continuity.profilesChanged()
    }
    func foreground() { current.foreground(); continuity.setForeground(true) }
    func background() { controllers.values.forEach { $0.background() }; externalPrivate?.background(); continuity.setForeground(false) }
    func route(_ url: URL) {
        guard ExternalLinkRouting.accepts(url) else { return }
        guard openExternalLinksPrivately else {
            if current.profileID == nil, let profile = profiles.first(where: { $0.id == lastRegularProfileID }) { select(profile) }
            current.route(url); return
        }
        current.sheet = nil; current.background(leavingProfile: current.profileID != nil)
        if externalPrivate == nil {
            let context = MobileController(profile: nil, privateTabIsolation: privateTabIsolation,
                                           forceEphemeral: isEphemeral, inheriting: controllers[lastRegularProfileID])
            let initial = context.session.selectedTabID
            context.session.addTab(url: url, isPrivate: true, load: false)
            if let initial { context.session.closeTab(initial) }
            externalPrivate = context
        } else { externalPrivate?.session.addTab(url: url, isPrivate: true, load: false) }
        current = externalPrivate!; current.foreground()
        externalMoveProfileID = lastRegularProfileID; externalBannerVisible = true
    }
    func showExternalPrivate() {
        guard let externalPrivate else { return }
        current.sheet = nil; current.background(leavingProfile: current !== externalPrivate); current = externalPrivate; current.foreground()
    }
    func moveExternalTab() {
        guard let context = externalPrivate, let tab = context.session.selectedTab,
              let url = ExternalLinkRouting.movableURL(tab.url),
              let profile = profiles.first(where: { $0.id == externalMoveProfileID && $0.archivedAt == nil }) else { return }
        context.close([tab.id],completion:{ [weak self,weak context] in
            guard let self, self.profiles.contains(where: { $0.id == profile.id && $0.archivedAt == nil }) else { return }
            self.select(profile); self.current.session.addTab(url:url)
            if context?.session.tabs.isEmpty == true { context?.session.shutdown(); self.externalPrivate = nil }
        })
    }
    /// Only the address moves. Private source closure must already be confirmed.
    /// Cookies, history and private data stores stay with their profile.
    func move(_ tab: BrowserTab, from source: MobileController, to profile: BrowserProfile) {
        guard source.profileID != profile.id, profile.archivedAt == nil,
              !continuity.state.isProfileDeleted(profile.id),
              (!tab.isPrivate || !source.session.tabs.contains { $0.id == tab.id }),
              let url = tab.url, ExternalLinkRouting.movableURL(url) != nil else { return }
        let target = obtain(profile)
        target.session.addTab(url: url, isPrivate: tab.isPrivate, load: false)
        source.session.closeTab(tab.id)
        if source === externalPrivate, source.session.tabs.isEmpty {
            source.session.shutdown(); externalPrivate = nil
        }
        source.sheet = nil
        select(profile)
    }
    func open(_ url: URL, in profile: BrowserProfile, isPrivate: Bool) {
        guard ExternalLinkRouting.movableURL(url) != nil, profile.archivedAt == nil,
              !continuity.state.isProfileDeleted(profile.id) else { return }
        current.sheet = nil
        let target = obtain(profile)
        target.session.addTab(url: url, isPrivate: isPrivate, load: false)
        select(profile)
    }
    func finishExternalGroupIfEmpty() {
        guard let context = externalPrivate, context.session.tabs.isEmpty else { return }
        if let profile = profiles.first(where: { $0.id == lastRegularProfileID }) { select(profile) }
        context.session.shutdown(); externalPrivate = nil
    }
}

private enum MobileProfileError: LocalizedError {
    case activeDownloads, unfinishedWork
    var errorDescription: String? {
        switch self {
        case .activeDownloads: "Finish or cancel this profile’s downloads before deleting it."
        case .unfinishedWork: "Finish or cancel this profile’s downloads and edited forms before archiving it."
        }
    }
}
