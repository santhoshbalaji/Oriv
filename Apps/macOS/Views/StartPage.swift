import SwiftUI

/// A quiet new-tab page. The toolbar field is the only search affordance.
struct StartPage: View {
    @Environment(\.browserTheme) private var theme
    @Bindable var controller: BrowserController
    let isPrivate: Bool

    var body: some View {
        ScrollView {
            Group {
                if isPrivate {
                    privateExplanation
                } else {
                    StartPageSites(session: controller.session, emptyMessage: "Search or enter an address above (⌘L)",
                        open: { controller.session.openSavedPage($0) }, showBookmarks: { controller.library = .bookmarks },
                        showHistory: { controller.library = .history })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OrivSpacing.xxl)
            .frame(maxWidth: OrivLayout.contentMaxWidth)
            .padding(.vertical, OrivSpacing.xxl + OrivSpacing.xl)
            .frame(maxWidth: .infinity)
        }
    }

    private var privateExplanation: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.small) {
            OrivBanner("Private browsing", tone: .privateBrowsing)
                .accessibilityAddTraits(.isHeader)
            Text("Private tabs aren’t saved or added to history. Cookies and website data are discarded when the last tab sharing them closes. Websites and your network can still see your activity, and downloaded files stay on your Mac.")
                .font(OrivType.body).foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, OrivSpacing.large)
                .padding(.bottom, OrivSpacing.large)
        }
        .background(theme.privateWash, in: .rect(cornerRadius: OrivRadius.panel))
        .clipShape(.rect(cornerRadius: OrivRadius.panel))
    }
}
