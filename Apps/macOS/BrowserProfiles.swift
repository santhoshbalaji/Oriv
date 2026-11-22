import AppKit
import BrowserCore
import BrowserEngine
import Observation

/// Owns profile lifetimes independently of the currently displayed SwiftUI scene.
/// Keeping opened profiles alive preserves form state and in-progress downloads.
@MainActor @Observable final class BrowserProfiles {
    let continuity: BrowserContinuity
    private let privateTabIsolation: PrivateTabIsolation
    private(set) var registry = ProfileRegistry()
    private(set) var canModify = true
    var error: String?
    var notice: String?
    var showManager = false
    var pendingSelection: UUID?
    private(set) var privateWindows: [UUID: BrowserController] = [:]
    private(set) var externalPrivate: BrowserController?
    private(set) var externalPresentationRequest = 0
    var externalSourceName: String?
    var externalBannerVisible = true
    var externalMoveProfileID = BrowserProfile.personalID
    @ObservationIgnored var showRegularWindow: (() -> Void)?
    @ObservationIgnored var showExternalWindow: (() -> Void)?
    @ObservationIgnored var closeExternalWindow: (() -> Void)?
    @ObservationIgnored private let linkDefaults: UserDefaults?
    var openExternalLinksPrivately: Bool {
        didSet { linkDefaults?.set(openExternalLinksPrivately, forKey: ExternalLinkRouting.defaultsKey) }
    }
    private(set) var controller: BrowserController
    @ObservationIgnored private var controllers: [UUID: BrowserController] = [:]
    @ObservationIgnored private let store: ProfileRegistryStore?
    @ObservationIgnored private let root: URL?
    @ObservationIgnored private let testing: Bool
    @ObservationIgnored private var deleting: Set<UUID> = []
    @ObservationIgnored private var selectionSave: Task<Void, Never>?
    @ObservationIgnored private var selectionNeedsSave = false
    private var profilePreviews: [UUID: ProfileSidebarPreview] = [:]
    let sidebarSwitch = ProfileSidebarSwitch()
    var profileSwipePreference: ProfileSwipePreference {
        didSet { linkDefaults?.set(profileSwipePreference.rawValue, forKey: ProfileSwipePreference.key) }
    }
    var active: BrowserProfile { registry.profiles.first { $0.id == registry.activeID } ?? .personal }
    var available: [BrowserProfile] { registry.profiles.filter { $0.archivedAt == nil && !continuity.state.isProfileDeleted($0.id) } }
    var archived: [BrowserProfile] { registry.profiles.filter { $0.archivedAt != nil && !continuity.state.isProfileDeleted($0.id) } }
    var allControllers: [BrowserController] {
        Array(controllers.values) + Array(privateWindows.values) + (externalPrivate.map { [$0] } ?? [])
    }

    init(rootDirectory: URL? = nil, testing: Bool? = nil) {
        let isTesting = testing ?? (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["BROWSER_TESTING"] == "1")
        self.testing = isTesting
        privateTabIsolation = PrivateTabIsolation(defaults: isTesting ? nil : .standard)
        linkDefaults = isTesting ? nil : .standard
        profileSwipePreference = linkDefaults?.string(forKey: ProfileSwipePreference.key)
            .flatMap(ProfileSwipePreference.init(rawValue:)) ?? .system
        openExternalLinksPrivately = ExternalLinkRouting.opensPrivately(defaults: isTesting ? nil : .standard)
        root = rootDirectory ?? (isTesting ? nil : URL.applicationSupportDirectory.appendingPathComponent("PersonalBrowser", isDirectory: true))
        continuity = BrowserContinuity(root: root, deviceName: "Mac")
        store = root.map { ProfileRegistryStore(fileURL: $0.appendingPathComponent("profiles.json")) }
        var loaded = ProfileRegistry()
        var loadError: String?, recovered = false
        do { if let store { let result = try store.load(); loaded = result.registry; recovered = result.recovered } }
        catch { loadError = error.localizedDescription }
        registry = loaded
        if continuity.state.isProfileDeleted(loaded.activeID) { loaded.activeID = BrowserProfile.personalID; registry = loaded }
        if !isTesting, loadError == nil {
            let replica = continuity.state
            SessionFactory.prepareCNAMEAtLaunch(
                profiles: loaded.profiles.filter { !replica.isProfileDeleted($0.id) },
                bundleID: Bundle.main.bundleIdentifier ?? "local.personalbrowser.mac"
            )
        }
        let selected = loaded.profiles.first { $0.id == loaded.activeID } ?? .personal
        controller = BrowserController(profile: selected, rootDirectory: root, testing: isTesting, privateTabIsolation: privateTabIsolation)
        controllers[selected.id] = controller
        if let loadError { canModify = false; notice = loadError }
        else if recovered { notice = "Your profile list was recovered from its last valid backup." }
        continuity.configure(profiles: { [weak self] in self?.available ?? [] }, source: { [weak self] profile in
            try self?.obtain(profile.id).continuitySource
        }, importProfiles: { [weak self] incoming in
            guard let self else { return }
            self.finishDeletedProfiles()
            let updated = try self.registry.importingContinuity(incoming)
            if updated != self.registry { try self.commit(updated) }
        })
        continuity.didOpenRequest = { [weak self] profileID, tabID in
            guard let self, self.continuity.isForeground else { return }
            self.perform {
                try self.select(profileID); self.controller.session.selectTab(tabID)
                self.showRegularWindow?()
                BackgroundUIMode.showBrowserWindow(NSApp.windows.first(where: { $0.identifier?.rawValue == "browser" }))
            }
        }
        finishDeletedProfiles()
    }

    private func finishDeletedProfiles() {
        if continuity.state.isProfileDeleted(active.id) {
            let old = controller
            old.leaveProfile()
            registry.activeID = BrowserProfile.personalID
            if let personal = try? obtain(BrowserProfile.personalID) {
                personal.prepareForProfileSwitch()
                controller = personal
                personal.session.setProfileActive(true)
            }
            old.session.setProfileActive(false)
        }
        for profile in registry.profiles where continuity.state.isProfileDeleted(profile.id) {
            controllers.removeValue(forKey: profile.id)?.shutdown()
            Task { [weak self] in
                guard let self else { return }
                do { try await self.eraseProfileData(profile) }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    func delete(_ profile: BrowserProfile) async throws {
        guard canModify, !profile.isPersonal, profile.id != active.id,
              registry.profiles.contains(where: { $0.id == profile.id }) else { throw ProfileError.protectedProfile }
        if let loaded = controllers[profile.id],
           loaded.downloads.items.contains(where: { !$0.isFinished || $0.isPaused || $0.isCancelling }) {
            throw BrowserProfileOperationError.unavailable("Finish or cancel this profile’s downloads before deleting it.")
        }
        try continuity.deleteProfile(profile.id)
        controllers.removeValue(forKey: profile.id)?.shutdown()
        try await eraseProfileData(profile)
    }

    private func eraseProfileData(_ profile: BrowserProfile) async throws {
        guard canModify, deleting.insert(profile.id).inserted else { return }
        defer { deleting.remove(profile.id) }
        try await SessionFactory.removeProfileData(profile, rootOverride: root,
            bundleID: Bundle.main.bundleIdentifier ?? "local.personalbrowser.mac", testing: testing)
        var next = registry
        next.profiles.removeAll { $0.id == profile.id }
        try store?.save(next, preservingPrevious: false)
        selectionDidSave()
        registry = next
    }

    private func commit(_ next: ProfileRegistry) throws {
        guard canModify else { throw ProfileError.invalidRegistry }
        _ = try next.validated()
        try store?.save(next)
        selectionDidSave()
        registry = next
        continuity.profilesChanged()
    }
    private func normalizedName(_ value: String, excluding id: UUID? = nil) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard ProfileRegistry.validName(name) else { throw ProfileError.invalidName }
        guard !registry.profiles.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw ProfileError.duplicateName }
        return name
    }
    @discardableResult func create(name: String, color: ProfileColor, symbol: ProfileSymbol) throws -> BrowserProfile {
        let profile = BrowserProfile(name: try normalizedName(name), color: color, symbol: symbol)
        var next = registry; next.profiles.append(profile); try commit(next)
        return profile
    }
    func update(_ id: UUID, name: String, color: ProfileColor, symbol: ProfileSymbol) throws {
        let name = try normalizedName(name, excluding: id)
        var next = registry
        guard let index = next.profiles.firstIndex(where: { $0.id == id }) else { throw ProfileError.missing }
        next.profiles[index].name = name; next.profiles[index].color = color; next.profiles[index].symbol = symbol
        try commit(next)
    }
    func loadedController(_ id: UUID) -> BrowserController? { controllers[id] }
    func finishProfileSheet() {
        guard let id = pendingSelection else { return }
        pendingSelection = nil
        // SwiftUI's onDismiss runs before AppKit detaches the sheet. Wait for
        // that transition, retaining the normal guard against any other editor.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<20 {
                if testing || !NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
                    perform { try select(id) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            perform { try select(id) }
        }
    }
    private func obtain(_ id: UUID) throws -> BrowserController {
        guard let profile = available.first(where: { $0.id == id }) else { throw ProfileError.missing }
        if let existing = controllers[id] { return existing }
        let created = BrowserController(profile: profile, rootDirectory: root, testing: testing, privateTabIsolation: privateTabIsolation)
        created.session.setProfileActive(false)
        controllers[id] = created
        return created
    }
    var switchBlocker: String? {
        if controller.isExportingPage || controller.isPreparingReader {
            return "Wait for the current page operation to finish before switching profiles."
        }
        if !testing && NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
            return "Finish or cancel the open dialog before switching profiles."
        }
        return nil
    }
    func canSwitchProfiles(from source: BrowserController) -> Bool {
        source === controller && !source.session.isExternalPrivate && source.profile != nil && available.count > 1
    }

    func swipeNeighbors(from source: BrowserController) -> (previous: BrowserProfile?, next: BrowserProfile?) {
        guard source === controller, !source.session.isExternalPrivate else { return (nil, nil) }
        let profiles = available
        guard let index = profiles.firstIndex(where: { $0.id == registry.activeID }) else { return (nil, nil) }
        return (index > 0 ? profiles[index - 1] : nil, index + 1 < profiles.count ? profiles[index + 1] : nil)
    }

    func relativeProfile(_ step: Int, wrapping: Bool) -> BrowserProfile? {
        let profiles = available
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == active.id }) else { return nil }
        let next = index + step
        if wrapping { return profiles[(next + profiles.count) % profiles.count] }
        return profiles.indices.contains(next) ? profiles[next] : nil
    }

    func warmProfilePreviews() async {
        guard let root else { return }
        let adjacent = swipeNeighbors(from: controller)
        let neighbors = [adjacent.previous, adjacent.next].compactMap { $0 }
        profilePreviews = profilePreviews.filter { id, _ in neighbors.contains { $0.id == id } }
        for profile in neighbors where loadedController(profile.id) == nil {
            let directory = profile.directory(in: root)
            let read = Task.detached(priority: .utility) { await ProfileSidebarPreview.read(directory: directory) }
            let preview = await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
            guard !Task.isCancelled else { return }
            profilePreviews[profile.id] = preview
        }
    }

    func preview(for profile: BrowserProfile) -> ProfileSidebarPreview {
        if let session = loadedController(profile.id)?.session { return ProfileSidebarPreview(session: session) }
        return profilePreviews[profile.id] ?? ProfileSidebarPreview()
    }

    func switchFromSidebar(_ id: UUID, source: BrowserController, direction: Int? = nil) {
        guard canSwitchProfiles(from: source), !source.sidebar.dragging,
              let target = available.first(where: { $0.id == id }) else { return }
        perform { try sidebarSwitch.select(target, profiles: self, source: source, direction: direction) }
    }

    func select(_ id: UUID, deferSelectionSave: Bool = false) throws {
        guard id != active.id else { return }
        if let reason = switchBlocker { throw BrowserProfileOperationError.unavailable(reason) }
        guard canModify else { throw ProfileError.invalidRegistry }
        let target = try obtain(id)
        var next = registry
        next.activeID = id
        if deferSelectionSave {
            registry = next
            scheduleSelectionSave()
        } else {
            // The synchronous path leaves the visible profile intact on a write failure.
            try commit(next)
        }
        controller.leaveProfile()
        let persistence = ProfileSidebarSwitch.signposter.beginInterval("DeactivateAndFlush")
        let start = ProcessInfo.processInfo.systemUptime
        controller.session.saveNow()
        controller.session.setProfileActive(false)
        ProfileSidebarSwitch.signposter.endInterval("DeactivateAndFlush", persistence)
        if ProfileSidebarSwitch.diagnosticsEnabled {
            print("ProfileSwitch deactivate/flush ms=\((ProcessInfo.processInfo.systemUptime - start) * 1_000)")
        }
        target.prepareForProfileSwitch()
        controller = target
        target.session.setProfileActive(true)
    }

    private func scheduleSelectionSave() {
        guard store != nil else { return }
        selectionNeedsSave = true
        selectionSave?.cancel()
        selectionSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.flushSelection()
        }
    }

    private func flushSelection() {
        guard selectionNeedsSave else { return }
        do {
            try store?.save(registry)
            selectionDidSave()
        } catch { self.error = error.localizedDescription }
    }

    private func selectionDidSave() {
        selectionNeedsSave = false
        selectionSave?.cancel()
        selectionSave = nil
    }

    func archive(_ id: UUID) throws {
        guard id != BrowserProfile.personalID, id != active.id, !continuity.state.isProfileDeleted(id) else { throw ProfileError.protectedProfile }
        if let loaded = controllers[id], loaded.downloads.items.contains(where: { !$0.isFinished || $0.isPaused }) || loaded.session.tabs.contains(where: \.hasEditedFields) {
            throw BrowserProfileOperationError.unavailable("Finish or cancel this profile’s downloads and edited forms before archiving it.")
        }
        var next = registry
        guard let index = next.profiles.firstIndex(where: { $0.id == id && $0.archivedAt == nil }) else { throw ProfileError.missing }
        next.profiles[index].archivedAt = .now; try commit(next)
        if let old = controllers.removeValue(forKey: id) { old.shutdown() }
    }
    func restore(_ id: UUID) throws {
        guard !continuity.state.isProfileDeleted(id) else { throw ProfileError.missing }
        var next = registry
        guard let index = next.profiles.firstIndex(where: { $0.id == id }) else { throw ProfileError.missing }
        next.profiles[index].archivedAt = nil; try commit(next)
    }
    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }
    func saveAll() {
        flushSelection()
        allControllers.forEach { $0.session.saveNow(); $0.session.flushPersistence() }
    }
    func shutdown() { continuity.shutdown(); allControllers.forEach { $0.shutdown() } }

    func openContinuityPage(_ page: ContinuityPage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Let a Library sheet finish dismissing before changing its owning profile.
            for _ in 0..<30 {
                if testing || !NSApp.windows.contains(where: { $0.attachedSheet != nil }) { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            perform {
                guard !continuity.state.isProfileDeleted(page.profile.id) else { throw ProfileError.missing }
                if !registry.profiles.contains(where: { $0.id == page.profile.id }) { try commit(registry.importingContinuity([page.profile])) }
                if registry.profiles.first(where: { $0.id == page.profile.id })?.archivedAt != nil { throw BrowserProfileOperationError.unavailable("Restore this profile before opening its tabs.") }
                try select(page.profile.id)
                controller.session.addTab(url: page.url)
                BackgroundUIMode.showBrowserWindow(NSApp.windows.first(where: { $0.identifier?.rawValue == "browser" }))
            }
        }
    }
    func createPrivateWindow() -> UUID {
        let id = UUID()
        let context = BrowserController(profile: nil, testing: testing, privateTabIsolation: privateTabIsolation)
        context.appearance = controller.appearance
        context.session.inheritPrivatePreferences(from: controller.session)
        privateWindows[id] = context
        return id
    }

    func endPrivateWindow(_ id: UUID) {
        privateWindows.removeValue(forKey: id)?.shutdown()
    }

    func handleIncomingURL(_ url: URL, sourceName: String? = nil) {
        guard ExternalLinkRouting.accepts(url) else { return }
        guard openExternalLinksPrivately else { controller.openExternal(url); return }
        if externalPrivate == nil {
            let context = BrowserController(profile: nil, testing: testing, privateTabIsolation: privateTabIsolation)
            context.appearance = controller.appearance
            context.session.inheritPrivatePreferences(from: controller.session)
            // The private-only session starts with an empty private tab. Replace it on first arrival.
            let initial = context.session.selectedTabID
            context.session.addTab(url: url, isPrivate: true)
            if let initial { context.session.closeTab(initial) }
            externalPrivate = context
            context.session.onContinuityChange = nil
        } else { externalPrivate?.session.addTab(url: url, isPrivate: true) }
        externalSourceName = sourceName
        externalMoveProfileID = active.id
        externalBannerVisible = true
        externalPresentationRequest += 1
        showExternalWindow?()
    }
    func moveExternalTab() throws {
        guard let context = externalPrivate, let tab = context.session.selectedTab,
              let url = ExternalLinkRouting.movableURL(tab.url) else { return }
        try select(externalMoveProfileID)
        controller.session.addTab(url: url)
        showRegularWindow?()
        BackgroundUIMode.showBrowserWindow(NSApp.windows.first(where: { $0.identifier?.rawValue == "browser" }))
        context.session.closeTab(tab.id)
        if context.session.tabs.isEmpty { closeExternalWindow?(); endExternalPrivate() }
    }
    func endExternalPrivate() {
        externalPrivate?.shutdown(); externalPrivate = nil
    }
}

enum BrowserProfileOperationError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}
