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
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, OrivSpacing.xxl).padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .background(theme.page)
    }

    private var privateExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Private browsing", systemImage: "eyeglasses").font(OrivType.body.weight(.semibold)).foregroundStyle(theme.privateAccent)
            Text("Private tabs aren’t saved or added to history. Their cookies and website data are erased when the last private tab closes. Websites and your network can still see your activity, and downloaded files stay on your Mac.")
                .font(OrivType.body).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 80)
    }
}
