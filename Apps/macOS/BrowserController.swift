import AppKit
import BrowserCore
import BrowserEngine
import Observation
import WebKit
import ProductivityKit

@MainActor @Observable
final class BrowserController {
    let session: BrowserSession
    let downloads = DownloadManager()
    let workspace: WorkspaceStore?
    let reminders = WorkspaceReminders()
    var workspaceError: String?
    var selectedItemID: UUID?
    var workspaceRequest = 0
    var captureDraft: PageCapture?
    var isCapturing = false
    var addressFocusRequest = 0
    var findRequest = 0
    var passwordsGuideRequest = 0
    var library: LibrarySection?
    var addressError: String?
    @ObservationIgnored private var adapters: [UUID: MacWebUIDelegate] = [:]

    init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["BROWSER_TESTING"] == "1"
        let applicationSupport = URL.applicationSupportDirectory.appendingPathComponent("PersonalBrowser", isDirectory: true)
        session = BrowserSession(store: isTesting ? nil : SessionFileStore(fileURL: applicationSupport.appendingPathComponent("session.json")),
                                 adBlocker: AdBlocker(defaults: isTesting ? nil : .standard))
        do {
            let store = try WorkspaceStore(url: isTesting ? nil : applicationSupport.appendingPathComponent("workspace.sqlite"))
            if session.canPersist { try store.migrateBookmarks(session.bookmarks) }
            workspace = store
        } catch { workspace = nil; workspaceError = "Workspace couldn’t open. Existing files were preserved. \(error.localizedDescription)" }
        session.configureWebView = { [weak self] view, tab in
            guard let self else { return }
            let adapter = MacWebUIDelegate(session: self.session, tab: tab)
            self.adapters[tab.id] = adapter
            view.uiDelegate = adapter
        }
        session.didCloseTab = { [weak self] id in self?.adapters.removeValue(forKey: id) }
        session.handleDownload = { [weak self] download in self?.downloads.begin(download) }
        session.handleExternalURL = { url in
            let alert = NSAlert()
            alert.messageText = "Open another application?"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    var savedBookmarks: [Bookmark] {
        guard let workspace else { return session.bookmarks }
        return workspace.items.filter { $0.deletedAt == nil && $0.archivedAt == nil }.compactMap { item in
            guard let url = item.url else { return nil }
            return Bookmark(id: item.id, title: item.title, url: url, createdAt: item.createdAt)
        }
    }
    func showWorkspace(itemID: UUID? = nil) { if let itemID { selectedItemID = itemID }; workspaceRequest += 1 }
    func saveCurrentPage(forceCapture: Bool = false) {
        guard let tab = session.selectedTab, !tab.isPrivate, let url = tab.url, !isCapturing else { return }
        guard let workspace else { showWorkspace(); return }
        if !forceCapture, let existing = workspace.existingItem(for: url) { showWorkspace(itemID: existing.id); return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do { captureDraft = try await PageCaptureService.capture(tab) }
            catch { workspaceError = error.localizedDescription }
        }
    }
    func performWorkspace(_ operation: () throws -> Void) {
        do { try operation(); refreshReminders() }
        catch { workspaceError = error.localizedDescription }
    }
    func refreshReminders(requestPermission: Bool = false) {
        guard let workspace else { return }
        let deliveries = workspace.reminderDeliveries()
        let active = Set(workspace.items.filter { $0.archivedAt == nil && $0.deletedAt == nil }.map(\.id))
        let retired = Set(workspace.actions.filter { $0.isComplete || !active.contains($0.itemID) }
            .map { "oriv.action.\($0.id.uuidString)" })
        Task { await reminders.reconcile(deliveries, retiringIDs: retired, requestPermission: requestPermission) }
    }

    func newTab(isPrivate: Bool = false) { session.addTab(isPrivate: isPrivate); focusAddress() }
    func focusAddress() { addressFocusRequest += 1 }
    func closeTabOrPanel() {
        // A browser shortcut must never close a background tab while Settings is active.
        let window = NSApp.keyWindow
        if library != nil, window?.identifier?.rawValue == "browser" || window?.sheetParent?.identifier?.rawValue == "browser" {
            library = nil
        } else if let window, window.identifier?.rawValue != "browser" {
            window.performClose(nil)
        } else if let id = session.selectedTabID {
            session.closeTab(id)
        }
    }
    func navigate(_ input: String) {
        do { try session.navigate(input); addressError = nil }
        catch { addressError = error.localizedDescription }
    }
    func openExternal(_ url: URL) {
        guard AddressResolver.isWebURL(url) else { return }
        session.addTab(url: url)
    }

    func suggestions(for query: String, isPrivate: Bool) -> [BrowserSuggestion] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var candidates = session.tabs.filter { $0.isPrivate == isPrivate }.compactMap { tab in
            tab.url.map { BrowserSuggestion(title: tab.displayTitle, url: $0, tabID: tab.id) }
        }
        if !isPrivate {
            candidates += savedBookmarks.map { BrowserSuggestion(title: $0.title, url: $0.url) }
            candidates += session.history.map { BrowserSuggestion(title: $0.title, url: $0.url) }
        }
        var seen = Set<URL>()
        return Array(candidates.filter {
            ($0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query))
                && seen.insert($0.url).inserted
        }.prefix(5))
    }
}

struct BrowserSuggestion: Identifiable {
    let title: String
    let url: URL
    var tabID: UUID?
    var id: URL { url }
}

enum LibrarySection: String, Identifiable, CaseIterable {
    case bookmarks = "Bookmarks", history = "History", downloads = "Downloads"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .bookmarks: "bookmark"
        case .history: "clock.arrow.circlepath"
        case .downloads: "arrow.down.circle"
        }
    }
}
