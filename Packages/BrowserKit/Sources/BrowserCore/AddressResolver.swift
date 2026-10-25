import Foundation

public enum AddressError: LocalizedError, Equatable {
    case empty, invalidURL, unsupportedScheme

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a website address or search terms."
        case .invalidURL: "This address could not be opened. Check the hostname and try again."
        case .unsupportedScheme: "Enter an HTTP or HTTPS address. Other address types cannot be opened here."
        }
    }
}

public enum AddressResolver {
    public static func resolve(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AddressError.empty }
        let lower = value.lowercased()
        if ["javascript:", "data:", "file:", "about:", "blob:"].contains(where: lower.hasPrefix) {
            throw AddressError.unsupportedScheme
        }
        if value.contains("://") {
            guard !value.contains(where: \.isWhitespace) else { throw AddressError.invalidURL }
            return try validatedWebURL(value)
        }
        let authority = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? authority
        let isLocal = host == "localhost" || host == "127.0.0.1" || authority.hasPrefix("[::1]")
        let looksLikeHost = isLocal || host.contains(".") || authority.hasPrefix("[")
        if looksLikeHost && !value.contains(where: \.isWhitespace) && !value.contains("@") {
            return try validatedWebURL("\(isLocal ? "http" : "https")://\(value)")
        }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: value)]
        return search.url!
    }

    public static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    private static func validatedWebURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased() else {
            throw AddressError.invalidURL
        }
        guard ["http", "https"].contains(scheme) else { throw AddressError.unsupportedScheme }
        guard let url = components.url, isWebURL(url),
              components.port.map({ (1...65535).contains($0) }) ?? true else { throw AddressError.invalidURL }
        return url
    }
}
