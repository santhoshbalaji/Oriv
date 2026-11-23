import BrowserCore
import BrowserEngine
import SwiftUI

/// Command content for the native page menu.
/// Presentation stays with BrowserWindow so a dismissed menu can open a popover.
struct MacPageActions: View {
    @Bindable var controller: BrowserController
    var profiles: BrowserProfiles? = nil
    var findOnPage: () -> Void
    var showSitePrivacy: () -> Void
    var fillPassword: (() -> Void)?
    var showPasswordsGuide: () -> Void
    var requestSiteForget: (BrowserSite) -> Void
    private var session: BrowserSession { controller.session }
    private var tab: BrowserTab? { session.selectedTab }

    var body: some View {
        Group {
            Section {
                Button(session.isBookmarked(tab?.url) ? "Remove Bookmark" : "Add Bookmark",
                       systemImage: session.isBookmarked(tab?.url) ? "bookmark.fill" : "bookmark") { controller.saveCurrentPage() }
                    .disabled(tab?.url == nil || tab?.isPrivate == true)
                if let url = tab?.url {
                    Button("Copy Link", systemImage: "doc.on.doc") { PrivacyPasteboard.copy(url) }
                    Button("Copy Original Link", systemImage: "link") { PrivacyPasteboard.copy(url, original: true) }
                }
                Button("Find on Page", systemImage: "magnifyingglass") { findOnPage() }
                    .disabled(tab?.url == nil)
            }
            Section {
                // Plain rows: a palette hides the reset label in macOS menus.
                Button("Zoom In", systemImage: "plus.magnifyingglass") { tab?.zoomIn() }
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { tab?.zoomOut() }
                Button("Actual Size (\(Int(((tab?.pageZoom ?? 1) * 100).rounded()))%)", systemImage: "1.magnifyingglass") { tab?.resetZoom() }
                    .disabled(tab?.pageZoom == nil || tab?.pageZoom == 1)
            }
            .disabled(tab?.url == nil)
            Section {
                Button("New Tab", systemImage: "plus") { controller.newTab() }
                Button("New Private Tab", systemImage: "eyeglasses") { controller.newTab(isPrivate: true) }
                Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { session.reopenClosedTab() }.disabled(!session.canReopenTab)
                if controller.downloads.hasActiveDownloads {
                    Button("Downloads in Progress", systemImage: "arrow.down.circle") { controller.library = .downloads }
                }
            }
            Section {
                if let profiles { SendPageMenu(continuity: profiles.continuity, session: session, profile: controller.profile) }
                Button("Read Page Text", systemImage: "doc.text") { controller.openReader() }.disabled(tab?.url == nil)
                Button(OrivStrings.sitePrivacy, systemImage: "shield.lefthalf.filled") { showSitePrivacy() }
                if let site = session.forgettableSite(for: tab) {
                    Button("Forget This Site…", systemImage: "trash", role: .destructive) { requestSiteForget(site) }
                }
                if let fillPassword {
                    Button("AutoFill from Passwords", systemImage: "key.fill", action: fillPassword)
                } else {
                    Button("Password AutoFill Help", systemImage: "key", action: showPasswordsGuide)
                }
            }
        }
    }

}
