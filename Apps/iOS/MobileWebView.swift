import SwiftUI
import WebKit

struct MobileWebView: UIViewRepresentable {
    let webView: WKWebView
    var topInset: CGFloat
    var bottomInset: CGFloat
    var reduceTransparency: Bool
    var onScroll: (CGFloat, Bool) -> Void

    func makeUIView(context: Context) -> MobileWebHost { MobileWebHost(webView: webView) }
    func updateUIView(_ host: MobileWebHost, context: Context) {
        host.onScroll = onScroll
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
    private var observation: NSKeyValueObservation?
    private var lastOffset: CGFloat = 0
    private var installedInsets = false
    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
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
    override func layoutSubviews() { super.layoutSubviews(); webView.frame = bounds }
    func updateInsets(top: CGFloat, bottom: CGFloat) {
        let insets = UIEdgeInsets(top: max(0, top), left: 0, bottom: max(0, bottom), right: 0)
        if webView.obscuredContentInsets != insets { webView.obscuredContentInsets = insets }
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
