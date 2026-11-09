import BrowserCore
import Foundation

/// The same allowlist is used by both apps. Private overrides and OS permissions stay local.
@MainActor public enum ContinuityPreferences {
    public static func snapshot(session: BrowserSession, appearance: String) -> [String: String] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ value: T) -> String {
            (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        return ["appearance": appearance, "searchEngine": session.settings.searchEngine.rawValue,
                "restoreTabs": String(session.settings.restoreTabs), "defaultZoom": String(session.settings.defaultZoom),
                "adBlockingMode": session.adBlocker.mode.rawValue,
                "adBlockingExceptions": json(session.adBlocker.regularExceptions.sorted()), "siteRules": json(session.settings.rules)]
    }
    public static func apply(_ values: [String: String], session: BrowserSession, appearance: (String) -> Void) {
        if let value = values["appearance"] { appearance(value) }
        if let value = values["searchEngine"].flatMap(SearchEngine.init(rawValue:)), session.settings.searchEngine != value { session.settings.searchEngine = value }
        if let value = values["restoreTabs"].flatMap(Bool.init), session.settings.restoreTabs != value { session.settings.restoreTabs = value }
        if let value = values["defaultZoom"].flatMap(Double.init), value.isFinite, (0.5...3).contains(value), session.settings.defaultZoom != value { session.settings.defaultZoom = value }
        if let value = values["adBlockingMode"].flatMap(AdBlockingMode.init(rawValue:)) { session.adBlocker.setMode(value) }
        if let data = values["adBlockingExceptions"]?.data(using: .utf8), let value = try? JSONDecoder().decode([String].self, from: data) { session.adBlocker.applyRegularExceptions(Set(value)) }
        if let data = values["siteRules"]?.data(using: .utf8), let value = try? JSONDecoder().decode([String: SiteRule].self, from: data) { session.settings.applyRegularRules(value) }
    }
}
