import BrowserEngine
import SwiftUI
import WebKit

struct WebPageView: NSViewRepresentable {
    let tab: BrowserTab
    var chrome: PageChrome? = nil
    var contentUnderChrome = false
    var headerInset: CGFloat = 0
    var profileTransition = false
    var profileEpoch: UUID? = nil
    var fullscreenChanged: ((Bool) -> Void)? = nil
    @Environment(\.browserReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> WebViewHost { WebViewHost(webView: tab.webView, tab: tab, profileTransition: profileTransition, profileEpoch: profileEpoch) }
    static func dismantleNSView(_ host: WebViewHost, coordinator: ()) { host.switchCover.cancel() }
    func updateNSView(_ host: WebViewHost, context: Context) {
        host.fullscreenChanged = fullscreenChanged
        host.switchCover.reduceMotion = reduceMotion
        host.setTab(tab, profileEpoch: profileEpoch)
        host.headerInset = headerInset; host.onGeometryChange = { chrome?.requestSample() }
        host.clipsToBounds = !contentUnderChrome; host.attachIfWindowed(); host.needsLayout = true
    }
}

/// SwiftUI sizes this container. WebKit owns the child view's frame and can
/// move it into its fullscreen window without carrying SwiftUI constraints.
/// See WebKit bug 313802 and WKWebView.fullscreenState's reparenting contract.
final class WebViewHost: NSView {
    private(set) var webView: WKWebView
    var headerInset: CGFloat = 0
    var onGeometryChange: (() -> Void)?
    var fullscreenChanged: ((Bool) -> Void)?
    private var fullscreenObservation: NSKeyValueObservation?
    private weak var pendingTab: BrowserTab?
    private var pendingProfileEpoch: UUID?
    private var profileEpoch: UUID?
    private var closingPresentation = false
    private weak var tab: BrowserTab?
    let switchCover = TabSwitchCover()

    init(webView: WKWebView, tab: BrowserTab? = nil, profileTransition: Bool = false, profileEpoch: UUID? = nil) {
        self.webView = webView
        self.tab = tab
        self.profileEpoch = profileEpoch
        super.init(frame: .zero)
        clipsToBounds = true
        switchCover.fadesWhenReady = profileTransition
        addSubview(switchCover)
        attachIfWindowed()
        if let tab { switchCover.begin(tab,in:webView,waitForLayout:true) }
        observeFullscreen()
    }
    func setTab(_ tab: BrowserTab, profileEpoch: UUID? = nil) {
        // A retained SwiftUI graph can receive one final update after close.
        // Do not invoke that same tab's lazy getter and resurrect its view.
        if self.tab === tab && !tab.isInstantiated { return }
        let view = tab.webView
        if webView !== view {
            // WebKit owns the view while it is in its fullscreen window. Close
            // that presentation and wait for its placeholder restoration before
            // changing children. Rapid selection keeps only the latest target.
            if webView.fullscreenState != .notInFullscreen {
                pendingTab = tab
                pendingProfileEpoch = profileEpoch
                guard !closingPresentation else { return }
                closingPresentation = true
                let outgoing = webView
                outgoing.closeAllMediaPresentations { [weak self,weak outgoing] in
                    guard let self, self.webView === outgoing else { return }
                    self.closingPresentation = false
                    self.finishPendingSelection()
                }
                return
            }
            pendingTab = nil; closingPresentation = false
            fullscreenObservation = nil
            webView.removeFromSuperview()
            webView = view; self.tab = tab
            switchCover.fadesWhenReady = self.profileEpoch != profileEpoch
            self.profileEpoch = profileEpoch
            attachIfWindowed(); switchCover.begin(tab,in:view,waitForLayout:true); needsLayout = true; observeFullscreen()
        } else { pendingTab = nil }
        switchCover.confirmIfReady(tab)
    }
    private func finishPendingSelection() {
        guard webView.fullscreenState == .notInFullscreen, let pendingTab else { return }
        self.pendingTab = nil; closingPresentation = false
        guard pendingTab.isInstantiated else { return }
        setTab(pendingTab, profileEpoch: pendingProfileEpoch)
    }
    private func observeFullscreen() {
        fullscreenObservation = webView.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                // Wait until WebKit has finished restoring its placeholder.
                if let self { self.fullscreenChanged?(self.webView.fullscreenState != .notInFullscreen) }
                self?.finishPendingSelection()
                self?.attachIfWindowed()
                self?.needsLayout = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        if let tab { switchCover.confirmIfReady(tab) }
    }

    func attachIfWindowed() {
        guard webView.fullscreenState == .notInFullscreen else { return }
        if webView.superview !== self {
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
            webView.frame = bounds
            addSubview(webView,positioned:.below,relativeTo:switchCover)
        }
    }

    override func layout() {
        super.layout()
        guard webView.fullscreenState == .notInFullscreen, webView.superview === self else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
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
        // Cover the same point viewport WebKit captured, including the portion
        // beneath the toolbar. A shorter host-sized cover stretched that image.
        switchCover.frame = webView.frame
        switchCover.layoutSubtreeIfNeeded()
        if let tab { switchCover.layoutDidSettle(tab) }
    }
}

/// The start page has no WebKit cover. Reveal it over its own window canvas.
struct HomeProfileFade: NSViewRepresentable {
    let epoch: UUID
    let color: Color
    let startsOnMount: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> Veil {
        let view = Veil()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: Veil, context: Context) {
        let changed = view.epoch.map { $0 != epoch } ?? startsOnMount
        view.epoch = epoch
        guard changed, let layer = view.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = NSColor(color).cgColor
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = reduceMotion ? 0.15 : 0.20
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "profileFade")
        CATransaction.commit()
    }

    final class Veil: NSView {
        var epoch: UUID?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
