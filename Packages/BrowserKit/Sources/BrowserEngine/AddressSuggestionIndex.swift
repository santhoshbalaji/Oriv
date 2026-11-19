import BrowserCore
import Foundation

/// Serialized off-main construction and URL-level updates.
public actor AddressSuggestionIndex {
    private var regular = LocalSuggestionIndex()
    private var revision = -1
    public init() {}
    func refreshHistory(from store: VisitHistoryStore?) {
        if let delta = try? store?.suggestionDelta() {
            if delta.replacesHistory { regular.replaceVisits(delta.entries) }
            else { regular.applyVisitDelta(delta.entries, changed: delta.changed) }
        }
    }

    public func matches(_ query: String, store: VisitHistoryStore?, bookmarks: [Bookmark], revision: Int,
                        tabs: [BrowserSuggestion], isPrivate: Bool) -> [BrowserSuggestion] {
        if isPrivate { return LocalSuggestionIndex().matches(query, tabs: tabs) }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        refreshHistory(from: store)
        if revision > self.revision {
            regular.updateBookmarks(bookmarks)
            self.revision = revision
        }
        return regular.matches(query, tabs: tabs)
    }
}
