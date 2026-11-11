import BrowserEngine
import SwiftUI
import WebKit

struct WebPageView: NSViewRepresentable {
    let tab: BrowserTab
    var chrome: PageChrome? = nil
    var contentUnderChrome = false
    var headerInset: CGFloat = 0

    func makeNSView(context: Context) -> WebViewHost { WebViewHost(webView: tab.webView) }
    func updateNSView(_ host: WebViewHost, context: Context) { host.headerInset = headerInset; host.onGeometryChange = { chrome?.requestSample() }; host.clipsToBounds = !contentUnderChrome; host.attachIfWindowed(); host.needsLayout = true }
}

/// SwiftUI sizes this container. WebKit owns the child view's frame and can
/// move it into its fullscreen window without carrying SwiftUI constraints.
/// See WebKit bug 313802 and WKWebView.fullscreenState's reparenting contract.
final class WebViewHost: NSView {
    let webView: WKWebView
    var headerInset: CGFloat = 0
    var onGeometryChange: (() -> Void)?
    private var fullscreenObservation: NSKeyValueObservation?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
        attachIfWindowed()
        fullscreenObservation = webView.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                // Wait until WebKit has finished restoring its placeholder.
                self?.attachIfWindowed()
                self?.needsLayout = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    func attachIfWindowed() {
        guard webView.fullscreenState == .notInFullscreen else { return }
        if webView.superview !== self {
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
            webView.frame = bounds
            addSubview(webView)
        }
    }

    override func layout() {
        super.layout()
        guard webView.fullscreenState == .notInFullscreen, webView.superview === self else { return }
        if let window {
            let rect = convert(bounds, to: nil)
            // Keep SwiftUI's native toolbar in its own layout region. Extending the
            // entire SwiftUI page with ignoresSafeArea puts its layer ABOVE NSToolbar
            // on macOS 27. Extend WebKit's child instead, beneath the native chrome.
            let extensionHeight = headerInset > 0
                ? (abs(rect.maxY - (window.frame.height - headerInset)) < 1 ? headerInset : 0)
                : (abs(rect.maxY - window.contentLayoutRect.maxY) < 1
                ? max(0, window.contentView!.bounds.height - window.contentLayoutRect.maxY) : 0)
            let frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + extensionHeight)
            if webView.frame != frame { webView.frame = frame; onGeometryChange?() }
            let top = headerInset > 0 ? extensionHeight : max(0, rect.maxY + extensionHeight - window.contentLayoutRect.maxY)
            if abs(webView.obscuredContentInsets.top - top) > 0.1 {
                webView.obscuredContentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
                onGeometryChange?()
            }
        } else { webView.frame = bounds }
    }
}

/// A window-local bridge; never changes another window or the process appearance.
struct BrowserTitlebar: NSViewRepresentable {
    var color: Color
    var reduceMotion = false
    func makeNSView(context: Context) -> TitlebarView { TitlebarView() }
    func updateNSView(_ view: TitlebarView, context: Context) {
        view.color = NSColor(color)
        view.reduceMotion = reduceMotion
        view.configure()
    }
    final class TitlebarView: NSView {
        var color = NSColor.windowBackgroundColor
        var reduceMotion = false
        private var transitionTimer: Timer?
        private var transitionSource = NSColor.black
        private var transitionTarget: NSColor?
        private var transitionStart = 0.0
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            if reduceMotion {
                transitionTimer?.invalidate()
                transitionTimer = nil
                transitionTarget = nil
                window.backgroundColor = color
            } else if transitionTarget != color && window.backgroundColor != color {
                transitionTimer?.invalidate()
                transitionSource = window.backgroundColor.usingColorSpace(.sRGB) ?? .black
                transitionTarget = color.usingColorSpace(.sRGB) ?? .black
                transitionStart = Date.timeIntervalSinceReferenceDate
                // A bounded, window-local transition. No timer runs between page changes.
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                    guard self != nil else { timer.invalidate(); return }
                    Task { @MainActor [weak self] in self?.advanceColor() }
                }
                transitionTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        private func advanceColor() {
            guard let window, let target = transitionTarget else {
                transitionTimer?.invalidate()
                transitionTimer = nil
                return
            }
            let progress = min(1, (Date.timeIntervalSinceReferenceDate - transitionStart) / 0.2)
            let fraction = progress * progress * (3 - 2 * progress)
            window.backgroundColor = transitionSource.blended(withFraction: fraction, of: target)
            if progress >= 1 {
                window.backgroundColor = target
                transitionTimer?.invalidate()
                transitionTimer = nil
            }
        }
    }
}


/// The anchor is reparented with NSToolbar's items in fullscreen and on reveal.
/// Place a non-interactive fill in the full-width toolbar ancestor, above AppKit's
/// window backing and below the controls. Never tint a fullscreen host's entire
/// window surface: WindowServer may group that surface with the document window.
struct BrowserToolbarBackdrop: NSViewRepresentable {
    var color: Color
    var adaptive: Bool
    var reduceMotion: Bool
    func makeNSView(context:Context) -> Anchor { Anchor() }
    func updateNSView(_ view:Anchor,context:Context) {
        view.color = NSColor(color).withAlphaComponent(adaptive ? 0 : 1)
        view.reduceMotion = reduceMotion; view.configure()
    }
    final class Fill: NSView {
        override func hitTest(_ point:NSPoint) -> NSView? { nil }
    }
    final class Anchor: NSView {
        var color = NSColor.clear
        var reduceMotion = true
        private let fill = Fill()
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
        override func layout() { super.layout(); configure() }
        func configure() {
            guard let window else { fill.removeFromSuperview(); return }
            var ancestor = superview
            while let candidate = ancestor {
                if candidate.bounds.width >= window.frame.width-2 && candidate.bounds.height >= 28 && candidate.bounds.height <= 150 {
                    if fill.superview !== candidate {
                        fill.removeFromSuperview(); fill.frame = candidate.bounds
                        fill.autoresizingMask = [.width,.height]; fill.wantsLayer = true
                        candidate.addSubview(fill,positioned:.below,relativeTo:nil)
                    }
                    let target = color.cgColor
                    if reduceMotion { fill.layer?.removeAnimation(forKey:"pageTint") }
                    if fill.layer?.backgroundColor != target {
                        let previous = fill.layer?.presentation()?.backgroundColor ?? fill.layer?.backgroundColor
                        fill.layer?.removeAnimation(forKey:"pageTint")
                        fill.layer?.backgroundColor = target
                        if !reduceMotion, let previous {
                            let animation = CABasicAnimation(keyPath:"backgroundColor")
                            animation.fromValue = previous; animation.toValue = target; animation.duration = 0.2
                            fill.layer?.add(animation,forKey:"pageTint")
                        }
                    }
                    return
                }
                ancestor = candidate.superview
            }
        }
    }
}
