import Foundation
import Observation
import BrowserCore
import BrowserEngine

@MainActor @Observable final class MobileProfiles {
    let continuity: BrowserContinuity
    private(set) var current: MobileController
    private(set) var profiles: [BrowserProfile]
    private(set) var externalPrivate: MobileController?
    private(set) var lastRegularProfileID: UUID
    var externalBannerVisible = true
    var externalMoveProfileID = BrowserProfile.personalID
    var openExternalLinksPrivately: Bool {
        didSet { if !isEphemeral { UserDefaults.standard.set(openExternalLinksPrivately, forKey: ExternalLinkRouting.defaultsKey) } }
    }
    @ObservationIgnored private let isEphemeral: Bool
    @ObservationIgnored private var controllers: [UUID: MobileController] = [:]
    init() {
        #if DEBUG && targetEnvironment(simulator)
        let liveCapture = ChromeVisualFixture.liveURL != nil
        #else
        let liveCapture = false
        #endif
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["BROWSER_TESTING"] == "1" || ChromeVisualFixture.mode != nil || liveCapture
        isEphemeral = testing
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
        profiles = ChromeVisualFixture.mode != nil ? [.personal, BrowserProfile(name: "Work")] : known
        let initialProfile = known.first { $0.id == selected && $0.archivedAt == nil } ?? .personal
        lastRegularProfileID = initialProfile.id
        current = MobileController(profile: initialProfile)
        controllers[current.profileID!] = current
        current.profiles = self
        continuity.configure(profiles: { [weak self] in self?.profiles.filter { $0.archivedAt == nil } ?? [] }, source: { [weak self] profile in
            guard let self else { return nil }
            return self.obtain(profile).continuitySource
        }, importProfiles: { [weak self] incoming in
            guard let self else { return }
            var registry = ProfileRegistry(); registry.profiles = self.profiles; registry.activeID = self.lastRegularProfileID
            self.profiles = try registry.importingContinuity(incoming).profiles; self.persist()
        })
        continuity.didOpenRequest = { [weak self] profileID, tabID in
            guard let self, let profile = self.profiles.first(where: { $0.id == profileID }) else { return }
            self.current.sheet = nil; self.select(profile); self.current.session.selectTab(tabID)
        }
    }
    private func obtain(_ profile: BrowserProfile) -> MobileController {
        if let existing = controllers[profile.id] { return existing }
        let created = MobileController(profile: profile); created.session.setProfileActive(false)
        created.profiles = self
        controllers[profile.id] = created; return created
    }
    func openContinuityPage(_ page: ContinuityPage) {
        current.perform {
            if !profiles.contains(where: { $0.id == page.profile.id }) {
                var registry = ProfileRegistry(); registry.profiles = profiles; registry.activeID = lastRegularProfileID
                profiles = try registry.importingContinuity([page.profile]).profiles; persist()
            }
            guard let profile = profiles.first(where: { $0.id == page.profile.id }), profile.archivedAt == nil else { throw ProfileError.protectedProfile }
            current.sheet = nil; select(profile); current.session.addTab(url: page.url)
        }
    }
    func select(_ profile: BrowserProfile) {
        guard profile.archivedAt == nil else { return }
        current.background()
        if !profiles.contains(where: { $0.id == profile.id }) { profiles.append(profile) }
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
            guard let index = profiles.firstIndex(where: { $0.id == id }), !profiles[index].isPersonal else { throw ProfileError.protectedProfile }
            profiles[index].name = name; persist()
        } else {
            guard profiles.count < 100 else { throw ProfileError.invalidRegistry }
            select(BrowserProfile(name: name))
        }
    }
    func archive(_ id: UUID) {
        guard id != lastRegularProfileID, let index = profiles.firstIndex(where: { $0.id == id }), !profiles[index].isPersonal else { return }
        if let controller = controllers[id] {
            for tab in controller.session.tabs.filter(\.isPrivate) { controller.session.closeTab(tab.id) }
            controller.background()
        }
        profiles[index].archivedAt = .now; persist()
    }
    func restore(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].archivedAt = nil; persist()
    }
    private func persist() {
        guard !isEphemeral else { return }
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "OrivMobileProfiles") }
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
        current.sheet = nil; current.background()
        if externalPrivate == nil {
            let context = MobileController(profile: nil)
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
        current.sheet = nil; current.background(); current = externalPrivate; current.foreground()
    }
    func moveExternalTab() {
        guard let context = externalPrivate, let tab = context.session.selectedTab,
              let url = ExternalLinkRouting.movableURL(tab.url),
              let profile = profiles.first(where: { $0.id == externalMoveProfileID && $0.archivedAt == nil }) else { return }
        select(profile); current.session.addTab(url: url)
        context.session.closeTab(tab.id)
        if context.session.tabs.isEmpty { context.session.shutdown(); externalPrivate = nil }
    }
    /// Only the address moves. Cookies, history and private data stores stay with their profile.
    func move(_ tab: BrowserTab, from source: MobileController, to profile: BrowserProfile) {
        guard source.profileID != profile.id, profile.archivedAt == nil,
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
        guard ExternalLinkRouting.movableURL(url) != nil, profile.archivedAt == nil else { return }
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
