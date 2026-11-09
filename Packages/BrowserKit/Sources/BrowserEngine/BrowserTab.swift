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
    public private(set) var content: TabContent
    public private(set) var isLoading = false
    public private(set) var progress = 0.0
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var errorMessage: String?
    public private(set) var hasLoaded = false
    public private(set) var isPinned: Bool
    public private(set) var pageZoom: Double = 1
    public private(set) var findResult: Bool?
    public private(set) var mediaSuspended = false
    public private(set) var isProfileActive = true
    public private(set) var isCapturingCamera = false
    public private(set) var isCapturingMicrophone = false
    public private(set) var hasOnlySecureContent = false
    public private(set) var hasEditedFields = false

    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public var onVisit: ((URL, String) -> Void)?
    @ObservationIgnored public var onTitleChange: ((URL, String) -> Void)?
    @ObservationIgnored public var onWebViewCreated: ((WKWebView) -> Void)?
    @ObservationIgnored public var onDownload: ((WKDownload) -> Void)?
    @ObservationIgnored public var onExternalURL: ((URL) -> Void)?
    @ObservationIgnored public var onOpenLink: ((URL, Bool) -> Void)?
    @ObservationIgnored public var onAuthentication: ((URLAuthenticationChallenge, @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void)?
    @ObservationIgnored private var backingWebView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let configuration: WKWebViewConfiguration
    @ObservationIgnored private let adBlocker: AdBlocker?
    @ObservationIgnored private let settings: BrowserSettings?
    @ObservationIgnored private var policyGeneration = 0
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var lastVisitedURL: URL?
    @ObservationIgnored private var isSelected = false
    @ObservationIgnored private var contentProcessTerminated = false
    @ObservationIgnored private var pendingNavigationMethod: String?
    @ObservationIgnored private var committedNavigationMethod: String?
    @ObservationIgnored private var lastAutomaticReload: TimeInterval?
    // Internal seams exercise real delegate paths without killing a WebKit process or replaying a form.
    @ObservationIgnored var recoveryClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var createWebView: (WKWebViewConfiguration) -> WKWebView = { WKWebView(frame: .zero, configuration: $0) }

    public init(record: TabRecord = TabRecord(), isPrivate: Bool = false,
                configuration: WKWebViewConfiguration? = nil, dataStore: WKWebsiteDataStore = .default(),
                adBlocker: AdBlocker? = nil, settings: BrowserSettings? = nil) {
        id = record.id
        title = record.title
        url = record.url
        content = configuration != nil ? .web : record.content
        isPinned = record.isPinned
        self.isPrivate = isPrivate
        self.settings = settings
        pageZoom = settings?.defaultZoom ?? 1
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
        let world = WKContentWorld.world(name: "OrivTabState")
        contentController.add(EditedFieldHandler(tab: self), contentWorld: world, name: "editedField")
        contentController.addUserScript(WKUserScript(source: """
            (() => {
            if (window.orivEditTracking) return;
            window.orivEditTracking = true;
            let reported = false;
            function reportEdit(event) {
                if (!reported && event.isTrusted && (event.target.matches('input,textarea,select') || event.target.isContentEditable)) {
                    reported = true; window.webkit.messageHandlers.editedField.postMessage(true);
                }
            }
            document.addEventListener('input', reportEdit, true);
            document.addEventListener('change', reportEdit, true);
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
    }

    public var record: TabRecord {
        let restorableURL = url.flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
        return TabRecord(id: id, title: restorableURL == nil ? "New tab" : title,
                         url: restorableURL, isPinned: isPinned,
                         content: restorableURL == nil ? .home : .web)
    }
    public var displayTitle: String {
        // Presentation only: the legacy stored home title remains unchanged in record.
        if url == nil && (title.isEmpty || title == "New tab") { return "New Tab" }
        return title.isEmpty ? (url?.host ?? "New Tab") : title
    }
    public var hostname: String { url?.host ?? (isPrivate ? "Private browsing" : "Start page") }

    public var isSecure: Bool { url?.scheme == "https" && hasOnlySecureContent && !isLoading && errorMessage == nil }
    public var isInstantiated: Bool { backingWebView != nil }

    public var webView: WKWebView {
        if let backingWebView { return backingWebView }
        // A popup can execute in its initial about:blank document before a
        // navigation callback. Install the opener session's prepared protection now.
        adBlocker?.applyPrepared(to: configuration.userContentController, url: url, isPrivate: isPrivate)
        let view = createWebView(configuration)
        view.pageZoom = pageZoom
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
            view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            view.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            view.observe(\.cameraCaptureState, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            view.observe(\.microphoneCaptureState, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        ]
        onWebViewCreated?(view)
        applySiteSettings()
        view.setAllMediaPlaybackSuspended(mediaSuspended || !isProfileActive, completionHandler: nil)
        return view
    }

    /// Restored background tabs stay dormant until selected.
    public func activate() {
        recoverContentProcessIfPossible()
        guard !hasLoaded, let url else { return }
        navigate(to: url)
    }

    public func navigate(to destination: URL) {
        guard AddressResolver.isWebURL(destination) else { return }
        let previous = record
        lastVisitedURL = nil
        contentProcessTerminated = false
        errorMessage = nil
        content = .web
        url = destination
        title = destination.host ?? "Website"
        hasLoaded = true
        isLoading = true
        webView.load(URLRequest(url: destination))
        if record != previous { onChange?() }
    }

    public func goBack() { errorMessage = nil; backingWebView?.goBack() }
    public func goForward() { errorMessage = nil; backingWebView?.goForward() }
    public func reload() {
        errorMessage = nil
        if backingWebView?.url != nil { backingWebView?.reload() }
        else if let url { navigate(to: url) }
    }
    public func stop() { backingWebView?.stopLoading(); isLoading = false }
    public func reloadFromOrigin() { errorMessage = nil; backingWebView?.reloadFromOrigin() }
    public func zoomIn() { setZoom(pageZoom + 0.1) }
    public func zoomOut() { setZoom(pageZoom - 0.1) }
    public func resetZoom() { setZoom(1) }
    private func setZoom(_ value: Double) { pageZoom = min(max((value * 100).rounded() / 100, 0.5), 3); backingWebView?.pageZoom = pageZoom }
    public func setPinned(_ value: Bool) {
        let previous = record
        isPinned = value
        if record != previous { onChange?() }
    }
    public func find(_ text: String, backwards: Bool = false, caseSensitive: Bool = false) {
        guard !text.isEmpty else { findResult = nil; return }
        let options = WKFindConfiguration(); options.backwards = backwards; options.caseSensitive = caseSensitive; options.wraps = true
        backingWebView?.find(text, configuration: options) { [weak self] result in self?.findResult = result.matchFound }
    }
    public func clearFind() { findResult = nil }
    public func toggleMediaSuspension() { mediaSuspended.toggle(); backingWebView?.setAllMediaPlaybackSuspended(mediaSuspended || !isProfileActive, completionHandler: nil) }
    public func setProfileActive(_ active: Bool) {
        isProfileActive = active
        if !active { stopCapture() }
        backingWebView?.setAllMediaPlaybackSuspended(mediaSuspended || !active, completionHandler: nil)
        if active { recoverContentProcessIfPossible() }
    }
    func setSelected(_ selected: Bool) {
        isSelected = selected
        if selected { recoverContentProcessIfPossible() }
    }
    public func stopCapture() {
        backingWebView?.setCameraCaptureState(.none, completionHandler: nil)
        backingWebView?.setMicrophoneCaptureState(.none, completionHandler: nil)
    }
    public func applySiteSettings() {
        guard let view = backingWebView else { return }
        let rule = settings?.rule(for: url, isPrivate: isPrivate) ?? SiteRule()
        view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = rule.allowsAutomaticPopups
        if rule.camera == .block { view.setCameraCaptureState(.none, completionHandler: nil) }
        if rule.microphone == .block { view.setMicrophoneCaptureState(.none, completionHandler: nil) }
    }
    public func dismissError() { errorMessage = nil }

    public func close() {
        isClosed = true
        policyGeneration += 1
        backingWebView?.stopLoading()
        backingWebView?.navigationDelegate = nil
        backingWebView?.uiDelegate = nil
        observations.removeAll()
        configuration.userContentController.removeScriptMessageHandler(forName: "editedField", contentWorld: .world(name: "OrivTabState"))
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
        refresh(from: view)
    }

    func refresh(from view: WKWebView) {
        guard !isClosed else { return }
        let previous = record
        let previousTitle = title
        // Display the actual document URL even for about/blob pages. Never leave an
        // earlier HTTPS origin in the address bar after the document has changed.
        if let current = view.url { url = current }
        if let currentTitle = view.title, !currentTitle.isEmpty { title = currentTitle }
        isLoading = view.isLoading
        progress = view.estimatedProgress
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        hasOnlySecureContent = view.hasOnlySecureContent
        isCapturingCamera = view.cameraCaptureState != .none
        isCapturingMicrophone = view.microphoneCaptureState != .none
        if record != previous { onChange?() }
        if title != previousTitle, let url, url == lastVisitedURL, !isPrivate {
            onTitleChange?(url, displayTitle)
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        documentRevision += 1
        errorMessage = nil
        hasLoaded = true
        findResult = nil
        refresh(from: webView)
    }
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committedNavigationMethod = pendingNavigationMethod
        pendingNavigationMethod = nil
        contentProcessTerminated = false
        lastVisitedURL = nil
        hasEditedFields = false
        refresh(from: webView)
        applySiteSettings()
    }
    func recordFieldEdit() { if !isClosed { hasEditedFields = true } }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh(from: webView)
        if let url, AddressResolver.isWebURL(url), !isPrivate {
            lastVisitedURL = url
            onVisit?(url, displayTitle)
        }
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
        guard !isClosed else { return }
        isLoading = false
        contentProcessTerminated = true
        errorMessage = "This tab’s website process stopped. Reload to continue."
        recoverContentProcessIfPossible()
    }

    private func recoverContentProcessIfPossible() {
        // Reload the existing view in its original (including ephemeral private) store.
        // No tab, navigation record, history entry or continuity record is exported here.
        guard contentProcessTerminated, isSelected, isProfileActive, !isClosed,
              !hasEditedFields, (pendingNavigationMethod ?? committedNavigationMethod) == "GET",
              committedNavigationMethod != "POST", let view = backingWebView,
              view.url.map(AddressResolver.isWebURL) == true else { return }
        let now = recoveryClock()
        guard lastAutomaticReload.map({ now - $0 >= 30 }) ?? true else { return }
        lastAutomaticReload = now
        contentProcessTerminated = false
        errorMessage = nil
        isLoading = true
        view.reload()
    }

    func recordAllowedMainFrameNavigation(_ request: URLRequest) {
        pendingNavigationMethod = request.httpMethod?.uppercased() ?? "GET"
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
        if ["http", "https"].contains(scheme), !AddressResolver.isWebURL(url) { decisionHandler(.cancel); return }
        #if os(macOS)
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command), AddressResolver.isWebURL(url) {
            onOpenLink?(url, navigationAction.modifierFlags.contains(.shift)); decisionHandler(.cancel); return
        }
        #endif
        if ["http", "https", "about", "blob", "data"].contains(scheme) {
            let policy: WKNavigationActionPolicy = navigationAction.shouldPerformDownload ? .download : .allow
            let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
            guard navigationAction.targetFrame?.isMainFrame == true, let adBlocker else {
                if isMainFrame && policy == .allow { recordAllowedMainFrameNavigation(navigationAction.request) }
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
                    if policy == .allow { self.recordAllowedMainFrameNavigation(navigationAction.request) }
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
    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault].contains(method),
              let onAuthentication else { completionHandler(.performDefaultHandling, nil); return }
        onAuthentication(challenge, completionHandler)
    }
}

@MainActor private final class EditedFieldHandler: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(tab: BrowserTab) { self.tab = tab }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? Bool == true { tab?.recordFieldEdit() }
    }
}
