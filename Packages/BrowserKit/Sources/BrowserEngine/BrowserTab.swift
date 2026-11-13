import BrowserCore
import Foundation
import Observation
import WebKit
#if os(iOS)
import UIKit
#endif

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
    public private(set) var isRestoringWebView = false
    public private(set) var isPinned: Bool
    public private(set) var pageZoom: Double = 1
    public private(set) var findResult: Bool?
    public private(set) var mediaSuspended = false
    public private(set) var isProfileActive = true
    public private(set) var isCapturingCamera = false
    public private(set) var isCapturingMicrophone = false
    public private(set) var hasOnlySecureContent = false
    public private(set) var hasEditedFields = false
    public private(set) var httpWarningURL: URL?
    @ObservationIgnored private var pendingHTTPUpgrade: URL?
    @ObservationIgnored private var pendingCleanedURL: URL?
    public var cleanedURL: URL? { url.map(URLCleaner.clean) }

    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public var onVisit: ((URL, String) -> Void)?
    @ObservationIgnored public var onTitleChange: ((URL, String) -> Void)?
    @ObservationIgnored public var onWebViewDiscarded: (() -> Void)?
    @ObservationIgnored public var onWebViewCreated: ((WKWebView) -> Void)?
    @ObservationIgnored public var onDownload: ((WKDownload) -> Void)?
    @ObservationIgnored public var onExternalURL: ((URL) -> Void)?
    @ObservationIgnored public var onOpenLink: ((URL, Bool) -> Void)?
    @ObservationIgnored public var onAuthentication: ((URLAuthenticationChallenge, @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void)?
    @ObservationIgnored private var savedInteractionState: Any?
    @ObservationIgnored private var savedViewSize: CGSize?
    @ObservationIgnored private var savedScrollOffset: CGPoint?
    @ObservationIgnored private var applyingRestoration = false
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
        if let size = savedViewSize { view.frame = CGRect(origin:.zero,size:size); savedViewSize = nil }
        view.pageZoom = pageZoom
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        #if os(iOS)
        view.isFindInteractionEnabled = true
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        view.scrollView.refreshControl = refresh
        view.scrollView.alwaysBounceVertical = true
        #endif
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
        #if os(iOS)
        observations.append(view.scrollView.observe(\.contentSize,options:[.new]) { [weak self] _,_ in
            Task { @MainActor [weak self] in self?.restoreScrollPosition() }
        })
        #endif
        onWebViewCreated?(view)
        applySiteSettings()
        view.setAllMediaPlaybackSuspended(mediaSuspended || !isProfileActive, completionHandler: nil)
        if let state = savedInteractionState {
            savedInteractionState = nil; hasLoaded = true; isRestoringWebView = true
            view.interactionState = state
        }
        return view
    }

    /// Restored background tabs stay dormant until selected.
    public func activate() {
        if savedInteractionState != nil { _ = webView; return }
        recoverContentProcessIfPossible()
        guard !hasLoaded, let url else { return }
        navigate(to: url)
    }

    #if os(iOS)
    /// Reclaim only an unattached, idle GET page. Forms, private tabs, media,
    /// loading pages and selected tabs retain their live state. WebKit's public
    /// interaction state preserves its history and scroll position in memory.
    public func discardBackgroundWebView(completion:@escaping @MainActor (Bool) -> Void) {
        guard let view = backingWebView, canDiscard(view) else { completion(false); return }
        let revision = documentRevision
        view.requestMediaPlaybackState { [weak self,weak view] playback in
            Task { @MainActor in
                guard let self, let view, playback == .none, self.canDiscard(view), self.documentRevision == revision else { completion(false); return }
                // An unattached WebKit page can have a DOM scroll position that
                // UIScrollView has not mirrored yet. Read only its coordinates.
                view.evaluateJavaScript("[scrollX,scrollY]") { [weak self,weak view] value,_ in
                    guard let self, let view, self.canDiscard(view), self.documentRevision == revision,
                          let state = view.interactionState else { completion(false); return }
                    let offset = value as? [Double]
                    let scroll = view.scrollView
                    self.savedScrollOffset = offset.flatMap { $0.count == 2 ? CGPoint(x:$0[0],y:$0[1]) : nil } ??
                        CGPoint(x:scroll.contentOffset.x+scroll.contentInset.left,y:scroll.contentOffset.y+scroll.contentInset.top)
                    self.onWebViewDiscarded?()
                    self.policyGeneration += 1; self.observations.removeAll()
                    view.navigationDelegate = nil; view.uiDelegate = nil; self.onAuthentication = nil
                    self.savedViewSize = view.bounds.size
                    self.savedInteractionState = state; self.backingWebView = nil; self.hasLoaded = false
                    completion(true)
                }
            }
        }
    }

    private func restoreScrollPosition(force:Bool = false) {
        guard let target = savedScrollOffset, let view = backingWebView, isRestoringWebView,
              !applyingRestoration, force || !view.isLoading else { return }
        guard !view.scrollView.isTracking else { savedScrollOffset = nil; isRestoringWebView = false; return }
        applyingRestoration = true
        let revision = documentRevision
        view.evaluateJavaScript("window.scrollTo(\(target.x),\(target.y)); void 0") { [weak self,weak view] _,_ in
            guard let self else { return }
            self.applyingRestoration = false
            guard self.backingWebView === view, self.documentRevision == revision else { return }
            self.savedScrollOffset = nil; self.isRestoringWebView = false
        }
    }

    private func canDiscard(_ view:WKWebView) -> Bool {
        !isClosed && !isSelected && !isPrivate && !hasEditedFields && !isLoading && !view.isLoading && view.url == url &&
                !isCapturingCamera && !isCapturingMicrophone && view.superview == nil &&
                backingWebView === view && url.map(AddressResolver.isWebURL) == true &&
                (committedNavigationMethod == nil || committedNavigationMethod == "GET")
    }

    #endif

    public func navigate(to destination: URL) {
        guard AddressResolver.isWebURL(destination) else { return }
        let destination = settings?.privacy.cleanedNavigationURL(destination, isPrivate: isPrivate) ?? URLCleaner.clean(destination)
        savedInteractionState = nil; savedViewSize = nil; savedScrollOffset = nil; isRestoringWebView = false; applyingRestoration = false
        pendingHTTPUpgrade = nil
        httpWarningURL = nil
        pendingCleanedURL = nil
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

    public func goBack() { httpWarningURL = nil; pendingHTTPUpgrade = nil; errorMessage = nil; backingWebView?.goBack() }
    public func goForward() { httpWarningURL = nil; pendingHTTPUpgrade = nil; errorMessage = nil; backingWebView?.goForward() }
    public func go(to item: WKBackForwardListItem) {
        guard let view = backingWebView,
              (view.backForwardList.backList + view.backForwardList.forwardList).contains(where: { $0 === item }) else { return }
        errorMessage = nil; view.go(to: item)
    }
    #if os(iOS)
    @objc private func pullToRefresh() { reload() }
    public func showFind() { webView.findInteraction?.presentFindNavigator(showingReplace: false) }
    #endif
    private func endRefreshing() {
        #if os(iOS)
        backingWebView?.scrollView.refreshControl?.endRefreshing()
        #endif
    }
    public func reload() {
        errorMessage = nil
        if backingWebView?.url != nil { backingWebView?.reload() }
        else if let url { navigate(to: url) }
    }
    public func stop() { backingWebView?.stopLoading(); isLoading = false; isRestoringWebView = false; savedScrollOffset = nil; endRefreshing() }
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
        #if os(iOS)
        if !selected {
            backingWebView?.findInteraction?.searchText = nil
            backingWebView?.findInteraction?.dismissFindNavigator()
            backingWebView?.endEditing(true)
            // Removing the interaction also handles a tab switch during the
            // navigator's presentation animation, when dismiss alone is ignored.
            backingWebView?.isFindInteractionEnabled = false
        } else { backingWebView?.isFindInteractionEnabled = true }
        #endif
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
    /// WebKit's user-mediated fallback is intercepted before any unencrypted reload.
    /// Only the original GET is eligible; certificate errors never arrive here as a bypass.
    public func continueToHTTP() {
        guard let destination = httpWarningURL else { return }
        settings?.privacy.setException(true, .httpsUpgrade, for: destination, isPrivate: isPrivate)
        httpWarningURL = nil; pendingHTTPUpgrade = nil
        navigate(to: destination)
    }
    func interceptHTTPFallback(_ request: URLRequest, kind: PrivacyNavigationKind) -> Bool {
        guard let destination = request.url, destination.scheme == "http", kind == .newNavigation,
              (request.httpMethod ?? "GET").uppercased() == "GET", request.httpBody == nil, request.httpBodyStream == nil else { return false }
        if let pendingHTTPUpgrade, Self.sameHTTPAttempt(pendingHTTPUpgrade, destination) {
            httpWarningURL = destination; isLoading = false
            return true
        }
        pendingHTTPUpgrade = destination
        return false
    }
    private static func sameHTTPAttempt(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? 80) == (b.port ?? 80)
            && (a.percentEncodedPath.isEmpty ? "/" : a.percentEncodedPath) == (b.percentEncodedPath.isEmpty ? "/" : b.percentEncodedPath)
            && a.percentEncodedQuery == b.percentEncodedQuery
    }
    public func cancelHTTPFallback() {
        httpWarningURL = nil; pendingHTTPUpgrade = nil; errorMessage = nil; isLoading = false
        // The failed/replaced navigation never committed a history item. Reveal
        // the current document instead of traversing past it or replaying a form.
        if let current = backingWebView?.backForwardList.currentItem {
            url = current.url; title = current.title ?? current.url.host ?? "Website"
        } else { url = nil; title = "New tab"; content = .home; hasLoaded = false }
        onChange?()
    }

    public func close() {
        endRefreshing()
        #if os(iOS)
        backingWebView?.findInteraction?.dismissFindNavigator()
        #endif
        savedInteractionState = nil; savedViewSize = nil; savedScrollOffset = nil
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
                if adBlocker.mode != .off || adBlocker.cookieBannersEnabled { try await adBlocker.prepare() }
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

    public static let navigationStarted = Notification.Name("OrivNavigationStarted")

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        #if os(iOS)
        webView.findInteraction?.dismissFindNavigator()
        #endif
        NotificationCenter.default.post(name: Self.navigationStarted, object: webView)
        documentRevision += 1
        errorMessage = nil
        hasLoaded = true
        findResult = nil
        refresh(from: webView)
    }
    #if DEBUG
    public static let navigationCommitted = Notification.Name("OrivNavigationCommitted")
    #endif

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        #if DEBUG
        NotificationCenter.default.post(name: Self.navigationCommitted, object: webView)
        #endif
        httpWarningURL = nil
        pendingHTTPUpgrade = nil
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
        #if os(iOS)
        restoreScrollPosition(force:true)
        #endif
        endRefreshing()
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
        endRefreshing()
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
        isRestoringWebView = false; savedScrollOffset = nil; applyingRestoration = false
        endRefreshing()
        let nsError = error as NSError
        let certificateCodes = [NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                                NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
                                NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired]
        if nsError.domain == NSURLErrorDomain && certificateCodes.contains(nsError.code) {
            pendingHTTPUpgrade = nil
            httpWarningURL = nil
        }
        // Cancelled navigation and downloads are not failed page loads.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
              !(nsError.domain == "WebKitErrorDomain" && nsError.code == 102) else { return }
        isLoading = false
        errorMessage = error.localizedDescription
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        self.webView(webView, decidePolicyFor: navigationAction, preferences: WKWebpagePreferences()) { policy, _ in decisionHandler(policy) }
    }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        preferences: WKWebpagePreferences,
                        decisionHandler preferencesHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let decisionHandler: @MainActor (WKNavigationActionPolicy) -> Void = { preferencesHandler($0, preferences) }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let mainFrame = navigationAction.targetFrame?.isMainFrame == true
        let kind: PrivacyNavigationKind = navigationAction.navigationType == .backForward ? .backForward : navigationAction.navigationType == .reload ? .reload : .newNavigation
        if mainFrame {
            settings?.privacy.apply(to: preferences, request: navigationAction.request, isPrivate: isPrivate)
            let enabled = (settings?.privacy.isEnabled(.linkCleaning, for: url, isPrivate: isPrivate) ?? true) && (settings?.privacy.isEnabled(.linkCleaning, for: webView.url, isPrivate: isPrivate) ?? true)
            if pendingCleanedURL == url { pendingCleanedURL = nil }
            else if !navigationAction.shouldPerformDownload,
                    let replacement = NavigationCleaningPolicy.replacement(for: navigationAction.request, source: webView.url ?? navigationAction.sourceFrame.request.url, isMainFrame: true, kind: kind, enabled: enabled) {
                pendingCleanedURL = replacement
                var request = navigationAction.request
                request.url = replacement
                decisionHandler(.cancel)
                webView.load(request)
                return
            }
            if preferences.preferredHTTPSNavigationPolicy == .userMediatedFallbackToHTTP {
                if interceptHTTPFallback(navigationAction.request, kind: kind) {
                    decisionHandler(.cancel)
                    return
                }
            } else if url.scheme == "http" { pendingHTTPUpgrade = nil }
        }
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
                    if adBlocker.mode != .off || adBlocker.cookieBannersEnabled { try await adBlocker.prepare() }
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
