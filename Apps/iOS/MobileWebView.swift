import SwiftUI
import WebKit

struct MobileWebView: UIViewRepresentable {
    let webView: WKWebView
    var chrome: PageChrome
    var topInset: CGFloat
    var bottomInset: CGFloat
    var reduceTransparency: Bool
    var obscured: Bool
    var onFindVisibilityChange: (Bool) -> Void
    var onAppearanceChange: (Bool) -> Void
    var onScroll: (CGFloat, Bool) -> Void
    var card: CGRect = .zero
    var progress: CGFloat = 0
    var reduceMotion = false
    var preparation: UUID?
    var onPrepared: ((UUID,Bool) -> Void)?

    func makeUIView(context: Context) -> MobileWebHost { MobileWebHost(webView: webView) }
    static func dismantleUIView(_ host: MobileWebHost, coordinator: ()) { host.prepareTransition(nil); host.detachScrollView() }
    func updateUIView(_ host: MobileWebHost, context: Context) {
        host.isUserInteractionEnabled = !obscured
        host.accessibilityElementsHidden = obscured
        webView.accessibilityElementsHidden = obscured
        host.onFindVisibilityChange = onFindVisibilityChange
        host.refreshFindVisibility()
        host.onScroll = onScroll
        host.onAppearanceChange = onAppearanceChange
        host.refreshAppearance()
        host.onGeometryChange = { chrome.requestSample() }
        host.updateInsets(top: topInset, bottom: bottomInset)
        host.applyMorph(progress:reduceMotion ? 0 : progress,card:card,animated:!reduceMotion && context.transaction.animation != nil)
        host.prepareTransition(preparation,completion:onPrepared)
        webView.scrollView.topEdgeEffect.style = .soft
        webView.scrollView.bottomEdgeEffect.style = .soft
        webView.scrollView.topEdgeEffect.isHidden = reduceTransparency
        webView.scrollView.bottomEdgeEffect.isHidden = reduceTransparency
    }
}

final class MobileWebHost: UIView {
    let webView: WKWebView
    private let clip = UIView()
    private var morphAnimator: UIViewPropertyAnimator?
    private var morphProgress: CGFloat = 0
    private var morphCard: CGRect = .zero
    private var viewportSize: CGSize = .zero
    private var suppressScrollUntil = 0.0
    private var preparation:UUID?
    private var preparationTask:Task<Void,Never>?
    private var preparationStarted = false
    private var preparationFinished = false
    private var preparationGeneration = 0
    private var prepared:((UUID,Bool) -> Void)?
    var onScroll: ((CGFloat, Bool) -> Void)?
    var onGeometryChange: (() -> Void)?
    var onAppearanceChange: ((Bool) -> Void)?
    var onFindVisibilityChange: ((Bool) -> Void)?
    private var lastFindVisible = false
    private var lastAppearance: UIUserInterfaceStyle?
    private var observation: NSKeyValueObservation?
    private weak var edgeController: UIViewController?
    private var lastOffset: CGFloat = 0
    private var installedInsets = false
    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clip.clipsToBounds = true; clip.layer.cornerCurve = .continuous
        addSubview(clip); clip.addSubview(webView)
        webView.layer.anchorPoint = .zero; webView.layer.position = .zero
        // Status text follows the sampled band; web CSS continues to follow the
        // scene's system appearance. This avoids light/dark feedback from chrome.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (host: MobileWebHost, _: UITraitCollection) in
            host.updatePageAppearance()
            host.onGeometryChange?()
        }
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardDidHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
        }
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        observation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            Task { @MainActor [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                let offset = scrollView.contentOffset.y + scrollView.contentInset.top
                // Observe rather than replace WebKit's scroll delegate. Chrome resizing,
                // restoration, find and keyboard scrolling must not collapse the bar.
                guard self.morphProgress == 0, self.morphAnimator == nil,
                      ProcessInfo.processInfo.systemUptime >= self.suppressScrollUntil,
                      scrollView.pinchGestureRecognizer?.state != .changed,
                      scrollView.pinchGestureRecognizer?.state != .began,
                      !scrollView.isZooming, !scrollView.isZoomBouncing else { self.lastOffset = offset; return }
                guard !scrollView.isTracking || offset >= 0 else { return }
                guard scrollView.refreshControl?.isRefreshing != true, offset >= 0,
                      scrollView.isDragging || scrollView.isDecelerating else { self.lastOffset = offset; return }
                guard abs(offset - self.lastOffset) > 12 else { return }
                let down = offset > self.lastOffset
                self.lastOffset = offset
                self.onScroll?(offset, down)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow(); updatePageAppearance(); connectScrollView(); schedulePreparation() }
    func prepareTransition(_ token:UUID?,completion:((UUID,Bool) -> Void)? = nil) {
        prepared = completion
        if preparation != token {
            preparationTask?.cancel(); preparationTask = nil
            preparation = token; preparationGeneration += 1
            preparationStarted = false; preparationFinished = false
            if let token {
                let generation = preparationGeneration
                // Start before attachment: neither a missing layout nor a
                // WebKit callback may hold the opaque grid indefinitely.
                preparationTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for:.seconds(3)) } catch { return }
                    self?.completePreparation(token,generation:generation,success:false)
                }
            }
        }
        schedulePreparation()
    }
    private func completePreparation(_ token:UUID,generation:Int,success:Bool) {
        guard preparation == token, preparationGeneration == generation, !preparationFinished else { return }
        preparationFinished = true; preparationTask?.cancel(); preparationTask = nil
        prepared?(token,success)
    }
    private func schedulePreparation() {
        guard let token = preparation, !preparationStarted, !preparationFinished,
              window != nil, viewportSize.width > 0, viewportSize.height > 0 else { return }
        preparationStarted = true
        let generation = preparationGeneration
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.preparation == token, self.preparationGeneration == generation,
                  !self.preparationFinished, self.window != nil else { return }
            self.layoutIfNeeded()
            // Keep the live surface below its backing card until WebKit paints.
            // Use the callback API so cancellation/timeout never leaves a task
            // suspended in WebKit's non-cancellable async snapshot operation.
            let config = WKSnapshotConfiguration(); config.snapshotWidth = 32; config.afterScreenUpdates = true
            #if DEBUG
            let started = ProcessInfo.processInfo.systemUptime
            #endif
            self.webView.takeSnapshot(with:config) { [weak self] image,_ in
                guard let self, self.preparation == token, self.preparationGeneration == generation,
                      !self.preparationFinished else { return }
                let success = image != nil && self.window != nil && self.window?.isHidden == false
                #if DEBUG
                MobileTransitionMetrics.recordPreparation(seconds:ProcessInfo.processInfo.systemUptime-started,success:success)
                #endif
                self.completePreparation(token,generation:generation,success:success)
            }
        }
    }
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
    @objc private func keyboardChanged(_ notification: Notification) {
        // The built-in Find Selection route does not pass through our page menu.
        // Observe keyboard/layout changes without replacing WebKit's find delegate.
        suppressScrollUntil = ProcessInfo.processInfo.systemUptime + 0.5
        DispatchQueue.main.async { [weak self] in self?.refreshFindVisibility() }
    }
    func refreshFindVisibility() {
        let visible = webView.findInteraction?.isFindNavigatorVisible == true
        guard lastFindVisible != visible else { return }
        lastFindVisible = visible
        DispatchQueue.main.async { [weak self] in self?.onFindVisibilityChange?(visible) }
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
    override func layoutSubviews() {
        super.layoutSubviews(); refreshFindVisibility(); connectScrollView()
        guard webView.superview === clip else { return }
        if viewportSize != bounds.size {
            viewportSize = bounds.size
            morphAnimator?.stopAnimation(true); morphAnimator = nil
            UIView.performWithoutAnimation {
                webView.bounds = CGRect(origin:.zero,size:bounds.size)
                setMorphGeometry()
            }
            onGeometryChange?()
        }
        schedulePreparation()
    }
    /// A single host owns the live layer for its entire lifetime. Only its clip
    /// and affine transform change; WebKit never gets a card-sized viewport.
    func applyMorph(progress:CGFloat,card:CGRect,animated:Bool) {
        let progress = min(max(progress,0),1)
        guard morphProgress != progress || morphCard != card else { return }
        if let animator = morphAnimator {
            let frame = clip.layer.presentation()?.frame ?? clip.frame
            let transform = webView.layer.presentation()?.affineTransform() ?? webView.transform
            let radius = clip.layer.presentation()?.cornerRadius ?? clip.layer.cornerRadius
            animator.stopAnimation(true); morphAnimator = nil
            UIView.performWithoutAnimation { clip.frame = frame; webView.transform = transform; clip.layer.cornerRadius = radius }
        }
        morphProgress = progress; morphCard = card
        if animated && viewportSize != .zero {
            let animator = UIViewPropertyAnimator(duration:0.42,dampingRatio:0.86) { [weak self] in self?.setMorphGeometry() }
            morphAnimator = animator
            animator.addCompletion { [weak self,weak animator] _ in
                if self?.morphAnimator === animator { self?.morphAnimator = nil }
            }
            animator.startAnimation()
        } else { UIView.performWithoutAnimation { setMorphGeometry() } }
    }
    private func setMorphGeometry() {
        let p = morphProgress
        guard bounds.width > 0, bounds.height > 0 else {
            clip.frame = bounds; clip.layer.cornerRadius = 0
            webView.transform = .identity; webView.layer.position = .zero
            return
        }
        let rect = CGRect(x:morphCard.minX*p,y:morphCard.minY*p,
            width:bounds.width+(morphCard.width-bounds.width)*p,
            height:bounds.height+(morphCard.height-bounds.height)*p)
        clip.frame = rect; clip.layer.cornerRadius = 18*p
        let scale = p == 0 ? 1 : rect.width/bounds.width
        webView.transform = CGAffineTransform(scaleX:scale,y:scale)
        webView.layer.position = .zero
    }
    func updateInsets(top: CGFloat, bottom: CGFloat) {
        let insets = UIEdgeInsets(top: max(0, top), left: 0, bottom: max(0, bottom), right: 0)
        if webView.obscuredContentInsets != insets { webView.obscuredContentInsets = insets; onGeometryChange?() }
        let scrollView = webView.scrollView
        // UIRefreshControl temporarily owns an extra top inset. Sampling and
        // SwiftUI updates during the pull must not take it away mid-gesture.
        let refreshing = scrollView.refreshControl?.isRefreshing == true
        let pulling = scrollView.isTracking && scrollView.contentOffset.y < -insets.top
        if !refreshing && !pulling && scrollView.contentInset != insets {
            suppressScrollUntil = ProcessInfo.processInfo.systemUptime + 0.25
            let atTop = !installedInsets && scrollView.contentOffset.y <= 0
            scrollView.contentInset = insets
            scrollView.verticalScrollIndicatorInsets = insets
            if atTop { scrollView.setContentOffset(CGPoint(x: 0, y: -top), animated: false) }
            installedInsets = true
        }
    }
}

/// UIKit owns keyboard geometry and timing. The transparent controller receives
/// touches only inside the actual bar, leaving the sibling WebKit surface live.
struct MobileKeyboardBar: UIViewControllerRepresentable {
    let content: AnyView
    let hidden: Bool
    let interactive: Bool
    let accessibilityHidden: Bool
    let onMetrics: (CGFloat,CGFloat) -> Void
    func makeUIViewController(context:Context) -> Controller {
        Controller(content:decorated(context))
    }
    func updateUIViewController(_ controller:Controller,context:Context) {
        controller.hosting.rootView = decorated(context)
        controller.onMetrics = onMetrics
        controller.loadViewIfNeeded()
        controller.view.isHidden = hidden
        controller.view.isUserInteractionEnabled = interactive
        controller.view.accessibilityElementsHidden = accessibilityHidden
    }
    private func decorated(_ context:Context) -> AnyView {
        AnyView(content.environment(\.browserTheme,context.environment.browserTheme)
            .environment(\.colorScheme,context.environment.colorScheme))
    }
    static func dismantleUIViewController(_ controller:Controller,coordinator:()) {
        controller.onMetrics = nil
        controller.hosting.rootView = AnyView(EmptyView())
    }
    final class Controller:UIViewController {
        let hosting:UIHostingController<AnyView>
        var onMetrics:((CGFloat,CGFloat) -> Void)?
        private var lastHeight:CGFloat = -1
        private var lastOcclusion:CGFloat = -1
        init(content:AnyView) {
            hosting = UIHostingController(rootView:content)
            super.init(nibName:nil,bundle:nil)
        }
        required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() { view = PassthroughView() }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear; view.isOpaque = false
            addChild(hosting)
            hosting.safeAreaRegions = []
            hosting.sizingOptions = .intrinsicContentSize
            hosting.view.backgroundColor = .clear; hosting.view.isOpaque = false
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hosting.view)
            (view as? PassthroughView)?.bar = hosting.view
            view.keyboardLayoutGuide.usesBottomSafeArea = true
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor),
                hosting.view.bottomAnchor.constraint(equalTo:view.keyboardLayoutGuide.topAnchor)
            ])
            hosting.didMove(toParent:self)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let height = hosting.view.bounds.height
            let occlusion = max(0,view.bounds.maxY-view.keyboardLayoutGuide.layoutFrame.minY)
            guard height > 0, abs(height-lastHeight)>0.5 || abs(occlusion-lastOcclusion)>0.5 else { return }
            lastHeight = height; lastOcclusion = occlusion
            DispatchQueue.main.async { [weak self] in self?.onMetrics?(height,occlusion) }
        }
    }
    final class PassthroughView:UIView {
        weak var bar:UIView?
        override func hitTest(_ point:CGPoint,with event:UIEvent?) -> UIView? {
            guard !isHidden, isUserInteractionEnabled, alpha > 0.01, let bar else { return nil }
            let local = bar.convert(point,from:self)
            guard bar.point(inside:local,with:event) else { return nil }
            return bar.hitTest(local,with:event)
        }
    }
}
