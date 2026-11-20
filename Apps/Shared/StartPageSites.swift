import BrowserCore
import BrowserEngine
import SwiftUI

/// Mounted only for regular home tabs on either platform.
struct StartPageSites: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: BrowserSession
    let emptyMessage: String
    let open: (URL) -> Void
    let showBookmarks: () -> Void
    let showHistory: () -> Void

    private struct Query: Equatable {
        let session: ObjectIdentifier
        let revision: Int
        let bookmarkURLs: Set<URL>
    }

    @State private var loadedQuery: Query?
    @State private var frequent: [HistoryEntry] = []

    var body: some View {
        let bookmarks = Array(session.bookmarks.prefix(6))
        let query = Query(session: ObjectIdentifier(session), revision: session.historyRevision,
                          bookmarkURLs: Set(bookmarks.map(\.url)))
        let suggestions = loadedQuery == query ? frequent : []
        VStack(alignment: .leading, spacing: OrivSpacing.xl) {
            if bookmarks.isEmpty && suggestions.isEmpty {
                BrowserEmptyState(emptyMessage).padding(.top, 56)
            } else {
                if !bookmarks.isEmpty {
                    section("Bookmarks", id: "homeBookmarks", items: bookmarks.map { ($0.title, $0.url) }, showAll: showBookmarks)
                }
                if !suggestions.isEmpty {
                    section("Frequently Visited", id: "homeFrequent", items: suggestions.map { ($0.title, $0.url) }, showAll: showHistory)
                }
            }
        }
        .task(id: query) {
            let entries = await session.frequentHistory(excluding: query.bookmarkURLs, isPrivate: false)
            guard !Task.isCancelled else { return }
            frequent = entries
            loadedQuery = query
        }
    }

    private func section(_ title: String, id: String, items: [(String, URL)], showAll: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: OrivSpacing.small) {
            HStack {
                Text(title).font(OrivType.detail.weight(.semibold)).foregroundStyle(theme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Show All", action: showAll).font(OrivType.detail)
                    .accessibilityLabel("Show All \(title)")
                    #if os(iOS)
                    .frame(minHeight: 44)
                    #endif
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 100),
                                         spacing: OrivSpacing.small)], alignment: .leading, spacing: OrivSpacing.small) {
                ForEach(items, id: \.1) { title, url in
                    let name = title.isEmpty ? (url.host ?? "Saved page") : title
                    Button { open(url) } label: {
                        VStack(spacing: OrivSpacing.xs) {
                            SiteIdentity(url: url, size: 36, cachedOnly: true)
                            Text(name).font(OrivType.detail).lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
                        }
                        .padding(OrivSpacing.small)
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .foregroundStyle(theme.text)
                        .background(theme.surface, in: .rect(cornerRadius: OrivRadius.medium))
                        .contentShape(.rect(cornerRadius: OrivRadius.medium))
                    }
                    #if os(macOS)
                    .buttonStyle(ContentButtonStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityLabel(name)
                    .accessibilityHint(url.host ?? "")
                    .accessibilityIdentifier("\(id)-tile")
                    .contextMenu { Button("Open in New Tab") { session.openSavedPage(url, inNewTab: true) } }
                    #if os(macOS)
                    .help(url.absoluteString)
                    #endif
                }
            }
        }
        .accessibilityIdentifier(id)
        #if os(macOS)
        .browserGeometryMarker(id)
        #endif
    }
}
