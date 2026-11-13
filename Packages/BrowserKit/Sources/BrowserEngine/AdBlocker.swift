import BrowserCore
import CryptoKit
import Darwin
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
    public static let rulesVersion = "2026.11.11-74c3e769a009"
    public var cookieBannersEnabled = false
    @ObservationIgnored public var privacy: BrowserPrivacy?
    public private(set) var compilationMeasurements: [RuleCompilationMeasurement] = []
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let preparedSource: Task<[PreparedRule], Error>
    @ObservationIgnored private let cacheNamespace: String
    private struct PreparedRule: Sendable {
        let key: String
        let json: String
        let identifier: String
    }
    @ObservationIgnored private var lists: [String: WKContentRuleList] = [:]
    @ObservationIgnored private var compilation: Task<[String: WKContentRuleList], Error>?

    public init(defaults: UserDefaults? = nil, rules: [AdBlockingMode: String]? = nil, cookieRules: String? = nil, cacheNamespace: String = "oriv.privacy") {
        self.cacheNamespace = cacheNamespace
        self.defaults = defaults
        mode = defaults?.string(forKey: "adBlockingMode").flatMap(AdBlockingMode.init(rawValue:)) ?? .balanced
        regularExceptions = Set(defaults?.stringArray(forKey: "adBlockingExceptions") ?? [])
        // Decompression, digest verification and hashing are CPU/file work.
        // Start them away from the UI actor, including on the first launch.
        preparedSource = Task.detached(priority:.userInitiated) {
            let source: [String:String]
            if let rules {
                var values = Dictionary(uniqueKeysWithValues:rules.map { ($0.key.rawValue,$0.value) })
                if let cookieRules { values["cookies-fixture"] = cookieRules }
                source = values
            } else { source = try BundledPrivacyRules.sources() }
            guard !source.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return source.keys.sorted().map { key in
                let json = source[key]!
                let hash = SHA256.hash(data:Data(json.utf8)).map { String(format:"%02x",$0) }.joined()
                return PreparedRule(key:key,json:json,identifier:"\(cacheNamespace).\(hash)")
            }
        }
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

    public func applyRegularExceptions(_ incoming: Set<String>) {
        guard incoming.count <= 1_000, incoming.allSatisfy({ host in
            host.count <= 253 && URL(string: "https://" + host).flatMap(Self.host) == host
        }), regularExceptions != incoming else { return }
        regularExceptions = incoming
        defaults?.set(incoming.sorted(), forKey: "adBlockingExceptions"); onChange?()
    }
    public func endPrivateSession() { privateExceptions.removeAll() }

    public func prepare() async throws {
        if !lists.isEmpty { return }
        if compilation == nil {
            isPreparing = true
            preparationError = nil
            let preparedSource = preparedSource
            compilation = Task { @MainActor [weak self] in
                let rules = try await preparedSource.value
                // WebKit compilation is asynchronous. Submit independent lists
                // together so an unused component cannot serialize the next one.
                let jobs = rules.map { rule in Task { @MainActor [weak self] in
                    let store = WKContentRuleListStore.default()!
                    #if DEBUG
                    let started = ProcessInfo.processInfo.systemUptime
                    let before = RuleCompilationMeasurement.residentBytes()
                    #endif
                    let cached = try? await store.contentRuleList(forIdentifier:rule.identifier)
                    let list: WKContentRuleList
                    if let cached { list = cached }
                    else {
                        guard let compiled = try await store.compileContentRuleList(forIdentifier:rule.identifier,encodedContentRuleList:rule.json) else { throw CocoaError(.coderReadCorrupt) }
                        list = compiled
                    }
                    #if DEBUG
                    self?.compilationMeasurements.append(RuleCompilationMeasurement(component:rule.key,identifier:rule.identifier,
                        peakProcessResident:RuleCompilationMeasurement.peakResidentBytes(),cached:cached != nil,
                        seconds:ProcessInfo.processInfo.systemUptime-started,residentBefore:before,residentAfter:RuleCompilationMeasurement.residentBytes()))
                    #endif
                    return list
                } }
                var result: [String:WKContentRuleList] = [:]
                for (rule,job) in zip(rules,jobs) { result[rule.key] = try await job.value }
                return result
            }
        }
        do {
            lists = try await compilation!.value
            compilation = nil
            isPreparing = false
        } catch {
            isPreparing = false
            preparationError = "Privacy filtering could not start. Try again or choose Off and disable cookie hiding to load without filtering."
            compilation = nil
            throw error
        }
    }

    public func apply(to controller: WKUserContentController, url: URL?, isPrivate: Bool) async throws {
        if mode != .off || cookieBannersEnabled { try await prepare() }
        applyPrepared(to: controller, url: url, isPrivate: isPrivate)
    }

    /// Compiled components contain no profile or private site data.
    func applyPrepared(to controller: WKUserContentController, url: URL?, isPrivate: Bool) {
        let hideCookies = cookieBannersEnabled && (privacy?.isEnabled(.cookieBanners, for: url, isPrivate: isPrivate) ?? true)
        CookieBannerRestoration.update(controller, enabled: hideCookies)
        for list in lists.values { controller.remove(list) }
        for (key, list) in lists {
            if key.hasPrefix("cookies") {
                if cookieBannersEnabled && (privacy?.isEnabled(.cookieBanners, for: url, isPrivate: isPrivate) ?? true) { controller.add(list) }
            } else if isEnabled(for: url, isPrivate: isPrivate) {
                if key == mode.rawValue || key.hasPrefix("network") || key.hasPrefix(mode == .strict ? "cosmetics-strict" : "cosmetics-light") || key == "original-strict" && mode == .strict { controller.add(list) }
            }
        }
    }

}

/// Original Strict first-party supplement. The default source also includes maintained lists.
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


public struct RuleCompilationMeasurement: Codable, Sendable {
    public var component: String
    public var identifier: String
    public var peakProcessResident: UInt64
    public var cached: Bool
    public var seconds: Double
    public var residentBefore: UInt64
    public var residentAfter: UInt64
    static func peakResidentBytes() -> UInt64 {
        var usage = rusage()
        return getrusage(RUSAGE_SELF, &usage) == 0 ? UInt64(max(0, usage.ru_maxrss)) : 0
    }
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

public enum BundledPrivacyRules {
    public static var acknowledgements: String {
        guard let root = Bundle.module.url(forResource: "Privacy", withExtension: nil) else { return "Privacy acknowledgements could not be read." }
        let notice = (try? String(contentsOf: root.appendingPathComponent("NOTICE.txt"), encoding: .utf8)) ?? ""
        let license = (try? String(contentsOf: root.appendingPathComponent("CC-BY-SA-3.0.txt"), encoding: .utf8)) ?? ""
        return notice + "\n\n" + license
    }
    private static let cachedSources = Result { try readSources() }
    static func sources() throws -> [String: String] { try cachedSources.get() }
    private struct Manifest: Decodable { let outputs: [String: [Resource]] }
    private struct Resource: Decodable { let file: String; let sha256: String }
    private static func readSources() throws -> [String: String] {
        guard let root = Bundle.module.url(forResource: "Privacy", withExtension: nil) else { throw CocoaError(.fileReadNoSuchFile) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let resources = manifest.outputs.values.flatMap { $0 }
        guard !resources.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let files = resources.map { root.appendingPathComponent($0.file) }
        var values: [String: String] = [:]
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", maxSplits: 1)
            guard lines.count == 2,
                  let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any],
                  header["sha256"] as? String == resources.first(where: { $0.file == file.lastPathComponent })?.sha256,
                  let limit = header["decodedBytes"] as? Int, (1...50_000_000).contains(limit),
                  let encoded = Data(base64Encoded: String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)),
                  let decoded = try (encoded as NSData).decompressed(using: .zlib) as Data?, decoded.count == limit,
                  SHA256.hash(data: decoded).map({ String(format: "%02x", $0) }).joined() == header["sha256"] as? String,
                  let json = String(data: decoded, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            values[file.deletingPathExtension().lastPathComponent] = json
        }
        values["original-strict"] = AdBlockingRules.bundled[.strict]
        return values
    }
}
