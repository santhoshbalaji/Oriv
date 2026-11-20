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
    @ObservationIgnored private let cacheNamespace: String
    @ObservationIgnored private let fixtureSource: [String: String]?
    @ObservationIgnored private var lists: [String: WKContentRuleList] = [:]
    private struct CompiledRules {
        let lists: [String: WKContentRuleList]
        let measurements: [RuleCompilationMeasurement]
    }
    private struct RuleSource: Sendable {
        let key: String
        let digest: String
        let read: @Sendable () throws -> String

        init(key: String, digest: String, read: @escaping @Sendable () throws -> String) {
            self.key = key; self.digest = digest; self.read = read
        }

        init(key: String, json: String) {
            self.init(key: key, digest: BundledPrivacyRules.digest(Data(json.utf8)), read: { json })
        }
    }
    private static let ruleStore = WKContentRuleListStore.default()
    private static var sharedCompilation: Task<CompiledRules, Error>?
    @ObservationIgnored private var compilation: Task<CompiledRules, Error>?
    private final class InstalledRules {
        let lists:[String:WKContentRuleList]
        init(_ lists:[String:WKContentRuleList]) { self.lists = lists }
    }
    // Each tab owns its controller. Weak keys release closed/private tabs;
    // values contain only compiled public rules, never hosts or browsing data.
    @ObservationIgnored private let installations = NSMapTable<WKUserContentController,InstalledRules>(keyOptions:.weakMemory,valueOptions:.strongMemory)

    public init(defaults: UserDefaults? = nil, rules: [AdBlockingMode: String]? = nil, cookieRules: String? = nil, cacheNamespace: String = "oriv.privacy") {
        self.cacheNamespace = cacheNamespace
        self.defaults = defaults
        mode = defaults?.string(forKey: "adBlockingMode").flatMap(AdBlockingMode.init(rawValue:)) ?? .balanced
        regularExceptions = Set(defaults?.stringArray(forKey: "adBlockingExceptions") ?? [])
        fixtureSource = rules.map { rules in
            var source = Dictionary(uniqueKeysWithValues: rules.map { ($0.key.rawValue, $0.value) })
            source["cookies-fixture"] = cookieRules
            return source
        }
    }

    private static func compile(namespace: String, fixture: [String: String]?) -> Task<CompiledRules, Error> {
        Task { @MainActor in
            guard let store = ruleStore else { throw CocoaError(.fileReadNoSuchFile) }
            let rules = try await Task.detached(priority: .userInitiated) {
                let rules: [RuleSource]
                if let fixture { rules = fixture.map { RuleSource(key: $0.key, json: $0.value) } }
                else {
                    rules = try BundledPrivacyRules.resources().map { resource in
                        RuleSource(key: resource.key, digest: resource.sha256, read: resource.read)
                    } + [RuleSource(key: "original-strict", json: AdBlockingRules.bundled[.strict]!)]
                }
                #if os(macOS) && ORIV_BENCH
                if BenchmarkOptions.disabled.contains("cosmetics") {
                    let source = try Dictionary(uniqueKeysWithValues: rules.map { ($0.key, try $0.read()) })
                    return try removingCosmetics(from: source).map { RuleSource(key: $0.key, json: $0.value) }
                }
                #endif
                return rules
            }.value
            guard !rules.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            var result: [String: WKContentRuleList] = [:]
            var measurements: [RuleCompilationMeasurement] = []
            for rule in rules.sorted(by: { $0.key < $1.key }) {
                let identifier = "\(namespace).\(rule.digest)"
                #if DEBUG
                let started = ProcessInfo.processInfo.systemUptime
                let before = RuleCompilationMeasurement.residentBytes()
                #endif
                let cached = try? await store.contentRuleList(forIdentifier: identifier)
                if let cached { result[rule.key] = cached }
                else {
                    let json = try await Task.detached(priority: .userInitiated, operation: rule.read).value
                    guard let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    result[rule.key] = list
                }
                #if DEBUG
                measurements.append(RuleCompilationMeasurement(component: rule.key, identifier: identifier,
                    peakProcessResident: RuleCompilationMeasurement.peakResidentBytes(), cached: cached != nil,
                    seconds: ProcessInfo.processInfo.systemUptime - started,
                    residentBefore: before, residentAfter: RuleCompilationMeasurement.residentBytes()))
                #endif
            }
            return CompiledRules(lists: result, measurements: measurements)
        }
    }

    #if os(macOS) && ORIV_BENCH
    nonisolated private static func removingCosmetics(from source: [String: String]) throws -> [String: String] {
        var components = source
        for (key, json) in source where !key.hasPrefix("cookies") {
            if key.hasPrefix("cosmetics") {
                components.removeValue(forKey: key)
                continue
            }
            guard let rules = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let kept = rules.filter { ($0["action"] as? [String: Any])?["type"] as? String != "css-display-none" }
            if kept.isEmpty { components.removeValue(forKey: key) }
            else if kept.count < rules.count {
                let data = try JSONSerialization.data(withJSONObject: kept, options: .sortedKeys)
                components[key] = String(decoding: data, as: UTF8.self)
            }
        }
        return components
    }
    #endif

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
        #if os(macOS) && ORIV_BENCH
        guard !BenchmarkOptions.disabled.contains("content-blocker") else { return }
        #endif
        if !lists.isEmpty { return }
        let sharesBundledRules = fixtureSource == nil && cacheNamespace == "oriv.privacy"
        if compilation == nil {
            isPreparing = true
            preparationError = nil
            if sharesBundledRules {
                if Self.sharedCompilation == nil {
                    Self.sharedCompilation = Self.compile(namespace: cacheNamespace, fixture: nil)
                }
                compilation = Self.sharedCompilation
            } else { compilation = Self.compile(namespace: cacheNamespace, fixture: fixtureSource) }
        }
        let pending = compilation!
        do {
            let compiled = try await pending.value
            lists = compiled.lists
            compilationMeasurements = compiled.measurements
            compilation = nil
            isPreparing = false
        } catch {
            if sharesBundledRules && Self.sharedCompilation == pending { Self.sharedCompilation = nil }
            guard compilation == pending else { throw error }
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

    /// The prepared hot path needs no actor hop. A partial/failed preparation
    /// cannot enter it, preserving the first-navigation protection gate.
    func applyIfPrepared(to controller:WKUserContentController,url:URL?,isPrivate:Bool) -> Bool {
        guard (mode == .off && !cookieBannersEnabled) || !lists.isEmpty else { return false }
        applyPrepared(to:controller,url:url,isPrivate:isPrivate)
        return true
    }

    #if os(macOS) && ORIV_BENCH
    public func installedRuleComponents(in controller: WKUserContentController) -> [String] {
        let installed = installations.object(forKey: controller)?.lists ?? [:]
        return lists.keys.filter { key in
            lists[key].map { installed[$0.identifier] != nil } ?? false
        }.sorted()
    }
    #endif

    /// Compiled components contain no profile or private site data.
    func applyPrepared(to controller: WKUserContentController, url: URL?, isPrivate: Bool) {
        var youtubeSource: String?
        if YouTubeProtection.supports(url), isEnabled(for: url, isPrivate: isPrivate),
           let privacy, privacy.isEnabled(.youtubeAds, for: url, isPrivate: isPrivate) {
            let disabled = YouTubeProtection.hosts.filter { host in
                let frameURL = URL(string: "https://" + host)
                return !isEnabled(for: frameURL, isPrivate: isPrivate)
                    || !privacy.isEnabled(.youtubeAds, for: frameURL, isPrivate: isPrivate)
            }
            youtubeSource = YouTubeProtection.source(disabledHosts: disabled, skipAds: privacy.skipYouTubeAds)
        }
        YouTubeProtection.update(controller, source: youtubeSource)
        let hideCookies = cookieBannersEnabled && (privacy?.isEnabled(.cookieBanners, for: url, isPrivate: isPrivate) ?? true)
        CookieBannerRestoration.update(controller, enabled: hideCookies)
        var desired:[String:WKContentRuleList] = [:]
        for (key, list) in lists {
            if key.hasPrefix("cookies") {
                if hideCookies { desired[list.identifier] = list }
            } else if isEnabled(for: url, isPrivate: isPrivate) {
                if key == mode.rawValue || key.hasPrefix("network") || key.hasPrefix(mode == .strict ? "cosmetics-strict" : "cosmetics-light") || key == "original-strict" && mode == .strict { desired[list.identifier] = list }
            }
        }
        let installed = installations.object(forKey:controller)?.lists ?? [:]
        for (id,list) in installed where desired[id] == nil { controller.remove(list) }
        for (id,list) in desired where installed[id] == nil { controller.add(list) }
        if Set(installed.keys) != Set(desired.keys) || installations.object(forKey:controller) == nil {
            installations.setObject(InstalledRules(desired),forKey:controller)
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
    private struct Manifest: Decodable { let outputs: [String: [Entry]] }
    private struct Entry: Decodable { let file: String; let sha256: String }

    struct Resource: Sendable {
        let file: URL
        let sha256: String
        var key: String { file.deletingPathExtension().lastPathComponent }

        func read() throws -> String {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", maxSplits: 1)
            guard lines.count == 2,
                  let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any],
                  header["sha256"] as? String == sha256,
                  let limit = header["decodedBytes"] as? Int, (1...50_000_000).contains(limit),
                  let encoded = Data(base64Encoded: String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)),
                  let decoded = try (encoded as NSData).decompressed(using: .zlib) as Data?, decoded.count == limit,
                  BundledPrivacyRules.digest(decoded) == sha256,
                  let json = String(data: decoded, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            return json
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func resources() throws -> [Resource] {
        guard let root = Bundle.module.url(forResource: "Privacy", withExtension: nil) else { throw CocoaError(.fileReadNoSuchFile) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let entries = manifest.outputs.values.flatMap { $0 }
        guard !entries.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return entries.map { Resource(file: root.appendingPathComponent($0.file), sha256: $0.sha256) }
    }
}
