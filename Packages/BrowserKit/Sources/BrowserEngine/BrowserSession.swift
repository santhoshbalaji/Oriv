import BrowserCore
import Foundation
import Observation
import WebKit

@MainActor @Observable
public final class BrowserSession {
    public let isExternalPrivate: Bool
    public let adBlocker: AdBlocker
    public let siteIcons: SiteIconStore
    public let settings: BrowserSettings
    public let websiteData: WebsiteDataManager
    public let tabSnapshots = TabSnapshotCache()
    public static let recentLiveTabCount = 3
    public private(set) var tabs: [BrowserTab] = []
    public private(set) var selectedTabID: UUID? { didSet { updateTabSelection() } }
    public private(set) var bookmarks: [Bookmark] = [] { didSet { suggestionRevision += 1 } }
    public private(set) var historyRevision = 0
    public var historyCount: Int { _ = historyRevision; return (try? historyStore?.count) ?? 0 }
    public var history: [HistoryEntry] { historyPage(limit: VisitHistoryStore.maximumVisits) }
    public func historyPage(search: String = "", offset: Int = 0, limit: Int = 100) -> [HistoryEntry] {
        _ = historyRevision
        return (try? historyStore?.page(search: search, offset: offset, limit: limit)) ?? []
    }
    public func recentHistory(excluding urls: Set<URL>, limit: Int = 5) -> [HistoryEntry] {
        _ = historyRevision
        let recent = (try? historyStore?.recentDistinct(limit: limit + urls.count)) ?? []
        return Array(recent.lazy.filter { !urls.contains($0.url) }.prefix(limit))
    }
    public func frequentHistory(excluding urls: Set<URL>, isPrivate: Bool) async -> [HistoryEntry] {
        guard !isPrivate, !isExternalPrivate, let historyStore else { return [] }
        let revision = historyRevision
        let limit = 6
        // Over-fetch so that several pages of one site still leave six distinct sites.
        let ranked = await Task.detached(priority: .utility) {
            (try? historyStore.frequentDestinations(limit: limit * 10 + urls.count)) ?? []
        }.value
        guard !Task.isCancelled, !isShutDown, revision == historyRevision else { return [] }
        // One tile per site: the most visited page of each host wins.
        var seenSites = Set<String>(), tiles: [HistoryEntry] = []
        for entry in ranked where tiles.count < limit && !urls.contains(entry.url) {
            if seenSites.insert(Self.siteKey(entry.url)).inserted { tiles.append(entry) }
        }
        return tiles
    }
    nonisolated static func siteKey(_ url: URL) -> String {
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
    public private(set) var persistenceNotice: String?
    public private(set) var canPersist = true
    public private(set) var isProfileActive = true
    public var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
    public var canReopenTab: Bool { !recentlyClosed.isEmpty }
    public var canUndoBookmarkRemoval: Bool { removedBookmark != nil }
    private var removedBookmark: (bookmark: Bookmark, index: Int)?
    public var orderedTabs: [BrowserTab] { [false, true].flatMap { mode in
        tabs.filter { $0.isPrivate == mode && $0.isPinned } + tabs.filter { $0.isPrivate == mode && !$0.isPinned }
    } }
    /// Newest first, memory only. Private tabs never enter this list.
    public var recentlyClosedTabs: [TabRecord] { recentlyClosed.reversed() }
    public var tabsInSelectedMode: [BrowserTab] {
        guard let selectedTab else { return [] }
        return orderedTabs.filter { $0.isPrivate == selectedTab.isPrivate }
    }

    @ObservationIgnored public var configureWebView: ((WKWebView, BrowserTab) -> Void)?
    @ObservationIgnored public var handleDownload: ((WKDownload) -> Void)?
    @ObservationIgnored public var handleExternalURL: ((URL) -> Void)?
    @ObservationIgnored public var shouldSelectTab: ((BrowserTab) -> Bool)?
    @ObservationIgnored public var didSelectTab: ((BrowserTab) -> Void)?
    @ObservationIgnored public var didCloseTab: ((UUID) -> Void)?
    @ObservationIgnored var onContinuitySnapshotChange: (() -> Void)?
    @ObservationIgnored public var onContinuityChange: (() -> Void)?
    @ObservationIgnored public var onContinuityHistoryRemoved: ((UUID) -> Void)?
    @ObservationIgnored public var onContinuityHistoryCleared: ((Date) -> Void)?
    @ObservationIgnored private let store: (any BrowserSessionStore)?
    @ObservationIgnored private var lastQueuedSnapshot: BrowserSnapshot?
    @ObservationIgnored private var lastSavedSnapshot: BrowserSnapshot?
    @ObservationIgnored private let writer: OrderedSessionWriter?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let suggestionIndex = AddressSuggestionIndex()
    @ObservationIgnored private var historyStore: VisitHistoryStore?
    @ObservationIgnored private let recordsQAFixtureHistory: Bool
    @ObservationIgnored private var sharedHistory: [HistoryEntry] = []
    @ObservationIgnored private var appliedHistoryRemovals = Set<UUID>()
    @ObservationIgnored private var appliedHistoryClears = Set<ClosedRange<Date>>()
    private var suggestionRevision = 0
    private var legacyBookmarksImported = false
    private var importingLegacyBookmarks = false
    private var isShutDown = false
    private var appliedOpenRequests: Set<UUID> = []
    private var recentlyClosed: [TabRecord] = []
    @ObservationIgnored private let regularDataStore: WKWebsiteDataStore
    @ObservationIgnored private var privateDataStore: WKWebsiteDataStore?
    #if os(macOS)
    @ObservationIgnored private(set) var tabReclamationMonitor: TabReclamationMonitor?
    @ObservationIgnored private var tabReclamationTask: Task<Void, Never>?
    @ObservationIgnored private var isReclaimingTabs = false
    #endif

    public init(store: (any BrowserSessionStore)? = nil, dataStore: WKWebsiteDataStore = .default(),
                adBlocker: AdBlocker = AdBlocker(), settings: BrowserSettings = BrowserSettings(), externalPrivate: Bool = false, faviconDirectory: URL? = nil,
                recordsQAFixtureHistory: Bool = false) {
        siteIcons = SiteIconStore(directory: externalPrivate ? nil : faviconDirectory)
        isExternalPrivate = externalPrivate
        self.recordsQAFixtureHistory = recordsQAFixtureHistory
        self.store = externalPrivate ? nil : store
        writer = externalPrivate ? nil : store.map { OrderedSessionWriter(store: $0) }
        self.adBlocker = adBlocker
        self.settings = settings
        websiteData = WebsiteDataManager(store: dataStore)
        regularDataStore = dataStore
        if !externalPrivate {
            do {
                let result = try store?.load()
                let fileURL = (store as? SessionFileStore)?.fileURL.deletingLastPathComponent().appendingPathComponent("history.sqlite")
                let historyStore = try VisitHistoryStore(fileURL: fileURL)
                self.historyStore = historyStore
                if let snapshot = result?.snapshot {
                    lastSavedSnapshot = snapshot; lastQueuedSnapshot = snapshot
                    legacyBookmarksImported = snapshot.legacyBookmarksImported == true
                    appliedOpenRequests = snapshot.appliedOpenRequests ?? []
                    bookmarks = snapshot.bookmarks
                    tabs = (settings.restoreTabs ? snapshot.tabs : snapshot.tabs.filter(\.isPinned)).map { makeTab(record: $0) }
                    selectedTabID = snapshot.selectedTabID
                    if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs.first?.id }
                }
                try historyStore.migrate((result?.snapshot?.history ?? []).filter { historyAllows($0.url) })
                refreshSharedHistory()
                if result?.recoveredFromBackup == true { persistenceNotice = "Your last valid session was recovered from a backup." }
                // Also scrub a legacy backup left after an interrupted migration.
                let legacyBackup = (store as? SessionFileStore).map {
                    FileManager.default.fileExists(atPath: $0.backupURL.path)
                        && ((try? SessionFileStore(fileURL: $0.backupURL).load().snapshot?.history.isEmpty) == false)
                } ?? false
                if let snapshot = result?.snapshot, !snapshot.history.isEmpty || legacyBackup {
                    var clean = snapshot
                    clean.history = []
                    try writer?.saveAndWait(clean, discardPrevious: true)
                    lastSavedSnapshot = clean; lastQueuedSnapshot = clean
                }
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
        adBlocker.privacy = settings.privacy
        adBlocker.cookieBannersEnabled = settings.privacy.isEnabled(.cookieBanners)
        settings.privacy.onChange = { [weak self] in
            guard let self else { return }
            self.adBlocker.cookieBannersEnabled = self.settings.privacy.isEnabled(.cookieBanners)
            self.tabs.forEach { $0.refreshContentBlocking() }
        }
        adBlocker.onChange = { [weak self] in self?.tabs.forEach { $0.refreshContentBlocking() } }
        settings.onRulesChanged = { [weak self] in self?.tabs.forEach { $0.applySiteSettings() } }
        siteIcons.document = { [weak self] url, isPrivate in
            guard let self, self.isProfileActive, !self.isShutDown else { return nil }
            return self.tabs.first { $0.isPrivate == isPrivate && $0.isInstantiated && !$0.isLoading
                && !$0.isRestoringWebView && $0.hasRenderedContent && $0.switchPresentation == nil
                && $0.url.flatMap { SiteIconStore.key($0, isPrivate: isPrivate) } == SiteIconStore.key(url, isPrivate: isPrivate) }?.webView
        }
        updateTabSelection()
        #if os(macOS)
        do {
            tabReclamationMonitor = TabReclamationMonitor { [weak self] pressure in
                guard let self, !self.isShutDown else { return }
                if pressure { self.tabSnapshots.removeAll() }
                guard self.tabReclamationTask == nil else { return }
                self.tabReclamationTask = Task { @MainActor [weak self] in
                    _ = await self?.reclaimBackgroundTabs(underMemoryPressure: pressure)
                    self?.tabReclamationTask = nil
                }
            }
        }
        #endif
    }

    private func updateTabSelection() { tabs.forEach { $0.setSelected($0.id == selectedTabID) } }

    public func activateSelectedTab() {
        if let selectedTab {
            if !selectedTab.isPrivate, let historyStore {
                let index = suggestionIndex
                Task(priority: .utility) { await index.refreshHistory(from: historyStore) }
            }
            didSelectTab?(selectedTab)
            selectedTab.activate()
        }
    }

    public func setProfileActive(_ active: Bool) {
        if !active { saveNow(); flushPersistence() }
        isProfileActive = active
        tabs.forEach { $0.setProfileActive(active) }
    }
    public func shutdown() {
        saveNow(); flushPersistence()
        onContinuitySnapshotChange = nil; onContinuityChange = nil; onContinuityHistoryRemoved = nil; onContinuityHistoryCleared = nil
        siteIcons.shutdown()
        isShutDown = true
        #if os(macOS)
        tabReclamationMonitor?.stop(); tabReclamationMonitor = nil
        tabReclamationTask?.cancel(); tabReclamationTask = nil
        #endif
        tabs.forEach { $0.close() }
        if isExternalPrivate {
            tabs.removeAll()
            selectedTabID = nil
        }
        privateDataStore = nil
        adBlocker.endPrivateSession()
        settings.endPrivateSession()
        tabSnapshots.removeAll()
        saveTask?.cancel()
        configureWebView = nil; handleDownload = nil; handleExternalURL = nil; didCloseTab = nil; shouldSelectTab = nil; didSelectTab = nil
    }

    #if os(macOS)
    /// Reclaim oldest eligible views first. WebKit state stays in RAM and never
    /// enters session persistence or continuity. Each IPC request is bounded.
    @discardableResult public func reclaimBackgroundTabs(underMemoryPressure: Bool = false) async -> Int {
        if underMemoryPressure { tabSnapshots.removeAll() }
        guard !isShutDown, !isReclaimingTabs else { return 0 }
        isReclaimingTabs = true
        defer { isReclaimingTabs = false }
        let minimumIdle = underMemoryPressure ? TabDiscardPolicy.recentUseInterval : TabDiscardPolicy.idleInterval
        let candidates = tabs.filter(\.isInstantiated).sorted { $0.lastSelectedTime < $1.lastSelectedTime }
        var reclaimed = 0
        for tab in candidates {
            guard !isShutDown, !Task.isCancelled else { break }
            // Recompute after each IPC: selection may have changed while the
            // previous candidate was being checked. Pressure may use the reserve.
            if !underMemoryPressure && recentLiveTabIDs.contains(tab.id) { continue }
            guard TabDiscardPolicy.isOldEnough(lastUsed: tab.lastSelectedTime, now: tab.recoveryClock(), underMemoryPressure: underMemoryPressure) else { continue }
            let discarded = await withCheckedContinuation { continuation in
                tab.discardBackgroundWebView(minimumIdle: minimumIdle) { continuation.resume(returning: $0) }
            }
            if discarded { reclaimed += 1 }
        }
        return reclaimed
    }
    #endif

    public var recentLiveTabIDs: Set<UUID> {
        Set(tabs.filter(\.isInstantiated).sorted { $0.lastSelectedTime > $1.lastSelectedTime }
            .prefix(Self.recentLiveTabCount).map(\.id))
    }

    @discardableResult public func addTab(url: URL? = nil, isPrivate: Bool = false,
                                          configuration: WKWebViewConfiguration? = nil,
                                          select: Bool = true, load: Bool = true) -> BrowserTab {
        insertTab(url: url, isPrivate: isPrivate, configuration: configuration, dataStore: nil, select: select, load: load)
    }

    /// Use WebKit's related configuration and the opener's store, including
    /// when the preference changed after the opener was created.
    public func openPopup(from opener: BrowserTab, url: URL?, configuration: WKWebViewConfiguration) -> WKWebView? {
        guard !isShutDown, isProfileActive, tabs.contains(where: { $0 === opener }),
              let dataStore = opener.websiteDataStore else { return nil }
        return insertTab(url: url, isPrivate: opener.isPrivate, configuration: configuration,
                         dataStore: dataStore, select: true, load: false).webView
    }

    private func insertTab(url: URL?, isPrivate: Bool, configuration: WKWebViewConfiguration?,
                           dataStore: WKWebsiteDataStore?, select: Bool, load: Bool) -> BrowserTab {
        let tab = makeTab(record: TabRecord(title: url?.host ?? "New tab", url: url),
                          isPrivate: isPrivate, configuration: configuration, openerStore: dataStore)
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

    /// The phone capsule has hard boundaries, unlike the Mac keyboard cycler.
    public func tabSwipeTarget(_ direction: Int) -> TabSwipeTarget {
        let peers = tabsInSelectedMode
        guard abs(direction) == 1, let current = peers.firstIndex(where: { $0.id == selectedTabID }) else { return .boundary }
        let next = current + direction
        if peers.indices.contains(next) { return .tab(peers[next].id) }
        return next == peers.count ? .newTab : .boundary
    }

    public func commitTabSwipe(_ direction: Int, from source: UUID) {
        guard isProfileActive, selectedTabID == source, let selectedTab else { return }
        switch tabSwipeTarget(direction) {
        case .tab(let id): selectTab(id)
        case .newTab: addTab(isPrivate: selectedTab.isPrivate)
        case .boundary: break
        }
    }

    public func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if !tab.isPrivate { recentlyClosed.append(tab.record); recentlyClosed = Array(recentlyClosed.suffix(20)) }
        tab.close()
        tabs.remove(at: index)
        didCloseTab?(id)
        if let privateDataStore, !tabs.contains(where: { $0.isPrivate && $0.websiteDataStore === privateDataStore }) {
            self.privateDataStore = nil
        }
        if !tabs.contains(where: \.isPrivate) {
            siteIcons.endPrivateSession()
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
        guard let tab = tabs.first(where: { $0.id == id }), !tab.isPrivate else { return }
        tab.setPinned(!tab.isPinned); scheduleSave()
    }
    /// An explicit drop on a section heading changes pin state, then appends to
    /// that section. Row drops continue to preserve pin and privacy boundaries.
    public func moveTab(_ id: UUID, intoPinnedSection pinned: Bool) {
        guard let tab = tabs.first(where: { $0.id == id }), !tab.isPrivate else { return }
        tab.setPinned(pinned)
        let peers = orderedTabs.filter { !$0.isPrivate && $0.isPinned == pinned }
        if let position = peers.firstIndex(where: { $0.id == id }) { moveTab(id, offset: peers.count - position - 1) }
        scheduleSave()
    }
    public func moveTab(_ id: UUID, offset: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[source]
        var peers = tabs.filter { $0.isPrivate == tab.isPrivate && $0.isPinned == tab.isPinned }
        guard let position = peers.firstIndex(where: { $0.id == id }), peers.indices.contains(position + offset) else { return }
        peers.insert(peers.remove(at: position), at: position + offset)
        var next = peers.makeIterator()
        tabs = tabs.map { $0.isPrivate == tab.isPrivate && $0.isPinned == tab.isPinned ? next.next()! : $0 }
        scheduleSave()
    }
    /// A drag cannot move a tab across pin or privacy sections.
    public func moveTab(_ id: UUID, to target: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }),
              let destination = tabs.first(where: { $0.id == target }),
              tab.isPrivate == destination.isPrivate, tab.isPinned == destination.isPinned else { return }
        let peers = orderedTabs.filter { $0.isPrivate == tab.isPrivate && $0.isPinned == tab.isPinned }
        guard let source = peers.firstIndex(where: { $0.id == id }), let end = peers.firstIndex(where: { $0.id == target }) else { return }
        moveTab(id, offset: end - source)
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
        guard let id = recentlyClosed.last?.id else { return }
        reopenClosedTab(id)
    }
    public func reopenClosedTab(_ id: UUID) {
        guard let index = recentlyClosed.lastIndex(where: { $0.id == id }) else { return }
        var record = recentlyClosed.remove(at: index)
        record.id = UUID()
        let tab = makeTab(record: record)
        tabs.append(tab)
        selectTab(tab.id)
    }

    public func navigate(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = settings.searchEngine
        let url = try AddressResolver.resolve(text, searchEngine: engine)
        if selectedTab == nil { addTab() }
        if AddressResolver.isDataURL(url) { selectedTab?.navigateToUserDataURL(url) }
        else { selectedTab?.navigate(to: url, typed: url != engine.searchURL(text)) }
    }

    /// Saved links reuse an empty regular tab; they never replace a private page or edited document.
    public func openSavedPage(_ url: URL, inNewTab: Bool = false) {
        guard AddressResolver.isBookmarkURL(url) else { return }
        let emptyTab = !inNewTab && selectedTab?.url == nil && selectedTab?.isPrivate == false ? selectedTab : nil
        if AddressResolver.isDataURL(url) {
            (emptyTab ?? addTab()).navigateToUserDataURL(url)
        } else if let emptyTab {
            emptyTab.navigate(to: url)
        } else { addTab(url: url) }
    }

    public func requiresCloseConfirmation(_ id: UUID) -> Bool {
        tabs.first { $0.id == id }?.hasEditedFields == true
    }

    /// Compatibility snapshot for noninteractive callers. Address editors use
    /// indexedSuggestions so normalization/matching never runs on the main actor.
    public func suggestions(for query: String, isPrivate: Bool) -> [BrowserSuggestion] {
        var index = LocalSuggestionIndex()
        if !isPrivate { index.update(history: history, bookmarks: bookmarks) }
        return index.matches(query, tabs: suggestionTabs(isPrivate: isPrivate), limit: 5)
    }
    private func suggestionTabs(isPrivate: Bool) -> [BrowserSuggestion] {
        tabs.filter { $0.isPrivate == isPrivate }.compactMap { tab in
            guard let url = tab.url, AddressResolver.isWebURL(url) else { return nil }
            return BrowserSuggestion(title: tab.displayTitle, url: url, tabID: tab.id)
        }
    }
    public func indexedSuggestions(for query: String, isPrivate: Bool) async -> [BrowserSuggestion] {
        await suggestionIndex.matches(query, store: isPrivate ? nil : historyStore, bookmarks: isPrivate ? [] : bookmarks,
            revision: suggestionRevision, tabs: suggestionTabs(isPrivate: isPrivate), isPrivate: isPrivate)
    }

    public func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    public func toggleBookmark() {
        guard let tab = selectedTab, !tab.isPrivate, let url = tab.url, AddressResolver.isBookmarkURL(url) else { return }
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
        let incoming = entries.filter { AddressResolver.isBookmarkURL($0.url) && urls.insert($0.url).inserted && ids.insert($0.id).inserted }
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
    public func clearHistory(since date: Date = .distantPast) {
        guard let historyStore else { return }
        do {
            try historyStore.clear(since: date)
            let index = suggestionIndex
            Task(priority: .utility) { await index.refreshHistory(from: historyStore) }
            tabs.forEach { $0.cancelPendingHistory() }
            refreshSharedHistory()
            historyRevision += 1
            recentlyClosed = []
            onContinuityHistoryCleared?(date)
            Task { await siteIcons.clearRegular() }
            saveNow(discardPrevious: true)
        } catch { persistenceNotice = error.localizedDescription }
    }
    public func removeHistory(_ id: UUID) {
        do {
            try historyStore?.remove(id)
            refreshSharedHistory()
            historyRevision += 1
            onContinuityHistoryRemoved?(id)
            saveNow(discardPrevious: true)
        } catch { persistenceNotice = error.localizedDescription }
    }
    public func dismissNotice() { if canPersist { persistenceNotice = nil } }

    public func snapshot() -> BrowserSnapshot {
        let records = tabs.filter { !$0.isPrivate }.map(\.record)
        let selected = records.contains { $0.id == selectedTabID } ? selectedTabID : records.first?.id
        return BrowserSnapshot(tabs: records, selectedTabID: selected, bookmarks: bookmarks, legacyBookmarksImported: legacyBookmarksImported, appliedOpenRequests: appliedOpenRequests)
    }

    func continuitySnapshot() -> BrowserSnapshot {
        var snapshot = snapshot()
        snapshot.history = sharedHistory
        return snapshot
    }

    private func refreshSharedHistory() {
        if let entries = try? historyStore?.sharedHistory() {
            sharedHistory = entries.map {
                var entry = $0
                entry.typedCount = 0
                return entry
            }
        }
    }

    private func historyAllows(_ url: URL) -> Bool {
        guard AddressResolver.isWebURL(url) else { return false }
        let fixture = [8768, 18768].contains(url.port ?? 0) && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "")
        return recordsQAFixtureHistory || !fixture
    }

    public func saveNow(discardPrevious: Bool = false) {
        saveTask?.cancel()
        completeWrites()
        guard canPersist, !isShutDown else { return }
        let snapshot = snapshot()
        onContinuitySnapshotChange?()
        guard let writer, discardPrevious || snapshot != lastQueuedSnapshot else { return }
        if discardPrevious {
            // Privacy erasure is a durability boundary, including deletion of a prior backup.
            do {
                try writer.saveAndWait(snapshot, discardPrevious: true)
                completeWrites()
                let changed = snapshot != lastSavedSnapshot
                lastQueuedSnapshot = snapshot; lastSavedSnapshot = snapshot
                if changed { onContinuityChange?() }
            } catch { lastQueuedSnapshot = nil; persistenceNotice = "Your session could not be saved: \(error.localizedDescription)" }
        } else {
            lastQueuedSnapshot = snapshot
            writer.enqueue(snapshot) { [weak self] in Task { @MainActor in self?.completeWrites() } }
        }
    }

    private func completeWrites() {
        for completion in writer?.takeCompletions() ?? [] {
            switch completion.result {
            case .success(let wrote):
                lastSavedSnapshot = completion.snapshot
                if wrote { onContinuityChange?() }
            case .failure(let error):
                if lastQueuedSnapshot == completion.snapshot { lastQueuedSnapshot = nil }
                persistenceNotice = "Your session could not be saved: \(error.localizedDescription)"
            }
        }
    }
    public func flushPersistence() {
        do { try writer?.flush() }
        catch { lastQueuedSnapshot = nil; persistenceNotice = "Your session could not be saved: \(error.localizedDescription)" }
        completeWrites()
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
            try writer?.saveAndWait(snapshot)
            if store != nil { completeWrites(); lastSavedSnapshot = snapshot; lastQueuedSnapshot = snapshot }
        } catch {
            tabs.removeAll { $0 === tab }; appliedOpenRequests.remove(request.id); selectedTabID = previousSelection
            tab.close(); throw error
        }
        if isProfileActive { tab.activate() }
        return true
    }

    /// Never replaces local tabs, website state or edited forms when receiving cloud changes.
    public func applyContinuity(bookmarks: [Bookmark], history: [HistoryEntry],
                                removedIDs: Set<UUID> = [],
                                clearRanges: [ClosedRange<Date>] = []) throws {
        guard canPersist, let historyStore else { throw ContinuityError.invalidData }
        // Data bookmarks are local documents and are outside the continuity URL policy.
        let bookmarks = bookmarks + self.bookmarks.filter { AddressResolver.isDataURL($0.url) }
        let history = history.filter { historyAllows($0.url) }
        let removedIDs = removedIDs.subtracting(appliedHistoryRemovals)
        let clearRanges = Set(clearRanges).subtracting(appliedHistoryClears)
        guard self.bookmarks != bookmarks || sharedHistory != history || !removedIDs.isEmpty || !clearRanges.isEmpty else { return }
        let oldBookmarks = self.bookmarks
        self.bookmarks = bookmarks
        let current = snapshot()
        do {
            try historyStore.applyShared(history, removedIDs: removedIDs, clearRanges: Array(clearRanges)) {
                try writer?.saveAndWait(current, discardPrevious: true)
            }
            appliedHistoryRemovals.formUnion(removedIDs)
            appliedHistoryClears.formUnion(clearRanges)
            if !clearRanges.isEmpty {
                tabs.forEach { $0.cancelPendingHistory() }
                Task { await siteIcons.clearRegular() }
            }
            refreshSharedHistory()
            historyRevision += 1
            if store != nil { completeWrites(); lastSavedSnapshot = current; lastQueuedSnapshot = current }
        } catch { self.bookmarks = oldBookmarks; throw error }
    }

    private func scheduleSave() {
        onContinuitySnapshotChange?()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveNow()
        }
    }

    private func makeTab(record: TabRecord = TabRecord(), isPrivate: Bool = false,
                         configuration: WKWebViewConfiguration? = nil, openerStore: WKWebsiteDataStore? = nil) -> BrowserTab {
        let isPrivate = isPrivate || isExternalPrivate
        let dataStore: WKWebsiteDataStore
        if let openerStore { dataStore = openerStore }
        else if !isPrivate { dataStore = regularDataStore }
        else if settings.privateTabIsolation.isEnabled { dataStore = .nonPersistent() }
        else {
            let shared = privateDataStore ?? .nonPersistent()
            privateDataStore = shared
            dataStore = shared
        }
        configuration?.websiteDataStore = dataStore
        let tab = BrowserTab(record: record, isPrivate: isPrivate, configuration: configuration,
                             dataStore: dataStore, adBlocker: adBlocker, settings: settings)
        tab.snapshotCache = tabSnapshots
        tab.setProfileActive(isProfileActive)
        tab.onChange = { [weak self, weak tab] in
            guard tab?.isPrivate == false else { return }
            self?.scheduleSave()
        }
        #if os(macOS) && ORIV_BENCH
        let recordVisits = !isPrivate && !BenchmarkOptions.disabled.contains("history")
        #else
        let recordVisits = !isPrivate
        #endif
        if recordVisits {
            tab.recordHistoryVisit = { [weak self] entry, shared in
                guard let self, !self.isShutDown, self.historyAllows(entry.url),
                      let historyStore = self.historyStore else { return }
                do {
                    try historyStore.record(entry, shared: shared)
                    self.historyRevision += 1
                    if shared {
                        self.refreshSharedHistory()
                        self.onContinuitySnapshotChange?()
                    }
                } catch { self.persistenceNotice = error.localizedDescription }
            }
            tab.discardHistoryVisit = { [weak self] id in self?.removeHistory(id) }
            tab.correctHistoryTitle = { [weak self] id, url, title in
                guard let self, !self.isShutDown, let historyStore = self.historyStore else { return }
                do {
                    guard try historyStore.updateTitle(id: id, url: url, title: title) else { return }
                    self.historyRevision += 1
                    if self.sharedHistory.contains(where: { $0.id == id }) {
                        self.refreshSharedHistory()
                        self.onContinuitySnapshotChange?()
                    }
                } catch { self.persistenceNotice = error.localizedDescription }
            }
        }
        tab.onDocumentReady = { [weak self, weak tab] url in
            Task { @MainActor [weak self, weak tab] in
                guard let self, !self.isShutDown, self.isProfileActive, let tab else { return }
                await self.siteIcons.load(url, isPrivate: tab.isPrivate)
            }
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

public enum TabSwipeTarget: Equatable, Sendable {
    case tab(UUID), newTab, boundary
}
