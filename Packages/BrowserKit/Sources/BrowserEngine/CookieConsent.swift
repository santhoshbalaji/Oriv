import Foundation
import JavaScriptCore
import WebKit

@MainActor final class CookieConsent: NSObject, WKScriptMessageHandlerWithReply {
    static let world = WKContentWorld.world(name: "OrivCookieConsent")
    static let handler = "orivConsent"
    private static let prefix = "// Oriv cookie consent policy\n"
    private static let cmpDomains = [
        "sp-prod.net", "privacy-mgmt.com", "consentmanager.net", "trustarc.com", "truste.com",
        "cookielaw.org", "cookiebot.com", "quantcast.mgr.consensu.org", "privacy-center.org"
    ]
    private static let privacyRoot = Bundle.module.url(forResource: "Privacy", withExtension: nil)
    static let resourceRoot = privacyRoot?.appendingPathComponent("Autoconsent", isDirectory: true)

    struct Manifest: Decodable {
        let version: String
        let files: [String: String]
    }

    private struct BundleData {
        let runtime: String
        let source: String
    }

    private static let bundle: BundleData? = {
        guard let root = resourceRoot, let privacyRoot,
              let manifestData = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.version == "18.9.0" else { return nil }
        func verified(_ name: String) -> String? {
            guard let digest = manifest.files[name],
                  let bytes = try? Data(contentsOf: root.appendingPathComponent(name)),
                  BundledPrivacyRules.digest(bytes) == digest else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
        guard let runtime = verified("autoconsent.cjs.js"), let rules = verified("compact-rules.json"),
              let bridge = try? String(contentsOf: privacyRoot.appendingPathComponent("autoconsent-oriv.js"), encoding: .utf8) else { return nil }
        return BundleData(runtime: runtime, source: """
            (() => {
                const module = { exports: {} };
                \(runtime)
                const indexedRules = \(rules);
                \(bridge)
            })();
            """)
    }()

    // Reviewed detection and rejection operations. The CJS module is executed
    // without any DOM or native bridge to extract these functions as source.
    private static let snippets: [String: String] = {
        let allowed = [
            "EVAL_COOKIEBOT_1", "EVAL_COOKIEBOT_2", "EVAL_COOKIEBOT_3", "EVAL_COOKIEBOT_4", "EVAL_COOKIEBOT_5",
            "EVAL_DIDOMI_OPT_OUT", "EVAL_DIDOMI_TEST", "EVAL_ONETRUST_1",
            "EVAL_CONSENTMANAGER_1", "EVAL_CONSENTMANAGER_2", "EVAL_CONSENTMANAGER_3",
            "EVAL_CONSENTMANAGER_5", "EVAL_CONSENTMANAGER_NCMP_REJECT",
            "EVAL_COOKIEINFORMATION_0", "EVAL_FIDES_DETECT_POPUP", "EVAL_IFRAME_SHOWN",
            "EVAL_OSANO_DETECT", "EVAL_SOURCEPOINT_RESTORE_SCROLL", "EVAL_TRUSTARC_FRAME_TEST",
            "EVAL_TRUSTARC_TOP"
        ]
        guard let bundle, let context = JSContext(),
              let exports = context.evaluateScript("""
              (() => { const module = { exports: {} }; \(bundle.runtime)
              return module.exports.evalSnippets; })()
              """), !exports.isUndefined else { return [:] }
        return allowed.reduce(into: [:]) { result, name in
            if let function = exports.forProperty(name), !function.isUndefined, let source = function.toString() {
                result[name] = source
            }
        }
    }()

    private struct CosmeticRule: Decodable {
        let trigger: [String: Filter]
        let action: Action
        struct Action: Decodable { let selector: String }

        enum Filter: Decodable {
            case patterns([String]), other
            init(from decoder: Decoder) throws {
                if let patterns = try? decoder.singleValueContainer().decode([String].self) { self = .patterns(patterns) }
                else { self = .other }
            }
        }

        func matches(top: URL, host: String) -> Bool {
            for (condition, filter) in trigger {
                guard case .patterns(let patterns) = filter else { continue }
                switch condition {
                case "if-domain", "unless-domain":
                    let matches = patterns.contains { pattern in
                        guard pattern.hasPrefix("*") else { return pattern == host }
                        let domain = pattern.dropFirst()
                        return host == domain || host.hasSuffix("." + domain)
                    }
                    if matches != (condition == "if-domain") { return false }
                case "if-top-url", "unless-top-url":
                    let matches = patterns.contains { top.absoluteString.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
                    if matches != (condition == "if-top-url") { return false }
                default: return false
                }
            }
            return true
        }
    }

    private static let fallbackRules: [CosmeticRule] = {
        guard let resource = try? BundledPrivacyRules.resources().first(where: { $0.key == "cookies-cosmetics-0" }),
              let json = try? resource.read() else { return [] }
        return (try? JSONDecoder().decode([CosmeticRule].self, from: Data(json.utf8))) ?? []
    }()

    static var isAvailable: Bool { bundle != nil }

    weak var tab: BrowserTab?
    init(tab: BrowserTab) { self.tab = tab }

    static func update(_ controller: WKUserContentController, enabled: Bool) {
        let source = enabled ? bundle?.source : nil
        let scripts = controller.userScripts
        let current = scripts.filter { $0.source.hasPrefix(prefix) }.count
        if current == (source == nil ? 0 : 2) { return }
        if current > 0 {
            controller.removeAllUserScripts()
            scripts.filter { !$0.source.hasPrefix(prefix) }.forEach(controller.addUserScript)
        }
        if let source {
            controller.addUserScript(WKUserScript(source: prefix + source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
            let domains = cmpDomains.map { "'\($0)'" }.joined(separator: ",")
            let frameProbe = """
                (() => {
                    if (window === window.top || !/^https?:$/.test(location.protocol)) return;
                    const host = location.hostname.replace(/\\.$/, '');
                    if ([\(domains)].some(domain => host === domain || host.endsWith('.' + domain))) {
                        void window.webkit.messageHandlers.orivConsent.postMessage({ type: 'startFrame' }).catch(() => {});
                    }
                })();
                """
            controller.addUserScript(WKUserScript(source: prefix + frameProbe, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let tab, let view = message.webView, let top = view.url, let topHost = AdBlocker.host(for: top),
              let frameHost = AdBlocker.host(for: message.frameInfo.request.url),
              tab.allowsCookieRejection(on: top), tab.allowsCookieRejection(on: message.frameInfo.request.url),
              message.frameInfo.isMainFrame || Self.cmpDomains.contains(where: { frameHost == $0 || frameHost.hasSuffix("." + $0) }),
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return (false, nil) }

        let frame = message.frameInfo
        switch type {
        case "startFrame" where !frame.isMainFrame:
            if let source = Self.bundle?.source {
                _ = try? await view.evaluateJavaScript(source, in: frame, contentWorld: Self.world)
            }
        case "eval":
            guard let name = body["snippet"] as? String, let source = Self.snippets[name] else { return (false, nil) }
            let result = try? await view.callAsyncJavaScript("return Boolean((\(source))());",
                arguments: [:], in: frame, contentWorld: .page)
            return (result as? Bool ?? false, nil)
        case "hide":
            let selectors = Self.fallbackRules.filter { $0.matches(top: top, host: topHost) }.map { $0.action.selector }
            let result = await applyFallback(selectors, to: view, frame: frame)
            if result, view.url == top, tab.cookieBannerResult == nil {
                tab.cookieBannerResult = "Hidden only"
            }
        case "handled":
            if let cmp = body["cmp"] as? String, cmp.count <= 100, view.url == top {
                tab.cookieBannerResult = "Opt-out rule completed (\(cmp))"
            }
        default: break
        }
        return (true, nil)
    }

    private func applyFallback(_ selectors: [String], to view: WKWebView, frame: WKFrameInfo) async -> Bool {
        do {
            let value = try await view.callAsyncJavaScript("""
                const sheet = new CSSStyleSheet();
                sheet.replaceSync(selectors.map(selector => selector + '{display:none!important}').join('\\n'));
                document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
                \(CookieBannerRestoration.source)
                return Array.from(sheet.cssRules).some(rule => rule.selectorText && document.querySelector(rule.selectorText));
                """, arguments: ["selectors": selectors], in: frame, contentWorld: Self.world)
            return value as? Bool ?? false
        } catch {
            #if DEBUG
            print("Oriv: cookie fallback CSS could not be applied: \(error.localizedDescription)")
            #endif
            return false
        }
    }
}
