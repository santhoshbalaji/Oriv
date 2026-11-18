import BrowserCore
import Foundation

/// Serialized off-main construction and incremental updates. No URL, title or
/// query leaves this actor for a remote suggestion provider.
public actor AddressSuggestionIndex {
    private var regular = LocalSuggestionIndex()
    private var revision = -1
    public init() {}
    public func matches(_ query: String, history: [HistoryEntry], bookmarks: [Bookmark], revision: Int,
                        tabs: [BrowserSuggestion], isPrivate: Bool) -> [BrowserSuggestion] {
        if isPrivate { return LocalSuggestionIndex().matches(query, tabs: tabs) }
        if revision > self.revision {
            regular.update(history: history, bookmarks: bookmarks); self.revision = revision
        }
        return regular.matches(query, tabs: tabs)
    }
}
