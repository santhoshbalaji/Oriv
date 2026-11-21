import Darwin
import Foundation

/// Site boundaries include the private section of the Public Suffix List,
/// so separate tenants of a shared hosting service stay separate.
public struct BrowserSite: Hashable, Sendable {
    public let domain: String

    public init?(url: URL) {
        guard AddressResolver.isWebURL(url), let host = url.host else { return nil }
        self.init(host: host)
    }

    public init?(host: String) {
        guard let host = Self.normalizedHost(host) else { return nil }
        domain = Self.suffixes?.registrableDomain(host) ?? host
    }

    public func contains(_ url: URL) -> Bool { BrowserSite(url: url) == self }
    public func contains(host: String) -> Bool { BrowserSite(host: host) == self }

    public static var suffixLicense: String {
        guard let url = Bundle.module.url(forResource: "MPL-2.0", withExtension: "txt") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func normalizedHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !host.isEmpty else { return nil }
        let ip = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        // WebKit canonicalizes IP literals before exposing them as URLs or cookie domains.
        // inet_aton also handles legacy shortened IPv4 spellings in older history.
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_aton(ip, &ipv4) == 1, inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil {
            return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        if inet_pton(AF_INET6, ip, &ipv6) == 1, inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil {
            return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        let ascii = host.utf8.allSatisfy { $0 < 128 } ? host : URL(string: "https://" + host)?.host?.lowercased()
        guard let ascii,
              ascii.utf8.allSatisfy(Self.hostnameBytes.contains),
              ascii.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else { return nil }
        return ascii
    }

    private static let hostnameBytes = Set("abcdefghijklmnopqrstuvwxyz0123456789-._".utf8)
    private static let suffixes: SuffixRules? = {
        guard let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"),
              let list = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SuffixRules(list)
    }()

    private struct SuffixRules: Sendable {
        var exact = Set<String>()
        var wildcard = Set<String>()
        var exceptions = Set<String>()

        init(_ list: String) {
            for line in list.split(whereSeparator: \.isNewline) where !line.hasPrefix("//") {
                let rule = line.split(whereSeparator: \.isWhitespace).first ?? ""
                if rule.hasPrefix("!"), let host = BrowserSite.normalizedHost(String(rule.dropFirst())) {
                    exceptions.insert(host)
                } else if rule.hasPrefix("*."), let host = BrowserSite.normalizedHost(String(rule.dropFirst(2))) {
                    wildcard.insert(host)
                } else if let host = BrowserSite.normalizedHost(String(rule)) {
                    exact.insert(host)
                }
            }
        }

        func registrableDomain(_ host: String) -> String {
            var ipv4 = in_addr()
            guard !host.contains(":"), inet_pton(AF_INET, host, &ipv4) != 1 else { return host }
            let labels = host.split(separator: ".")
            var suffixLength = 1
            for start in labels.indices {
                let suffix = labels[start...].joined(separator: ".")
                let length = labels.count - start
                if exceptions.contains(suffix) {
                    suffixLength = length - 1
                    break
                }
                if exact.contains(suffix) { suffixLength = max(suffixLength, length) }
                if start > 0, wildcard.contains(suffix) { suffixLength = max(suffixLength, length + 1) }
            }
            return labels.count > suffixLength ? labels.suffix(suffixLength + 1).joined(separator: ".") : host
        }
    }
}

public struct SiteHistoryDeletion: Hashable, Sendable {
    public let site: BrowserSite
    public let through: Date

    public init(site: BrowserSite, through: Date) {
        self.site = site
        self.through = through
    }

    static func cutoffs(_ deletions: some Sequence<Self>) -> [BrowserSite: Date] {
        Dictionary(deletions.map { ($0.site, $0.through) }, uniquingKeysWith: max)
    }
}
