import AppKit
import BrowserCore
import BrowserEngine
import Observation
import WebKit

@MainActor @Observable final class BrowserProfileUI {
    var address = ""
    let addressMatches = AddressSuggestions()
    var findText = ""
    var findCaseSensitive = false
    var showFind = false
    var showProtection = false
    var siteToForget: BrowserSite?
    var showPasswords = false
    var showSiteInfo = false
    var showTabs = false
    let pageChrome = PageChrome()
    var closeOthers: UUID?
    var closeToRight = false
    var settledQuery = ""

    func dismissPresentations() {
        showProtection = false
        siteToForget = nil
        showPasswords = false
        showSiteInfo = false
        showTabs = false
        closeOthers = nil
        closeToRight = false
    }
}

struct ProfileScoped<Value: Equatable>: Equatable {
    let owner: UUID
    let value: Value
}

@MainActor @Observable
final class BrowserController {
    let profile: BrowserProfile?
    @ObservationIgnored private let profileDefaults: UserDefaults?
    var appearance: BrowserAppearance { didSet { profileDefaults?.set(appearance.rawValue, forKey: "browserAppearance") } }
    private var storedSidebarColor: SidebarColor
    var sidebarColor: SidebarColor {
        get { storedSidebarColor }
        set {
            guard profile != nil, storedSidebarColor != newValue else { return }
            storedSidebarColor = newValue
            profileDefaults?.set(newValue.rawValue, forKey: SidebarColor.preferenceKey)
        }
    }

    func sidebarProfileColor(in profiles: BrowserProfiles?) -> ProfileColor? {
        guard let profile else { return nil }
        if let active = profiles?.active, active.id == profile.id { return active.color }
        return profile.color
    }

    let session: BrowserSession
    let downloads = DownloadManager()
    let sidebar = SidebarPresentation()
    let sidebarTooltip = SidebarTooltip()
    let profileUI = BrowserProfileUI()

    func scoped<Value: Equatable>(_ value: Value) -> ProfileScoped<Value> {
        ProfileScoped(owner: sidebarDragID, value: value)
    }

    func leaveProfile() {
        // Resign the old field editor while its bindings still target this profile.
        sidebarWindow?.makeFirstResponder(nil)
        sidebarWindow = nil
        sidebar.cancel()
        sidebarTooltip.dismiss()
        tabSearchReturnFocus = nil
        tabSearchPanel = false
        sidebar.searchOpen = false
        profileUI.dismissPresentations()
        profileUI.pageChrome.observe(nil)
    }
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
    private(set) var addressFocusRequestAtProfileSwitch: Int?
    var activeAddressFocusRequest: Int {
        addressFocusRequest == addressFocusRequestAtProfileSwitch ? 0 : addressFocusRequest
    }
    var findRequest = 0
    var findNextRequest = 0
    var findBackwards = false
    var passwordsGuideRequest = 0
    var passwordFillRequest = 0
    var canAutoFillPassword: Bool {
        guard let tab = session.selectedTab, tab.isInstantiated else { return false }
        return tab.passwordFields.kind?.supportsPasswordFill == true
    }
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

    init(profile: BrowserProfile? = .personal, rootDirectory: URL? = nil, testing: Bool? = nil, websiteStore: WKWebsiteDataStore? = nil,
         privateTabIsolation: PrivateTabIsolation? = nil) {
        self.profile = profile
        let factory = SessionFactory(profile: profile, rootOverride: rootDirectory,
            testing: testing ?? SessionFactory.isTesting,
            bundleID: Bundle.main.bundleIdentifier ?? "local.personalbrowser.mac", websiteStore: websiteStore,
            privateTabIsolation: privateTabIsolation)
        let defaults = factory.defaults
        profileDefaults = defaults
        storedSidebarColor = SidebarColor.saved(defaults?.string(forKey: SidebarColor.preferenceKey))
        sidebar.preferredRail = defaults?.bool(forKey: "compactSidebar") ?? false
        sidebar.hoverEnabled = defaults?.bool(forKey: "hoverSidebar") ?? false
        appearance = BrowserAppearance.saved(defaults?.string(forKey: "browserAppearance"))
        session = factory.session
        bookmarkMigration = factory.importLegacyBookmarks()
        session.configureWebView = { [weak self] view, tab in
            #if DEBUG
            ChromeTiming.install(on: view)
            #endif
            PageChrome.install(on: view, isPrivate: tab.isPrivate)
            guard let self else { return }
            let adapter = MacWebUIDelegate(session: self.session, tab: tab)
            self.adapters[tab.id] = adapter
            SessionFactory.attach(adapter, to: view, tab: tab)
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
        }
        session.didCloseTab = { [weak self] id in self?.adapters.removeValue(forKey: id); self?.privacyMenus.removeValue(forKey: id)?.invalidate() }
        downloads.activityChanged = { [weak self] view in
            self?.session.tabs.first { $0.isInstantiated && $0.webView === view }?.updateInactiveScheduling()
        }
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
            let saved = self.profileDefaults?.string(forKey: "browserAppearance").flatMap(BrowserAppearance.init(rawValue:))
            return ContinuityPreferences.snapshot(session: self.session, appearance: saved?.rawValue)
        }, applyPreferences: { [weak self] values in
            guard let self else { return }
            ContinuityPreferences.apply(values, session: self.session) { value in
                if let appearance = BrowserAppearance(rawValue: value),
                   self.profileDefaults?.string(forKey: "browserAppearance") != value {
                    self.appearance = appearance
                }
            }
        })
    }
    func newTab(isPrivate: Bool? = nil) { session.addTab(isPrivate: isPrivate ?? session.selectedTab?.isPrivate ?? session.isExternalPrivate); focusAddress() }
    func focusAddress() { addressFocusRequest += 1 }
    func prepareForProfileSwitch() {
        // Only requests made after selection should reach the retained address field.
        addressFocusRequestAtProfileSwitch = addressFocusRequest
    }
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
