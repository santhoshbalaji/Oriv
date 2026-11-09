import Foundation

/// Describes exactly what submitting the address field will do, before it happens.
public enum AddressAction {
    private static func destination(for input: String, engine: SearchEngine) -> (url: URL, isSearch: Bool)? {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = try? AddressResolver.resolve(query, searchEngine: engine) else { return nil }
        return (url, url == engine.searchURL(query))
    }

    /// `compact` drops the engine name so the query itself survives very large text sizes.
    public static func title(for input: String, engine: SearchEngine, compact: Bool = false) -> String {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destination = destination(for: query, engine: engine) else { return "Open address or search" }
        if destination.isSearch { return compact ? "Search “\(query)”" : "Search \(engine.rawValue) for “\(query)”" }
        let url = destination.url
        // The exact host (no "www." trimming): this line promises where Return goes.
        guard let host = url.host(percentEncoded: false) else { return "Go to \(url.absoluteString)" }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path(percentEncoded: false) == "/" ? "" : url.path(percentEncoded: false)
        return "Go to \(host)\(port)\(path)"
    }

    public static func symbol(for input: String, engine: SearchEngine) -> String {
        destination(for: input, engine: engine)?.isSearch == false ? "arrow.up.right" : "magnifyingglass"
    }
}
