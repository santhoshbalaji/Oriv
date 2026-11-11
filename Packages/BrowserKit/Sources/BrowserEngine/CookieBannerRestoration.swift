import Foundation
import WebKit

/// Original, narrowly scoped scroll restoration. No clicks, cookie writes or consent claims.
/// Only known CMP lock classes with a confirmed, CSS-hidden banner qualify.
enum CookieBannerRestoration {
    static let source = """
    (() => {
      const id = 'oriv-cookie-scroll-restoration';
      if (document.getElementById(id)) return;
      const restore = () => {
        if (document.getElementById(id)) return;
        const oneTrust = document.querySelector('#onetrust-banner-sdk');
        const cookieBot = document.querySelector('#CybotCookiebotDialog');
        const hidden = el => el && getComputedStyle(el).display === 'none';
        let css = '';
        if (hidden(oneTrust)) css += 'html.ot-overflow-hidden,body.ot-overflow-hidden{overflow:auto!important}';
        if (hidden(cookieBot)) css += 'html.CybotCookiebotDialogActive,body.CybotCookiebotDialogActive{overflow:auto!important}';
        if (!css) return;
        const style = document.createElement('style'); style.id = id; style.textContent = css;
        document.documentElement.appendChild(style);
      };
      restore();
      let checks = 0;
      const observer = new MutationObserver(() => { if (++checks <= 50) restore(); else observer.disconnect(); });
      observer.observe(document.documentElement, {childList:true,subtree:true});
      setTimeout(() => observer.disconnect(), 10000);
    })();
    """
    @MainActor static func update(_ controller: WKUserContentController, enabled: Bool) {
        let kept = controller.userScripts.filter { $0.source != source }
        controller.removeAllUserScripts()
        kept.forEach { controller.addUserScript($0) }
        if enabled { controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .world(name: "OrivCookieRestoration"))) }
    }
}
