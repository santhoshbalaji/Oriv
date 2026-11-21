import BrowserCore
import Foundation
import Observation
import WebKit

public enum PrivacyLayer: String, CaseIterable, Identifiable, Codable, Sendable {
    case linkCleaning, httpsUpgrade, cookieBanners, globalPrivacyControl, youtubeAds
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .linkCleaning: "Clean Tracking Links"
        case .httpsUpgrade: "Upgrade to HTTPS"
        case .cookieBanners: "Handle Cookie Banners"
        case .globalPrivacyControl: "Global Privacy Control"
        case .youtubeAds: "Block YouTube Ads"
        }
    }
    public var defaultEnabled: Bool { true }
}

public enum CookieBannerMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off", hide = "Hide", reject = "Reject"
    public var id: String { rawValue }
}

/// One instance per profile, as with the blocker. No private hostname reaches defaults or rule caches.
@MainActor @Observable public final class BrowserPrivacy {
    private var enabledLayers: Set<PrivacyLayer>
    public private(set) var cookieBannerMode: CookieBannerMode
    public private(set) var regularExceptions: [String: Set<PrivacyLayer>]
    public private(set) var privateExceptions: [String: Set<PrivacyLayer>] = [:]
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored public var onChange: (() -> Void)?
    public static var supportsGPC: Bool {
        #if compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) { return true }
        #endif
        return false
    }
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        skipYouTubeAds = defaults?.bool(forKey: "privacy.skipYouTubeAds") ?? false
        let legacy = defaults?.object(forKey: "privacy.cookieBanners") as? Bool
        cookieBannerMode = defaults?.string(forKey: "privacy.cookieBannerMode").flatMap(CookieBannerMode.init(rawValue:))
            ?? legacy.map { $0 ? .hide : .off } ?? .reject
        enabledLayers = Set(PrivacyLayer.allCases.filter { $0 != .cookieBanners }.filter { defaults?.object(forKey: "privacy." + $0.rawValue) as? Bool ?? $0.defaultEnabled })
        regularExceptions = defaults?.data(forKey: "privacy.exceptions").flatMap { try? JSONDecoder().decode([String: Set<PrivacyLayer>].self, from: $0) } ?? [:]
    }
    public var skipYouTubeAds: Bool {
        didSet {
            defaults?.set(skipYouTubeAds, forKey: "privacy.skipYouTubeAds")
            onChange?()
        }
    }
    public func isEnabled(_ layer: PrivacyLayer) -> Bool {
        layer == .cookieBanners ? cookieBannerMode != .off : enabledLayers.contains(layer)
    }
    public func setCookieBannerMode(_ mode: CookieBannerMode) {
        guard cookieBannerMode != mode else { return }
        cookieBannerMode = mode
        defaults?.set(mode.rawValue, forKey: "privacy.cookieBannerMode")
        onChange?()
    }
    public func isEnabled(_ layer: PrivacyLayer, for url: URL?, isPrivate: Bool) -> Bool {
        isEnabled(layer, forHost: AdBlocker.host(for: url), isPrivate: isPrivate)
    }
    func isEnabled(_ layer: PrivacyLayer, forHost host: String?, isPrivate: Bool) -> Bool {
        isEnabled(layer) && !isException(layer, forHost: host, isPrivate: isPrivate)
    }
    public func isException(_ layer: PrivacyLayer, for url: URL?, isPrivate: Bool) -> Bool {
        isException(layer, forHost: AdBlocker.host(for: url), isPrivate: isPrivate)
    }
    private func isException(_ layer: PrivacyLayer, forHost host: String?, isPrivate: Bool) -> Bool {
        guard let host else { return false }
        return (isPrivate ? privateExceptions : regularExceptions)[host]?.contains(layer) == true
    }
    public func setEnabled(_ enabled: Bool, _ layer: PrivacyLayer) {
        if layer == .cookieBanners {
            if enabled && cookieBannerMode != .off { return }
            setCookieBannerMode(enabled ? .reject : .off)
            return
        }
        if enabled { enabledLayers.insert(layer) } else { enabledLayers.remove(layer) }
        defaults?.set(enabled, forKey: "privacy." + layer.rawValue); onChange?()
    }
    public func setException(_ excepted: Bool, _ layer: PrivacyLayer, for url: URL?, isPrivate: Bool) {
        guard let host = AdBlocker.host(for: url) else { return }
        var exceptions = isPrivate ? privateExceptions : regularExceptions
        var layers = exceptions[host] ?? []
        if excepted { layers.insert(layer) } else { layers.remove(layer) }
        exceptions[host] = layers.isEmpty ? nil : layers
        if isPrivate { privateExceptions = exceptions }
        else {
            regularExceptions = exceptions
            if let data = try? JSONEncoder().encode(exceptions) { defaults?.set(data, forKey: "privacy.exceptions") }
        }
        onChange?()
    }
    public func endPrivateSession() { privateExceptions = [:] }
    public func cleanedNavigationURL(_ url: URL, isPrivate: Bool) -> URL {
        guard isEnabled(.linkCleaning, for: url, isPrivate: isPrivate) else { return url }
        if let target = RedirectUnwrapper.destination(for: url) {
            return isEnabled(.linkCleaning, for: target, isPrivate: isPrivate) ? URLCleaner.clean(target) : url
        }
        return URLCleaner.clean(url)
    }
    public func apply(to preferences: WKWebpagePreferences, request: URLRequest, isPrivate: Bool) {
        // Xcode 27's Swift 6.4 toolchain introduces the native GPC SDK property.
        #if compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) {
            preferences.globalPrivacyControlEnabled = isEnabled(.globalPrivacyControl, for: request.url, isPrivate: isPrivate)
        }
        #endif
        let upgrade = request.url.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && !HTTPSUpgradePolicy.isExempt($0) } == true
            && (request.httpMethod ?? "GET").uppercased() == "GET" && request.httpBody == nil && request.httpBodyStream == nil
            && isEnabled(.httpsUpgrade, for: request.url, isPrivate: isPrivate)
        // Oriv presents one native, exact-host consent prompt. WebKit must
        // return an error, never perform an automatic unencrypted fallback.
        preferences.preferredHTTPSNavigationPolicy = upgrade ? .errorOnFailure : .keepAsRequested
    }
}
