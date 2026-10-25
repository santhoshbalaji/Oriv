import CryptoKit
import Foundation
import Observation
import WebKit

public enum AdBlockingMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off", balanced = "Balanced", strict = "Strict"
    public var id: String { rawValue }
    public var detail: String {
        switch self {
        case .off: "Allow ads and trackers."
        case .balanced: "Block known advertising networks and common trackers."
        case .strict: "Also block analytics and hide common ad slots. Some sites may need an exception."
        }
    }
}

/// Compiled rules contain no browsing data or site exceptions. Only the user's
/// regular-site exceptions are saved; private exceptions never reach the rule store.
@MainActor @Observable
public final class AdBlocker {
    public private(set) var mode: AdBlockingMode
    public private(set) var regularExceptions: Set<String>
    public private(set) var privateExceptions: Set<String> = []
    public private(set) var isPreparing = false
    public private(set) var preparationError: String?
    public static let rulesVersion = "2026.10.25"
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let source: [AdBlockingMode: String]
    @ObservationIgnored private var lists: [AdBlockingMode: WKContentRuleList] = [:]
    @ObservationIgnored private var compilation: Task<[AdBlockingMode: WKContentRuleList], Error>?

    public init(defaults: UserDefaults? = nil, rules: [AdBlockingMode: String]? = nil) {
        self.defaults = defaults
        mode = defaults?.string(forKey: "adBlockingMode").flatMap(AdBlockingMode.init(rawValue:)) ?? .balanced
        regularExceptions = Set(defaults?.stringArray(forKey: "adBlockingExceptions") ?? [])
        source = rules ?? AdBlockingRules.bundled
    }

    public static func host(for url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    public func isException(_ url: URL?, isPrivate: Bool) -> Bool {
        guard let host = Self.host(for: url) else { return false }
        return (isPrivate ? privateExceptions : regularExceptions).contains(host)
    }

    public func isEnabled(for url: URL?, isPrivate: Bool) -> Bool {
        mode != .off && !isException(url, isPrivate: isPrivate)
    }

    public func setMode(_ value: AdBlockingMode) {
        guard mode != value else { return }
        mode = value
        if value == .off { preparationError = nil }
        defaults?.set(value.rawValue, forKey: "adBlockingMode")
        onChange?()
    }

    public func setException(_ allowed: Bool, for url: URL?, isPrivate: Bool) {
        guard let host = Self.host(for: url) else { return }
        if isPrivate {
            if allowed { privateExceptions.insert(host) } else { privateExceptions.remove(host) }
        } else {
            if allowed { regularExceptions.insert(host) } else { regularExceptions.remove(host) }
            defaults?.set(regularExceptions.sorted(), forKey: "adBlockingExceptions")
        }
        onChange?()
    }

    public func removeRegularException(_ host: String) {
        regularExceptions.remove(host)
        defaults?.set(regularExceptions.sorted(), forKey: "adBlockingExceptions")
        onChange?()
    }

    public func endPrivateSession() { privateExceptions.removeAll() }

    public func prepare() async throws {
        if !lists.isEmpty { return }
        if compilation == nil {
            isPreparing = true
            preparationError = nil
            let source = source
            compilation = Task { @MainActor in
                var result: [AdBlockingMode: WKContentRuleList] = [:]
                for mode in [AdBlockingMode.balanced, .strict] {
                    guard let json = source[mode] else { throw CocoaError(.fileReadCorruptFile) }
                    let hash = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
                    let identifier = "oriv.\(mode.rawValue.lowercased()).\(hash)"
                    let store = WKContentRuleListStore.default()!
                    if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                        result[mode] = cached
                    } else {
                        result[mode] = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
                    }
                }
                return result
            }
        }
        do {
            lists = try await compilation!.value
            isPreparing = false
        } catch {
            isPreparing = false
            preparationError = "Ad blocking could not start. Try again or choose Off to load without filtering."
            compilation = nil
            throw error
        }
    }

    public func apply(to controller: WKUserContentController, url: URL?, isPrivate: Bool) async throws {
        if mode != .off { try await prepare() }
        applyPrepared(to: controller, url: url, isPrivate: isPrivate)
    }

    /// Redirect handling must be synchronous; the navigation gate already prepared the lists.
    func applyPrepared(to controller: WKUserContentController, url: URL?, isPrivate: Bool) {
        for list in lists.values { controller.remove(list) }
        if isEnabled(for: url, isPrivate: isPrivate), let list = lists[mode] { controller.add(list) }
    }
}

/// Original, deliberately bounded rules. No downloaded executable code, browsing
/// telemetry, cosmetic page script or third-party extension is involved.
public enum AdBlockingRules {
    public static var bundled: [AdBlockingMode: String] {
        let advertising = [
            "doubleclick.net", "googlesyndication.com", "googleadservices.com", "googletagservices.com",
            "adservice.google.com", "amazon-adsystem.com", "adsystem.com", "adnxs.com", "adsrvr.org",
            "advertising.com", "adform.net", "adition.com", "adroll.com", "ads-twitter.com",
            "bidswitch.net", "casalemedia.com", "criteo.com", "criteo.net", "demdex.net", "dotomi.com",
            "exelator.com", "eyeota.net", "flashtalking.com", "gumgum.com", "indexww.com",
            "lijit.com", "mathtag.com", "media.net", "moatads.com", "mookie1.com", "openx.net",
            "outbrain.com", "pubmatic.com", "quantserve.com", "revcontent.com", "rfihub.com",
            "rubiconproject.com", "scorecardresearch.com", "sharethrough.com", "smartadserver.com",
            "smartadsserver.com", "spotxchange.com", "spotx.tv", "taboola.com", "tapad.com",
            "teads.tv", "tremorhub.com", "tribalfusion.com", "triplelift.com", "turn.com",
            "undertone.com", "yieldmo.com", "yieldlab.net", "zedo.com"
        ]
        let analytics = ["google-analytics.com", "analytics.google.com", "googletagmanager.com",
                         "hotjar.com", "hotjar.io", "clarity.ms", "mixpanel.com", "segment.io",
                         "segment.com", "amplitude.com", "mouseflow.com", "fullstory.com", "crazyegg.com"]
        func rules(_ domains: [String], thirdPartyOnly: Bool) -> [[String: Any]] {
            domains.map { domain in
                var trigger: [String: Any] = [
                    "url-filter": "^https?://([a-z0-9-]+\\.)*" + domain.replacingOccurrences(of: ".", with: "\\.") + "[:/]",
                    // Never block top-level navigation, media files, fonts or styles.
                    "resource-type": ["image", "script", "raw", "fetch", "ping", "child-document", "svg-document"]
                ]
                if thirdPartyOnly { trigger["load-type"] = ["third-party"] }
                return ["trigger": trigger, "action": ["type": "block"]]
            }
        }
        let balanced = rules(advertising, thirdPartyOnly: true)
        let strict = rules(advertising + analytics, thirdPartyOnly: false) + [
            ["trigger": ["url-filter": ".*"],
             "action": ["type": "css-display-none", "selector": "ins.adsbygoogle, [data-ad-slot], [data-ad-unit], .ad-banner, .advertisement, #ad-banner"]]
        ]
        return [.balanced: encode(balanced), .strict: encode(strict)]
    }

    private static func encode(_ rules: [[String: Any]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), encoding: .utf8)!
    }
}
