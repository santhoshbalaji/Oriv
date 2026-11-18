import BrowserCore
import Foundation
import Observation
import WebKit
#if os(macOS)
import AppKit
#else
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
    public private(set) var isRestoringWebView = false {
        didSet { if !isRestoringWebView { notifyDocumentReady() } }
    }
    /// The committed document has painted, or completed as an empty document.
    /// Attachment still requires a native rendering barrier before revealing it.
    public private(set) var hasRenderedContent = false
    /// The native host owns this weak presentation marker until its destination
    /// cover is gone. Optional document work must not compete with that handoff.
    public weak var switchPresentation: AnyObject? {
        didSet { if switchPresentation == nil { notifyDocumentReady() } }
    }
    public private(set) var lastPageBackground: ChromeColor?
    public var switchSnapshot: TabSnapshotCache.Snapshot? { snapshotCache?.snapshot(for: id) }
    @ObservationIgnored var snapshotCache: TabSnapshotCache?
    @ObservationIgnored private var snapshotGeneration = 0
    @ObservationIgnored private var expectedPaintDocument: Double?
    @ObservationIgnored private var paintedDocuments: Set<Double> = []
    public private(set) var isPinned: Bool
    public private(set) var pageZoom: Double = 1
    public private(set) var findResult: Bool?
    public private(set) var mediaSuspended = false
    /// Mac sidebar metadata, updated by media events without a row polling loop.
    public private(set) var isPlayingAudio = false
    #if os(macOS)
    @ObservationIgnored private var audibleFrames: Set<String> = []
    #endif
    public private(set) var isProfileActive = true
    public private(set) var isCapturingCamera = false
    public private(set) var isCapturingMicrophone = false
    public private(set) var hasOnlySecureContent = false
    public private(set) var hasEditedFields = false
    public private(set) var hasRequestedDisplayCapture = false
    public private(set) var httpWarningURL: URL?
    private struct HTTPUpgradeAttempt {
        let url:URL
        var navigation:WKNavigation?
    }
    @ObservationIgnored private var pendingHTTPUpgrade: HTTPUpgradeAttempt?
    @ObservationIgnored private var pendingCleanedURL: URL?
    public var cleanedURL: URL? { url.map(URLCleaner.clean) }

    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public var onVisit: ((URL, String) -> Void)?
    @ObservationIgnored var onDocumentReady: ((URL) -> Void)?
    @ObservationIgnored private var finishedDocumentRevision: Int?
    @ObservationIgnored public var onTitleChange: ((URL, String) -> Void)?
    @ObservationIgnored public var onWebViewDiscarded: (() -> Void)?
    @ObservationIgnored public var onWebViewCreated: ((WKWebView) -> Void)?
    @ObservationIgnored public var onDownload: ((WKDownload) -> Void)?
    @ObservationIgnored public var onExternalURL: ((URL) -> Void)?
    @ObservationIgnored public var onOpenLink: ((URL, Bool) -> Void)?
    @ObservationIgnored public var onAuthentication: ((URLAuthenticationChallenge, @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void)?
    @ObservationIgnored var discardTimeout:Duration = .seconds(8)
    @ObservationIgnored var lastSelectedTime = ProcessInfo.processInfo.systemUptime
    /// The platform download owner includes active and resumable downloads.
    @ObservationIgnored public var hasActiveDownloads: (() -> Bool)?
    @ObservationIgnored private var didStartDownload = false
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
    @ObservationIgnored private var pendingNavigationHasBody = false
    @ObservationIgnored private var committedNavigationHasBody = false
    @ObservationIgnored private var lastAutomaticReload: TimeInterval?
    // Internal seams exercise real delegate paths without killing a WebKit process or replaying a form.
    @ObservationIgnored var recoveryClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var createWebView: (WKWebViewConfiguration) -> WKWebView = { WKWebView(frame: .zero, configuration: $0) }
    #if DEBUG
    @ObservationIgnored var onScrollRestorationCheck: ((CGPoint, CGPoint, CGPoint?, Int) -> Void)?
    #endif

    public init(record: TabRecord = TabRecord(), isPrivate: Bool = false,
                configuration: WKWebViewConfiguration? = nil, dataStore: WKWebsiteDataStore = .default(),
                adBlocker: AdBlocker? = nil, settings: BrowserSettings? = nil) {
        id = record.id
        title = record.title
        url = record.url
        content = configuration != nil ? .web : record.content
        isPinned = record.isPinned && !isPrivate
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
        contentController.add(TabPaintHandler(tab: self), contentWorld: world, name: "tabPaint")
        if !contentController.userScripts.contains(where: { $0.source == Self.paintScript }) {
            contentController.addUserScript(WKUserScript(source: Self.paintScript, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: world))
        }
        let editedFieldScript = WKUserScript(source: """
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
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
        if !contentController.userScripts.contains(where: { $0.source == editedFieldScript.source }) {
            contentController.addUserScript(editedFieldScript)
        }
        #if os(macOS)
        contentController.add(TabAudioHandler(tab: self), contentWorld: world, name: "tabAudio")
        let audioScript = WKUserScript(source: """
            (() => {
                const frame = globalThis.crypto?.randomUUID?.() ?? String(Math.random());
                let previous = false;
                const report = () => {
                    const audible = [...document.querySelectorAll('audio,video')].some(m => !m.paused && !m.ended && !m.muted && m.volume > 0);
                    if (audible === previous) return;
                    previous = audible;
                    window.webkit.messageHandlers.tabAudio.postMessage({frame, audible});
                };
                ['play','playing','pause','ended','volumechange','emptied'].forEach(e => document.addEventListener(e, report, true));
                window.addEventListener('pagehide', () => { previous = false; window.webkit.messageHandlers.tabAudio.postMessage({frame, audible:false}); });
                window.addEventListener('pageshow', report);
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
        if !contentController.userScripts.contains(where: { $0.source == audioScript.source }) { contentController.addUserScript(audioScript) }
        // Public WebKit has no display-capture state property. Conservatively
        // protect a document for its entire lifetime after any display request,
        // including a pending/denied request. Read no stream or page contents.
        contentController.add(DisplayCaptureHandler(tab: self), contentWorld: .page, name: "displayCaptureRequested")
        let displayCaptureScript = WKUserScript(source: """
            (() => {
                const protect = () => {
                    try { window.webkit.messageHandlers.displayCaptureRequested.postMessage(true); } catch {}
                };
                try {
                    const proto = window.MediaDevices?.prototype;
                    const original = proto?.getDisplayMedia;
                    if (!original) return;
                    const wrapped = new Proxy(original, { apply(target, receiver, args) {
                        protect(); return Reflect.apply(target, receiver, args);
                    }});
                    proto.getDisplayMedia = wrapped;
                    if (proto.getDisplayMedia !== wrapped) protect();
                } catch { protect(); }
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        if !contentController.userScripts.contains(where: { $0.source == displayCaptureScript.source }) {
            contentController.addUserScript(displayCaptureScript)
        }
        #endif
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
        hasRenderedContent = false
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
            // Only a committed GET can enter the saved-state path. WebKit may
            // restore it without sending a fresh navigation-action callback.
            pendingNavigationMethod = "GET"
            pendingNavigationHasBody = false
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

    /// Reclaim only an unattached, idle GET page. Forms, private tabs, media,
    /// loading pages and selected tabs retain their live state. WebKit's public
    /// interaction state preserves its history and scroll position in memory.
    public func discardBackgroundWebView(minimumIdle: TimeInterval = 0, completion:@escaping @MainActor (Bool) -> Void) {
        guard let view = backingWebView, canDiscard(view, minimumIdle: minimumIdle) else { completion(false); return }
        let revision = documentRevision
        let request = DiscardRequest(timeout:discardTimeout,completion:completion)
        view.requestMediaPlaybackState { [weak self,weak view,request] playback in
            Task { @MainActor in
                guard request.isPending, let self, let view, playback == .none, self.canDiscard(view, minimumIdle: minimumIdle), self.documentRevision == revision else { request.finish(false); return }
                // An unattached WebKit page can have a DOM scroll position that
                // UIScrollView has not mirrored yet. Read only its coordinates.
                view.evaluateJavaScript("[scrollX,scrollY]") { [weak self,weak view,request] value,_ in
                    guard request.isPending, let view else { request.finish(false); return }
                    let offset = value as? [Double]
                    // Playback may start while JavaScript/IPC is in flight. Make
                    // its final query the last asynchronous step before release.
                    view.requestMediaPlaybackState { [weak self,weak view,request] playback in
                        guard request.isPending, let self, let view, playback == .none,
                              self.canDiscard(view, minimumIdle: minimumIdle), self.documentRevision == revision,
                              let state = view.interactionState else { request.finish(false); return }
                        self.savedScrollOffset = offset.flatMap { $0.count == 2 && $0.allSatisfy(\.isFinite) ? CGPoint(x:$0[0],y:$0[1]) : nil }
                        #if os(iOS)
                        if self.savedScrollOffset == nil {
                            let scroll = view.scrollView
                            self.savedScrollOffset = CGPoint(x:scroll.contentOffset.x+scroll.contentInset.left,y:scroll.contentOffset.y+scroll.contentInset.top)
                        }
                        #endif
                        guard self.savedScrollOffset != nil else { request.finish(false); return }
                        self.onWebViewDiscarded?()
                        self.policyGeneration += 1; self.observations.removeAll()
                        view.navigationDelegate = nil; view.uiDelegate = nil; self.onAuthentication = nil
                        self.savedViewSize = view.bounds.size
                        self.savedInteractionState = state; self.backingWebView = nil; self.hasLoaded = false
                        self.hasRenderedContent = false
                        request.finish(true)
                    }
                }
            }
        }
    }

    @MainActor private final class DiscardRequest {
        private var completion:(@MainActor (Bool) -> Void)?
        private var timeout:Task<Void,Never>?
        var isPending:Bool { completion != nil }
        init(timeout duration:Duration,completion:@escaping @MainActor (Bool) -> Void) {
            self.completion = completion
            // Keep the one-shot completion alive even if WebKit drops its
            // callback. The deadline or a reply breaks this bounded ownership.
            timeout = Task { @MainActor in
                do { try await Task.sleep(for:duration) } catch { return }
                self.finish(false)
            }
        }
        func finish(_ discarded:Bool) {
            guard let completion else { return }
            self.completion = nil; timeout?.cancel(); timeout = nil
            completion(discarded)
        }
    }

    private func restoreScrollPosition(force:Bool = false) {
        guard let target = savedScrollOffset, let view = backingWebView, isRestoringWebView,
              !applyingRestoration, view.url.map(AddressResolver.isWebURL) == true,
              force || (hasRenderedContent && !view.isLoading) else { return }
        #if os(iOS)
        guard !view.scrollView.isTracking else { savedScrollOffset = nil; isRestoringWebView = false; return }
        #endif
        applyingRestoration = true
        applySavedScroll(target,in:view,revision:documentRevision,attempt:0)
    }

    private func applySavedScroll(_ target:CGPoint,in view:WKWebView,revision:Int,attempt:Int) {
        // A scrollTo acknowledgement at didFinish is not a stable restored
        // viewport: WebKit can subsequently apply its own history scroll. Read
        // back layout, then verify once across a bounded settling interval.
        let script = """
            (() => {
            const e = document.scrollingElement || document.documentElement;
            const mx = Math.max(0,e.scrollWidth-innerWidth), my = Math.max(0,e.scrollHeight-innerHeight);
            const x = getComputedStyle(e).direction === 'rtl' ? Math.max(-mx,Math.min(0,\(target.x))) : Math.max(0,Math.min(mx,\(target.x)));
            const y = Math.max(0,Math.min(my,\(target.y)));
            window.scrollTo(x,y); return [x,y];
            })();
            """
        view.evaluateJavaScript(script) { [weak self,weak view] value,_ in
            guard let self, let view, !self.isClosed, self.backingWebView === view,
                  self.documentRevision == revision, self.isRestoringWebView else { return }
            guard let expected = value as? [Double], expected.count == 2 else { self.finishScrollRestoration(); return }
            self.verifySavedScroll(target,expected:CGPoint(x:expected[0],y:expected[1]),in:view,revision:revision,attempt:attempt)
        }
    }
    private func verifySavedScroll(_ target:CGPoint,expected:CGPoint,in view:WKWebView,revision:Int,attempt:Int,stableSamples:Int = 0) {
        Task { @MainActor [weak self,weak view] in
            do { try await Task.sleep(for:.milliseconds(50)) } catch { return }
            guard let self, let view, !self.isClosed, self.backingWebView === view,
                  self.documentRevision == revision, self.isRestoringWebView else { return }
            view.evaluateJavaScript("[scrollX,scrollY]") { [weak self,weak view] value,_ in
                guard let self, let view, !self.isClosed, self.backingWebView === view,
                      self.documentRevision == revision, self.isRestoringWebView else { return }
                let actual = (value as? [Double]).flatMap { $0.count == 2 ? CGPoint(x:$0[0],y:$0[1]) : nil }
                #if DEBUG
                self.onScrollRestorationCheck?(target,expected,actual,attempt)
                #endif
                // A smaller provisional layout can clamp the saved point;
                // give it the same bounded retry before accepting the clamp.
                let reachedTarget = abs(expected.x-target.x) <= 1 && abs(expected.y-target.y) <= 1
                let settled = reachedTarget && (actual.map { abs($0.x-expected.x) <= 1 && abs($0.y-expected.y) <= 1 } ?? false)
                if settled && stableSamples == 0 {
                    self.verifySavedScroll(target,expected:expected,in:view,revision:revision,attempt:attempt,stableSamples:1)
                } else if !settled && attempt < 2 {
                    self.applySavedScroll(target,in:view,revision:revision,attempt:attempt+1)
                } else { self.finishScrollRestoration() }
            }
        }
    }
    private func finishScrollRestoration() {
        savedScrollOffset = nil; isRestoringWebView = false; applyingRestoration = false
    }

    private func canDiscard(_ view:WKWebView, minimumIdle: TimeInterval) -> Bool {
        let policy = TabDiscardPolicy(isSelected: isSelected, isPinned: isPinned, isPrivate: isPrivate,
            hasEditedFields: hasEditedFields, isLoading: isLoading || view.isLoading || isRestoringWebView,
            isCapturing: isCapturingCamera || isCapturingMicrophone || hasRequestedDisplayCapture ||
                view.cameraCaptureState != .none || view.microphoneCaptureState != .none,
            hasDownloads: hasActiveDownloads?() ?? didStartDownload, hasTerminated: contentProcessTerminated,
            hasRequestBody: pendingNavigationHasBody || committedNavigationHasBody,
            committedMethod: committedNavigationMethod, pendingMethod: pendingNavigationMethod)
        return !isClosed && policy.allowsDiscard && recoveryClock() - lastSelectedTime >= minimumIdle &&
            view.url == url && view.superview == nil && view.window == nil &&
            backingWebView === view && url.map(AddressResolver.isWebURL) == true
    }

    public func navigate(to destination: URL) {
        guard AddressResolver.isWebURL(destination) else { return }
        let destination = settings?.privacy.cleanedNavigationURL(destination, isPrivate: isPrivate) ?? URLCleaner.clean(destination)
        invalidateSwitchSnapshot()
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
    public func stop() { backingWebView?.stopLoading(); isLoading = false; finishScrollRestoration(); endRefreshing() }
    public func reloadFromOrigin() { errorMessage = nil; backingWebView?.reloadFromOrigin() }
    public func zoomIn() { setZoom(pageZoom + 0.1) }
    public func zoomOut() { setZoom(pageZoom - 0.1) }
    public func resetZoom() { setZoom(1) }
    private func setZoom(_ value: Double) { pageZoom = min(max((value * 100).rounded() / 100, 0.5), 3); backingWebView?.pageZoom = pageZoom }
    public func setPinned(_ value: Bool) {
        guard !isPrivate else { return }
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
    #if os(macOS)
    func recordAudio(frame: String, audible: Bool) {
        guard !isClosed, frame.count <= 80 else { return }
        if audible { if audibleFrames.count < 256 { audibleFrames.insert(frame) } }
        else { audibleFrames.remove(frame) }
        isPlayingAudio = !audibleFrames.isEmpty
    }
    private func resetAudio() { audibleFrames.removeAll(); isPlayingAudio = false }
    #endif
    public func setProfileActive(_ active: Bool) {
        isProfileActive = active
        if !active { stopCapture() }
        backingWebView?.setAllMediaPlaybackSuspended(mediaSuspended || !active, completionHandler: nil)
        if active { recoverContentProcessIfPossible(); notifyDocumentReady() }
    }
    func setSelected(_ selected: Bool) {
        if isSelected && !selected { captureSwitchSnapshot() }
        if selected || isSelected { lastSelectedTime = recoveryClock() }
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
    /// Consent applies only to the exact destination displayed by the prompt.
    public func continueToHTTP(_ destination:URL) {
        guard destination == httpWarningURL else { return }
        settings?.privacy.setException(true, .httpsUpgrade, for: destination, isPrivate: isPrivate)
        httpWarningURL = nil; pendingHTTPUpgrade = nil
        navigate(to: destination)
    }
    func recordHTTPUpgrade(_ request: URLRequest, kind: PrivacyNavigationKind) {
        pendingHTTPUpgrade = nil
        guard let destination = request.url, destination.scheme == "http", kind == .newNavigation,
              (request.httpMethod ?? "GET").uppercased() == "GET", request.httpBody == nil, request.httpBodyStream == nil else { return }
        pendingHTTPUpgrade = HTTPUpgradeAttempt(url:destination)
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

    private static let paintScript = """
        (() => {
            if (window.orivTabPaint) return;
            window.orivTabPaint = true;
            const observer = new PerformanceObserver(list => {
                if (list.getEntries().some(e => e.name === 'first-contentful-paint')) {
                    window.webkit.messageHandlers.tabPaint.postMessage(performance.timeOrigin);
                    observer.disconnect();
                }
            });
            observer.observe({type:'paint', buffered:true});
        })();
        """

    private func identifyPaintedDocument(_ view: WKWebView) {
        let revision = documentRevision
        view.callAsyncJavaScript("return {id:performance.timeOrigin,painted:performance.getEntriesByType('paint').some(e=>e.name==='first-contentful-paint')};",
            arguments:[:],in:nil,in:.world(name:"OrivTabState")) { [weak self,weak view] result in
                guard let self, !self.isClosed, self.backingWebView === view, self.documentRevision == revision,
                      let value = (try? result.get()) as? [String:Any], let id = value["id"] as? Double else { return }
                self.expectedPaintDocument = id
                if value["painted"] as? Bool == true || self.paintedDocuments.contains(id) { self.hasRenderedContent = true }
            }
    }
    func recordFirstPaint(_ id: Double) {
        guard !isClosed, id.isFinite else { return }
        // At most a few messages can race a commit; never retain an unbounded
        // document history or accept a previous document's delayed signal.
        if paintedDocuments.count >= 4 { paintedDocuments.removeAll() }
        paintedDocuments.insert(id)
        if expectedPaintDocument == id { hasRenderedContent = true }
    }
    private func invalidateSwitchSnapshot() {
        snapshotGeneration += 1; snapshotCache?.remove(id)
    }
    private func captureSwitchSnapshot() {
        guard !isClosed, hasRenderedContent, !isRestoringWebView, let view = backingWebView,
              view.bounds.width > 0, view.bounds.height > 0, let cache = snapshotCache,
              let token = cache.beginCapture() else { return }
        let generation = snapshotGeneration, revision = documentRevision
        #if os(macOS)
        let scale = view.window?.backingScaleFactor ?? 2
        let color = view.underPageBackgroundColor.usingColorSpace(.sRGB)
        if let color { lastPageBackground = ChromeColor(color.redComponent,color.greenComponent,color.blueComponent) }
        #else
        let scale = view.traitCollection.displayScale
        var r:CGFloat = 0, g:CGFloat = 0, b:CGFloat = 0, a:CGFloat = 0
        if view.underPageBackgroundColor.getRed(&r,green:&g,blue:&b,alpha:&a) { lastPageBackground = ChromeColor(r,g,b) }
        #endif
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: min(view.bounds.width,view.bounds.width/view.bounds.height*CGFloat(TabSnapshotCache.maximumDimension),CGFloat(TabSnapshotCache.maximumDimension))/max(1,scale))
        // Flush pending drawing: didFinish can precede presentation on iOS.
        // The callback never blocks selection, nor initiates a page load.
        config.afterScreenUpdates = true
        view.takeSnapshot(with:config) { [weak self,weak view,weak cache] image,_ in
            guard let cache, cache.finishCapture(token), let self, let view, !self.isClosed,
                  self.snapshotGeneration == generation, self.documentRevision == revision,
                  self.backingWebView === view, let image else { return }
            #if os(macOS)
            let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil)
            #else
            let cg = image.cgImage
            #endif
            if let cg, let snapshot = TabSnapshotCache.compress(cg) { cache.insert(snapshot,for:self.id) }
        }
    }

    public func close() {
        guard !isClosed else { return }
        #if os(macOS)
        resetAudio()
        #endif
        invalidateSwitchSnapshot()
        snapshotCache = nil
        // Adapters must unregister while their live view is still reachable,
        // including session shutdown (which does not call didCloseTab).
        onWebViewDiscarded?(); onWebViewDiscarded = nil
        onAuthentication = nil; onWebViewCreated = nil
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
        configuration.userContentController.removeScriptMessageHandler(forName: "tabPaint", contentWorld: .world(name: "OrivTabState"))
        #if os(macOS)
        configuration.userContentController.removeScriptMessageHandler(forName: "displayCaptureRequested", contentWorld: .page)
        #endif
        hasActiveDownloads = nil
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

    /// Optional document work starts only after navigation and restoration
    /// finish and the native destination cover is gone. Each readiness edge
    /// uses the store's coalescing/cache, never a sidebar presentation task.
    private func notifyDocumentReady() {
        guard !isClosed, isProfileActive, finishedDocumentRevision == documentRevision,
              !isLoading, !isRestoringWebView, hasRenderedContent, switchPresentation == nil,
              let view = backingWebView, !view.isLoading, let url = view.url,
              AddressResolver.isWebURL(url) else { return }
        onDocumentReady?(url)
    }

    public static let navigationStarted = Notification.Name("OrivNavigationStarted")

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isClosed, backingWebView === webView else { return }
        finishedDocumentRevision = nil
        if applyingRestoration { finishScrollRestoration() }
        expectedPaintDocument = nil; paintedDocuments.removeAll(); hasRenderedContent = false
        // A retained discard image remains until restoration paints. Ordinary
        // navigation cannot reuse a screenshot of the previous document.
        if !isRestoringWebView { invalidateSwitchSnapshot() }
        // Server/HTTPS upgrade redirects keep their WKNavigation identity.
        // A replacement, including a script navigation, cannot inherit consent.
        if let previous = pendingHTTPUpgrade?.navigation, previous !== navigation {
            pendingHTTPUpgrade = nil
        } else { pendingHTTPUpgrade?.navigation = navigation }
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
    #if os(iOS)
    public static let documentCommitted = Notification.Name("OrivDocumentCommitted")
    #endif

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        #if os(macOS)
        resetAudio()
        #endif
        guard !isClosed, backingWebView === webView else { return }
        identifyPaintedDocument(webView)
        #if os(iOS)
        NotificationCenter.default.post(name:Self.documentCommitted,object:webView)
        #endif
        #if DEBUG
        NotificationCenter.default.post(name: Self.navigationCommitted, object: webView)
        #endif
        httpWarningURL = nil
        pendingHTTPUpgrade = nil
        committedNavigationMethod = pendingNavigationMethod
        committedNavigationHasBody = pendingNavigationHasBody
        pendingNavigationHasBody = false
        pendingNavigationMethod = nil
        contentProcessTerminated = false
        lastVisitedURL = nil
        hasEditedFields = false
        hasRequestedDisplayCapture = false
        refresh(from: webView)
        applySiteSettings()
    }
    func recordFieldEdit() { if !isClosed { hasEditedFields = true } }
    func recordDisplayCaptureRequest() { if !isClosed { hasRequestedDisplayCapture = true } }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed, backingWebView === webView else { return }
        restoreScrollPosition(force:true)
        // Empty pages, PDFs and unsupported Paint Timing documents must also
        // become usable. The host's afterScreenUpdates barrier still runs.
        hasRenderedContent = true
        endRefreshing()
        refresh(from: webView)
        finishedDocumentRevision = documentRevision
        notifyDocumentReady()
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
        handle(error,navigation:navigation)
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { handle(error,navigation:navigation) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed, backingWebView === webView else { return }
        hasRenderedContent = false
        endRefreshing()
        isLoading = false
        contentProcessTerminated = true
        var message = "This tab’s website process stopped. Reload to continue."
        if hasEditedFields {
            message += " Automatic recovery is paused because this page contains edited fields."
        } else if (pendingNavigationMethod ?? committedNavigationMethod) != "GET" || committedNavigationMethod == "POST" || pendingNavigationHasBody || committedNavigationHasBody {
            message += " Automatic recovery cannot safely replay this page’s request."
        }
        errorMessage = message
        recoverContentProcessIfPossible()
    }

    private func recoverContentProcessIfPossible() {
        // Reload the existing view in its original (including ephemeral private) store.
        // No tab, navigation record, history entry or continuity record is exported here.
        guard contentProcessTerminated, isSelected, isProfileActive, !isClosed,
              !hasEditedFields, (pendingNavigationMethod ?? committedNavigationMethod) == "GET",
              !pendingNavigationHasBody, !committedNavigationHasBody,
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
        pendingNavigationHasBody = request.httpBody != nil || request.httpBodyStream != nil
    }
    private func handle(_ error: Error,navigation:WKNavigation?) {
        isRestoringWebView = false; savedScrollOffset = nil; applyingRestoration = false
        endRefreshing()
        let nsError = error as NSError
        // Only a failed upgrade of an original HTTP GET may offer consent.
        // Explicit HTTPS URLs, certificate errors, unrelated/stale failures,
        // form submissions and history traversals never become bypasses.
        let connectionErrors = [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                                NSURLErrorNetworkConnectionLost, NSURLErrorSecureConnectionFailed]
        let failedURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        if nsError.domain == NSURLErrorDomain, connectionErrors.contains(nsError.code),
           let attempt = pendingHTTPUpgrade, attempt.navigation === navigation, let failedURL {
            let original = attempt.url
            var upgraded = URLComponents(url:original,resolvingAgainstBaseURL:false)
            upgraded?.scheme = "https"
            if upgraded?.port == 80 { upgraded?.port = nil }
            if Self.sameHTTPAttempt(original,failedURL) || upgraded?.url == failedURL {
                pendingHTTPUpgrade = nil; httpWarningURL = original
                errorMessage = nil; isLoading = false
                return
            }
        }
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
        guard !isClosed else { decisionHandler(.cancel); return }
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
            if preferences.preferredHTTPSNavigationPolicy == .errorOnFailure {
                // A redirected HTTPS request belongs to the same upgrade;
                // preserve its original HTTP destination until commit/failure.
                // Explicit links/forms/history actions replace that attempt.
                if url.scheme == "http" || navigationAction.navigationType != .other {
                    recordHTTPUpgrade(navigationAction.request,kind:kind)
                }
            } else { pendingHTTPUpgrade = nil }
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
            if adBlocker.applyIfPrepared(to:webView.configuration.userContentController,url:url,isPrivate:isPrivate) {
                if policy == .allow { recordAllowedMainFrameNavigation(navigationAction.request) }
                decisionHandler(policy)
                return
            }
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
        didStartDownload = true
        onDownload?(download)
    }
    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        didStartDownload = true
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

#if os(macOS)
@MainActor private final class TabAudioHandler: NSObject, WKScriptMessageHandler {
    private weak var tab: BrowserTab?
    init(tab: BrowserTab) { self.tab = tab }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let frame = body["frame"] as? String,
              let audible = body["audible"] as? Bool else { return }
        tab?.recordAudio(frame: frame, audible: audible)
    }
}

@MainActor private final class DisplayCaptureHandler: NSObject, WKScriptMessageHandler {
    private weak var tab: BrowserTab?
    init(tab: BrowserTab) { self.tab = tab }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? Bool == true { tab?.recordDisplayCaptureRequest() }
    }
}
#endif

@MainActor private final class EditedFieldHandler: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(tab: BrowserTab) { self.tab = tab }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? Bool == true { tab?.recordFieldEdit() }
    }
}

@MainActor private final class TabPaintHandler: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(tab: BrowserTab) { self.tab = tab }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let id = message.body as? Double else { return }
        tab?.recordFirstPaint(id)
    }
}
