import SwiftUI
import WebKit

struct MobileWebView: UIViewRepresentable {
    let webView: WKWebView
    var chrome: PageChrome
    var topInset: CGFloat
    var bottomInset: CGFloat
    var reduceTransparency: Bool
    var onAppearanceChange: (Bool) -> Void
    var onScroll: (CGFloat, Bool) -> Void

    func makeUIView(context: Context) -> MobileWebHost { MobileWebHost(webView: webView) }
    static func dismantleUIView(_ host: MobileWebHost, coordinator: ()) { host.detachScrollView() }
    func updateUIView(_ host: MobileWebHost, context: Context) {
        host.onScroll = onScroll
        host.onAppearanceChange = onAppearanceChange
        host.refreshAppearance()
        host.onGeometryChange = { chrome.requestSample() }
        host.updateInsets(top: topInset, bottom: bottomInset)
        webView.scrollView.topEdgeEffect.style = .soft
        webView.scrollView.bottomEdgeEffect.style = .soft
        webView.scrollView.topEdgeEffect.isHidden = reduceTransparency
        webView.scrollView.bottomEdgeEffect.isHidden = reduceTransparency
    }
}

final class MobileWebHost: UIView {
    let webView: WKWebView
    var onScroll: ((CGFloat, Bool) -> Void)?
    var onGeometryChange: (() -> Void)?
    var onAppearanceChange: ((Bool) -> Void)?
    private var lastAppearance: UIUserInterfaceStyle?
    private var observation: NSKeyValueObservation?
    private weak var edgeController: UIViewController?
    private var lastOffset: CGFloat = 0
    private var installedInsets = false
    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
        // Status text follows the sampled band; web CSS continues to follow the
        // scene's system appearance. This avoids light/dark feedback from chrome.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (host: MobileWebHost, _: UITraitCollection) in
            host.updatePageAppearance()
            host.onGeometryChange?()
        }
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        observation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            Task { @MainActor [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                let offset = scrollView.contentOffset.y + scrollView.contentInset.top
                // Observe rather than replace WebKit's scroll delegate. Chrome resizing,
                // restoration, find and keyboard scrolling must not collapse the bar.
                guard scrollView.isDragging || scrollView.isDecelerating else { self.lastOffset = offset; return }
                guard abs(offset - self.lastOffset) > 12 else { return }
                let down = offset > self.lastOffset
                self.lastOffset = offset
                self.onScroll?(offset, down)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow(); updatePageAppearance(); connectScrollView() }
    private func connectScrollView() {
        guard window != nil else { detachScrollView(); return }
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController {
                if edgeController !== controller {
                    detachScrollView()
                    edgeController = controller
                    // SwiftUI cannot discover the scroll view inside WKWebView
                    // reliably. Give the enclosing bars the real scroll view.
                    controller.setContentScrollView(webView.scrollView, for: .all)
                }
                return
            }
            responder = current.next
        }
    }
    func detachScrollView() {
        if edgeController?.contentScrollView(for: .top) === webView.scrollView {
            edgeController?.setContentScrollView(nil, for: .all)
        }
        edgeController = nil
    }
    func refreshAppearance() { updatePageAppearance() }
    private func updatePageAppearance() {
        let style = window?.windowScene?.traitCollection.userInterfaceStyle ?? .unspecified
        webView.overrideUserInterfaceStyle = style
        if style != .unspecified && lastAppearance != style {
            lastAppearance = style
            DispatchQueue.main.async { [weak self] in self?.onAppearanceChange?(style == .dark) }
        }
    }
    override func layoutSubviews() { super.layoutSubviews(); connectScrollView(); if webView.frame != bounds { webView.frame = bounds; onGeometryChange?() } }
    func updateInsets(top: CGFloat, bottom: CGFloat) {
        let insets = UIEdgeInsets(top: max(0, top), left: 0, bottom: max(0, bottom), right: 0)
        if webView.obscuredContentInsets != insets { webView.obscuredContentInsets = insets; onGeometryChange?() }
        let scrollView = webView.scrollView
        if scrollView.contentInset != insets {
            let atTop = !installedInsets && scrollView.contentOffset.y <= 0
            scrollView.contentInset = insets
            scrollView.verticalScrollIndicatorInsets = insets
            if atTop { scrollView.setContentOffset(CGPoint(x: 0, y: -top), animated: false) }
            installedInsets = true
        }
    }
}
