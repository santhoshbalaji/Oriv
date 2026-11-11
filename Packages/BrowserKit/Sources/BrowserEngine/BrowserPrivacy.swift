import BrowserCore
import Foundation
import Observation
import WebKit

public enum PrivacyLayer: String, CaseIterable, Identifiable, Codable, Sendable {
    case linkCleaning, httpsUpgrade, cookieBanners, globalPrivacyControl
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .linkCleaning: "Clean Tracking Links"
        case .httpsUpgrade: "Upgrade to HTTPS"
        case .cookieBanners: "Hide Cookie Banners"
        case .globalPrivacyControl: "Global Privacy Control"
        }
    }
    public var defaultEnabled: Bool { self != .cookieBanners }
}

/// One instance per profile, as with the blocker. No private hostname reaches defaults or rule caches.
@MainActor @Observable public final class BrowserPrivacy {
    public private(set) var enabledLayers: Set<PrivacyLayer>
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
        enabledLayers = Set(PrivacyLayer.allCases.filter { defaults?.object(forKey: "privacy." + $0.rawValue) as? Bool ?? $0.defaultEnabled })
        regularExceptions = defaults?.data(forKey: "privacy.exceptions").flatMap { try? JSONDecoder().decode([String: Set<PrivacyLayer>].self, from: $0) } ?? [:]
    }
    public func isEnabled(_ layer: PrivacyLayer) -> Bool { enabledLayers.contains(layer) }
    public func isEnabled(_ layer: PrivacyLayer, for url: URL?, isPrivate: Bool) -> Bool {
        guard isEnabled(layer) else { return false }
        return !isException(layer, for: url, isPrivate: isPrivate)
    }
    public func isException(_ layer: PrivacyLayer, for url: URL?, isPrivate: Bool) -> Bool {
        guard let host = AdBlocker.host(for: url) else { return false }
        return (isPrivate ? privateExceptions : regularExceptions)[host]?.contains(layer) == true
    }
    public func setEnabled(_ enabled: Bool, _ layer: PrivacyLayer) {
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
        isEnabled(.linkCleaning, for: url, isPrivate: isPrivate) ? URLCleaner.clean(url) : url
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
        preferences.preferredHTTPSNavigationPolicy = upgrade ? .userMediatedFallbackToHTTP : .keepAsRequested
    }
}
