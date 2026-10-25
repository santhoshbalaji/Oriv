import BrowserCore
import Foundation
import Observation
import WebKit

@MainActor @Observable
public final class BrowserSession {
    public let adBlocker: AdBlocker
    public private(set) var tabs: [BrowserTab] = []
    public private(set) var selectedTabID: UUID?
    public private(set) var bookmarks: [Bookmark] = []
    public private(set) var history: [HistoryEntry] = []
    public private(set) var persistenceNotice: String?
    public private(set) var canPersist = true
    public var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
    public var canReopenTab: Bool { !recentlyClosed.isEmpty }

    @ObservationIgnored public var configureWebView: ((WKWebView, BrowserTab) -> Void)?
    @ObservationIgnored public var handleDownload: ((WKDownload) -> Void)?
    @ObservationIgnored public var handleExternalURL: ((URL) -> Void)?
    @ObservationIgnored public var didCloseTab: ((UUID) -> Void)?
    @ObservationIgnored private let store: SessionFileStore?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private var recentlyClosed: [TabRecord] = []
    @ObservationIgnored private let regularDataStore: WKWebsiteDataStore
    @ObservationIgnored private var privateDataStore: WKWebsiteDataStore?

    public init(store: SessionFileStore? = nil, dataStore: WKWebsiteDataStore = .default(),
                adBlocker: AdBlocker = AdBlocker()) {
        self.store = store
        self.adBlocker = adBlocker
        regularDataStore = dataStore
        if let store {
            do {
                let result = try store.load()
                if let snapshot = result.snapshot {
                    bookmarks = snapshot.bookmarks
                    history = snapshot.history
                    tabs = snapshot.tabs.map { makeTab(record: $0) }
                    selectedTabID = snapshot.selectedTabID
                }
                if result.recoveredFromBackup { persistenceNotice = "Your last valid session was recovered from a backup." }
            } catch {
                canPersist = false
                persistenceNotice = error.localizedDescription + " Saving is paused to protect it."
            }
        }
        if tabs.isEmpty {
            let tab = makeTab()
            tabs = [tab]
            selectedTabID = tab.id
        }
        adBlocker.onChange = { [weak self] in self?.tabs.forEach { $0.refreshContentBlocking() } }
    }

    public func activateSelectedTab() { selectedTab?.activate() }

    @discardableResult public func addTab(url: URL? = nil, isPrivate: Bool = false,
                                          configuration: WKWebViewConfiguration? = nil,
                                          select: Bool = true, load: Bool = true) -> BrowserTab {
        let tab = makeTab(record: TabRecord(title: url?.host ?? "New tab", url: url),
                          isPrivate: isPrivate, configuration: configuration)
        tabs.append(tab)
        if select { selectedTabID = tab.id }
        if load && select { tab.activate() }
        scheduleSave()
        return tab
    }

    public func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        selectedTab?.activate()
        scheduleSave()
    }

    public func selectRelativeTab(_ offset: Int) {
        guard let current = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectTab(tabs[(current + offset + tabs.count) % tabs.count].id)
    }

    public func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if !tab.isPrivate { recentlyClosed.append(tab.record); recentlyClosed = Array(recentlyClosed.suffix(20)) }
        tab.close()
        tabs.remove(at: index)
        didCloseTab?(id)
        if !tabs.contains(where: \.isPrivate) {
            privateDataStore = nil
            adBlocker.endPrivateSession()
        }
        if tabs.isEmpty { addTab() }
        else if selectedTabID == id { selectTab(tabs[min(index, tabs.count - 1)].id) }
        scheduleSave()
    }

    public func duplicateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        addTab(url: tab.url, isPrivate: tab.isPrivate)
    }

    public func reopenClosedTab() {
        guard var record = recentlyClosed.popLast() else { return }
        record.id = UUID()
        let tab = makeTab(record: record)
        tabs.append(tab)
        selectTab(tab.id)
    }

    public func navigate(_ input: String) throws {
        let url = try AddressResolver.resolve(input)
        if selectedTab == nil { addTab() }
        selectedTab?.navigate(to: url)
    }

    public func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    public func toggleBookmark() {
        guard let tab = selectedTab, !tab.isPrivate, let url = tab.url, AddressResolver.isWebURL(url) else { return }
        if let index = bookmarks.firstIndex(where: { $0.url == url }) { bookmarks.remove(at: index) }
        else { bookmarks.append(Bookmark(title: tab.displayTitle, url: url)) }
        saveNow()
    }

    public func removeBookmark(_ id: UUID) { bookmarks.removeAll { $0.id == id }; saveNow() }
    public func clearHistory() { history.removeAll(); saveNow(discardPrevious: true) }
    public func dismissNotice() { if canPersist { persistenceNotice = nil } }

    public func snapshot() -> BrowserSnapshot {
        let records = tabs.filter { !$0.isPrivate }.map(\.record)
        let selected = records.contains { $0.id == selectedTabID } ? selectedTabID : records.first?.id
        return BrowserSnapshot(tabs: records, selectedTabID: selected, bookmarks: bookmarks, history: history)
    }

    public func saveNow(discardPrevious: Bool = false) {
        saveTask?.cancel()
        guard canPersist, let store else { return }
        do { try store.save(snapshot(), discardPrevious: discardPrevious) }
        catch { persistenceNotice = "Your session could not be saved: \(error.localizedDescription)" }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveNow()
        }
    }

    private func makeTab(record: TabRecord = TabRecord(), isPrivate: Bool = false,
                         configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        if isPrivate && privateDataStore == nil { privateDataStore = .nonPersistent() }
        let tab = BrowserTab(record: record, isPrivate: isPrivate, configuration: configuration,
                             dataStore: isPrivate ? privateDataStore! : regularDataStore, adBlocker: adBlocker)
        tab.onChange = { [weak self] in self?.scheduleSave() }
        tab.onVisit = { [weak self, weak tab] url, title in
            guard let self, let tab, !tab.isPrivate else { return }
            self.history.removeAll { $0.url == url }
            self.history.insert(HistoryEntry(title: title, url: url), at: 0)
            self.history = Array(self.history.prefix(500))
            self.scheduleSave()
        }
        tab.onWebViewCreated = { [weak self, weak tab] view in
            guard let tab else { return }
            self?.configureWebView?(view, tab)
        }
        tab.onDownload = { [weak self] download in self?.handleDownload?(download) }
        tab.onExternalURL = { [weak self] url in self?.handleExternalURL?(url) }
        return tab
    }
}
