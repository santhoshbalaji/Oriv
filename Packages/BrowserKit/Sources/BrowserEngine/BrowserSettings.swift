import BrowserCore
import Foundation
import Observation
import WebKit

/// A device-local preference shared by regular profiles and profile-less sessions.
@MainActor @Observable
public final class PrivateTabIsolation {
    private static let key = "browser.isolatePrivateTabs"
    @ObservationIgnored private let defaults: UserDefaults?
    public var isEnabled: Bool { didSet { defaults?.set(isEnabled, forKey: Self.key) } }

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        isEnabled = defaults?.object(forKey: Self.key) as? Bool ?? true
    }
}

@MainActor @Observable
public final class BrowserSettings {
    public let privacy: BrowserPrivacy
    public let privateTabIsolation: PrivateTabIsolation
    public var searchEngine: SearchEngine { didSet { defaults?.set(searchEngine.rawValue, forKey: "browser.searchEngine") } }
    public var restoreTabs: Bool { didSet { defaults?.set(restoreTabs, forKey: "browser.restoreTabs") } }
    public var defaultZoom: Double { didSet { defaults?.set(defaultZoom, forKey: "browser.defaultZoom") } }
    public private(set) var rules: [String: SiteRule] = [:]
    private var privateRules: [String: SiteRule] = [:]
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored public var onRulesChanged: (() -> Void)?

    public init(defaults: UserDefaults? = .standard, privateTabIsolation: PrivateTabIsolation? = nil) {
        self.defaults = defaults
        self.privateTabIsolation = privateTabIsolation ?? PrivateTabIsolation(defaults: defaults)
        privacy = BrowserPrivacy(defaults: defaults)
        searchEngine = defaults?.string(forKey: "browser.searchEngine").flatMap(SearchEngine.init(rawValue:)) ?? .duckDuckGo
        restoreTabs = defaults?.object(forKey: "browser.restoreTabs") as? Bool ?? true
        let zoom = defaults?.double(forKey: "browser.defaultZoom") ?? 1
        defaultZoom = zoom.isFinite && (0.5...3).contains(zoom) ? zoom : 1
        if let data = defaults?.data(forKey: "browser.siteRules"), let saved = try? JSONDecoder().decode([String: SiteRule].self, from: data) { rules = saved }
    }
    public func rule(for url: URL?, isPrivate: Bool) -> SiteRule {
        guard let url, let origin = SiteOrigin(url) else { return SiteRule() }
        return (isPrivate ? privateRules : rules)[origin.id] ?? SiteRule()
    }
    public func setRule(_ rule: SiteRule, for url: URL, isPrivate: Bool) {
        guard let origin = SiteOrigin(url) else { return }
        if isPrivate { privateRules[origin.id] = rule.isDefault ? nil : rule }
        else { rules[origin.id] = rule.isDefault ? nil : rule; persist() }
        onRulesChanged?()
    }
    public func removeRule(_ origin: String) { rules[origin] = nil; persist(); onRulesChanged?() }
    public func clearRules() { rules = [:]; privateRules = [:]; persist(); onRulesChanged?() }
    public func applyRegularRules(_ incoming: [String: SiteRule]) {
        guard incoming.count <= 1_000, incoming.keys.allSatisfy({ key in URL(string: key).flatMap(SiteOrigin.init)?.id == key }) else { return }
        guard rules != incoming else { return }
        rules = incoming; persist(); onRulesChanged?()
    }
    public func endPrivateSession() { privateRules = [:]; privacy.endPrivateSession() }
    private func persist() { if let data = try? JSONEncoder().encode(rules) { defaults?.set(data, forKey: "browser.siteRules") } }
}

@MainActor @Observable
public final class WebsiteDataManager {
    public private(set) var records: [WKWebsiteDataRecord] = []
    public private(set) var isWorking = false
    @ObservationIgnored private let store: WKWebsiteDataStore
    public init(store: WKWebsiteDataStore) { self.store = store }
    public func refresh() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    public func remove(_ records: [WKWebsiteDataRecord]) async {
        guard !isWorking else { return }
        isWorking = true
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        isWorking = false
        await refresh()
    }
    public func remove(site: BrowserSite) async throws {
        guard !isWorking else { throw CocoaError(.fileLocking, userInfo: [NSLocalizedDescriptionKey: "Website data is busy. Try again when the other operation finishes."]) }
        isWorking = true; defer { isWorking = false }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let matching = await store.dataRecords(ofTypes: types).filter { site.contains(host: $0.displayName) }
        if !matching.isEmpty { await store.removeData(ofTypes: types, for: matching) }
        let cookies = store.httpCookieStore
        for cookie in await cookies.allCookies() where site.contains(host: cookie.domain) {
            await cookies.deleteCookie(cookie)
        }
        records = await store.dataRecords(ofTypes: types).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    public func clear(since: Date, cacheOnly: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        let types = cacheOnly ? Set([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache]) : WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: since)
        isWorking = false
        await refresh()
    }
}
