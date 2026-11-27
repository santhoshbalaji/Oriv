import BrowserCore
import BrowserEngine
import Observation
import SwiftUI

@MainActor @Observable final class AddressSuggestions {
    var rows: [BrowserSuggestion] = []
    var completion: String?
    var selected: Int?
    var query = ""
    private var generation = 0
    func update(_ query: String, session: BrowserSession, isPrivate: Bool) async {
        generation += 1; let generation = generation
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = trimmed.isEmpty ? nil
            : BrowserSuggestion(title: "Search for ‘\(trimmed)’", url: session.settings.searchEngine.searchURL(trimmed), source: .search)
        self.query = query; selected = nil
        if let search {
            // Keep the previous matches on screen until this query's arrive.
            // Clearing them first collapsed the popover to its search row for
            // a frame on every keystroke. The inline completion is only shown
            // while it still extends the typed text.
            rows = rows.filter { $0.source != .search } + [search]
        } else {
            rows = []; completion = nil
        }
        let matches = await session.indexedSuggestions(for: query, isPrivate: isPrivate)
        guard !Task.isCancelled, generation == self.generation else { return }
        selected = nil
        completion = LocalSuggestionIndex.completion(for: query, matches: matches)
        let order: [BrowserSuggestion.Source] = [.tab, .bookmark, .history]
        rows = order.flatMap { source in matches.filter { $0.source == source } } + (search.map { [$0] } ?? [])
    }
    func move(_ offset: Int) {
        guard !rows.isEmpty else { return }
        selected = min(rows.count - 1, max(0, (selected ?? (offset > 0 ? -1 : rows.count)) + offset))
    }
}

/// Highlights without modifying the original Unicode text or URL.
func suggestionText(_ text: String, query: String) -> Text {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return Text(text) }
    var result = Text("")
    var start = text.startIndex
    while start < text.endIndex, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
        result = Text("\(result)\(Text(String(text[start..<range.lowerBound])))\(Text(String(text[range])).bold())")
        start = range.upperBound
    }
    return Text("\(result)\(Text(String(text[start...])))")
}

struct AddressSuggestionRow: View {
    let suggestion: BrowserSuggestion
    let query: String
    var isPrivate = false
    private var address: String {
        // Suggestions must expose the path/query being chosen, including when
        // several results have the same title and host.
        var components = URLComponents(url: suggestion.url, resolvingAgainstBaseURL: false)
        components?.user = nil; components?.password = nil
        let value = components?.string ?? suggestion.url.absoluteString
        return value.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
    }
    var body: some View {
        let isSearch = suggestion.source == .search
        let title = suggestion.title.isEmpty ? (URLDisplay.site(suggestion.url) ?? "Page") : suggestion.title
        PageRowContent(title: title, url: suggestion.url, layout: isSearch ? .titleOnly : .stacked,
                       iconSize: OrivSpacing.larger, spacing: OrivSpacing.medium, secondaryFont: OrivType.caption,
                       isPrivate: isPrivate, accessory: suggestion.tabID == nil ? .none : .alreadyOpen,
                       highlightedTitle: suggestionText(title, query: query),
                       highlightedAddress: isSearch ? nil : suggestionText(address, query: query),
                       identitySymbol: isSearch ? "magnifyingglass" : nil, compactTitle: true)
            .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}
