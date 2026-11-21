import BrowserCore
import BrowserEngine
import Observation
import UIKit
import WebKit

@MainActor @Observable final class MobileController {
    let session: BrowserSession
    let downloads: MobileDownloads
    let profileID: UUID?
    @ObservationIgnored private let profileDefaults: UserDefaults?
    var appearance: BrowserAppearance { didSet { profileDefaults?.set(appearance.rawValue, forKey: "browserAppearance") } }
    var sheet: MobileSheet?
    var addressFocusRequest = 0
    var message: String?
    let tabPresentation = MobileTabPresentation()
    let tabSwipe = MobileTabSwipe()
    let gridMorph = MobileGridMorph()
    let topChrome = MobileTopChrome()
    let viewportLayout = MobileViewportLayout()
    @ObservationIgnored private var chromes: [UUID:PageChrome] = [:]
    @ObservationIgnored private let homeChrome = PageChrome()
    func chrome(for tab:BrowserTab?) -> PageChrome {
        guard let tab, tab.url != nil || tab.hasLoaded else { return homeChrome }
        // configureWebView and onWebViewDiscarded own observer attachment.
        // A render-time lookup must stay read-only: reconnecting here can
        // publish PageChrome changes recursively during a hosting-graph update.
        if let chrome = chromes[tab.id] { return chrome }
        let chrome = PageChrome(); chromes[tab.id] = chrome
        if tab.isInstantiated { chrome.observe(tab.webView,isPrivate:tab.isPrivate) }
        return chrome
    }
    @ObservationIgnored weak var closeConfirmation: UIAlertController?
    @ObservationIgnored var pendingTabClose: MobileTabCloseConfirmation?
    weak var profiles: MobileProfiles?
    @ObservationIgnored private var protectionWarmup: Task<Void,Never>?
    @ObservationIgnored private var memoryObserver: MobileMemoryObserver?
    @ObservationIgnored private var trimTask: Task<Void,Never>?
    @ObservationIgnored private var lastUsed: [UUID:Double] = [:]
    @ObservationIgnored private var bookmarkMigration: Task<Void, Never>?
    @ObservationIgnored private var delegates: [UUID: MobileWebDelegate] = [:]

    init(profile: BrowserProfile? = .personal, privateTabIsolation: PrivateTabIsolation? = nil, forceEphemeral: Bool = false, inheriting source: MobileController? = nil) {
        #if DEBUG && targetEnvironment(simulator)
        let liveCapture = ChromeVisualFixture.liveURL != nil
        #else
        let liveCapture = false
        #endif
        let testing = forceEphemeral || SessionFactory.isTesting || ChromeVisualFixture.mode != nil || liveCapture
        profileID = profile?.id
        downloads = MobileDownloads(stagingDirectory: SessionFactory.downloadStagingDirectory(for: profile?.id))
        let factory = SessionFactory(profile: profile, testing: testing, bundleID: Bundle.main.bundleIdentifier ?? "OrivMobile",
                                     privateTabIsolation: privateTabIsolation)
        let defaults = factory.defaults
        profileDefaults = defaults
        appearance = BrowserAppearance.saved(defaults?.string(forKey: "browserAppearance"))
        session = factory.session
        tabSwipe.topChrome = topChrome
        tabSwipe.chromeForTab = { [weak self] id in
            guard let self, let tab = session.tabs.first(where:{ $0.id == id }) else { return (ChromeColor(0,0,0),1) }
            let chrome = chrome(for:tab)
            return (MobileTopChrome.rgb(UIColor(chrome.color)),chrome.showsContentUnderChrome ? 0 : 1)
        }
        bookmarkMigration = factory.importLegacyBookmarks()
        memoryObserver = MobileMemoryObserver { [weak self] in
            self?.session.tabSnapshots.removeAll()
            self?.tabPresentation.releaseCachedSnapshots()
            self?.trimBackgroundTabs(limit:1)
        }
        session.configureWebView = { [weak self] view, tab in
            #if DEBUG
            ChromeTiming.install(on: view)
            #endif
            PageChrome.install(on: view, isPrivate: tab.isPrivate)
            guard let self else { return }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            viewportLayout.prepare(view,window:scene?.keyWindow)
            let chrome = chromes[tab.id] ?? PageChrome(); chromes[tab.id] = chrome
            chrome.observe(view,isPrivate:tab.isPrivate)
            let adapter = MobileWebDelegate(session: session, tab: tab); adapter.controller = self
            let id = tab.id
            tab.onWebViewDiscarded = { [weak self] in
                // Detach WebKit ownership but retain the tab's measured tint for
                // its next restoration and the first interactive swipe frame.
                self?.chromes[id]?.observe(nil)
                self?.delegates.removeValue(forKey:id)?.invalidate()
            }
            delegates[tab.id] = adapter
            SessionFactory.attach(adapter, to: view, tab: tab)
            // Mobile downloads own their progress/delegate lifetime. Protect all
            // tabs while that owner reports an active transfer.
            tab.hasActiveDownloads = { [weak self] in (self?.downloads.activeCount ?? 0) > 0 }
            adapter.installContextTracking(on: view)
        }
        session.didCloseTab = { [weak self] id in self?.delegates.removeValue(forKey: id)?.invalidate(); self?.tabPresentation.remove(id); self?.chromes.removeValue(forKey:id)?.observe(nil) }
        session.didResetSiteTab = { [weak self] id in self?.tabPresentation.remove(id) }
        session.handleDownload = { [weak self] download in
            guard let self, session.isProfileActive else { download.cancel { _ in }; return }
            downloads.begin(download)
        }
        session.handleExternalURL = { [weak self] url in
            guard self?.session.isProfileActive == true else { return }
            let alert = UIAlertController(title: "Open another app?", message: url.absoluteString, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in
                guard self?.session.isProfileActive == true else { return }
                UIApplication.shared.open(url)
            })
            MobileWebDelegate.presenter?.present(alert, animated: true)
        }
        if profile == nil, let source {
            appearance = source.appearance
            session.inheritPrivatePreferences(from: source.session)
        }
        if !testing { warmProtection() }
    }
    /// Compile ahead of address entry without awaiting launch or weakening the
    /// navigation policy. An immediate first URL still waits for protection.
    func warmProtection() {
        guard protectionWarmup == nil, session.adBlocker.requiresRulePreparation else { return }
        protectionWarmup = Task { @MainActor [weak blocker = session.adBlocker] in
            guard let blocker else { return }
            do { try await blocker.prepare() }
            catch { /* The existing navigation policy reports preparation errors. */ }
        }
    }
    func trimBackgroundTabs(limit:Int = 8) {
        if let id = session.selectedTabID { lastUsed[id] = ProcessInfo.processInfo.systemUptime }
        trimTask?.cancel()
        trimTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for:.seconds(1))
            // Retry one transient native IPC failure; each request still has
            // its own deadline and cannot act after expiring.
            for _ in 0..<2 {
                guard !Task.isCancelled, self != nil, self?.tabPresentation.activeID == nil, (self?.session.isProfileActive == false || self?.sheet != .tabs),
                      let live = self?.session.tabs.filter(\.isInstantiated).sorted(by:{
                          (self?.lastUsed[$0.id,default:0] ?? 0) < (self?.lastUsed[$1.id,default:0] ?? 0)
                      }) else { return }
                // Independent WebKit IPC requests overlap in bounded waves. Never
                // retain the controller across an await. Each wave is bounded by the known excess.
                var remaining = live.count, index = 0
                while remaining > limit && index < live.count {
                    guard !Task.isCancelled, self != nil, self?.tabPresentation.activeID == nil, (self?.session.isProfileActive == false || self?.sheet != .tabs) else { return }
                    let count = min(4,min(remaining-limit,live.count-index))
                    let wave = Array(live[index..<(index+count)]); index += count
                    let reclaimed:Int = await withCheckedContinuation { continuation in
                        var outstanding = wave.count, successes = 0
                        for tab in wave {
                            tab.discardBackgroundWebView { discarded in
                                if discarded { successes += 1 }
                                outstanding -= 1
                                if outstanding == 0 { continuation.resume(returning:successes) }
                            }
                        }
                    }
                    remaining -= reclaimed
                }
            }
        }
    }
    func perform(_ operation: () throws -> Void) { do { try operation() } catch { message = error.localizedDescription } }
    func open(_ url: URL) {
        guard AddressResolver.isBookmarkURL(url) else { return }
        session.openSavedPage(url); sheet = nil
    }
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
    func shutdown() {
        trimTask?.cancel()
        bookmarkMigration?.cancel()
        protectionWarmup?.cancel()
        memoryObserver = nil
        tabPresentation.discard()
        session.shutdown()
        delegates.values.forEach { $0.invalidate() }
        delegates.removeAll()
        chromes.values.forEach { $0.observe(nil) }
        chromes.removeAll()
    }
    func foreground() { tabPresentation.resume(); session.setProfileActive(true); session.activateSelectedTab(); trimBackgroundTabs() }
    func background(leavingProfile: Bool = false) {
        tabPresentation.discard()
        session.saveNow()
        session.setProfileActive(false)
        if leavingProfile { trimBackgroundTabs(limit: 1) }
    }
}

enum MobileSheet: String, Identifiable {
    case library, bookmarks, history, tabs, settings, site, share
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
