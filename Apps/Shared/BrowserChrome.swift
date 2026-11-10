import SwiftUI
import WebKit

#if os(macOS)
/// Window-local colour and scroll-edge observation. A computed background read is needed only if
/// WebKit supplies neither an opaque theme colour nor an under-page colour.
@MainActor @Observable final class PageChrome {
    static let foregroundThreshold = sqrt(1.05 * 0.05) - 0.05
    var color: Color = Theme.t3Code.canvas
    var isDark = true
    private(set) var hasScrolled = false
    private(set) var luminance = 0.0
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sampledBackground: NSColor?
    @ObservationIgnored private var didRequestBackground = false
    @ObservationIgnored private var didInstallScroll = false
    @ObservationIgnored private var privatePage = false
    private static let contentWorld = WKContentWorld.world(name: "OrivPageChrome")

    var foreground: Color { isDark ? .white : .black }

    func observe(_ view: WKWebView?, isPrivate: Bool = false) {
        if let old = webView {
            old.configuration.userContentController.removeScriptMessageHandler(forName: "scrollEdge", contentWorld: Self.contentWorld)
            old.evaluateJavaScript("window.__orivChromeStop?.(); void 0", in: nil, in: Self.contentWorld) { _ in }
        }
        observations.removeAll()
        hasScrolled = false
        didInstallScroll = false
        privatePage = isPrivate
        generation += 1
        sampledBackground = nil
        didRequestBackground = false
        webView = view
        guard let view else { apply(NSColor(Theme.t3Code.canvas)); return }
        view.configuration.userContentController.add(PageChromeScrollHandler(owner: self), contentWorld: Self.contentWorld, name: "scrollEdge")
        observations = [
            view.observe(\.themeColor, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
            view.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.generation += 1
                    self.sampledBackground = nil
                    self.didRequestBackground = false
                    self.didInstallScroll = false
                    self.hasScrolled = false
                    self.refresh()
                }
            }
        ]
        refresh()
    }

    /// Semantic cues keep their hue when readable; otherwise retain their shape
    /// and label with the same high-contrast foreground as the address.
    func contrasting(_ candidate: Color) -> Color {
        guard let rgb = NSColor(candidate).usingColorSpace(.sRGB) else { return foreground }
        let value = Self.relativeLuminance(rgb)
        return (max(value, luminance) + 0.05) / (min(value, luminance) + 0.05) >= 4.5 ? candidate : foreground
    }

    private func refresh() {
        guard let webView else { return }
        let canvas = NSColor(Theme.t3Code.canvas)
        guard webView.url != nil else { apply(canvas); return }
        installScrollObserver(webView)
        guard !privatePage else { apply(canvas); return }
        let page = Self.usable(webView.underPageBackgroundColor)
        let theme = webView.themeColor.flatMap(Self.usable)
        apply(theme ?? page ?? sampledBackground ?? canvas, over: page ?? sampledBackground ?? canvas)
        guard theme == nil, page == nil, !webView.isLoading, !didRequestBackground else { return }
        didRequestBackground = true
        let request = generation
        Task { @MainActor [weak self, weak webView] in
            guard let webView else { return }
            // One background read, no polling or persistence. Never called for a private tab.
            let value = try? await webView.evaluateJavaScript("""
                (() => {
                    const canvas = document.createElement('canvas');
                    canvas.width = canvas.height = 1;
                    const ctx = canvas.getContext('2d');
                    for (const node of [document.documentElement, document.body]) {
                        if (!node) continue;
                        ctx.fillStyle = getComputedStyle(node).backgroundColor;
                        ctx.fillRect(0, 0, 1, 1);
                    }
                    const c = Array.from(ctx.getImageData(0, 0, 1, 1).data);
                    return c[3] > 0 ? c : null;
                })()
                """)
            guard let self, self.webView === webView, self.generation == request,
                  let rgba = value as? [Double], rgba.count == 4 else { return }
            self.sampledBackground = NSColor(srgbRed: rgba[0] / 255, green: rgba[1] / 255,
                                            blue: rgba[2] / 255, alpha: rgba[3] / 255)
            self.refresh()
        }
    }

    private func installScrollObserver(_ webView: WKWebView) {
        guard !webView.isLoading, !didInstallScroll else { return }
        didInstallScroll = true
        // Only two states cross the bridge, on threshold transitions. No scroll
        // coordinates, page content, timers, colour reads, or persistent scripts.
        webView.evaluateJavaScript("""
            (() => {
                window.__orivChromeStop?.();
                let previous;
                const update = () => {
                    const scrolled = window.scrollY > 1;
                    if (scrolled === previous) return;
                    previous = scrolled;
                    window.webkit.messageHandlers.scrollEdge.postMessage(scrolled);
                };
                window.addEventListener('scroll', update, {passive:true});
                window.__orivChromeStop = () => window.removeEventListener('scroll', update);
                update();
            })()
            """, in: nil, in: Self.contentWorld) { _ in }
    }

    fileprivate func receiveScroll(_ message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              let scrolled = message.body as? Bool else { return }
        hasScrolled = scrolled
    }

    private static func usable(_ color: NSColor) -> NSColor? {
        guard let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent > 0,
              [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].allSatisfy({ $0.isFinite }) else { return nil }
        return rgb
    }

    private func apply(_ color: NSColor, over background: NSColor = .black) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        let base = background.usingColorSpace(.sRGB) ?? .black
        let alpha = rgb.alphaComponent
        let r = rgb.redComponent * alpha + base.redComponent * (1 - alpha)
        let g = rgb.greenComponent * alpha + base.greenComponent * (1 - alpha)
        let b = rgb.blueComponent * alpha + base.blueComponent * (1 - alpha)
        let opaque = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        luminance = Self.relativeLuminance(opaque)
        isDark = luminance < Self.foregroundThreshold
        self.color = Color(nsColor: opaque)
    }

    private static func relativeLuminance(_ rgb: NSColor) -> Double {
        func linear(_ c: CGFloat) -> Double { c <= 0.04045 ? Double(c / 12.92) : pow(Double((c + 0.055) / 1.055), 2.4) }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
}

@MainActor private final class PageChromeScrollHandler: NSObject, WKScriptMessageHandler {
    weak var owner: PageChrome?
    init(owner: PageChrome) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receiveScroll(message)
    }
}
#else
/// Observe only the displayed page. No scripts, colour sampling, or persistence are involved.
@MainActor @Observable final class PageChrome {
    var color: Color = Theme.t3Code.chrome
    var isDark = true
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private weak var webView: WKWebView?

    func observe(_ view: WKWebView?) {
        observations.removeAll()
        webView = view
        guard let view else { color = Theme.t3Code.chrome; isDark = true; return }
        observations = [
            view.observe(\.themeColor, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
            view.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        ]
        refresh()
    }

    private func refresh() {
        guard let webView else { return }
        // Resolve alpha against the page background: a transparent theme colour must
        // never turn the status bar into a black strip on an otherwise light page.
        #if os(macOS)
        let page = webView.underPageBackgroundColor.usingColorSpace(.sRGB) ?? .white
        let tint = (webView.themeColor ?? page).usingColorSpace(.sRGB) ?? page
        let a = tint.alphaComponent
        let r = tint.redComponent * a + page.redComponent * (1 - a)
        let g = tint.greenComponent * a + page.greenComponent * (1 - a)
        let b = tint.blueComponent * a + page.blueComponent * (1 - a)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        var pr: CGFloat = 1, pg: CGFloat = 1, pb: CGFloat = 1, pa: CGFloat = 1
        webView.underPageBackgroundColor.getRed(&pr, green: &pg, blue: &pb, alpha: &pa)
        (webView.themeColor ?? webView.underPageBackgroundColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        r = r * a + pr * (1 - a); g = g * a + pg * (1 - a); b = b * a + pb * (1 - a)
        #endif
        color = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
        func linear(_ c: CGFloat) -> Double { c <= 0.04045 ? Double(c / 12.92) : pow(Double((c + 0.055) / 1.055), 2.4) }
        // Black or white status text: choose the larger WCAG contrast ratio.
        isDark = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) < 0.179
    }
}

#endif

/// Chrome alone uses glass. The dark backing bounds text contrast even over white
/// pages; increased contrast and Reduce Transparency use the existing solid tokens.
private struct BrowserGlass: ViewModifier {
    @Environment(\.browserTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    var radius: CGFloat
    func body(content: Content) -> some View {
        Group {
            if reduceTransparency || captureReduceTransparency || contrast == .increased {
                content.background(theme.field, in: .rect(cornerRadius: radius))
            } else {
                content.background(theme.field.opacity(0.96), in: .rect(cornerRadius: radius))
                    .glassEffect(.regular.tint(theme.chrome.opacity(0.2)), in: .rect(cornerRadius: radius))
            }
        }.environment(\.colorScheme, .dark)
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
