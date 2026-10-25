import BrowserEngine
import SwiftUI
import WebKit

struct WebPageView: NSViewRepresentable {
    let tab: BrowserTab

    func makeNSView(context: Context) -> WebViewHost { WebViewHost(webView: tab.webView) }
    func updateNSView(_ host: WebViewHost, context: Context) { host.attachIfWindowed() }
}

/// SwiftUI sizes this container. WebKit owns the child view's frame and can
/// move it into its fullscreen window without carrying SwiftUI constraints.
/// See WebKit bug 313802 and WKWebView.fullscreenState's reparenting contract.
final class WebViewHost: NSView {
    let webView: WKWebView
    private var fullscreenObservation: NSKeyValueObservation?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
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
        webView.frame = bounds
    }
}
