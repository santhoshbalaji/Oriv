import SwiftUI
import WebKit
import BrowserCore
import BrowserEngine

#if os(macOS)
private typealias PlatformColor = NSColor
#else
private typealias PlatformColor = UIColor
#endif

/// Window-local Safari 26 style viewport-edge colour extension, using public APIs.
@MainActor @Observable final class PageChrome {
    static let foregroundThreshold = sqrt(1.05 * 0.05) - 0.05
    var color: Color = Theme.t3Code.canvas
    private(set) var isDark = true
    private(set) var animatesColor = false
    private(set) var hasScrolled = false
    /// Keep the canvas/header extension at the top; otherwise let native content
    /// and the system scroll edge supply the backdrop. Private pages stay opaque.
    var showsContentUnderChrome: Bool { hasScrolled && sampledTop == nil && !privatePage }
    private(set) var luminance = 0.0
    private(set) var sampledTop: ChromeColor?
    @ObservationIgnored private var bodyBackground: ChromeColor?
    @ObservationIgnored private var htmlBackground: ChromeColor?
    @ObservationIgnored private var dimmingLayer = false
    #if DEBUG
    private(set) var sampleCount = 0
    static var diagnosticObserver: ((PageChrome) -> Void)?
    @ObservationIgnored private var diagnosticFrames: [[String: Any]] = []
    @ObservationIgnored private var diagnosticValues: [String: Any] = [:]
    #endif
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var lastSample = Date.distantPast
    @ObservationIgnored private var sampleRevision = 0
    @ObservationIgnored private var privatePage = false
    @ObservationIgnored private var installed = false
    @ObservationIgnored private var navigationPainting = true
    @ObservationIgnored private var documentID = 0.0
    @ObservationIgnored private var lastScrollTime = 0.0
    @ObservationIgnored private var navigationSeed: (key:String, color:ChromeColor)?
    @ObservationIgnored private var remembered: [String: ChromeColor] = [:]
    @ObservationIgnored private var navigationObservers: [NSObjectProtocol] = []

    /// Install before load, including window.open and background tabs. The script
    /// is idempotent and uses an isolated world; it never reads page text/images.
    static func install(on web: WKWebView) {
        let controller = web.configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source == observerScript }) else { return }
        controller.addUserScript(WKUserScript(source: observerScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: contentWorld))
    }
    private func beginNavigation() {
        resetTransitions()
        generation += 1; sampledTop = nil; bodyBackground = nil; htmlBackground = nil
        dimmingLayer = false; hasScrolled = false; installed = false; navigationPainting = true
        animatesColor = false; sampleTask?.cancel(); sampleTask = nil
        documentID = 0; lastScrollTime = 0
        navigationSeed = nil
        if !privatePage, let key = cacheKey(webView?.url), let cached = remembered[key] { navigationSeed = (key,cached) }
        applyRemembered()
    }
    /// Fragment changes stay in the same document. WebKit can report the
    /// native URL after the isolated-world observer has already seen pushState.
    static func matchesDocument(_ href: String?, url: URL?) -> Bool {
        guard let href, let url, var page = URLComponents(string: href),
              var native = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        page.fragment = nil; native.fragment = nil
        return page.url == native.url
    }

    private func cacheKey(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        return parts.string
    }
    @discardableResult private func applyRemembered() -> Bool {
        guard !privatePage, let key = cacheKey(webView?.url), let rgb = remembered[key] else { return false }
        apply(rgb); return true
    }
    @ObservationIgnored private var scrollRevision = 0
    @ObservationIgnored private var scrollState = ChromeScrollState()
    @ObservationIgnored private var scrollTask: Task<Void, Never>?
    private struct Band: Equatable, Sendable {
        let edge: ChromeColor?
        let body: ChromeColor?
        let html: ChromeColor?
        let underPage: ChromeColor?
        let dimming: Bool
    }
    @ObservationIgnored private var stableBand = ChromeStableValue<Band>()
    @ObservationIgnored private var bandTask: Task<Void, Never>?
    private static let contentWorld = WKContentWorld.world(name: "OrivPageChrome")
    #if DEBUG
    @ObservationIgnored private var timingObservers: [NSObjectProtocol] = []
    #endif
    var foreground: Color { isDark ? .white : .black }

    func observe(_ view: WKWebView?, isPrivate: Bool = false) {
        sampleTask?.cancel(); sampleTask = nil
        resetTransitions()
        if let old = webView {
            old.configuration.userContentController.removeScriptMessageHandler(forName: "chromeEdge", contentWorld: Self.contentWorld)
            old.evaluateJavaScript("window.__orivChromeStop?.(); void 0", in: nil, in: Self.contentWorld) { _ in }
        }
        #if DEBUG
        timingObservers.forEach(NotificationCenter.default.removeObserver); timingObservers.removeAll()
        if let view { for (name, event) in [(BrowserTab.navigationStarted, "navigationStart"), (BrowserTab.navigationCommitted, "commit")] {
            timingObservers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak view] _ in
                MainActor.assumeIsolated { ChromeTiming.event(event, web: view) }
            })
        } }
        #endif
        navigationObservers.forEach(NotificationCenter.default.removeObserver); navigationObservers.removeAll()
        observations.removeAll()
        generation += 1; sampledTop = nil; bodyBackground = nil; htmlBackground = nil; dimmingLayer = false; hasScrolled = false; installed = false
        privatePage = isPrivate; webView = view
        navigationPainting = true; animatesColor = false; documentID = 0; lastScrollTime = 0; navigationSeed = nil
        guard let view else { apply(Self.rgba(PlatformColor(Theme.t3Code.canvas))!); return }
        Self.install(on: view)
        navigationObservers.append(NotificationCenter.default.addObserver(forName: BrowserTab.navigationStarted, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginNavigation() }
        })
        view.configuration.userContentController.add(PageChromeScrollHandler(owner: self), contentWorld: Self.contentWorld, name: "chromeEdge")
        observations = [
            view.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh(); self?.requestSample() }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, change in
                let loading = change.newValue ?? false
                Task { @MainActor [weak self] in
                    guard let self, self.webView === view else { return }
                    if loading { self.beginNavigation() }
                    self.refresh(); self.requestSample()
                }
            },
            view.observe(\.url, options: [.old,.new]) { [weak self] view, change in
                let old = change.oldValue ?? nil, next = change.newValue ?? nil
                Task { @MainActor [weak self] in
                    guard let self, self.webView === view else { return }
                    if !view.isLoading && self.cacheKey(old) != self.cacheKey(next) { self.beginNavigation() }
                    self.refresh(); self.requestSample()
                }
            }
        ]
        refresh(); requestSample()
    }

    func contrasting(_ candidate: Color) -> Color {
        guard let rgb = Self.rgba(PlatformColor(candidate)) else { return foreground }
        let value = rgb.luminance
        return (max(value, luminance) + 0.05) / (min(value, luminance) + 0.05) >= 4.5 ? candidate : foreground
    }

    /// Called after native geometry/appearance changes too, including obscured insets.
    func requestSample() {
        guard let webView, webView.url != nil, !privatePage else { return }
        sampleTask?.cancel()
        let request = generation
        let delay = navigationPainting ? 0 : max(0.22, 0.6 - Date().timeIntervalSince(lastSample))
        sampleTask = Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let webView, self.webView === webView, self.generation == request else { return }
            self.sample(webView, generation: request)
        }
    }

    private func refresh() {
        let canvas = Self.rgba(PlatformColor(Theme.t3Code.canvas))!
        guard let webView, webView.url != nil else { apply(canvas); return }
        installObserver(webView)
        #if os(macOS)
        var neutral = ChromeColor(0.94, 0.94, 0.94)
        webView.effectiveAppearance.performAsCurrentDrawingAppearance { neutral = Self.rgba(PlatformColor.windowBackgroundColor) ?? neutral }
        #else
        let neutral = Self.rgba(UIColor.systemBackground.resolvedColor(with: webView.traitCollection)) ?? ChromeColor(1, 1, 1)
        #endif
        if navigationPainting && stableBand.value == nil && applyRemembered() { return }
        let selected = ChromeColorSelection.select(edge:sampledTop, body:bodyBackground, html:htmlBackground, isDimming:dimmingLayer,
            underPage:stableBand.value != nil ? stableBand.value?.underPage : Self.rgba(webView.underPageBackgroundColor), neutral:privatePage ? canvas : neutral, isPrivate:privatePage)
        if navigationPainting, !privatePage, let key = cacheKey(webView.url) {
            if navigationSeed?.key != key { navigationSeed = remembered[key].map { (key,$0) } }
            // Revisited pages can paint a near-identical placeholder header before
            // DOM readiness (Apple: #1d1d1f -> #161617). Hold the known tint through
            // that phase; materially different paint still corrects immediately.
            if let seed = navigationSeed?.color, selected.deltaE(seed) <= 4 { apply(seed); return }
        }
        apply(selected)
    }

    private func sample(_ web: WKWebView, generation request: Int) {
        guard web.bounds.width > 16, web.bounds.height > web.obscuredContentInsets.top + 8 else { return }
        // WebKit can suspend an evaluation issued during a BFCache restore.
        // A newer sample supersedes it instead of waiting on a global busy flag.
        sampleRevision += 1
        let sample = sampleRevision
        lastSample = Date()
        let revision = scrollRevision
        // Normal tabs ignore theme-color. Query only computed backgrounds of the
        // viewport-constrained edge and page canvas; text/images in ordinary flow
        // must not accidentally become the chrome colour.
        web.callAsyncJavaScript(Self.edgeScript,
            arguments: ["inset": web.obscuredContentInsets.top, "viewWidth": web.bounds.width],
            in: nil, in: Self.contentWorld) { [weak self, weak web] result in
                // A restored document may never finish an earlier evaluation.
                // Keep its callback weak and accept only the newest sample.
                guard let self, let web, self.webView === web,
                      self.generation == request, self.sampleRevision == sample else { return }
                guard self.scrollRevision == revision else { self.requestSample(); return }
                let values = (try? result.get()) as? [String: Any] ?? [:]
                if Self.matchesDocument(values["href"] as? String, url: web.url) { self.accept(values) }
            }
    }

    private func accept(_ values: [String: Any]) {
        guard !values.isEmpty else { return }
        func decode(_ key: String) -> ChromeColor? {
            guard let c = values[key] as? [Double], c.count == 4 else { return nil }
            return ChromeColor(c[0], c[1], c[2], alpha: c[3])
        }
        if let time = values["sampleTime"] as? Double, time < lastScrollTime { return }
        let offset = values["scrollY"] as? Double ?? 0
        // Rubber band snapshots are not new viewport paint. Preserve the last
        // band and mode until WebKit reports a real document position again.
        guard offset.isFinite, offset >= 0 else { return }
        updateScroll(offset)
        let band = Band(edge: decode("edge"), body: decode("body"), html: decode("html"),
                        underPage: webView.flatMap { Self.rgba($0.underPageBackgroundColor) }, dimming: values["dimming"] as? Bool ?? false)
        let early = navigationPainting && !hasScrolled && offset <= ChromeScrollState.leaveOffset
        animatesColor = !early
        // During initial painting CSS and headers can appear between frames.
        // Never make the first rendered band wait for scroll-time confirmation.
        if early { stableBand = ChromeStableValue() }
        if stableBand.update(band, at: ProcessInfo.processInfo.systemUptime) {
            bodyBackground = band.body; htmlBackground = band.html
            sampledTop = band.edge; dimmingLayer = band.dimming
        }
        scheduleBandConfirmation()
        #if DEBUG
        sampleCount += 1
        #endif
        if values["initialComplete"] as? Bool == true { navigationPainting = false; navigationSeed = nil }
        refresh()
        if !privatePage, let key = cacheKey(webView?.url), let rgb = Self.rgba(PlatformColor(color)) {
            if remembered.count >= 64 && remembered[key] == nil { remembered.removeAll(keepingCapacity: true) }
            remembered[key] = rgb
        }
        #if DEBUG
        diagnosticValues = values
        ChromeTiming.event("edgeSample",web:webView,extra:["sampleTime":values["sampleTime"] ?? 0,"edge":values["edge"] ?? NSNull(),"body":values["body"] ?? NSNull(),"html":values["html"] ?? NSNull(),"initial":early])
        recordDiagnostics()
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if ChromeVisualFixture.liveURL != nil,
           let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("oriv-chrome-edge.json"), options: .atomic)
        }
        #endif
    }

    /// Public DOM approximation of WebKit's fixedContainerEdges. Five hit tests
    /// avoid text/icon holes. Backgrounds on wide descendants of a fixed/sticky
    /// container count too; fully transparent paint continues to the next layer.
    static let edgeScript: String = {
        #if DEBUG
        let diagnosticSetup = """
        const describe = el => ({tag:el.tagName, id:el.id, position:getComputedStyle(el).position,
            background:getComputedStyle(el).backgroundColor, image:getComputedStyle(el).backgroundImage,
            rect:{top:el.getBoundingClientRect().top,bottom:el.getBoundingClientRect().bottom,
                  width:el.getBoundingClientRect().width}});
        const hits = [];
        """
        let diagnosticHit = "hits.push(found ? describe(found.element) : null);"
        let diagnosticResult = """
        selected:winner ? describe(winner.element) : null, hits,
        viewport:{top,y,width,nativeInset:inset,height:vv?.height || innerHeight}, title:document.title,
        """
        #else
        let diagnosticSetup = "", diagnosticHit = "", diagnosticResult = ""
        #endif
        return """
        const rgba = value => {
            if (!value || !CSS.supports('color', value)) return null;
            // Computed sRGB preserves the author's unpremultiplied channels.
            // A canvas round trip can turn rgba(22,22,23,.8) into (23,23,23).
            if (/^rgba?\\(/.test(value)) {
                const n = value.match(/[0-9.]+/g).map(Number), a = n[3] ?? 1;
                return a > 0 ? [n[0]/255, n[1]/255, n[2]/255, a] : null;
            }
            const c = document.createElement('canvas').getContext('2d');
            c.fillStyle = value; c.fillRect(0, 0, 1, 1);
            const p = c.getImageData(0, 0, 1, 1).data;
            return p[3] ? [p[0]/255, p[1]/255, p[2]/255, p[3]/255] : null;
        };
        const vv = visualViewport;
        const left = vv?.offsetLeft || 0, width = vv?.width || innerWidth;
        // DOM viewport coordinates already exclude WKWebView's obscured/native
        // content inset. Adding the inset again skips short mobile headers.
        const top = vv?.offsetTop || 0;
        const y = Math.min(top + 1, innerHeight - 1);
        \(diagnosticSetup)
        const votes = [];
        for (const fraction of [.05, .25, .5, .75, .95]) {
            let found = null;
            for (const hit of document.elementsFromPoint(left + width * fraction, y)) {
                let paint = null;
                for (let el = hit; el && el !== document.documentElement; el = el.parentElement) {
                    const s = getComputedStyle(el), r = el.getBoundingClientRect();
                    if (s.visibility !== 'visible' || Number(s.opacity) < .01 || Number(s.zIndex) < 0) continue;
                    const wide = r.width >= width * .9 && r.left <= left + width * .1 && r.right >= left + width * .9;
                    if (wide && r.height > 10 && !paint) {
                        paint = rgba(s.backgroundColor);
                        if (paint) paint[3] *= Number(s.opacity);
                    }
                    if ((s.position === 'fixed' || s.position === 'sticky') && wide &&
                        r.top <= top + 2 && r.bottom > y && r.height <= (vv?.height || innerHeight) * 1.05) {
                        if (paint) {
                            const dimming = r.height >= (vv?.height || innerHeight) * .9 && el.children.length === 0 && paint[3] < 1;
                            found = {element:el, color:paint, dimming};
                        }
                        // A transparent constrained container may cover another
                        // constrained layer; continue the hit stack when unpainted.
                        break;
                    }
                }
                if (found) break;
            }
            \(diagnosticHit)
            if (found) votes.push(found);
        }
        const winner = votes.find(v => votes.filter(w => w.element === v.element).length >= 3);
        return {body:rgba(document.body && getComputedStyle(document.body).backgroundColor),
            html:rgba(getComputedStyle(document.documentElement).backgroundColor),
            edge:winner?.color || null, dimming:winner?.dimming || false,
            \(diagnosticResult)
            sampleTime:performance.timeOrigin + performance.now(), scrollY, href:location.href};
        """
    }()

    private func installObserver(_ web: WKWebView) {
        guard !installed, !privatePage else { return }
        installed = true
        web.evaluateJavaScript(Self.observerScript, in: nil, in: Self.contentWorld) { _ in }
    }

    static var observerScript: String {
        """
        (() => {
            if (window.__orivChromeStop) { window.__orivChromeSend?.(); return; }
            let timer, deadline, edgeTimer, frame, lastEdge = -Infinity, initial = true;
            const readEdge = () => { const inset = 0, viewWidth = innerWidth;
                \(Self.edgeScript)
            };
            const sendEdge = () => {
                clearTimeout(edgeTimer); edgeTimer = null; lastEdge = performance.now();
                if (!window.webkit?.messageHandlers?.chromeEdge || !document.documentElement || !document.body) return;
                const edge = {...readEdge(), documentID:performance.timeOrigin, initialComplete:!initial};
                window.__orivChromeLatest = edge;
                window.webkit?.messageHandlers?.chromeEdge?.postMessage({edge});
            };
            const send = () => { clearTimeout(timer); clearTimeout(deadline); timer = deadline = null; sendEdge(); };
            const nextPaint = () => {
                if (!frame) frame = requestAnimationFrame(() => { frame = null; sendEdge(); });
            };
            const changed = () => {
                if (initial) { nextPaint(); return; }
                clearTimeout(timer); timer = setTimeout(send, 220);
                if (!deadline) deadline = setTimeout(send, 1000);
            };
            const scroll = () => {
                if (window.scrollY < 0) return;
                window.webkit?.messageHandlers?.chromeEdge?.postMessage({scrollY:window.scrollY,scrollTime:performance.timeOrigin + performance.now()});
                if (performance.now() - lastEdge >= 125) sendEdge();
                else if (!edgeTimer) edgeTimer = setTimeout(sendEdge, 125 - (performance.now() - lastEdge));
            };
            const ready = () => { sendEdge(); nextPaint(); };
            const painted = () => { sendEdge(); nextPaint(); };
            const loaded = () => {
                // DOM readiness must end the initial phase even when a hidden
                // window throttles rAF. Send the ready paint before confirmation
                // becomes active, then mark the phase complete atomically.
                sendEdge(); initial = false; sendEdge(); nextPaint();
            };
            const paintObserver = new PerformanceObserver(list => {
                if (list.getEntries().some(e => e.name === 'first-contentful-paint')) painted();
            });
            paintObserver.observe({type:'paint', buffered:true});
            const media = matchMedia('(prefers-color-scheme: dark)');
            const observer = new MutationObserver(changed);
            observer.observe(document, {subtree:true, childList:true, attributes:true, attributeFilter:['style','class','content','media']});
            window.addEventListener('scroll', scroll, {passive:true, capture:true});
            window.addEventListener('wheel', scroll, {passive:true, capture:true});
            window.addEventListener('resize', ready);
            window.addEventListener('pageshow', ready);
            window.addEventListener('popstate', ready);
            window.addEventListener('hashchange', ready);
            document.addEventListener('DOMContentLoaded', loaded, {once:true});
            document.addEventListener('load', changed, true);
            window.addEventListener('load', loaded, {once:true});
            if (document.readyState === 'complete') loaded();
            media.addEventListener('change', ready);
            window.__orivChromeSend = ready;
            window.__orivChromeStop = () => {
                clearTimeout(timer); clearTimeout(deadline); clearTimeout(edgeTimer); cancelAnimationFrame(frame);
                observer.disconnect(); paintObserver.disconnect();
                window.removeEventListener('scroll', scroll, true); window.removeEventListener('wheel', scroll, true); window.removeEventListener('resize', ready);
                window.removeEventListener('pageshow', ready); window.removeEventListener('popstate', ready);
                window.removeEventListener('hashchange', ready); document.removeEventListener('DOMContentLoaded', loaded);
                document.removeEventListener('load', changed, true); window.removeEventListener('load', loaded); media.removeEventListener('change', ready);
                delete window.__orivChromeStop; delete window.__orivChromeSend;
            };
            ready();
        })()
        """
    }

    fileprivate func receiveScroll(_ message: WKScriptMessage) {
        guard !privatePage, message.webView === webView, message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        if let edge = body["edge"] as? [String: Any] {
            guard Self.matchesDocument(edge["href"] as? String, url: webView?.url) else { return }
            if let id = edge["documentID"] as? Double {
                guard id >= documentID else { return }
                if id != documentID { documentID = id; navigationPainting = true; stableBand = ChromeStableValue() }
            }
            scrollRevision += 1; accept(edge); return
        }
        if let offset = body["scrollY"] as? Double {
            if let time = body["scrollTime"] as? Double {
                guard time >= lastScrollTime else { return }
                lastScrollTime = time
            }
            updateScroll(offset)
        }
        if body["sample"] as? Bool == true { refresh(); requestSample() }
    }

    #if DEBUG
    private func recordDiagnostics() {
        Self.diagnosticObserver?(self)
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--oriv-chrome-diagnostics") {
            let frame: [String: Any] = ["time": ProcessInfo.processInfo.systemUptime,
                "scrollY": diagnosticValues["scrollY"] ?? 0, "scrolled": hasScrolled,
                "under": showsContentUnderChrome, "luminance": luminance,
                "edge": diagnosticValues["edge"] ?? NSNull(), "href": diagnosticValues["href"] ?? ""]
            diagnosticFrames.append(frame)
            if diagnosticFrames.count > 4000 { diagnosticFrames.removeFirst() }
            if let data = try? JSONSerialization.data(withJSONObject: diagnosticFrames, options: [.sortedKeys]) {
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("oriv-chrome-scroll.json"), options: .atomic)
            }
        }
        #endif
    }
    #endif

    private func resetTransitions() {
        scrollTask?.cancel(); scrollTask = nil
        bandTask?.cancel(); bandTask = nil
        scrollState = ChromeScrollState()
        stableBand = ChromeStableValue()
    }

    private func updateScroll(_ offset: Double) {
        scrollState.update(offset: offset, at: ProcessInfo.processInfo.systemUptime)
        hasScrolled = scrollState.isScrolled
        guard let deadline = scrollState.deadline else { scrollTask?.cancel(); scrollTask = nil; return }
        guard scrollTask == nil else { return }
        let request = generation
        scrollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            guard !Task.isCancelled, let self, self.generation == request else { return }
            self.scrollTask = nil
            self.scrollState.settle(at: ProcessInfo.processInfo.systemUptime)
            self.hasScrolled = self.scrollState.isScrolled
            #if DEBUG
            self.recordDiagnostics()
            #endif
        }
    }

    private func scheduleBandConfirmation() {
        guard let deadline = stableBand.deadline else { bandTask?.cancel(); bandTask = nil; return }
        guard bandTask == nil else { return }
        let request = generation
        bandTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            guard !Task.isCancelled, let self, self.generation == request, let web = self.webView else { return }
            self.bandTask = nil
            // Measure again before accepting a new sticky/header colour. A
            // single transient result cannot replace the cached band.
            self.sample(web, generation: request)
        }
    }

    private static func rgba(_ color: PlatformColor) -> ChromeColor? {
        #if os(macOS)
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        let rgba = ChromeColor(c.redComponent, c.greenComponent, c.blueComponent, alpha: c.alphaComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        let rgba = ChromeColor(r, g, b, alpha: a)
        #endif
        return rgba.usable ? rgba : nil
    }
    private func apply(_ rgb: ChromeColor) {
        luminance = rgb.luminance; isDark = rgb.whiteForeground
        #if DEBUG
        ChromeTiming.event("colourTarget", web: webView, extra: ["rgb": [rgb.red, rgb.green, rgb.blue], "scrolled":hasScrolled])
        #endif
        color = Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

@MainActor private final class PageChromeScrollHandler: NSObject, WKScriptMessageHandler {
    weak var owner: PageChrome?
    init(owner: PageChrome) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receiveScroll(message) }
}

/// Chrome alone uses glass. The dark backing bounds text contrast even over white
/// pages; increased contrast and Reduce Transparency use the existing solid tokens.
struct ChromePageTint { let color: Color; let isDark: Bool }
private struct ChromePageTintKey: EnvironmentKey { static let defaultValue: ChromePageTint? = nil }
extension EnvironmentValues {
    var chromePageTint: ChromePageTint? {
        get { self[ChromePageTintKey.self] }
        set { self[ChromePageTintKey.self] = newValue }
    }
}

private struct BrowserGlass: ViewModifier {
    @Environment(\.browserTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    @Environment(\.chromePageTint) private var pageTint
    var radius: CGFloat
    func body(content: Content) -> some View {
        Group {
            if let pageTint {
                if reduceTransparency || captureReduceTransparency || contrast == .increased {
                    content.background(pageTint.color, in: .rect(cornerRadius: radius))
                        .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder((pageTint.isDark ? Color.white : .black).opacity(contrast == .increased ? 0.8 : 0.35), lineWidth: 1) }
                } else {
                    content.background(pageTint.color.opacity(0.72), in: .rect(cornerRadius: radius))
                        .glassEffect(.clear.tint(pageTint.color.opacity(0.3)), in: .rect(cornerRadius: radius))
                }
            } else if reduceTransparency || captureReduceTransparency || contrast == .increased {
                content.background(theme.field, in: .rect(cornerRadius: radius))
            } else {
                content.background(theme.field.opacity(0.96), in: .rect(cornerRadius: radius))
                    .glassEffect(.regular.tint(theme.chrome.opacity(0.2)), in: .rect(cornerRadius: radius))
            }
        }.environment(\.colorScheme, pageTint.map { $0.isDark ? .dark : .light } ?? .dark)
    }
}

private struct ChromeReduceTransparencyKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Snapshot-only mirror; the real accessibility preference always takes precedence.
    var chromeReduceTransparencyOverride: Bool {
        get { self[ChromeReduceTransparencyKey.self] }
        set { self[ChromeReduceTransparencyKey.self] = newValue }
    }
}

extension View {
    func browserGlass(radius: CGFloat = 24) -> some View { modifier(BrowserGlass(radius: radius)) }
}
