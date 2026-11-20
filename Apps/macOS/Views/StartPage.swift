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
                    StartPageSites(session: controller.session, emptyMessage: "Search or enter a website above (⌘L)",
                        open: { controller.session.openSavedPage($0) }, showBookmarks: { controller.library = .bookmarks },
                        showHistory: { controller.library = .history })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: 640)
            .padding(.horizontal, OrivSpacing.xxl).padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .background(theme.page)
    }

    private var privateExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Private browsing").foregroundStyle(theme.text)
            } icon: {
                Image(systemName: "eyeglasses").foregroundStyle(theme.privateAccent)
            }.font(OrivType.title)
            Text("Private tabs aren’t saved or added to history. Cookies and website data are discarded when the last tab sharing them closes. Websites and your network can still see your activity, and downloaded files stay on your Mac.")
                .font(OrivType.body).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 80)
    }
}
