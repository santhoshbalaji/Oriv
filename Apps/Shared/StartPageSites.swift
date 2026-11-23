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

    private var columns: [GridItem] {
        #if os(macOS)
        if typeSize.isAccessibilitySize {
            return [GridItem(.adaptive(minimum: 240), spacing: OrivSpacing.small)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: OrivSpacing.small), count: 4)
        #else
        let count = typeSize.isAccessibilitySize ? 1 : 3
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: OrivSpacing.small), count: count)
        #endif
    }

    var body: some View {
        #if os(macOS)
        let bookmarkLimit = 8
        #else
        let bookmarkLimit = 6
        #endif
        let bookmarks = Array(session.bookmarks.prefix(bookmarkLimit))
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
            SectionHeader(title: title, kind: .content, showAll: showAll)
            LazyVGrid(columns: columns, alignment: .leading, spacing: OrivSpacing.small) {
                ForEach(items, id: \.1) { title, url in
                    let name = title.isEmpty ? (url.host ?? "Saved page") : title
                    Button { open(url) } label: {
                        VStack(spacing: OrivSpacing.xs) {
                            SiteIdentity(url: url, size: 36, cachedOnly: true)
                            Text(name).font(OrivType.detail).multilineTextAlignment(.center)
                                #if os(macOS)
                                .lineLimit(2, reservesSpace: true)
                                #else
                                .modifier(StartTileTitleLines(accessibilitySize: typeSize.isAccessibilitySize))
                                .fixedSize(horizontal: false, vertical: true)
                                #endif
                        }
                        .padding(OrivSpacing.small)
                        .frame(maxWidth: .infinity, minHeight: OrivLayout.tileMinimumHeight)
                        .foregroundStyle(theme.text)
                        .contentShape(.rect(cornerRadius: OrivRadius.tile))
                    }
                    #if os(macOS)
                    .orivButton(.quiet)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .modifier(Tile(kind: .site))
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

#if os(iOS)
private struct StartTileTitleLines: ViewModifier {
    let accessibilitySize: Bool

    func body(content: Content) -> some View {
        if accessibilitySize {
            content
        } else {
            content.lineLimit(3, reservesSpace: true)
        }
    }
}
#endif
