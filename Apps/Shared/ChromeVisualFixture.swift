import Foundation

/// Synthetic visual fixtures are compiled out of release builds and never use real accounts.
enum ChromeVisualFixture {
    static var mode: String? {
        #if DEBUG
        #if os(macOS)
        if let scene = ProcessInfo.processInfo.environment["ORIV_GLASS_SCENE"], !scene.isEmpty { return scene }
        #elseif targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--oriv-glass-fixture"), i + 1 < args.count { return args[i + 1] }
        #endif
        #endif
        return nil
    }
    #if DEBUG && targetEnvironment(simulator)
    static var liveURL: URL? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--oriv-chrome-url"), i + 1 < args.count,
           let url = URL(string: args[i + 1]), url.scheme == "https" { return url }
        return nil
    }
    #endif
    #if DEBUG
static func html(dark: Bool = false, card: Int = 0) -> String {
    let bg = dark ? "#111111" : "#fbfbf9", fg = dark ? "#f5f5f5" : "#1b2024", muted = dark ? "#b4b7bd" : "#535d65"
    let titles = ["Designing calm interfaces", "A little room to think", "Materials and meaning", "A quieter kind of focus"]
    return """
    <!doctype html><html><head><title>\(titles[card % titles.count])</title><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="\(bg)"><meta name="color-scheme" content="\(dark ? "dark" : "light")"><style>
    *{box-sizing:border-box}body{margin:0;background:\(bg);color:\(fg);font:18px/1.68 -apple-system,BlinkMacSystemFont,sans-serif}header{max-width:980px;margin:auto;padding:25px 36px 22px;display:flex;justify-content:space-between;border-bottom:1px solid \(dark ? "#303030" : "#dedfdc");font-size:14px}header strong{font-size:17px;font-weight:600}header span{color:\(muted)}main{max-width:980px;margin:auto;padding:62px 36px 100px}.meta{font-size:14px;color:\(muted)}h1{font:500 58px/1.08 ui-serif,Georgia,serif;letter-spacing:-1.8px;max-width:720px;margin:20px 0 24px}.dek{font-size:22px;line-height:1.5;color:\(muted);max-width:690px}.landscape{height:320px;position:relative;overflow:hidden;margin:38px 0 12px;border-radius:5px;background:radial-gradient(ellipse at 72% 18%,#efc997 0%,transparent 38%),linear-gradient(160deg,#b8cbd0 8%,#88a9b0 40%,#587e8e 63%,#284b62 100%)}.landscape:before{content:'';position:absolute;left:-8%;bottom:-75px;width:80%;height:260px;transform:rotate(-12deg);border-radius:50%;background:linear-gradient(120deg,#5e8190,#263f52)}.landscape:after{content:'';position:absolute;right:-12%;bottom:-90px;width:85%;height:280px;border-radius:50%;transform:rotate(12deg);background:linear-gradient(140deg,#a8b7ad,#506e71 60%,#264657)}figcaption{font-size:12px;color:\(muted)}article{max-width:690px;margin:42px auto}h2{font:500 32px/1.2 ui-serif,Georgia,serif;margin-top:40px}p{margin:0 0 24px}blockquote{font:400 30px/1.4 ui-serif,Georgia,serif;border-left:2px solid #8aa7b3;margin:40px 0;padding-left:28px}a{color:\(dark ? "#88aaff" : "#2455b0")}@media(max-width:600px){header{padding:20px 24px}header span{font-size:12px}main{padding:36px 24px 100px}h1{font-size:42px;letter-spacing:-1px;margin:16px 0 20px}.dek{font-size:19px}.landscape{height:270px;margin-top:28px}article{margin-top:32px}h2{font-size:29px}body{font-size:17px}}
    </style></head><body><header><strong>Fieldnotes</strong><span>Design & everyday life</span></header><main><div class="meta">Interface journal · 8 min read</div><h1>\(titles[card % titles.count])</h1><p class="dek">Make room for what matters. A practical reflection on clarity, attention, and the spaces between.</p><div class="landscape" role="img" aria-label="Synthetic landscape in blue and warm sand gradients"></div><figcaption>A study in light, space, and quiet contrast.</figcaption><article><h2>Clarity begins with less</h2><p>A calm interface gives every element a reason to be there. It lets the page lead, while navigation stays familiar and close at hand. The best details are often the ones we stop noticing.</p><p>Space is more than an absence of content. It gives an idea time to settle, separates one thought from the next, and helps us find our place without having to search.</p><blockquote>Let the content be the destination. Let the interface be the way.</blockquote><h2>A material with a purpose</h2><p>Translucent controls can preserve a sense of context as a page moves underneath them. Used with restraint, a material makes the relationship between the page and its controls easy to understand.</p><p>Contrast does the quiet work. A legible label, a consistent symbol, and a generous target reduce the effort of every small decision.</p><div class="landscape"></div><h2>Keep the familiar close</h2><p>Browsing is a rhythm of reading, moving, and returning. Controls should follow that rhythm, stepping back while we read and returning when we need them.</p><p>Good defaults leave room for individual choices. Different profiles, private pages, and different devices should each have a clear place without demanding attention all the time.</p><h2>Leave room to think</h2><p>There is no single recipe for calm. Start with the content, choose a small number of clear signals, and test the result in the moments where people actually use it.</p><p>When a design feels effortless, that ease comes from many careful decisions. The aim is to make those decisions serve the person on the other side of the screen.</p></article></main></body></html>
    """
}


    #endif
}

#if DEBUG
import WebKit
import BrowserCore

/// Opt-in timing evidence in isolated Debug runs. No browsing log in Release.
@MainActor final class ChromeTiming: NSObject, WKScriptMessageHandler {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["ORIV_CHROME_TIMING"] == "1" ||
        ProcessInfo.processInfo.arguments.contains("--oriv-chrome-timing")
    }
    private static var rows: [[String: Any]] = []
    static func event(_ name: String, web: WKWebView?, extra: [String: Any] = [:]) {
        guard enabled else { return }
        var row = extra
        row["event"] = name; row["time"] = Date().timeIntervalSince1970 * 1000
        row["url"] = web?.url?.absoluteString ?? ""; row["web"] = web.map { String(describing: ObjectIdentifier($0)) } ?? ""
        rows.append(row)
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("oriv-chrome-timing.json"), options: .atomic)
        }
    }
    static func install(on web: WKWebView) {
        guard enabled else { return }
        let handler = ChromeTiming()
        web.configuration.userContentController.add(handler, contentWorld: .world(name: "OrivTiming"), name: "chromeTiming")
        web.configuration.userContentController.addUserScript(WKUserScript(source: """
        (() => {
          const send = (event, extra = {}) => window.webkit.messageHandlers.chromeTiming.postMessage({event, time:performance.timeOrigin + performance.now(), href:location.href, ...extra});
          send('documentStart');
          new PerformanceObserver(list => { for (const e of list.getEntries()) send(e.name, {paintTime:performance.timeOrigin + e.startTime}); }).observe({type:'paint', buffered:true});
          document.addEventListener('DOMContentLoaded', () => send('DOMContentLoaded'), {once:true});
          window.addEventListener('load', () => send('load'), {once:true});
        })()
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .world(name: "OrivTiming")))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let values = message.body as? [String: Any], let name = values["event"] as? String else { return }
        Self.event(name, web: message.webView, extra: values)
    }
}
#endif
