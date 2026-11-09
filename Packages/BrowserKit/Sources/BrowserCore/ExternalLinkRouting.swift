import Foundation

/// Device-local policy; links clicked within a page never pass through this route.
public enum ExternalLinkRouting {
    public static let defaultsKey = "browser.openExternalLinksPrivately"
    public static func opensPrivately(defaults: UserDefaults? = .standard) -> Bool {
        defaults?.object(forKey: defaultsKey) as? Bool ?? true
    }
    public static func accepts(_ url: URL) -> Bool { AddressResolver.isWebURL(url) }
    public static func movableURL(_ url: URL?) -> URL? {
        url.flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
    }
}
