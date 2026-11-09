import AppKit
import BrowserCore
import BrowserEngine
import Observation

/// Owns profile lifetimes independently of the currently displayed SwiftUI scene.
/// Keeping opened profiles alive preserves form state and in-progress downloads.
@MainActor @Observable final class BrowserProfiles {
    let continuity: BrowserContinuity
    private(set) var registry = ProfileRegistry()
    private(set) var canModify = true
    var error: String?
    var notice: String?
    var showManager = false
    var pendingSelection: UUID?
    private(set) var externalPrivate: BrowserController?
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
    var active: BrowserProfile { registry.profiles.first { $0.id == registry.activeID } ?? .personal }
    var available: [BrowserProfile] { registry.profiles.filter { $0.archivedAt == nil } }
    var archived: [BrowserProfile] { registry.profiles.filter { $0.archivedAt != nil } }
    var allControllers: [BrowserController] { Array(controllers.values) + (externalPrivate.map { [$0] } ?? []) }

    init(rootDirectory: URL? = nil, testing: Bool? = nil) {
        let isTesting = testing ?? (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["BROWSER_TESTING"] == "1")
        self.testing = isTesting
        linkDefaults = isTesting ? nil : .standard
        openExternalLinksPrivately = ExternalLinkRouting.opensPrivately(defaults: isTesting ? nil : .standard)
        root = rootDirectory ?? (isTesting ? nil : URL.applicationSupportDirectory.appendingPathComponent("PersonalBrowser", isDirectory: true))
        continuity = BrowserContinuity(root: root, deviceName: "Mac")
        store = root.map { ProfileRegistryStore(fileURL: $0.appendingPathComponent("profiles.json")) }
        var loaded = ProfileRegistry()
        var loadError: String?, recovered = false
        do { if let store { let result = try store.load(); loaded = result.registry; recovered = result.recovered } }
        catch { loadError = error.localizedDescription }
        registry = loaded
        let selected = loaded.profiles.first { $0.id == loaded.activeID } ?? .personal
        controller = BrowserController(profile: selected, rootDirectory: root, testing: isTesting)
        controllers[selected.id] = controller
        if let loadError { canModify = false; notice = loadError }
        else if recovered { notice = "Your profile list was recovered from its last valid backup." }
        continuity.configure(profiles: { [weak self] in self?.available ?? [] }, source: { [weak self] profile in
            try self?.obtain(profile.id).continuitySource
        }, importProfiles: { [weak self] incoming in
            guard let self else { return }
            try self.commit(self.registry.importingContinuity(incoming))
        })
        continuity.didOpenRequest = { [weak self] profileID, tabID in
            guard let self else { return }
            self.perform {
                try self.select(profileID); self.controller.session.selectTab(tabID)
                self.showRegularWindow?()
                NSApp.windows.first(where: { $0.identifier?.rawValue == "browser" })?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func commit(_ next: ProfileRegistry) throws {
        guard canModify else { throw ProfileError.invalidRegistry }
        _ = try next.validated()
        try store?.save(next)
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
        guard let profile = registry.profiles.first(where: { $0.id == id && $0.archivedAt == nil }) else { throw ProfileError.missing }
        if let existing = controllers[id] { return existing }
        let created = BrowserController(profile: profile, rootDirectory: root, testing: testing)
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
    func select(_ id: UUID) throws {
        guard id != active.id else { return }
        if let reason = switchBlocker { throw BrowserProfileOperationError.unavailable(reason) }
        let target = try obtain(id)
        var next = registry; next.activeID = id
        // A failed metadata write leaves both the visible profile and its tabs intact.
        try commit(next)
        controller.session.saveNow()
        controller.session.setProfileActive(false)
        controller = target
        target.session.setProfileActive(true)
        target.focusAddress()
    }
    func archive(_ id: UUID) throws {
        guard id != BrowserProfile.personalID, id != active.id else { throw ProfileError.protectedProfile }
        if let loaded = controllers[id], loaded.downloads.items.contains(where: { !$0.isFinished || $0.isPaused }) || loaded.session.tabs.contains(where: \.hasEditedFields) {
            throw BrowserProfileOperationError.unavailable("Finish or cancel this profile’s downloads and edited forms before archiving it.")
        }
        var next = registry
        guard let index = next.profiles.firstIndex(where: { $0.id == id && $0.archivedAt == nil }) else { throw ProfileError.missing }
        next.profiles[index].archivedAt = .now; try commit(next)
        if let old = controllers.removeValue(forKey: id) { old.shutdown() }
    }
    func restore(_ id: UUID) throws {
        var next = registry
        guard let index = next.profiles.firstIndex(where: { $0.id == id }) else { throw ProfileError.missing }
        next.profiles[index].archivedAt = nil; try commit(next)
    }
    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }
    func saveAll() { allControllers.forEach { $0.session.saveNow() } }
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
                if !registry.profiles.contains(where: { $0.id == page.profile.id }) { try commit(registry.importingContinuity([page.profile])) }
                if registry.profiles.first(where: { $0.id == page.profile.id })?.archivedAt != nil { throw BrowserProfileOperationError.unavailable("Restore this profile before opening its tabs.") }
                try select(page.profile.id)
                controller.session.addTab(url: page.url)
                NSApp.windows.first(where: { $0.identifier?.rawValue == "browser" })?.makeKeyAndOrderFront(nil)
            }
        }
    }
    func handleIncomingURL(_ url: URL, sourceName: String? = nil) {
        guard ExternalLinkRouting.accepts(url) else { return }
        guard openExternalLinksPrivately else { controller.openExternal(url); return }
        if externalPrivate == nil {
            let context = BrowserController(profile: nil, testing: testing)
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
        showExternalWindow?()
    }
    func moveExternalTab() throws {
        guard let context = externalPrivate, let tab = context.session.selectedTab,
              let url = ExternalLinkRouting.movableURL(tab.url) else { return }
        try select(externalMoveProfileID)
        controller.session.addTab(url: url)
        showRegularWindow?()
        NSApp.windows.first(where: { $0.identifier?.rawValue == "browser" })?.makeKeyAndOrderFront(nil)
        context.session.closeTab(tab.id)
        if context.session.tabs.isEmpty { closeExternalWindow?(); endExternalPrivate() }
    }
    func endExternalPrivate() {
        externalPrivate?.shutdown(); externalPrivate = nil
    }
}

private enum BrowserProfileOperationError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}
