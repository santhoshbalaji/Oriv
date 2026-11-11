import AppKit
import BrowserCore
import BrowserEngine
import WebKit

/// Intercepts only trusted link-context gestures in an isolated world. All other
/// WebKit menus (text, forms, media) keep their native behavior.
@MainActor final class MacPrivacyLinkMenu: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    weak var session: BrowserSession?
    private var destination: URL?
    private var revision = 0
    init(tab: BrowserTab, session: BrowserSession, view: WKWebView) {
        self.tab = tab; self.session = session
        super.init()
        let world = WKContentWorld.world(name: "OrivLinkMenu")
        view.configuration.userContentController.add(self, contentWorld: world, name: "privacyLink")
        view.configuration.userContentController.addUserScript(WKUserScript(source: """
        document.addEventListener('contextmenu', event => {
            const link = event.target.closest && event.target.closest('a[href]');
            if (!event.isTrusted || !link || !/^https?:/.test(link.href)) return;
            event.preventDefault();
            window.webkit.messageHandlers.privacyLink.postMessage({url:link.href});
        }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab, let session, session.isProfileActive, session.selectedTabID == tab.id,
              let view = message.webView, view.window != nil,
              let raw = (message.body as? [String: Any])?["url"] as? String, raw.count <= 32_768,
              let url = URL(string: raw), AddressResolver.isWebURL(url) else { return }
        destination = url; revision = tab.documentRevision
        let menu = NSMenu(title: url.host ?? "Link")
        for (title, selector) in [("Open Link", #selector(openLink)), ("Open in New Tab", #selector(openTab)), ("Open in Background", #selector(openBackground)), ("Open in Private Tab", #selector(openPrivate)), ("Download Linked File", #selector(downloadLink)), ("Copy Link", #selector(copyLink)), ("Copy Original Link", #selector(copyOriginal)), ("Share Link", #selector(shareLink))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: view.convert(view.window!.mouseLocationOutsideOfEventStream, from: nil), in: view)
    }
    private var current: URL? { tab?.documentRevision == revision && session?.isProfileActive == true && session?.selectedTabID == tab?.id ? destination : nil }
    @objc private func openLink() { if let url = current { tab?.navigate(to: url) } }
    @objc private func openTab() { if let url = current { session?.addTab(url: url, isPrivate: tab?.isPrivate ?? false) } }
    @objc private func openBackground() { if let url = current { session?.addTab(url: url, isPrivate: tab?.isPrivate ?? false, select: false).activate() } }
    @objc private func openPrivate() { if let url = current { session?.addTab(url: url, isPrivate: true) } }
    @objc private func downloadLink() {
        if let url = current, let tab { tab.webView.startDownload(using: URLRequest(url: url)) { [weak tab] download in tab?.onDownload?(download) } }
    }
    @objc private func copyLink() { if let url = current { PrivacyPasteboard.copy(url) } }
    @objc private func copyOriginal() { if let url = current { PrivacyPasteboard.copy(url, original: true) } }
    @objc private func shareLink() {
        if let url = current, let view = tab?.webView {
            NSSharingServicePicker(items: [URLCleaner.clean(url)]).show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }
}
