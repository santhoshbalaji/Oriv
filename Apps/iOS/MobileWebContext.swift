import BrowserCore
import BrowserEngine
import Photos
import UIKit
import WebKit

/// Image metadata stays in an isolated world. Text, scrolling, links and video
/// keep WebKit's recognizers; only image callouts receive Oriv's menu.
@MainActor final class MobileContextTracker: NSObject, WKScriptMessageHandler {
    weak var owner: MobileWebDelegate?
    init(owner: MobileWebDelegate) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        owner?.touchedLinkTitle = String((body["title"] as? String ?? "Link").prefix(500))
        owner?.touchedImageURL = (body["image"] as? String).flatMap(URL.init(string:))
        owner?.touchedImageLinkURL = (body["link"] as? String).flatMap(URL.init(string:)).flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
        owner?.touchedImageRevision = owner?.tab?.documentRevision
        owner?.touchedImageTime = ProcessInfo.processInfo.systemUptime
        if body["kind"] as? String == "imageMenu", let view = message.webView,
           let image = owner?.touchedImageURL {
            let link = (body["link"] as? String).flatMap(URL.init(string:)).flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
            let point = message.frameInfo.isMainFrame ? CGPoint(x: body["x"] as? Double ?? view.bounds.midX, y: body["y"] as? Double ?? view.bounds.midY) : CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            owner?.showImageMenu(image: image, link: link, point: point, in: view)
        }
    }
    static let script = """
    (() => {
      if (window.orivImageContextInstalled) return;
      window.orivImageContextInstalled = true;
      let point = {x:0, y:0};
      document.addEventListener('touchstart', e => {
        if (!e.isTrusted) return;
        if (e.touches.length !== 1) {
          window.webkit.messageHandlers.orivContext.postMessage({image:'',link:''}); return;
        }
        point = {x:e.touches[0].clientX, y:e.touches[0].clientY};
        const img = e.target.closest && e.target.closest('img');
        const link = e.target.closest && e.target.closest('a[href]');
        window.webkit.messageHandlers.orivContext.postMessage({image: img ? (img.currentSrc || img.src || '') : '', link:link ? link.href : '', title:link ? (link.innerText || link.title || 'Link') : ''});
      }, {passive:true, capture:true});
      document.addEventListener('contextmenu', e => {
        const img = e.target.closest && e.target.closest('img');
        if (!e.isTrusted || !img) return;
        e.preventDefault();
        const link = img.closest('a[href]');
        window.webkit.messageHandlers.orivContext.postMessage({kind:'imageMenu', image:img.currentSrc || img.src || '', link:link ? link.href : '', x:point.x, y:point.y});
      }, true);
    })();
    """
}

extension MobileWebDelegate: @preconcurrency UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    @objc func imageHeld(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .cancelled || gesture.state == .failed { cancelContextGesture(); return }
        guard contextCancellation?.suspended != true, gesture.state == .began, let image = touchedImageURL, let view = gesture.view as? WKWebView else { return }
        showImageMenu(image: image, link: touchedImageLinkURL, point: gesture.location(in: view), in: view)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.numberOfTouches == 1 && touchedImageURL != nil && touchedImageLinkURL == nil && touchedImageRevision == tab?.documentRevision && ProcessInfo.processInfo.systemUptime - touchedImageTime < 3
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    func invalidate() {
        if let tab, tab.isInstantiated {
            let view = tab.webView
            view.configuration.userContentController.removeScriptMessageHandler(forName:"orivContext",contentWorld:.world(name:"OrivContext"))
            if let imageMenuInteraction { view.removeInteraction(imageMenuInteraction) }
        }
        contextCancellation = nil
        imageTransfers.values.forEach { $0.cancel() }
        imageTransfers.removeAll()
        touchedImageURL = nil
        imageMenuInteraction?.dismissMenu(); imageMenuTarget = nil
    }
    func showImageMenu(image: URL, link: URL?, point: CGPoint, in view: WKWebView) {
        guard let tab, contextIsCurrent(tab.documentRevision) else { return }
        imageMenuInteraction?.dismissMenu()
        if let imageMenuInteraction { view.removeInteraction(imageMenuInteraction) }
        imageMenuTarget = (image, link, tab.documentRevision)
        let interaction = UIEditMenuInteraction(delegate: self)
        imageMenuInteraction = interaction; view.addInteraction(interaction)
        interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let target = imageMenuTarget, contextIsCurrent(target.revision) else { return nil }
        var actions: [UIMenuElement] = imageActions(target.image, revision: target.revision)
        if let link = target.link { actions += linkActions(link, revision: target.revision) }
        return UIMenu(children: actions)
    }
    func cancelContextGesture() {
        touchedImageURL = nil; touchedImageLinkURL = nil
        imageMenuInteraction?.dismissMenu(); imageMenuTarget = nil
    }
    func installContextTracking(on view: WKWebView) {
        contextCancellation = MobileGestureCancellation { [weak self] in self?.cancelContextGesture() }
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(imageHeld(_:)))
        hold.minimumPressDuration = 0.55; hold.cancelsTouchesInView = false; hold.numberOfTouchesRequired = 1; hold.delegate = self
        view.addGestureRecognizer(hold)
        let world = WKContentWorld.world(name: "OrivContext")
        let tracker = MobileContextTracker(owner: self)
        view.configuration.userContentController.add(tracker, contentWorld: world, name: "orivContext")
        let scripts: [(String,WKUserScriptInjectionTime)] = [
            (MobileContextTracker.script,.atDocumentStart),
            ("const style=document.createElement('style');style.textContent='img{-webkit-touch-callout:none!important}';document.documentElement.appendChild(style);",.atDocumentEnd)
        ]
        for (source,time) in scripts where !view.configuration.userContentController.userScripts.contains(where: { $0.source == source }) {
            view.configuration.userContentController.addUserScript(WKUserScript(source:source,injectionTime:time,forMainFrameOnly:false,in:world))
        }
    }
    private func contextIsCurrent(_ revision: Int) -> Bool {
        guard let tab, let session else { return false }
        return session.isProfileActive && session.selectedTabID == tab.id && tab.documentRevision == revision && session.tabs.contains { $0.id == tab.id }
    }
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void) {
        guard let tab, let session, contextIsCurrent(tab.documentRevision) else { completionHandler(nil); return }
        let revision = tab.documentRevision
        let link = elementInfo.linkURL.flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
        let image = touchedImageRevision == revision && ProcessInfo.processInfo.systemUptime - touchedImageTime < 3 ? touchedImageURL : nil
        guard link != nil || image != nil else { completionHandler(nil); return }
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: {
            guard let link else { return nil }
            return MobileLinkPreview(url: link, title: self.touchedLinkTitle, source: tab, session: session)
        }, actionProvider: { [weak self] _ in
            guard let self, contextIsCurrent(revision) else { return UIMenu(children: []) }
            var children: [UIMenuElement] = []
            if let image { children.append(UIMenu(options: .displayInline, children: imageActions(image, revision: revision))) }
            if let link { children.append(contentsOf: linkActions(link, revision: revision)) }
            return UIMenu(title: link?.host ?? "Image", children: children)
        }))
    }
    func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
                 willCommitWithAnimator animator: any UIContextMenuInteractionCommitAnimating) {
        guard let tab, let url = elementInfo.linkURL, AddressResolver.isWebURL(url) else { return }
        let revision = tab.documentRevision
        animator.addCompletion { [weak self] in
            guard let self, contextIsCurrent(revision) else { return }
            self.tab?.navigate(to: url)
        }
    }
    func linkActions(_ url: URL, revision: Int) -> [UIMenuElement] {
        guard let tab, let session, let controller else { return [] }
        func action(_ title: String, _ symbol: String, _ operation: @escaping () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
                guard self?.contextIsCurrent(revision) == true else { return }; operation()
            }
        }
        var items: [UIMenuElement] = [
            action("Load Preview", "eye") { [weak self] in
                guard let presenter = MobileWebDelegate.presenter else { return }
                let preview = MobileLinkPreview(url: url, title: self?.touchedLinkTitle ?? "Link", source: tab, session: session)
                preview.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak preview] _ in preview?.dismiss(animated: true) })
                presenter.present(UINavigationController(rootViewController: preview), animated: true)
                preview.loadViewIfNeeded(); preview.loadPreview()
            },
            action("Open", "arrow.up.right") { tab.navigate(to: url) },
            action("Open in New Tab", "plus.square") { session.addTab(url: url, isPrivate: tab.isPrivate) },
            action("Open in Background", "square.on.square") {
                session.addTab(url: url, isPrivate: tab.isPrivate, select: false).activate()
            },
            action("Open in Private Tab", "eyeglasses") { session.addTab(url: url, isPrivate: true) }
        ]
        let profiles = controller.profiles
        items.append(UIMenu(title: "Open in Another Profile", image: UIImage(systemName: "person.crop.circle"), children:
            (profiles?.profiles ?? []).filter { $0.archivedAt == nil && $0.id != controller.profileID }.map { profile in
                action(profile.name, profile.symbol.rawValue) { profiles?.open(url, in: profile, isPrivate: tab.isPrivate) }
            }))
        items += [
            action("Download Linked File", "arrow.down.circle") { [weak controller] in
                tab.webView.startDownload(using: URLRequest(url: url)) { download in controller?.downloads.begin(download) }
            },
            action("Copy Link", "doc.on.doc") { PrivacyPasteboard.copy(url) },
            action("Copy Original Link", "link") { PrivacyPasteboard.copy(url, original: true) },
            action("Share", "square.and.arrow.up") { [weak controller] in controller?.share([URLCleaner.clean(url)]) }
        ]
        let page = profiles?.profiles.first { $0.id == controller.profileID }.flatMap {
            ContinuityPage(url: url, title: url.host ?? "Page", profile: $0, isPrivate: tab.isPrivate)
        }
        let destinations = (profiles?.continuity.otherDevices ?? []).map { device in
            action(device.name, "laptopcomputer") { if let page { profiles?.continuity.sendPage(page, to: device.id) } }
        }
        items.append(UIMenu(title: "Open on Mac", image: UIImage(systemName: "paperplane"), children:
            page != nil && profiles?.continuity.canSendPage == true ? destinations : [UIAction(title: tab.isPrivate ? "Unavailable in Private Browsing" : "Set Up Mac & iPhone in Settings", attributes: .disabled) { _ in }]))
        return items
    }
    private func imageActions(_ url: URL, revision: Int) -> [UIMenuElement] {
        [("Save to Photos", "square.and.arrow.down"), ("Copy Image", "doc.on.doc"), ("Share Image", "square.and.arrow.up")].enumerated().map { index, item in
            UIAction(title: item.0, image: UIImage(systemName: item.1)) { [weak self] _ in
                guard let self, contextIsCurrent(revision), let tab else { return }
                let task = MobileImageTransfer()
                imageTransfers[task.id] = task
                task.run(url: url, in: tab.webView) { [weak self] result in
                    guard let self else { return }
                    defer { imageTransfers[task.id] = nil }
                    switch result {
                    case .failure(let error): controller?.message = error.localizedDescription
                    case .success(let data):
                        guard let image = UIImage(data: data) else { controller?.message = "This image format could not be opened."; return }
                        if index == 1 { UIPasteboard.general.image = image }
                        else if index == 2 { controller?.share([image]) }
                        else {
                            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                                guard status == .authorized || status == .limited else {
                                    Task { @MainActor in self?.controller?.message = "Allow Photos access in Settings to save this image." }; return
                                }
                                PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: image) }) { success, error in
                                    if !success { Task { @MainActor in self?.controller?.message = error?.localizedDescription ?? "The image could not be saved." } }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Pure native card until an explicit Load Preview action. No WKWebView is
/// instantiated by a long press, including in private/external-private tabs.
@MainActor final class MobileLinkPreview: UIViewController {
    private(set) var preview: BrowserTab?
    private let destination: URL
    private let linkTitle: String
    private weak var source: BrowserTab?
    private weak var session: BrowserSession?
    private let revision: Int
    init(url: URL, title: String = "Link", source: BrowserTab, session: BrowserSession) {
        destination = URLCleaner.clean(url); linkTitle = title
        self.source = source; self.session = session; revision = source.documentRevision
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 380, height: 460)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let root = UIView(); root.backgroundColor = .systemBackground
        let title = UILabel(); title.text = linkTitle; title.font = .preferredFont(forTextStyle: .headline); title.numberOfLines = 3
        let domain = UILabel(); domain.text = destination.host; domain.font = .preferredFont(forTextStyle: .subheadline)
        let url = UITextView(); url.text = destination.absoluteString; url.font = .preferredFont(forTextStyle: .body)
        url.isEditable = false; url.isSelectable = true; url.backgroundColor = .clear
        let button = UIButton(type: .system); button.setTitle("Load Preview", for: .normal)
        button.addTarget(self, action: #selector(loadPreview), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, domain, url, button]); stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        view = root
    }
    @objc func loadPreview() {
        guard preview == nil, let source, let session, source.documentRevision == revision,
              session.isProfileActive, session.tabs.contains(where: { $0 === source }) else { return }
        let tab = BrowserTab(record: TabRecord(url: destination), isPrivate: source.isPrivate,
            dataStore: source.webView.configuration.websiteDataStore, adBlocker: session.adBlocker, settings: session.settings)
        preview = tab; tab.toggleMediaSuspension()
        let web = tab.webView; web.frame = view.bounds; web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.subviews.forEach { $0.removeFromSuperview() }; view.addSubview(web)
        tab.activate()
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); preview?.close() }
}

/// Uses WebKit's own cookie/data store, never a separate network client. Bytes and files
/// are temporary, removed on completion, and fetched only after a menu command.
@MainActor final class MobileImageTransfer: NSObject, WKDownloadDelegate {
    let id = UUID()
    private var completion: ((Result<Data, Error>) -> Void)?
    private var download: WKDownload?
    private var observation: NSKeyValueObservation?
    private var file: URL?
    private var cancelled = false
    private static let limit: Int64 = 25 * 1024 * 1024
    func cancel() {
        cancelled = true
        completion = nil; observation = nil
        download?.cancel { _ in }; download = nil
        if let file { try? FileManager.default.removeItem(at: file) }; file = nil
    }
    func run(url: URL, in view: WKWebView, completion: @escaping (Result<Data, Error>) -> Void) {
        guard AddressResolver.isWebURL(url) || ["data", "blob"].contains(url.scheme?.lowercased() ?? "") else { completion(.failure(URLError(.unsupportedURL))); return }
        self.completion = completion
        view.startDownload(using: URLRequest(url: url)) { [self] download in
            guard !cancelled else { download.cancel { _ in }; return }
            self.download = download; download.delegate = self
            observation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
                let count = progress.completedUnitCount
                Task { @MainActor in if count > Self.limit { self?.download?.cancel { _ in }; self?.finish(.failure(URLError(.dataLengthExceedsMaximum))) } }
            }
        }
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard response.expectedContentLength <= Self.limit else { completionHandler(nil); finish(.failure(URLError(.dataLengthExceedsMaximum))); return }
        let url = URL.temporaryDirectory.appendingPathComponent("OrivImage-\(id.uuidString)")
        file = url; completionHandler(url)
    }
    func downloadDidFinish(_ download: WKDownload) {
        do {
            guard let file else { throw URLError(.fileDoesNotExist) }
            let data = try Data(contentsOf: file)
            guard data.count <= Self.limit else { throw URLError(.dataLengthExceedsMaximum) }
            finish(.success(data))
        } catch { finish(.failure(error)) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { finish(.failure(error)) }
    private func finish(_ result: Result<Data, Error>) {
        let callback = completion; completion = nil; observation = nil; download = nil
        if let file { try? FileManager.default.removeItem(at: file) }; file = nil
        callback?(result)
    }
}
