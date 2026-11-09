import BrowserCore
import SwiftUI

/// A quiet new-tab page. The toolbar field is the only search affordance.
struct StartPage: View {
    @Environment(\.browserTheme) private var theme
    @Bindable var controller: BrowserController
    let isPrivate: Bool

    private var bookmarks: [Bookmark] { Array(controller.savedBookmarks.prefix(6)) }
    /// Recent pages that are not already shown as bookmarks.
    private var recent: [HistoryEntry] {
        let shown = Set(bookmarks.map(\.url))
        return Array(controller.session.history.filter { !shown.contains($0.url) }.prefix(5))
    }

    var body: some View {
        let context = URLDisplay.Context(bookmarks.map { ($0.title, $0.url) } + recent.map { ($0.title, $0.url) })
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                if isPrivate {
                    privateExplanation
                } else if bookmarks.isEmpty && recent.isEmpty {
                    emptyState
                } else {
                    if !bookmarks.isEmpty {
                        section("Bookmarks", showAll: .bookmarks) {
                            ForEach(bookmarks) { row($0.title, url: $0.url, context: context) }
                        }
                    }
                    if !recent.isEmpty {
                        section("Recent", showAll: .history) {
                            ForEach(recent) { row($0.title, url: $0.url, context: context) }
                        }
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, OrivSpacing.xxl).padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .background(theme.page)
    }

    private var emptyState: some View {
        BrowserEmptyState("Search or enter a website above (⌘L)")
            .padding(.top, 96)
    }

    private var privateExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Private browsing", systemImage: "eyeglasses").font(OrivType.body.weight(.semibold)).foregroundStyle(theme.privateAccent)
            Text("Private tabs aren’t saved or added to history. Their cookies and website data are erased when the last private tab closes. Websites and your network can still see your activity, and downloaded files stay on your Mac.")
                .font(OrivType.body).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 80)
    }

    private func section<Rows: View>(_ title: String, showAll: LibrarySection, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: OrivSpacing.xs) {
            HStack {
                Text(title).font(OrivType.detail.weight(.medium)).foregroundStyle(theme.secondaryText).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Show All") { controller.library = showAll }.buttonStyle(.plain)
                    .font(OrivType.detail).foregroundStyle(theme.secondaryText)
            }.padding(.horizontal, OrivSpacing.small).padding(.bottom, OrivSpacing.xs)
            rows()
        }
    }

    private func row(_ title: String, url: URL, context: URLDisplay.Context) -> some View {
        Button { controller.session.openSavedPage(url) } label: {
            PageRowContent(title: title, url: url, context: context)
                .padding(.horizontal, OrivSpacing.small).frame(height: 36).contentShape(Rectangle())
        }.buttonStyle(ContentButtonStyle()).help(url.absoluteString)
    }
}
