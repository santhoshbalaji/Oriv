import Foundation

/// How a page's address is shown under its title in lists. Pure formatting; no navigation or storage.
public enum URLDisplay {
    /// Host without a leading "www.", plus a non-default port.
    public static func site(_ url: URL) -> String? {
        guard var host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        let defaultPort = url.scheme == "http" ? 80 : url.scheme == "https" ? 443 : nil
        if let port = url.port, port != defaultPort { host += ":\(port)" }
        return host
    }

    /// The line under a row's title, or nil when it would only repeat the title.
    ///
    /// The host is shown when the title is something else. Path, then query, then fragment are added
    /// only as far as needed to tell this row apart from other rows in `peers` that show the same title.
    /// A title that is empty or equal to the host shows the address itself when it has a path or port.
    public static func secondaryLine(title: String, url: URL?, peers: [(title: String, url: URL)] = []) -> String? {
        Context(peers).secondaryLine(title: title, url: url)
    }

    /// The rows of one visible list, grouped by displayed title once so each row's line is cheap.
    public struct Context: Sendable {
        private let groups: [String: [URL]]
        public init(_ rows: [(title: String, url: URL)]) {
            groups = Dictionary(grouping: rows.map { (URLDisplay.titleKey($0.title, url: $0.url), $0.url) }, by: \.0)
                .mapValues { $0.map(\.1) }
        }
        public func secondaryLine(title: String, url: URL?) -> String? {
            guard let url, let site = URLDisplay.site(url) else { return nil }
            let key = URLDisplay.titleKey(title, url: url)
            let rivals = (groups[key] ?? []).filter { $0 != url }
            let titleIsAddress = key == site.lowercased() || key == url.host(percentEncoded: false)?.lowercased()
            var level = titleIsAddress ? 1 : 0
            while level < 3, rivals.contains(where: { URLDisplay.line($0, level: level) == URLDisplay.line(url, level: level) }) { level += 1 }
            let result = URLDisplay.line(url, level: level)
            return result.lowercased() == key ? nil : result
        }
    }

    fileprivate static func titleKey(_ title: String, url: URL) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Empty row titles display the bare host in both apps; the port still belongs on the secondary line.
        return trimmed.isEmpty ? (url.host(percentEncoded: false)?.lowercased() ?? "") : trimmed
    }

    /// 0: site, 1: + path, 2: + query, 3: + fragment.
    fileprivate static func line(_ url: URL, level: Int) -> String {
        var text = site(url) ?? url.absoluteString
        guard level >= 1 else { return text }
        let path = url.path(percentEncoded: false)
        if path != "/" { text += path }
        if level >= 2, let query = url.query(percentEncoded: false), !query.isEmpty { text += "?" + query }
        if level >= 3, let fragment = url.fragment(percentEncoded: false), !fragment.isEmpty { text += "#" + fragment }
        return text
    }
}
