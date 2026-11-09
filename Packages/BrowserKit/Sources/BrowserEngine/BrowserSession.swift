import BrowserCore
import Foundation
import Observation
import WebKit

@MainActor @Observable
public final class BrowserSession {
    public let adBlocker: AdBlocker
    public let settings: BrowserSettings
    public let websiteData: WebsiteDataManager
    public private(set) var tabs: [BrowserTab] = []
    public private(set) var selectedTabID: UUID?
    public private(set) var bookmarks: [Bookmark] = []
    public private(set) var history: [HistoryEntry] = []
    public private(set) var persistenceNotice: String?
    public private(set) var canPersist = true
    public private(set) var isProfileActive = true
    public var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
    public var canReopenTab: Bool { !recentlyClosed.isEmpty }
    public var canUndoBookmarkRemoval: Bool { removedBookmark != nil }
    private var removedBookmark: (bookmark: Bookmark, index: Int)?
    public var orderedTabs: [BrowserTab] { tabs.filter { !$0.isPrivate && $0.isPinned } + tabs.filter { !$0.isPrivate && !$0.isPinned } + tabs.filter(\.isPrivate) }

    @ObservationIgnored public var configureWebView: ((WKWebView, BrowserTab) -> Void)?
    @ObservationIgnored public var handleDownload: ((WKDownload) -> Void)?
    @ObservationIgnored public var handleExternalURL: ((URL) -> Void)?
    @ObservationIgnored public var shouldSelectTab: ((BrowserTab) -> Bool)?
    @ObservationIgnored public var didSelectTab: ((BrowserTab) -> Void)?
    @ObservationIgnored public var didCloseTab: ((UUID) -> Void)?
    @ObservationIgnored public var onContinuityChange: (() -> Void)?
    @ObservationIgnored public var onContinuityHistoryRemoved: ((UUID) -> Void)?
    @ObservationIgnored public var onContinuityHistoryCleared: ((Date) -> Void)?
    @ObservationIgnored private let store: SessionFileStore?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private var legacyBookmarksImported = false
    private var importingLegacyBookmarks = false
    private var isShutDown = false
    private var recentlyClosed: [TabRecord] = []
    @ObservationIgnored private let regularDataStore: WKWebsiteDataStore
    @ObservationIgnored private var privateDataStore: WKWebsiteDataStore?

    public init(store: SessionFileStore? = nil, dataStore: WKWebsiteDataStore = .default(),
                adBlocker: AdBlocker = AdBlocker(), settings: BrowserSettings = BrowserSettings()) {
        self.store = store
        self.adBlocker = adBlocker
        self.settings = settings
        websiteData = WebsiteDataManager(store: dataStore)
        regularDataStore = dataStore
        if let store {
            do {
                let result = try store.load()
                if let snapshot = result.snapshot {
                    legacyBookmarksImported = snapshot.legacyBookmarksImported == true
                    bookmarks = snapshot.bookmarks
                    history = snapshot.history
                    tabs = (settings.restoreTabs ? snapshot.tabs : snapshot.tabs.filter(\.isPinned)).map { makeTab(record: $0) }
                    selectedTabID = snapshot.selectedTabID
                    if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs.first?.id }
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
        settings.onRulesChanged = { [weak self] in self?.tabs.forEach { $0.applySiteSettings() } }
    }

    public func activateSelectedTab() { if let selectedTab { didSelectTab?(selectedTab); selectedTab.activate() } }

    public func setProfileActive(_ active: Bool) {
        isProfileActive = active
        tabs.forEach { $0.setProfileActive(active) }
    }
    public func shutdown() {
        saveNow()
        onContinuityChange = nil; onContinuityHistoryRemoved = nil; onContinuityHistoryCleared = nil
        isShutDown = true
        tabs.forEach { $0.close() }
        saveTask?.cancel()
        configureWebView = nil; handleDownload = nil; handleExternalURL = nil; didCloseTab = nil; shouldSelectTab = nil; didSelectTab = nil
    }

    @discardableResult public func addTab(url: URL? = nil, isPrivate: Bool = false,
                                          configuration: WKWebViewConfiguration? = nil,
                                          select: Bool = true, load: Bool = true) -> BrowserTab {
        let tab = makeTab(record: TabRecord(title: url?.host ?? "New tab", url: url),
                          isPrivate: isPrivate, configuration: configuration)
        tabs.append(tab)
        if select { selectedTabID = tab.id; didSelectTab?(tab) }
        if load && select { tab.activate() }
        scheduleSave()
        return tab
    }

    public func selectTab(_ id: UUID) {
        guard let target = tabs.first(where: { $0.id == id }), shouldSelectTab?(target) != false else { return }
        selectedTabID = id
        didSelectTab?(target)
        selectedTab?.activate()
        scheduleSave()
    }

    public func selectRelativeTab(_ offset: Int) {
        let ordered = orderedTabs
        guard let current = ordered.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectTab(ordered[(current + offset + ordered.count) % ordered.count].id)
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
            settings.endPrivateSession()
        }
        if tabs.isEmpty { addTab() }
        else if selectedTabID == id {
            selectTab(tabs[min(index, tabs.count - 1)].id)
            if selectedTabID == id { addTab() }
        }
        scheduleSave()
    }

    public func duplicateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        addTab(url: tab.url, isPrivate: tab.isPrivate)
    }

    public func togglePinned(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.setPinned(!tab.isPinned); scheduleSave()
    }
    public func moveTab(_ id: UUID, offset: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[source]
        let peers = tabs.indices.filter { tabs[$0].isPrivate == tab.isPrivate && tabs[$0].isPinned == tab.isPinned }
        guard let position = peers.firstIndex(of: source), peers.indices.contains(position + offset) else { return }
        tabs.swapAt(source, peers[position + offset]); scheduleSave()
    }
    public func closeOtherTabs(_ id: UUID, toRight: Bool = false) {
        let ordered = orderedTabs
        guard let selected = ordered.firstIndex(where: { $0.id == id }) else { return }
        let privateGroup = ordered[selected].isPrivate
        let ids = ordered.enumerated().filter { $0.element.id != id && !$0.element.isPinned && $0.element.isPrivate == privateGroup && (!toRight || $0.offset > selected) }.map { $0.element.id }
        ids.forEach { closeTab($0) }
    }
    public func selectNumberedTab(_ number: Int) {
        let ordered = orderedTabs
        if number == 9, let last = ordered.last { selectTab(last.id) }
        else if ordered.indices.contains(number - 1) { selectTab(ordered[number - 1].id) }
    }

    public func reopenClosedTab() {
        guard var record = recentlyClosed.popLast() else { return }
        record.id = UUID()
        let tab = makeTab(record: record)
        tabs.append(tab)
        selectTab(tab.id)
    }

    public func navigate(_ input: String) throws {
        let url = try AddressResolver.resolve(input, searchEngine: settings.searchEngine)
        if selectedTab == nil { addTab() }
        selectedTab?.navigate(to: url)
    }

    /// Saved links reuse an empty regular tab; they never replace a private page or edited document.
    public func openSavedPage(_ url: URL, inNewTab: Bool = false) {
        guard AddressResolver.isWebURL(url) else { return }
        if !inNewTab, let tab = selectedTab, tab.url == nil, !tab.isPrivate {
            tab.navigate(to: url)
        } else { addTab(url: url) }
    }

    public func requiresCloseConfirmation(_ id: UUID) -> Bool {
        tabs.first { $0.id == id }?.hasEditedFields == true
    }

    /// All suggestions are local to this profile. Private queries see only private open tabs.
    public func suggestions(for query: String, isPrivate: Bool) -> [BrowserSuggestion] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var candidates = tabs.filter { $0.isPrivate == isPrivate }.compactMap { tab in
            tab.url.map { BrowserSuggestion(title: tab.displayTitle, url: $0, tabID: tab.id) }
        }
        if !isPrivate {
            candidates += bookmarks.map { BrowserSuggestion(title: $0.title, url: $0.url) }
            candidates += history.map { BrowserSuggestion(title: $0.title, url: $0.url) }
        }
        var seen = Set<URL>()
        return Array(candidates.filter {
            ($0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query))
                && seen.insert($0.url).inserted
        }.prefix(5))
    }

    public func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    public func toggleBookmark() {
        guard let tab = selectedTab, !tab.isPrivate, let url = tab.url, AddressResolver.isWebURL(url) else { return }
        if let existing = bookmarks.first(where: { $0.url == url }) { removeBookmark(existing.id); return }
        else { bookmarks.append(Bookmark(title: tab.displayTitle, url: url)) }
        saveNow()
    }

    /// Read the old saved links once, outside the browser's launch path; never mutate the old store.
    public func importLegacyBookmarks(from url: URL) async {
        guard canPersist, !isShutDown, !legacyBookmarksImported, !importingLegacyBookmarks else { return }
        importingLegacyBookmarks = true
        defer { importingLegacyBookmarks = false }
        let originalIDs = Set(bookmarks.map(\.id))
        do {
            let result = try await Task.detached(priority: .utility) { try LegacyBookmarkReader.read(at: url) }.value
            guard !Task.isCancelled, !isShutDown else { return }
            // Preserve new bookmarks made while reading. Existing retired records remain excluded.
            let currentIDs = Set(bookmarks.map(\.id))
            let removedWhileReading = originalIDs.subtracting(currentIDs)
            bookmarks.removeAll { originalIDs.contains($0.id) && (result.knownIDs.contains($0.id) || result.knownURLs.contains($0.url)) }
            var urls = Set(bookmarks.map(\.url)), ids = Set(bookmarks.map(\.id))
            for bookmark in result.bookmarks where !removedWhileReading.contains(bookmark.id) {
                if !urls.contains(bookmark.url) && !ids.contains(bookmark.id) { bookmarks.append(bookmark); urls.insert(bookmark.url); ids.insert(bookmark.id) }
            }
            legacyBookmarksImported = true
            saveNow()
        } catch { persistenceNotice = "Older saved links could not be imported. The original data is unchanged. \(error.localizedDescription)" }
    }

    @discardableResult public func importBookmarks(_ entries: [Bookmark]) -> Int {
        var urls = Set(bookmarks.map(\.url)), ids = Set(bookmarks.map(\.id))
        let incoming = entries.filter { AddressResolver.isWebURL($0.url) && urls.insert($0.url).inserted && ids.insert($0.id).inserted }
        bookmarks.append(contentsOf: incoming); saveNow(); return incoming.count
    }

    public func removeBookmark(_ id: UUID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        removedBookmark = (bookmarks.remove(at: index), index)
        saveNow()
    }
    public func undoBookmarkRemoval() {
        guard let removed = removedBookmark else { return }
        removedBookmark = nil
        guard !bookmarks.contains(where: { $0.id == removed.bookmark.id || $0.url == removed.bookmark.url }) else { return }
        bookmarks.insert(removed.bookmark, at: min(removed.index, bookmarks.count)); saveNow()
    }
    public func dismissBookmarkUndo() { removedBookmark = nil }
    public func clearHistory(since date: Date = .distantPast) { onContinuityHistoryCleared?(date); history.removeAll { $0.visitedAt >= date }; recentlyClosed = []; saveNow(discardPrevious: true) }
    public func removeHistory(_ id: UUID) { onContinuityHistoryRemoved?(id); history.removeAll { $0.id == id }; saveNow(discardPrevious: true) }
    public func dismissNotice() { if canPersist { persistenceNotice = nil } }

    public func snapshot() -> BrowserSnapshot {
        let records = tabs.filter { !$0.isPrivate }.map(\.record)
        let selected = records.contains { $0.id == selectedTabID } ? selectedTabID : records.first?.id
        return BrowserSnapshot(tabs: records, selectedTabID: selected, bookmarks: bookmarks, history: history, legacyBookmarksImported: legacyBookmarksImported)
    }

    public func saveNow(discardPrevious: Bool = false) {
        saveTask?.cancel()
        guard canPersist else { return }
        do { try store?.save(snapshot(), discardPrevious: discardPrevious); onContinuityChange?() }
        catch { persistenceNotice = "Your session could not be saved: \(error.localizedDescription)" }
    }

    /// Never replaces local tabs, website state or edited forms when receiving cloud changes.
    public func applyContinuity(bookmarks: [Bookmark], history: [HistoryEntry]) throws {
        guard canPersist else { throw ContinuityError.invalidData }
        guard self.bookmarks != bookmarks || self.history != history else { return }
        let oldBookmarks = self.bookmarks, oldHistory = self.history
        self.bookmarks = bookmarks; self.history = history
        do { try store?.save(snapshot(), discardPrevious: true) }
        catch { self.bookmarks = oldBookmarks; self.history = oldHistory; throw error }
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
                             dataStore: isPrivate ? privateDataStore! : regularDataStore, adBlocker: adBlocker, settings: settings)
        tab.setProfileActive(isProfileActive)
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
        tab.onOpenLink = { [weak self, weak tab] url, select in
            guard let tab else { return }
            self?.addTab(url: url, isPrivate: tab.isPrivate, select: select)
        }
        return tab
    }
}

public struct BrowserSuggestion: Identifiable, Equatable, Sendable {
    public let title: String
    public let url: URL
    public var tabID: UUID? = nil
    public var id: URL { url }
}
