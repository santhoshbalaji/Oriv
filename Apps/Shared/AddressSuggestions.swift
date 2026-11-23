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
        self.query = query; selected = nil; completion = nil; rows = []
        let matches = await session.indexedSuggestions(for: query, isPrivate: isPrivate)
        guard !Task.isCancelled, generation == self.generation else { return }
        selected = nil
        completion = LocalSuggestionIndex.completion(for: query, matches: matches)
        let order: [BrowserSuggestion.Source] = [.tab, .bookmark, .history]
        rows = order.flatMap { source in matches.filter { $0.source == source } }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            rows.append(BrowserSuggestion(title: "Search for ‘\(query)’", url: session.settings.searchEngine.searchURL(query), source: .search))
        }
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
    @Environment(\.browserTheme) private var theme
    private var address: String {
        // Suggestions must expose the path/query being chosen, including when
        // several results have the same title and host.
        var components = URLComponents(url: suggestion.url, resolvingAgainstBaseURL: false)
        components?.user = nil; components?.password = nil
        let value = components?.string ?? suggestion.url.absoluteString
        return value.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
    }
    var body: some View {
        HStack(spacing: 10) {
            if suggestion.source == .search { Image(systemName: "magnifyingglass").frame(width: 20).accessibilityHidden(true) }
            else { SiteIdentity(url: suggestion.url, size: 20, isPrivate: isPrivate) }
            VStack(alignment: .leading, spacing: 2) {
                suggestionText(suggestion.title.isEmpty ? (URLDisplay.site(suggestion.url) ?? "Page") : suggestion.title, query: query).foregroundStyle(theme.text).lineLimit(1)
                if suggestion.source != .search {
                    suggestionText(address, query: query)
                        .font(.caption).foregroundStyle(theme.secondaryText).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if suggestion.tabID != nil { SwitchToTabBadge() }
        }.font(OrivType.body).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityCustomContent(Text("Address"), Text(verbatim: suggestion.url.absoluteString))
    }
}
