import BrowserCore
import Foundation
import Observation
import WebKit

@MainActor @Observable
public final class BrowserSession {
    public let isExternalPrivate: Bool
    public let adBlocker: AdBlocker
    public let settings: BrowserSettings
    public let websiteData: WebsiteDataManager
    public private(set) var tabs: [BrowserTab] = []
    public private(set) var selectedTabID: UUID? { didSet { updateTabSelection() } }
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
    @ObservationIgnored private let store: (any BrowserSessionStore)?
    @ObservationIgnored private var lastSavedData: Data?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private var legacyBookmarksImported = false
    private var importingLegacyBookmarks = false
    private var isShutDown = false
    private var appliedOpenRequests: Set<UUID> = []
    private var recentlyClosed: [TabRecord] = []
    @ObservationIgnored private let regularDataStore: WKWebsiteDataStore
    @ObservationIgnored private var privateDataStore: WKWebsiteDataStore?

    public init(store: (any BrowserSessionStore)? = nil, dataStore: WKWebsiteDataStore = .default(),
                adBlocker: AdBlocker = AdBlocker(), settings: BrowserSettings = BrowserSettings(), externalPrivate: Bool = false) {
        isExternalPrivate = externalPrivate
        self.store = externalPrivate ? nil : store
        self.adBlocker = adBlocker
        self.settings = settings
        websiteData = WebsiteDataManager(store: dataStore)
        regularDataStore = dataStore
        if let store, !externalPrivate {
            do {
                let result = try store.load()
                if let snapshot = result.snapshot {
                    legacyBookmarksImported = snapshot.legacyBookmarksImported == true
                    appliedOpenRequests = snapshot.appliedOpenRequests ?? []
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
            let tab = makeTab(isPrivate: externalPrivate)
            tabs = [tab]
            selectedTabID = tab.id
        }
        adBlocker.onChange = { [weak self] in self?.tabs.forEach { $0.refreshContentBlocking() } }
        settings.onRulesChanged = { [weak self] in self?.tabs.forEach { $0.applySiteSettings() } }
        updateTabSelection()
    }

    private func updateTabSelection() { tabs.forEach { $0.setSelected($0.id == selectedTabID) } }

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
        if tabs.isEmpty {
            selectedTabID = nil
            if !isExternalPrivate { addTab() }
        }
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
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        struct Candidate {
            var suggestion: BrowserSuggestion
            var titles: [String]
            var bookmarked = false
            var visitedAt = Date.distantPast
        }
        var candidates: [URL: Candidate] = [:]
        // Choose a stable tab identity even if several open tabs share a URL.
        for tab in tabs.filter({ $0.isPrivate == isPrivate }).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let url = tab.url, AddressResolver.isWebURL(url) else { continue }
            if candidates[url] == nil {
                candidates[url] = Candidate(suggestion: BrowserSuggestion(title: tab.displayTitle, url: url, tabID: tab.id), titles: [])
            }
            candidates[url]?.titles.append(tab.displayTitle)
        }
        if !isPrivate {
            for bookmark in bookmarks {
                if candidates[bookmark.url] == nil {
                    candidates[bookmark.url] = Candidate(suggestion: BrowserSuggestion(title: bookmark.title, url: bookmark.url), titles: [])
                }
                candidates[bookmark.url]?.titles.append(bookmark.title)
                candidates[bookmark.url]?.bookmarked = true
            }
            for entry in history {
                if candidates[entry.url] == nil {
                    candidates[entry.url] = Candidate(suggestion: BrowserSuggestion(title: entry.title, url: entry.url), titles: [])
                }
                candidates[entry.url]?.titles.append(entry.title)
                let latestVisit = max(candidates[entry.url]!.visitedAt, entry.visitedAt)
                candidates[entry.url]?.visitedAt = latestVisit
            }
        }
        let hostQuery = query.hasPrefix("www.") ? String(query.dropFirst(4)) : query
        func tier(_ candidate: Candidate) -> Int? {
            let url = candidate.suggestion.url
            var host = url.host?.lowercased() ?? ""
            if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
            let hostPrefix = !hostQuery.isEmpty && (host.hasPrefix(hostQuery) || host.split(separator: ".").contains { $0.hasPrefix(hostQuery) })
            let titlePrefix = candidate.titles.contains { title in
                title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(query) }
            }
            if candidate.suggestion.tabID != nil && (hostPrefix || titlePrefix || url.absoluteString.lowercased().hasPrefix(query)) { return 0 }
            if hostPrefix { return 1 }
            if titlePrefix { return 2 }
            if url.absoluteString.lowercased().contains(query) || candidate.titles.contains(where: { $0.lowercased().contains(query) }) { return 3 }
            return nil
        }
        return candidates.values.compactMap { candidate in tier(candidate).map { (candidate, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.bookmarked != rhs.0.bookmarked { return lhs.0.bookmarked }
                if lhs.0.visitedAt != rhs.0.visitedAt { return lhs.0.visitedAt > rhs.0.visitedAt }
                return lhs.0.suggestion.url.absoluteString < rhs.0.suggestion.url.absoluteString
            }.prefix(5).map { $0.0.suggestion }
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
        return BrowserSnapshot(tabs: records, selectedTabID: selected, bookmarks: bookmarks, history: history, legacyBookmarksImported: legacyBookmarksImported, appliedOpenRequests: appliedOpenRequests)
    }

    public func saveNow(discardPrevious: Bool = false) {
        saveTask?.cancel()
        guard canPersist, !isShutDown else { return }
        do {
            let snapshot = snapshot()
            let data = try SessionFileStore.encodedSnapshot(snapshot)
            // A privacy deletion must still reach the store to discard an older backup.
            guard discardPrevious || data != lastSavedData else { return }
            let wrote = try store?.save(snapshot, discardPrevious: discardPrevious) ?? false
            if store != nil { lastSavedData = data }
            if wrote { onContinuityChange?() }
        }
        catch { persistenceNotice = "Your session could not be saved: \(error.localizedDescription)" }
    }

    /// Save the receipt atomically with the new regular tab, before activating its WebView.
    /// If the replica tombstone write fails, recovery observes this receipt and never opens a duplicate,
    /// even if the user has since closed the delivered tab or disabled session restoration.
    @discardableResult public func applyOpenRequest(_ request: ContinuityOpenRequest) throws -> Bool {
        _ = try request.validated()
        guard canPersist, !isExternalPrivate else { throw ContinuityError.invalidData }
        guard !appliedOpenRequests.contains(request.id) else { return false }
        let previousSelection = selectedTabID
        // Request bodies are untrusted. Even a request UUID colliding with an existing tab
        // must append a distinct tab, never create duplicate identities or replace that page.
        let tabID = tabs.contains { $0.id == request.id } ? UUID() : request.id
        let tab = makeTab(record: TabRecord(id: tabID, title: request.title, url: request.url))
        tabs.append(tab); appliedOpenRequests.insert(request.id); selectedTabID = tab.id
        do {
            let snapshot = snapshot()
            try store?.save(snapshot, discardPrevious: false)
            if store != nil { lastSavedData = try SessionFileStore.encodedSnapshot(snapshot) }
        } catch {
            tabs.removeAll { $0 === tab }; appliedOpenRequests.remove(request.id); selectedTabID = previousSelection
            tab.close(); throw error
        }
        if isProfileActive { tab.activate() }
        return true
    }

    /// Never replaces local tabs, website state or edited forms when receiving cloud changes.
    public func applyContinuity(bookmarks: [Bookmark], history: [HistoryEntry]) throws {
        guard canPersist else { throw ContinuityError.invalidData }
        guard self.bookmarks != bookmarks || self.history != history else { return }
        let oldBookmarks = self.bookmarks, oldHistory = self.history
        self.bookmarks = bookmarks; self.history = history
        do {
            let snapshot = snapshot()
            let data = try SessionFileStore.encodedSnapshot(snapshot)
            try store?.save(snapshot, discardPrevious: true)
            if store != nil { lastSavedData = data }
        }
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
        let isPrivate = isPrivate || isExternalPrivate
        if isPrivate && privateDataStore == nil { privateDataStore = .nonPersistent() }
        if isExternalPrivate { configuration?.websiteDataStore = privateDataStore! }
        let tab = BrowserTab(record: record, isPrivate: isPrivate, configuration: configuration,
                             dataStore: isPrivate ? privateDataStore! : regularDataStore, adBlocker: adBlocker, settings: settings)
        tab.setProfileActive(isProfileActive)
        tab.onChange = { [weak self, weak tab] in
            guard tab?.isPrivate == false else { return }
            self?.scheduleSave()
        }
        tab.onTitleChange = { [weak self, weak tab] url, title in
            guard let self, tab?.isPrivate == false, self.history.first?.url == url,
                  self.history[0].title != title else { return }
            // A title correction is the same visit: retain its UUID and recency.
            self.history[0].title = title
            self.scheduleSave()
        }
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
