import BrowserCore
import Foundation
import Observation
import WebKit

@MainActor @Observable
public final class BrowserTab: NSObject, Identifiable, WKNavigationDelegate {
    public let id: UUID
    public let isPrivate: Bool
    public private(set) var documentRevision = 0
    public private(set) var title: String
    public private(set) var url: URL?
    public private(set) var isLoading = false
    public private(set) var progress = 0.0
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var errorMessage: String?
    public private(set) var hasLoaded = false

    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public var onVisit: ((URL, String) -> Void)?
    @ObservationIgnored public var onWebViewCreated: ((WKWebView) -> Void)?
    @ObservationIgnored public var onDownload: ((WKDownload) -> Void)?
    @ObservationIgnored public var onExternalURL: ((URL) -> Void)?
    @ObservationIgnored private var backingWebView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let configuration: WKWebViewConfiguration
    @ObservationIgnored private let adBlocker: AdBlocker?
    @ObservationIgnored private var policyGeneration = 0
    @ObservationIgnored private var isClosed = false

    public init(record: TabRecord = TabRecord(), isPrivate: Bool = false,
                configuration: WKWebViewConfiguration? = nil, dataStore: WKWebsiteDataStore = .default(),
                adBlocker: AdBlocker? = nil) {
        id = record.id
        title = record.title
        url = record.url
        self.isPrivate = isPrivate
        self.configuration = configuration ?? WKWebViewConfiguration()
        self.adBlocker = adBlocker
        if configuration == nil { self.configuration.websiteDataStore = dataStore }
        // WebKit popups can share their opener's controller. Give each tab its
        // own filtering state so a site's exception cannot disable another tab.
        // Oriv installs its own adapters after creation; preserve supplied scripts.
        let contentController = WKUserContentController()
        self.configuration.userContentController.userScripts.forEach { contentController.addUserScript($0) }
        self.configuration.userContentController = contentController
        BrowserWebConfiguration.apply(to: self.configuration)
        super.init()
    }

    public var record: TabRecord {
        let restorableURL = url.flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
        return TabRecord(id: id, title: restorableURL == nil ? "New tab" : title, url: restorableURL)
    }
    public var displayTitle: String { title.isEmpty ? (url?.host ?? "New tab") : title }
    public var hostname: String { url?.host ?? (isPrivate ? "Private browsing" : "Start page") }
    public var isSecure: Bool { url?.scheme == "https" }
    public var isInstantiated: Bool { backingWebView != nil }

    public var webView: WKWebView {
        if let backingWebView { return backingWebView }
        // A popup can execute in its initial about:blank document before a
        // navigation callback. Install the opener session's prepared protection now.
        adBlocker?.applyPrepared(to: configuration.userContentController, url: url, isPrivate: isPrivate)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        #if DEBUG
        view.isInspectable = true
        #endif
        backingWebView = view
        observations = [
            view.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            view.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        ]
        onWebViewCreated?(view)
        return view
    }

    /// Restored background tabs stay dormant until selected.
    public func activate() {
        guard !hasLoaded, let url else { return }
        navigate(to: url)
    }

    public func navigate(to destination: URL) {
        guard AddressResolver.isWebURL(destination) else { return }
        errorMessage = nil
        url = destination
        title = destination.host ?? "Website"
        hasLoaded = true
        isLoading = true
        webView.load(URLRequest(url: destination))
        onChange?()
    }

    public func goBack() { errorMessage = nil; backingWebView?.goBack() }
    public func goForward() { errorMessage = nil; backingWebView?.goForward() }
    public func reload() {
        errorMessage = nil
        if backingWebView?.url != nil { backingWebView?.reload() }
        else if let url { navigate(to: url) }
    }
    public func stop() { backingWebView?.stopLoading(); isLoading = false }
    public func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    public func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    public func resetZoom() { backingWebView?.pageZoom = 1 }
    public func find(_ text: String) {
        guard !text.isEmpty else { return }
        backingWebView?.find(text, configuration: WKFindConfiguration()) { _ in }
    }
    public func dismissError() { errorMessage = nil }

    public func close() {
        isClosed = true
        policyGeneration += 1
        backingWebView?.stopLoading()
        backingWebView?.navigationDelegate = nil
        backingWebView?.uiDelegate = nil
        observations.removeAll()
        backingWebView = nil
    }

    public func refreshContentBlocking() {
        guard let view = backingWebView, let adBlocker else { return }
        Task { @MainActor [weak self] in
            do {
                if adBlocker.mode != .off { try await adBlocker.prepare() }
                guard let self, !self.isClosed else { return }
                adBlocker.applyPrepared(to: view.configuration.userContentController,
                                        url: view.url ?? self.url, isPrivate: self.isPrivate)
            } catch { /* Navigation reports preparation failure before loading. */ }
        }
    }

    private func refresh() {
        guard let view = backingWebView else { return }
        // Display the actual document URL even for about/blob pages. Never leave an
        // earlier HTTPS origin in the address bar after the document has changed.
        if let current = view.url { url = current }
        if let currentTitle = view.title, !currentTitle.isEmpty { title = currentTitle }
        isLoading = view.isLoading
        progress = view.estimatedProgress
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        onChange?()
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        documentRevision += 1
        errorMessage = nil
        hasLoaded = true
        refresh()
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh()
        if let url, AddressResolver.isWebURL(url) { onVisit?(url, displayTitle) }
    }
    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        adBlocker?.applyPrepared(to: webView.configuration.userContentController,
                                url: webView.url, isPrivate: isPrivate)
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { handle(error) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        errorMessage = "This tab’s website process stopped. Reload to continue."
    }
    private func handle(_ error: Error) {
        let nsError = error as NSError
        // Cancelled navigation and downloads are not failed page loads.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
              !(nsError.domain == "WebKitErrorDomain" && nsError.code == 102) else { return }
        isLoading = false
        errorMessage = error.localizedDescription
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob", "data"].contains(scheme) {
            let policy: WKNavigationActionPolicy = navigationAction.shouldPerformDownload ? .download : .allow
            guard navigationAction.targetFrame?.isMainFrame == true, let adBlocker else {
                decisionHandler(policy); return
            }
            policyGeneration += 1
            let generation = policyGeneration
            Task { @MainActor [weak self] in
                do {
                    if adBlocker.mode != .off { try await adBlocker.prepare() }
                    guard let self, !self.isClosed, self.policyGeneration == generation else {
                        decisionHandler(.cancel); return
                    }
                    adBlocker.applyPrepared(to: webView.configuration.userContentController, url: url, isPrivate: self.isPrivate)
                    decisionHandler(policy)
                } catch {
                    guard let self, !self.isClosed, self.policyGeneration == generation else {
                        decisionHandler(.cancel); return
                    }
                    self.isLoading = false
                    self.errorMessage = adBlocker.preparationError
                    decisionHandler(.cancel)
                }
            }
        } else {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, ["mailto", "tel"].contains(scheme) {
                onExternalURL?(url)
            }
        }
    }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        onDownload?(download)
    }
    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        onDownload?(download)
    }
}
