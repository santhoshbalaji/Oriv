import AppKit
import BrowserCore
import BrowserEngine
import Observation
import WebKit

@MainActor @Observable
final class BrowserController {
    let profile: BrowserProfile?
    @ObservationIgnored private let profileDefaults: UserDefaults?
    var appearance: BrowserAppearance { didSet { profileDefaults?.set(appearance.rawValue, forKey: "browserAppearance") } }
    let session: BrowserSession
    let downloads = DownloadManager()
    let sidebar = SidebarPresentation()
    let sidebarTooltip = SidebarTooltip()
    var compactSidebar: Bool {
        get { sidebar.preferredRail }
        set {
            let changed = sidebar.preferredRail != newValue
            sidebar.setPreference(newValue)
            if changed { profileDefaults?.set(newValue, forKey: "compactSidebar") }
        }
    }
    var hoverSidebar: Bool {
        get { sidebar.hoverEnabled }
        set {
            guard sidebar.hoverEnabled != newValue else { return }
            sidebar.hoverEnabled = newValue
            profileDefaults?.set(newValue, forKey: "hoverSidebar")
        }
    }
    var sidebarToggleRequest = 0
    @ObservationIgnored weak var sidebarWindow: NSWindow?
    @ObservationIgnored weak var tabSearchReturnFocus: NSResponder?
    var tabSearchPanel = false
    var tabSearch = ""
    var tabSearchFocusRequest = 0
    let sidebarDragID = UUID()
    func searchTabs() {
        sidebarTooltip.dismiss()
        if sidebar.reservesRail {
            if !tabSearchPanel {
                let responder = sidebarWindow?.firstResponder
                tabSearchReturnFocus = (responder as? NSTextView)?.delegate as? NSView ?? responder
            }
            tabSearchPanel = true; sidebar.searchOpen = true
        }
        tabSearchFocusRequest += 1
    }
    func dismissTabSearch() { tabSearchPanel = false; tabSearch = ""; sidebar.searchOpen = false }
    func toggleSidebar() {
        let previous = compactSidebar
        let next = sidebar.toggle()
        if previous != next { profileDefaults?.set(next, forKey: "compactSidebar") }
        sidebarTooltip.dismiss(); dismissTabSearch()
    }
    var addressFocusRequest = 0
    var findRequest = 0
    var findNextRequest = 0
    var findBackwards = false
    var passwordsGuideRequest = 0
    var library: LibrarySection?
    var addressError: String?
    var browserError: String?
    var browserNotice: String?
    var showWebsiteData = false
    var showClearBrowsingData = false
    var isExportingPage = false
    var readerCapture: PageCapture?
    var isPreparingReader = false
    @ObservationIgnored private var bookmarkMigration: Task<Void, Never>?
    @ObservationIgnored private var privacyMenus: [UUID: MacPrivacyLinkMenu] = [:]
    @ObservationIgnored private var adapters: [UUID: MacWebUIDelegate] = [:]

    init(profile: BrowserProfile? = .personal, rootDirectory: URL? = nil, testing: Bool? = nil, websiteStore: WKWebsiteDataStore? = nil) {
        self.profile = profile
        let isTesting = testing ?? (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["BROWSER_TESTING"] == "1")
        let root = rootDirectory ?? URL.applicationSupportDirectory.appendingPathComponent("PersonalBrowser", isDirectory: true)
        let applicationSupport = profile?.directory(in: root) ?? root
        let bundleID = Bundle.main.bundleIdentifier ?? "local.personalbrowser.mac"
        let defaults: UserDefaults? = isTesting || profile == nil ? nil : profile!.isPersonal ? .standard : UserDefaults(suiteName: profile!.defaultsName(bundleID: bundleID)!)
        profileDefaults = defaults
        sidebar.preferredRail = defaults?.bool(forKey: "compactSidebar") ?? false
        sidebar.hoverEnabled = defaults?.bool(forKey: "hoverSidebar") ?? false
        appearance = defaults?.string(forKey: "browserAppearance").flatMap(BrowserAppearance.init(rawValue:)) ?? .t3Code
        let persistent = profile != nil && (!isTesting || rootDirectory != nil)
        session = BrowserSession(store: persistent ? SessionFileStore(fileURL: applicationSupport.appendingPathComponent("session.json")) : nil,
                                 dataStore: websiteStore ?? (isTesting || profile == nil ? .nonPersistent() : profile!.isPersonal ? .default() : WKWebsiteDataStore(forIdentifier: profile!.id)),
                                 adBlocker: AdBlocker(defaults: defaults), settings: BrowserSettings(defaults: defaults), externalPrivate: profile == nil,
                                 faviconDirectory: persistent ? applicationSupport.appendingPathComponent("Favicons", isDirectory: true) : nil)
        if persistent {
            bookmarkMigration = Task { [weak session] in
                await session?.importLegacyBookmarks(from: applicationSupport.appendingPathComponent("workspace.sqlite"))
            }
        }
        session.configureWebView = { [weak self] view, tab in
            #if DEBUG
            ChromeTiming.install(on: view)
            #endif
            PageChrome.install(on: view, isPrivate: tab.isPrivate)
            guard let self else { return }
            let adapter = MacWebUIDelegate(session: self.session, tab: tab)
            self.adapters[tab.id] = adapter
            view.uiDelegate = adapter
            self.privacyMenus.removeValue(forKey: tab.id)?.invalidate()
            self.privacyMenus[tab.id] = MacPrivacyLinkMenu(tab: tab, session: self.session, view: view)
            let id = tab.id
            tab.onWebViewDiscarded = { [weak self] in
                self?.adapters.removeValue(forKey: id)
                self?.privacyMenus.removeValue(forKey: id)?.invalidate()
            }
            tab.hasActiveDownloads = { [weak self, weak view] in
                guard let view else { return false }
                return self?.downloads.items.contains { $0.sourceView === view && (!$0.isFinished || $0.isPaused || $0.isCancelling) } == true
            }
            tab.onAuthentication = { [weak adapter] challenge, completion in
                guard let adapter else { completion(.cancelAuthenticationChallenge, nil); return }
                adapter.authenticate(challenge, completion: completion)
            }
        }
        session.didCloseTab = { [weak self] id in self?.adapters.removeValue(forKey: id); self?.privacyMenus.removeValue(forKey: id)?.invalidate() }
        session.handleDownload = { [weak self] download in
            guard let self, self.session.isProfileActive else { download.cancel { _ in }; return }
            self.downloads.begin(download)
        }
        session.handleExternalURL = { [weak self] url in
            guard self?.session.isProfileActive == true else { return }
            let alert = NSAlert()
            alert.messageText = "Open another application?"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    func shutdown() { sidebar.cancel(); sidebarTooltip.dismiss(); bookmarkMigration?.cancel(); session.shutdown(); downloads.shutdown() }

    var savedBookmarks: [Bookmark] { session.bookmarks }
    func saveCurrentPage() { session.toggleBookmark() }

    var continuitySource: ContinuitySource {
        ContinuitySource(session: session, preferences: { [weak self] in
            guard let self else { return [:] }
            return ContinuityPreferences.snapshot(session: self.session, appearance: self.appearance.rawValue)
        }, applyPreferences: { [weak self] values in
            guard let self else { return }
            ContinuityPreferences.apply(values, session: self.session) { value in
                if let appearance = BrowserAppearance(rawValue: value), self.appearance != appearance { self.appearance = appearance }
            }
        })
    }
    func newTab(isPrivate: Bool? = nil) { session.addTab(isPrivate: isPrivate ?? session.selectedTab?.isPrivate ?? session.isExternalPrivate); focusAddress() }
    func focusAddress() { addressFocusRequest += 1 }
    func closeTabOrPanel() {
        // A browser shortcut must never close a background tab while Settings is active.
        if session.isExternalPrivate {
            if library != nil { library = nil }
            else if let id = session.selectedTabID { requestCloseTab(id) }
            return
        }
        let window = NSApp.keyWindow
        if library != nil, window?.identifier?.rawValue == "browser" || window?.sheetParent?.identifier?.rawValue == "browser" {
            library = nil
        } else if let window, window.identifier?.rawValue != "browser" {
            window.performClose(nil)
            if window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
                BackgroundUIMode.showBrowserWindow(NSApp.windows.first(where: { $0.identifier?.rawValue == "browser" }))
            }
        } else if let id = session.selectedTabID {
            requestCloseTab(id)
        }
    }
    func requestCloseTab(_ id: UUID) {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return }
        if session.requiresCloseConfirmation(id) {
            let alert = NSAlert(); alert.messageText = "Close a page with edited fields?"
            alert.informativeText = "\(tab.displayTitle) contains fields you edited. Oriv cannot determine whether the website saved them."
            alert.addButton(withTitle: "Keep tab"); alert.addButton(withTitle: "Close tab")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        session.closeTab(id)
    }
    func openReader() {
        guard let tab = session.selectedTab, !isPreparingReader else { return }
        isPreparingReader = true
        Task {
            defer { isPreparingReader = false }
            do {
                let capture = try await PageCaptureService.readerText(tab)
                guard session.selectedTabID == tab.id else { return }
                guard !capture.text.isEmpty else { browserError = "No readable text was found on this page."; return }
                readerCapture = capture
            } catch { browserError = error.localizedDescription }
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
        session.suggestions(for: query, isPrivate: isPrivate)
    }
}

enum LibrarySection: String, Identifiable, CaseIterable {
    case bookmarks = "Bookmarks", history = "History", downloads = "Downloads", devices = "Other Devices"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .bookmarks: "bookmark"
        case .history: "clock.arrow.circlepath"
        case .downloads: "arrow.down.circle"
        case .devices: "laptopcomputer.and.iphone"
        }
    }
}
