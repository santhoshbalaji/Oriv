import BrowserCore
import BrowserEngine
import Observation
import UIKit
import WebKit

@MainActor @Observable final class MobileController {
    let session: BrowserSession
    let downloads = MobileDownloads()
    let profileID: UUID
    @ObservationIgnored private let profileDefaults: UserDefaults?
    var appearance: BrowserAppearance { didSet { profileDefaults?.set(appearance.rawValue, forKey: "browserAppearance") } }
    var sheet: MobileSheet?
    var addressFocusRequest = 0
    var message: String?
    @ObservationIgnored private var bookmarkMigration: Task<Void, Never>?
    @ObservationIgnored private var delegates: [UUID: MobileWebDelegate] = [:]

    init(profile: BrowserProfile = .personal) {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["BROWSER_TESTING"] == "1"
        profileID = profile.id
        let root = profile.directory(in: URL.applicationSupportDirectory.appendingPathComponent("Oriv", isDirectory: true))
        let defaults: UserDefaults? = testing ? nil : profile.isPersonal ? .standard : UserDefaults(suiteName: profile.defaultsName(bundleID: Bundle.main.bundleIdentifier ?? "OrivMobile")!)
        profileDefaults = defaults
        appearance = defaults?.string(forKey: "browserAppearance").flatMap(BrowserAppearance.init(rawValue:)) ?? .t3Code
        session = BrowserSession(store: testing ? nil : SessionFileStore(fileURL: root.appendingPathComponent("session.json")),
            dataStore: testing ? .nonPersistent() : profile.isPersonal ? .default() : WKWebsiteDataStore(forIdentifier: profileID),
            adBlocker: AdBlocker(defaults: defaults), settings: BrowserSettings(defaults: defaults))
        if !testing {
            bookmarkMigration = Task { [weak session] in
                await session?.importLegacyBookmarks(from: root.appendingPathComponent("workspace.sqlite"))
            }
        }
        session.configureWebView = { [weak self] view, tab in
            guard let self else { return }
            let adapter = MobileWebDelegate(session: session, tab: tab); delegates[tab.id] = adapter; view.uiDelegate = adapter
            tab.onAuthentication = { [weak adapter] challenge, completion in
                guard let adapter else { completion(.cancelAuthenticationChallenge, nil); return }
                adapter.authenticate(challenge, completion: completion)
            }
        }
        session.didCloseTab = { [weak self] id in self?.delegates.removeValue(forKey: id) }
        session.handleDownload = { [weak self] download in self?.downloads.begin(download) }
        session.handleExternalURL = { url in
            let alert = UIAlertController(title: "Open another app?", message: url.absoluteString, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in UIApplication.shared.open(url) })
            MobileWebDelegate.presenter?.present(alert, animated: true)
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
    func newTab(isPrivate: Bool = false) {
        session.addTab(isPrivate: isPrivate); sheet = nil; addressFocusRequest += 1
    }
    func route(_ url: URL) {
        guard AddressResolver.isWebURL(url) else { return }
        session.addTab(url: url); sheet = nil
    }
    func foreground() { session.setProfileActive(true) }
    func background() { session.saveNow(); session.setProfileActive(false) }
}

enum MobileSheet: String, Identifiable {
    case library, tabs, settings, site, share
    var id: String { rawValue }
}
