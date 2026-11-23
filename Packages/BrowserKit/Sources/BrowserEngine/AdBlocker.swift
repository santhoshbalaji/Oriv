import BrowserCore
import CryptoKit
import Darwin
import Foundation
import Observation
import OSLog
import WebKit

public enum AdBlockingMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off", balanced = "Balanced", strict = "Strict"
    public var id: String { rawValue }
    public var detail: String {
        switch self {
        case .off: "Allow ads and trackers."
        case .balanced: "Block known advertising networks and common trackers."
        case .strict: "Also block analytics and disguised (CNAME-cloaked) trackers and hide common ad slots. Uses extra storage. Some sites may need an exception."
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
    public var isPreparingCNAME: Bool { mode == .strict && preparingCNAME }
    public var cnamePreparationError: String? { mode == .strict ? cnameError : nil }
    private var preparingCNAME = false
    private var cnameError: String?
    public static let rulesVersion = (try? BundledPrivacyRules.manifest().rulesVersion) ?? "Unavailable"
    public var cookieBannersEnabled = false
    @ObservationIgnored public var privacy: BrowserPrivacy?
    public private(set) var compilationMeasurements: [RuleCompilationMeasurement] = []
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let cacheNamespace: String
    @ObservationIgnored private let fixtureSource: [String: String]?
    @ObservationIgnored private let cnameFixture: (@Sendable () async throws -> String)?
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
    private static let logger = Logger(subsystem: "Oriv", category: "ContentBlocking")
    private static let bundledNamespace = "oriv.privacy"
    private static var sharedCompilation: Task<CompiledRules, Error>?
    private static var sharedCNAMECompilation: Task<CompiledRules, Error>?
    private static var cnameCleanup: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var compilation: Task<CompiledRules, Error>?
    @ObservationIgnored private var didStartCNAME = false
    @ObservationIgnored private var isWarming = false
    private final class Installation {
        var host: String?
        var isPrivate = false
        var lists: [String: WKContentRuleList] = [:]
    }
    // Keep only the current policy host in memory, including during provisional
    // navigation when WKWebView.url may describe the previous document.
    @ObservationIgnored private let installations = NSMapTable<WKUserContentController, Installation>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    public convenience init(defaults: UserDefaults? = nil, rules: [AdBlockingMode: String]? = nil, cookieRules: String? = nil, cacheNamespace: String = "oriv.privacy") {
        self.init(defaults: defaults, rules: rules, cookieRules: cookieRules, cacheNamespace: cacheNamespace, cnameFixture: nil)
    }

    init(defaults: UserDefaults? = nil, rules: [AdBlockingMode: String]? = nil, cookieRules: String? = nil,
         cacheNamespace: String, cnameFixture: (@Sendable () async throws -> String)?) {
        self.cacheNamespace = cacheNamespace
        self.defaults = defaults
        self.cnameFixture = cnameFixture
        mode = defaults?.string(forKey: "adBlockingMode").flatMap(AdBlockingMode.init(rawValue:)) ?? .balanced
        regularExceptions = Set(defaults?.stringArray(forKey: "adBlockingExceptions") ?? [])
        fixtureSource = rules.map { rules in
            var source = Dictionary(uniqueKeysWithValues: rules.map { ($0.key.rawValue, $0.value) })
            source["cookies-fixture"] = cookieRules
            return source
        }
    }

    private static func compile(namespace: String, fixture: [String: String]? = nil, cnameOnly: Bool = false,
                                cnameFixture: (@Sendable () async throws -> String)? = nil) -> Task<CompiledRules, Error> {
        let priority: TaskPriority = cnameOnly ? .background : .userInitiated
        let cleanup = cnameOnly ? cnameCleanup[namespace] : nil
        return Task(priority: priority) { @MainActor in
            await cleanup?.value
            guard let store = ruleStore else { throw CocoaError(.fileReadNoSuchFile) }
            let rules = try await Task.detached(priority: priority) {
                let rules: [RuleSource]
                if let cnameFixture {
                    rules = [RuleSource(key: BundledPrivacyRules.cnameComponent, json: try await cnameFixture())]
                } else if let fixture { rules = fixture.map { RuleSource(key: $0.key, json: $0.value) } }
                else {
                    let resources = try BundledPrivacyRules.resources(cnameOnly: cnameOnly)
                    rules = resources.map { resource in
                        RuleSource(key: resource.key, digest: resource.sha256, read: resource.read)
                    } + (cnameOnly ? [] : [RuleSource(key: "original-strict", json: AdBlockingRules.bundled[.strict]!)])
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
                let identifier = cnameOnly ? "\(namespace).cname.\(rule.digest)" : "\(namespace).\(rule.digest)"
                #if DEBUG
                let started = ProcessInfo.processInfo.systemUptime
                let before = RuleCompilationMeasurement.residentBytes()
                #endif
                let cached = try? await store.contentRuleList(forIdentifier: identifier)
                if let cached { result[rule.key] = cached }
                else {
                    let json = try await Task.detached(priority: priority, operation: rule.read).value
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

    /// Run once against the saved profiles at app startup. A Strict profile can
    /// need the cache even if its controller has not been created yet.
    static func prepareCNAMEAtLaunch(hasStrictProfile: @escaping @MainActor () -> Bool) {
        let needsCNAME = hasStrictProfile()
        if sharedCNAMECompilation == nil {
            removeCNAMECache(namespace: bundledNamespace, legacyOnly: needsCNAME)
        }
        guard needsCNAME else { return }
        #if os(macOS) && ORIV_BENCH
        guard !BenchmarkOptions.disabled.contains("content-blocker") else { return }
        #endif
        let core = prepareSharedCore()
        Task(priority: .background) {
            do {
                _ = try await core.value
                if hasStrictProfile() { _ = prepareSharedCNAME() }
            } catch {
                if sharedCompilation == core { sharedCompilation = nil }
            }
        }
    }

    /// Enumerate identifiers without looking up compiled lists. Include the
    /// current bundle's legacy digest-only identifiers for Phase 6 upgrades.
    @discardableResult
    static func removeCNAMECache(namespace: String, legacyOnly: Bool = false) -> Task<Void, Never> {
        if let pending = cnameCleanup[namespace] { return pending }
        let pending = Task(priority: .background) {
            defer { cnameCleanup[namespace] = nil }
            guard let store = ruleStore else { return }
            let prefix = "\(namespace).cname."
            let legacy = (try? BundledPrivacyRules.manifest().outputs[BundledPrivacyRules.cnameComponent]) ?? []
            let legacyIdentifiers = Set(legacy.map { "\(namespace).\($0.sha256)" })
            let identifiers = await store.availableIdentifiers() ?? []
            for identifier in identifiers
                where (!legacyOnly && identifier.hasPrefix(prefix)) || legacyIdentifiers.contains(identifier) {
                do { try await store.removeContentRuleList(forIdentifier: identifier) }
                catch { logger.error("Could not remove cached CNAME tracker rules (code \((error as NSError).code, privacy: .public))") }
            }
        }
        cnameCleanup[namespace] = pending
        return pending
    }

    private static func prepareSharedCore() -> Task<CompiledRules, Error> {
        if let sharedCompilation { return sharedCompilation }
        let pending = compile(namespace: bundledNamespace)
        sharedCompilation = pending
        return pending
    }

    private static func prepareSharedCNAME() -> Task<CompiledRules, Error> {
        if let sharedCNAMECompilation { return sharedCNAMECompilation }
        let pending = compile(namespace: bundledNamespace, cnameOnly: true)
        sharedCNAMECompilation = pending
        return pending
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
        isException(host: Self.host(for: url), isPrivate: isPrivate)
    }

    private func isException(host: String?, isPrivate: Bool) -> Bool {
        guard let host else { return false }
        return (isPrivate ? privateExceptions : regularExceptions).contains(host)
    }

    public func isEnabled(for url: URL?, isPrivate: Bool) -> Bool {
        mode != .off && !isException(url, isPrivate: isPrivate)
    }

    public func setMode(_ value: AdBlockingMode) {
        guard mode != value else { return }
        let wasStrict = mode == .strict
        mode = value
        if value == .off { preparationError = nil }
        defaults?.set(value.rawValue, forKey: "adBlockingMode")
        if wasStrict || value == .strict { refreshInstalledRules() }
        if value == .strict { warmUp() }
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

    func warmUp() {
        guard requiresRulePreparation, !isWarming else { return }
        if !lists.isEmpty {
            startCNAMEPreparation()
            return
        }
        isWarming = true
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.isWarming = false }
            // A core failure is reported by prepare() and retried on navigation.
            try? await self.prepare()
        }
    }

    public func prepare() async throws {
        #if os(macOS) && ORIV_BENCH
        guard !BenchmarkOptions.disabled.contains("content-blocker") else { return }
        #endif
        if !lists.isEmpty {
            startCNAMEPreparation()
            return
        }
        let sharesBundledRules = fixtureSource == nil && cacheNamespace == Self.bundledNamespace
        if compilation == nil {
            isPreparing = true
            preparationError = nil
            if sharesBundledRules {
                compilation = Self.prepareSharedCore()
            } else { compilation = Self.compile(namespace: cacheNamespace, fixture: fixtureSource) }
        }
        let pending = compilation!
        do {
            let compiled = try await pending.value
            guard compilation == pending else { return }
            lists = compiled.lists
            compilationMeasurements = compiled.measurements
            compilation = nil
            isPreparing = false
            startCNAMEPreparation()
        } catch {
            if sharesBundledRules && Self.sharedCompilation == pending { Self.sharedCompilation = nil }
            guard compilation == pending else { throw error }
            isPreparing = false
            preparationError = "Privacy filtering could not start. Try again or choose Off and turn off cookie-banner handling to load without filtering."
            compilation = nil
            throw error
        }
    }

    private func startCNAMEPreparation() {
        guard mode == .strict, !lists.isEmpty, !didStartCNAME, fixtureSource == nil || cnameFixture != nil else { return }
        didStartCNAME = true
        preparingCNAME = true
        let pending: Task<CompiledRules, Error>
        if cacheNamespace == Self.bundledNamespace, cnameFixture == nil {
            pending = Self.prepareSharedCNAME()
        } else {
            pending = Self.compile(namespace: cacheNamespace, cnameOnly: true, cnameFixture: cnameFixture)
        }
        // Join only from a background task, never from the navigation gate.
        Task(priority: .background) { [weak self] in
            do {
                let compiled = try await pending.value
                guard let self else { return }
                self.lists.merge(compiled.lists) { _, new in new }
                self.compilationMeasurements += compiled.measurements
                if self.mode == .strict { self.refreshInstalledRules() }
                self.preparingCNAME = false
            } catch {
                Self.logger.error("CNAME tracker rules failed to prepare (code \((error as NSError).code, privacy: .public))")
                self?.cnameError = "CNAME tracker protection is unavailable. Other privacy filters are still active."
                self?.preparingCNAME = false
            }
        }
    }

    private func refreshInstalledRules() {
        for case let controller as WKUserContentController in installations.keyEnumerator().allObjects {
            guard let installation = installations.object(forKey: controller) else { continue }
            let hideCookies = usesCookieHideRules &&
                (privacy?.isEnabled(.cookieBanners, forHost: installation.host, isPrivate: installation.isPrivate) ?? true)
            updateRules(on: controller, installation: installation, hideCookies: hideCookies)
        }
    }

    private var usesCookieHideRules: Bool {
        cookieBannersEnabled && (privacy?.cookieBannerMode != .reject || !CookieConsent.isAvailable)
    }

    public var requiresRulePreparation: Bool { mode != .off || usesCookieHideRules }

    public func apply(to controller: WKUserContentController, url: URL?, isPrivate: Bool) async throws {
        if requiresRulePreparation { try await prepare() }
        applyPrepared(to: controller, url: url, isPrivate: isPrivate)
    }

    /// The prepared hot path needs no actor hop. A partial/failed preparation
    /// cannot enter it, preserving the first-navigation protection gate.
    var canApplyWithoutPreparing: Bool { !requiresRulePreparation || !lists.isEmpty }

    func applyIfPrepared(to controller:WKUserContentController,url:URL?,isPrivate:Bool) -> Bool {
        guard canApplyWithoutPreparing else { return false }
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
        let installation: Installation
        if let existing = installations.object(forKey: controller) {
            installation = existing
        } else {
            installation = Installation()
            installations.setObject(installation, forKey: controller)
        }
        installation.host = Self.host(for: url)
        installation.isPrivate = isPrivate
        applyPolicy(to: controller, installation: installation)
    }

    func detach(from controller: WKUserContentController) {
        installations.removeObject(forKey: controller)
    }

    func refreshPrepared(on controller: WKUserContentController) {
        guard let installation = installations.object(forKey: controller) else { return }
        applyPolicy(to: controller, installation: installation)
    }

    private func applyPolicy(to controller: WKUserContentController, installation: Installation) {
        let host = installation.host
        let isPrivate = installation.isPrivate
        var youtubeSource: String?
        if let host, YouTubeProtection.hosts.contains(host), mode != .off, !isException(host: host, isPrivate: isPrivate),
           let privacy, privacy.isEnabled(.youtubeAds, forHost: host, isPrivate: isPrivate) {
            let disabled = YouTubeProtection.hosts.filter { host in
                let frameURL = URL(string: "https://" + host)
                return !isEnabled(for: frameURL, isPrivate: isPrivate)
                    || !privacy.isEnabled(.youtubeAds, for: frameURL, isPrivate: isPrivate)
            }
            youtubeSource = YouTubeProtection.source(disabledHosts: disabled, skipAds: privacy.skipYouTubeAds)
        }
        YouTubeProtection.update(controller, source: youtubeSource)
        let handleCookies = cookieBannersEnabled && (privacy?.isEnabled(.cookieBanners, forHost: host, isPrivate: isPrivate) ?? true)
        let hideCookies = handleCookies && usesCookieHideRules
        CookieConsent.update(controller, enabled: handleCookies && !hideCookies && host != nil)
        CookieBannerRestoration.update(controller, enabled: hideCookies)
        updateRules(on: controller, installation: installation, hideCookies: hideCookies)
        startCNAMEPreparation()
    }

    private func updateRules(on controller: WKUserContentController, installation: Installation, hideCookies: Bool) {
        let blockAds = mode != .off && !isException(host: installation.host, isPrivate: installation.isPrivate)
        var desired: [String: WKContentRuleList] = [:]
        for (key, list) in lists {
            if key.hasPrefix("cookies") {
                if hideCookies { desired[list.identifier] = list }
            } else if blockAds {
                if key.hasPrefix(BundledPrivacyRules.cnameComponent) {
                    if mode == .strict { desired[list.identifier] = list }
                } else if key == mode.rawValue || key.hasPrefix("network") || key.hasPrefix(mode == .strict ? "cosmetics-strict" : "cosmetics-light") || key == "original-strict" && mode == .strict {
                    desired[list.identifier] = list
                }
            }
        }
        let installed = installation.lists
        for (id,list) in installed where desired[id] == nil { controller.remove(list) }
        for (id,list) in desired where installed[id] == nil { controller.add(list) }
        installation.lists = desired
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
    static let cnameComponent = "network-cname"
    public static var acknowledgements: String {
        guard let root = Bundle.module.url(forResource: "Privacy", withExtension: nil) else { return "Privacy acknowledgements could not be read." }
        let notice = (try? String(contentsOf: root.appendingPathComponent("NOTICE.txt"), encoding: .utf8)) ?? ""
        let license = (try? String(contentsOf: root.appendingPathComponent("CC-BY-SA-3.0.txt"), encoding: .utf8)) ?? ""
        let consent = ["NOTICE.txt", "MPL-2.0.txt"].compactMap {
            try? String(contentsOf: root.appendingPathComponent("Autoconsent").appendingPathComponent($0), encoding: .utf8)
        }
        let cname = (try? String(contentsOf: root.appendingPathComponent("AdGuard-MIT.txt"), encoding: .utf8)) ?? ""
        let suffixes = "Mozilla Public Suffix List (https://publicsuffix.org/list/), distributed under MPL 2.0.\n\n" + BrowserSite.suffixLicense
        return ([notice, license, cname, suffixes] + consent).joined(separator: "\n\n")
    }
    struct Manifest: Decodable { let rulesVersion: String; let outputs: [String: [Entry]] }
    struct Entry: Decodable { let file: String; let sha256: String }
    private static let root = Bundle.module.url(forResource: "Privacy", withExtension: nil)

    static func manifest() throws -> Manifest {
        guard let root else { throw CocoaError(.fileReadNoSuchFile) }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }

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

    static func resources(cnameOnly: Bool = false) throws -> [Resource] {
        guard let root else { throw CocoaError(.fileReadNoSuchFile) }
        let entries = try manifest().outputs.filter { ($0.key == cnameComponent) == cnameOnly }.values.flatMap { $0 }
        guard !entries.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return entries.map { Resource(file: root.appendingPathComponent($0.file), sha256: $0.sha256) }
    }
}
