import Foundation

public enum SearchEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case duckDuckGo = "DuckDuckGo", google = "Google", bing = "Bing", brave = "Brave"
    public var id: String { rawValue }
    public func searchURL(_ query: String) -> URL {
        let base: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .google: base = "https://www.google.com/search"
        case .bing: base = "https://www.bing.com/search"
        case .brave: base = "https://search.brave.com/search"
        }
        var url = URLComponents(string: base)!
        url.queryItems = [URLQueryItem(name: "q", value: query)]
        return url.url!
    }
}

/// Exact origins keep permissions separate across schemes and ports. Never key permissions by suffix matching.
public struct SiteOrigin: Hashable, Codable, Sendable, Identifiable {
    public let scheme: String
    public let host: String
    public let port: Int
    public var id: String { "\(scheme)://\(host):\(port)" }
    public var displayName: String { id }
    public init?(_ url: URL) {
        guard AddressResolver.isWebURL(url), let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return nil }
        self.scheme = scheme; self.host = host; port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
    }
}

public enum SitePermission: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask = "Ask", block = "Block"
    public var id: String { rawValue }
}

public struct SiteRule: Codable, Equatable, Sendable {
    public var camera: SitePermission = .ask
    public var microphone: SitePermission = .ask
    public var allowsAutomaticPopups = false
    public init() {}
    public var isDefault: Bool { self == Self() }
}
