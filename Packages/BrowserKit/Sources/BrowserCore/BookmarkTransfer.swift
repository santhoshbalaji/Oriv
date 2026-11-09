import Foundation

public enum BookmarkTransferError: LocalizedError {
    case tooLarge, invalidEncoding, tooMany
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "Choose a bookmark HTML file smaller than 5 MB."
        case .invalidEncoding: "This file is not readable UTF-8 bookmark HTML."
        case .tooMany: "Import at most 5,000 bookmarks in one file."
        }
    }
}

/// Reads exported bookmark links as inert text. Never renders the HTML or loads linked resources.
public enum BookmarkTransfer {
    public struct Import: Sendable {
        public let bookmarks: [Bookmark]
        public let skipped: Int
    }
    public static func parse(_ data: Data) throws -> Import {
        guard data.count <= 5_000_000 else { throw BookmarkTransferError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw BookmarkTransferError.invalidEncoding }
        let anchors = try NSRegularExpression(pattern: #"<a\b([^>]*)>(.*?)</a\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let href = try NSRegularExpression(pattern: #"(?:^|\s)href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: [.caseInsensitive])
        let tags = try NSRegularExpression(pattern: "<[^>]*>")
        var result: [Bookmark] = [], seen = Set<URL>(), skipped = 0
        let matches = anchors.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count <= 5_000 else { throw BookmarkTransferError.tooMany }
        let source = text as NSString
        for match in matches {
            let attributes = source.substring(with: match.range(at: 1))
            guard let link = href.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
                  let group = (1...3).first(where: { link.range(at: $0).location != NSNotFound }) else { skipped += 1; continue }
            let raw = decodeEntities((attributes as NSString).substring(with: link.range(at: group))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), AddressResolver.isWebURL(url), seen.insert(url).inserted else { skipped += 1; continue }
            let body = source.substring(with: match.range(at: 2))
            let stripped = tags.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
            let title = decodeEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Bookmark(title: title.isEmpty ? (url.host ?? "Saved page") : String(title.prefix(500)), url: url))
        }
        return Import(bookmarks: result, skipped: skipped)
    }
    public static func export(_ bookmarks: [Bookmark]) -> Data {
        let links = bookmarks.filter { AddressResolver.isWebURL($0.url) }.map {
            "    <DT><A HREF=\"\(escape($0.url.absoluteString))\">\(escape($0.title))</A>"
        }.joined(separator: "\n")
        return Data("""
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Oriv Bookmarks</TITLE>
        <H1>Oriv Bookmarks</H1>
        <DL><p>
        \(links)
        </DL><p>
        """.utf8)
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    private static func decodeEntities(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt);"#) else { return value }
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            let entity = (value as NSString).substring(with: match.range(at: 1))
            let replacements = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
            let decoded: String?
            if entity.hasPrefix("#") {
                let number = entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16) : UInt32(entity.dropFirst())
                decoded = number.flatMap(UnicodeScalar.init).map(String.init)
            } else { decoded = replacements[entity] }
            if let decoded, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: decoded) }
        }
        return result
    }
}
