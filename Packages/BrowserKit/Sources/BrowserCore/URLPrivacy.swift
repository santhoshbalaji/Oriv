import Foundation
import Darwin

/// Original conservative table. Values, ordering, duplicates and fragments are never decoded/rebuilt.
/// See docs/privacy.md for the table's scope and the sensitive-link bypass contract.
public enum URLCleaner {
    public static let trackingKeys: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "mc_eid", "mc_cid", "igshid", "yclid", "_hsenc", "_hsmi",
        "gbraid", "wbraid", "twclid", "ttclid", "li_fat_id", "mkt_tok", "vero_id", "vero_conv"
    ]
    private static let sensitiveKeys: Set<String> = [
        "signature", "sig", "token", "access_token", "id_token", "refresh_token", "auth", "authorization",
        "code", "state", "samlrequest", "samlresponse", "relaystate", "redirect_uri", "redirect_url",
        "client_secret", "session_id", "payment_intent", "payment_intent_client_secret", "hmac", "hash",
        "key-pair-id", "policy", "jwt", "ticket", "expires", "expiry", "exp", "sso", "nonce"
    ]
    public static func clean(_ url: URL) -> URL {
        guard AddressResolver.isWebURL(url), url.user == nil, url.password == nil else { return url }
        let path = url.path.removingPercentEncoding?.lowercased() ?? url.path.lowercased()
        let protectedSegments = ["oauth", "oauth2", "authorize", "auth", "login", "signin", "sign-in", "checkout", "payment", "payments", "callback", "reset-password", "magic-link"]
        guard !path.split(separator: "/").contains(where: { segment in protectedSegments.contains { segment == $0 || segment.hasPrefix($0 + ".") } }) else { return url }
        let raw = url.absoluteString
        let fragmentStart = raw.firstIndex(of: "#") ?? raw.endIndex
        guard let question = raw[..<fragmentStart].firstIndex(of: "?") else { return url }
        let parts = raw[raw.index(after: question)..<fragmentStart].split(separator: "&", omittingEmptySubsequences: false)
        let keys = parts.map { part -> String in
            let key = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return String(key).removingPercentEncoding?.lowercased() ?? String(key).lowercased()
        }
        // A signature can cover any query byte, including tracking-looking parameters.
        guard !keys.contains(where: { sensitiveKeys.contains($0) || $0.hasPrefix("x-amz-") || $0.hasPrefix("x-goog-") || $0.hasSuffix("signature") || $0.hasSuffix("_token") }) else { return url }
        let host = url.host?.lowercased() ?? ""
        let kept = zip(parts, keys).filter { _, key in
            if trackingKeys.contains(key) || key.hasPrefix("utm_") { return false }
            // Only YouTube's sharing marker: `si` is meaningful on many other sites.
            if key == "si", ["youtu.be", "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host) { return false }
            return true
        }.map { String($0.0) }
        guard kept.count != parts.count else { return url }
        let result = String(raw[..<question]) + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) + raw[fragmentStart...]
        return URL(string: result) ?? url
    }
}

public enum PrivacyNavigationKind: Sendable { case newNavigation, backForward, reload }
public enum NavigationCleaningPolicy {
    /// Exact-host comparison intentionally errs toward leaving sibling-host links alone.
    /// A registrable-domain heuristic without a maintained PSL could silently break auth flows.
    public static func replacement(for request: URLRequest, source: URL?, isMainFrame: Bool,
                                   kind: PrivacyNavigationKind, enabled: Bool) -> URL? {
        guard enabled, isMainFrame, kind == .newNavigation,
              (request.httpMethod ?? "GET").uppercased() == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url else { return nil }
        if let source, source.host?.lowercased() == url.host?.lowercased() || sameDocument(source, url) { return nil }
        let cleaned = URLCleaner.clean(url)
        return cleaned == url ? nil : cleaned
    }
    public static func sameDocument(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.absoluteString.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first == rhs.absoluteString.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
    }
}

public enum HTTPSUpgradePolicy {
    public static func isExempt(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return true }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".") && !host.contains(":") { return true }
        // Platform captive-portal endpoints; don't defeat their connectivity check.
        if ["captive.apple.com", "www.apple.com"].contains(host), url.path == "/hotspot-detect.html" { return true }
        if ["connectivitycheck.gstatic.com", "connectivitycheck.android.com", "www.msftconnecttest.com"].contains(host) { return true }
        var address = in6_addr()
        // Link-local IPv6 URLs may include an interface scope (for example %25en0).
        let numericHost = host.contains(":") ? String(host.split(separator: "%", maxSplits: 1)[0]) : host
        if numericHost.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 {
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            if bytes.allSatisfy({ $0 == 0 }) || bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
            if bytes[0] & 0xfe == 0xfc || bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                let v4 = bytes.suffix(4).map(String.init).joined(separator: ".")
                return URL(string: "http://" + v4).map(isExempt) ?? false
            }
            return false
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            return parts[0] == 0 || parts[0] == 10 || parts[0] == 127 || parts[0] == 169 && parts[1] == 254 || parts[0] == 172 && (16...31).contains(parts[1]) || parts[0] == 192 && parts[1] == 168 || parts[0] == 100 && (64...127).contains(parts[1])
        }
        return false
    }
}
