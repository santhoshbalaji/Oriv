import BrowserCore
import BrowserEngine
import Observation
import UIKit
import WebKit

@MainActor @Observable final class MobileController {
    let session: BrowserSession
    let downloads = MobileDownloads()
    let profileID: UUID?
    @ObservationIgnored private let profileDefaults: UserDefaults?
    var appearance: BrowserAppearance { didSet { profileDefaults?.set(appearance.rawValue, forKey: "browserAppearance") } }
    var sheet: MobileSheet?
    var addressFocusRequest = 0
    var message: String?
    let tabPresentation = MobileTabPresentation()
    @ObservationIgnored private var chromes: [UUID:PageChrome] = [:]
    @ObservationIgnored private let homeChrome = PageChrome()
    func chrome(for tab:BrowserTab?) -> PageChrome {
        guard let tab, tab.url != nil || tab.hasLoaded else { return homeChrome }
        if let chrome = chromes[tab.id] { chrome.observe(tab.webView,isPrivate:tab.isPrivate); return chrome }
        let chrome = PageChrome(); chromes[tab.id] = chrome
        chrome.observe(tab.webView,isPrivate:tab.isPrivate)
        return chrome
    }
    @ObservationIgnored weak var closeConfirmation: UIAlertController?
    weak var profiles: MobileProfiles?
    @ObservationIgnored private var protectionWarmup: Task<Void,Never>?
    @ObservationIgnored private var memoryObserver: MobileMemoryObserver?
    @ObservationIgnored private var trimTask: Task<Void,Never>?
    @ObservationIgnored private var lastUsed: [UUID:Double] = [:]
    @ObservationIgnored private var bookmarkMigration: Task<Void, Never>?
    @ObservationIgnored private var delegates: [UUID: MobileWebDelegate] = [:]

    init(profile: BrowserProfile? = .personal) {
        #if DEBUG && targetEnvironment(simulator)
        let liveCapture = ChromeVisualFixture.liveURL != nil
        #else
        let liveCapture = false
        #endif
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["BROWSER_TESTING"] == "1" || ChromeVisualFixture.mode != nil || liveCapture
        profileID = profile?.id
        let root = profile?.directory(in: URL.applicationSupportDirectory.appendingPathComponent("Oriv", isDirectory: true))
        let defaults: UserDefaults? = testing || profile == nil ? nil : profile!.isPersonal ? .standard : UserDefaults(suiteName: profile!.defaultsName(bundleID: Bundle.main.bundleIdentifier ?? "OrivMobile")!)
        profileDefaults = defaults
        appearance = defaults?.string(forKey: "browserAppearance").flatMap(BrowserAppearance.init(rawValue:)) ?? .t3Code
        session = BrowserSession(store: testing || root == nil ? nil : SessionFileStore(fileURL: root!.appendingPathComponent("session.json")),
            dataStore: testing || profile == nil ? .nonPersistent() : profile!.isPersonal ? .default() : WKWebsiteDataStore(forIdentifier: profile!.id),
            adBlocker: AdBlocker(defaults: defaults), settings: BrowserSettings(defaults: defaults), externalPrivate: profile == nil)
        if !testing, let root {
            bookmarkMigration = Task { [weak session] in
                await session?.importLegacyBookmarks(from: root.appendingPathComponent("workspace.sqlite"))
            }
        }
        memoryObserver = MobileMemoryObserver { [weak self] in self?.trimBackgroundTabs(limit:1) }
        session.configureWebView = { [weak self] view, tab in
            #if DEBUG
            ChromeTiming.install(on: view)
            #endif
            PageChrome.install(on: view)
            guard let self else { return }
            let chrome = chromes[tab.id] ?? PageChrome(); chromes[tab.id] = chrome
            chrome.observe(view,isPrivate:tab.isPrivate)
            let adapter = MobileWebDelegate(session: session, tab: tab); adapter.controller = self
            let id = tab.id
            tab.onWebViewDiscarded = { [weak self] in
                self?.chromes.removeValue(forKey:id)?.observe(nil)
                self?.delegates.removeValue(forKey:id)?.invalidate()
            }
            delegates[tab.id] = adapter; view.uiDelegate = adapter
            adapter.installContextTracking(on: view)
            tab.onAuthentication = { [weak adapter] challenge, completion in
                guard let adapter else { completion(.cancelAuthenticationChallenge, nil); return }
                adapter.authenticate(challenge, completion: completion)
            }
        }
        session.didCloseTab = { [weak self] id in self?.delegates.removeValue(forKey: id)?.invalidate(); self?.tabPresentation.remove(id); self?.chromes.removeValue(forKey:id)?.observe(nil) }
        session.handleDownload = { [weak self] download in self?.downloads.begin(download) }
        session.handleExternalURL = { url in
            let alert = UIAlertController(title: "Open another app?", message: url.absoluteString, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in UIApplication.shared.open(url) })
            MobileWebDelegate.presenter?.present(alert, animated: true)
        }
        if !testing { warmProtection() }
    }
    /// Compile ahead of address entry without awaiting launch or weakening the
    /// navigation policy. An immediate first URL still waits for protection.
    func warmProtection() {
        guard protectionWarmup == nil, session.adBlocker.mode != .off || session.adBlocker.cookieBannersEnabled else { return }
        protectionWarmup = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await session.adBlocker.prepare() }
            catch { /* The existing navigation policy reports preparation errors. */ }
        }
    }
    func trimBackgroundTabs(limit:Int = 8) {
        if let id = session.selectedTabID { lastUsed[id] = ProcessInfo.processInfo.systemUptime }
        trimTask?.cancel()
        trimTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for:.seconds(1))
            guard !Task.isCancelled, let self, tabPresentation.activeID == nil, sheet != .tabs else { return }
            let live = session.tabs.filter(\.isInstantiated).sorted { lastUsed[$0.id,default:0] < lastUsed[$1.id,default:0] }
            var remaining = live.count
            for tab in live where remaining > limit {
                guard !Task.isCancelled, tabPresentation.activeID == nil else { return }
                let discarded = await withCheckedContinuation { continuation in
                    tab.discardBackgroundWebView { continuation.resume(returning:$0) }
                }
                if discarded { remaining -= 1 }
            }
        }
    }
    func perform(_ operation: () throws -> Void) { do { try operation() } catch { message = error.localizedDescription } }
    func open(_ url: URL) {
        guard AddressResolver.isWebURL(url) else { return }
        session.openSavedPage(url); sheet = nil
    }
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
    func newTab(isPrivate: Bool = false, animated:Bool = true) {
        guard !animated || (!tabPresentation.inserting && tabPresentation.pendingNewTab == nil) else { return }
        if sheet == .tabs && animated {
            tabPresentation.pendingNewTab = isPrivate; sheet = nil; return
        }
        tabPresentation.inserting = animated
        session.addTab(isPrivate:isPrivate); sheet = nil; addressFocusRequest += 1
    }
    func route(_ url: URL) {
        guard AddressResolver.isWebURL(url) else { return }
        session.addTab(url: url); sheet = nil
    }
    func foreground() { tabPresentation.resume(); session.setProfileActive(true); session.activateSelectedTab(); trimBackgroundTabs() }
    func background() { tabPresentation.discard(); session.saveNow(); session.setProfileActive(false) }
}

enum MobileSheet: String, Identifiable {
    case library, bookmarks, tabs, settings, site, share
    var id: String { rawValue }
}

@MainActor private final class MobileMemoryObserver: NSObject {
    private let action: () -> Void
    init(_ action:@escaping () -> Void) {
        self.action = action; super.init()
        NotificationCenter.default.addObserver(self,selector:#selector(receive),name:UIApplication.didReceiveMemoryWarningNotification,object:nil)
    }
    @objc private func receive() { action() }
    deinit { NotificationCenter.default.removeObserver(self) }
}
