import Observation
import BrowserEngine
import SwiftUI
import UIKit
import WebKit
import BrowserCore

/// SwiftUI changes membership only at the start and end of an interaction.
/// UIKit moves the already mounted surfaces and springs them to an endpoint.
@MainActor @Observable final class MobileTabSwipe {
    @ObservationIgnored weak var topChrome:MobileTopChrome?
    @ObservationIgnored var chromeForTab:((UUID) -> (ChromeColor,CGFloat))?
    private(set) var sourceID:UUID?
    private(set) var destinationID:UUID?
    private(set) var preparation:UUID?
    private(set) var image:UIImage?
    private(set) var direction = 1
    private(set) var reduceMotion = false
    var isActive:Bool { sourceID != nil }
    @ObservationIgnored private weak var outgoing:UIView?
    @ObservationIgnored private weak var incoming:UIView?
    @ObservationIgnored private weak var backing:UIView?
    @ObservationIgnored private var translation:CGFloat = 0
    @ObservationIgnored private var animator:UIViewPropertyAnimator?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var atEndpoint = false
    @ObservationIgnored private var completion:(() -> Void)?
    @ObservationIgnored private var pendingFinish:(Bool,() -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timeout:Task<Void,Never>?
    @ObservationIgnored private var navigationObserver:MobileSwipeNavigationObserver?
    private final class Surface { weak var view:UIView?; init(_ view:UIView) { self.view = view } }
    @ObservationIgnored private var hosts:[UUID:Surface] = [:]
    #if DEBUG
    private var paintedSurface:ObjectIdentifier?
    private var paintedWebParent:ObjectIdentifier?
    private var paintedViewport:CGSize = .zero
    #endif

    func begin(source:UUID,destination:UUID,direction:Int,image:UIImage?,reduceMotion:Bool) {
        guard sourceID != source || destinationID != destination else { return }
        cancel()
        sourceID = source; destinationID = destination; self.direction = direction
        self.image = image; self.reduceMotion = reduceMotion; preparation = UUID()
        outgoing = hosts[source]?.view; incoming = hosts[destination]?.view
        if let tint = chromeForTab?(destination) { topChrome?.beginSwipe(to:tint.0,opacity:tint.1) }
        navigationObserver = MobileSwipeNavigationObserver { [weak self] notification in
            guard let self, let view = notification.object as? WKWebView,
                  view === (self.incoming?.superview as? MobileWebHost)?.webView else { return }
            // A render from the previous document cannot satisfy a new load.
            // Without a backing image, interruption returns to the source.
            if self.ready && self.image == nil { self.cancel(); return }
            self.ready = false; self.preparation = UUID()
        }
        (outgoing?.superview as? MobileWebHost)?.requestHighRefresh()
        let request = generation
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:.seconds(4)) } catch { return }
            guard let self, request == self.generation else { return }
            self.cancel()
        }
        #if DEBUG
        MobileTransitionMetrics.stop()
        MobileTransitionMetrics.start("bar-swipe",frameSampler:{ [weak self] in self?.frameEvidence() ?? [:] })
        MobileTransitionMetrics.note("swipe-mounted",["hasSnapshot":image != nil])
        #endif
    }
    func attach(_ view:UIView,for id:UUID) {
        if hosts[id]?.view !== view { hosts[id] = Surface(view) }
        if id == sourceID { outgoing = view }
        else if id == destinationID { incoming = view }
        else {
            if view.transform != .identity { view.transform = .identity }
            let alpha:CGFloat = (view.superview as? MobileWebHost)?.selected == false ? 0 : 1
            if view.alpha != alpha { view.alpha = alpha }
            return
        }
        refreshPresentation()
    }
    func attachBacking(_ view:UIView) { backing = view; refreshPresentation() }
    func detach(_ view:UIView) {
        let interrupted = outgoing === view || incoming === view || backing === view
        if outgoing === view { outgoing = nil }
        if incoming === view { incoming = nil }
        if backing === view { backing = nil }
        hosts = hosts.filter { $0.value.view != nil && $0.value.view !== view }
        guard interrupted, isActive else { return }
        let request = generation
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.generation == request else { return }
            self.cancel()
        }
    }
    func move(_ delta:CGFloat) {
        guard isActive, animator == nil, completion == nil, pendingFinish == nil else { return }
        translation = min(max(delta,-width),width)
        // No observable property or SwiftUI transaction is touched per frame.
        UIView.performWithoutAnimation { apply() }
    }
    private var width:CGFloat { max(1,outgoing?.bounds.width ?? incoming?.bounds.width ?? backing?.bounds.width ?? 1) }
    var isPrepared:Bool { ready }
    private var canRender:Bool {
        (outgoing?.bounds.width ?? 0) > 0 && (incoming?.bounds.width ?? 0) > 0 &&
            (image?.cgImage != nil ? (backing?.bounds.width ?? 0) > 0 : ready)
    }
    private func refreshPresentation() {
        guard animator == nil else { return }
        if let pendingFinish, canRender {
            self.pendingFinish = nil
            startSpring(commit:pendingFinish.0,completion:pendingFinish.1)
        } else { UIView.performWithoutAnimation { apply() } }
    }
    private func apply() {
        guard canRender else {
            topChrome?.moveSwipe(0)
            outgoing?.transform = .identity; outgoing?.alpha = 1
            incoming?.transform = reduceMotion ? .identity : CGAffineTransform(translationX:CGFloat(direction)*width,y:0); incoming?.alpha = 0
            backing?.transform = incoming?.transform ?? .identity; backing?.alpha = 0
            return
        }
        let progress = min(abs(translation)/width,1)
        topChrome?.moveSwipe(progress)
        outgoing?.transform = reduceMotion ? .identity : CGAffineTransform(translationX:translation,y:0)
        incoming?.transform = reduceMotion ? .identity : CGAffineTransform(translationX:translation+CGFloat(direction)*width,y:0)
        backing?.transform = incoming?.transform ?? .identity
        outgoing?.alpha = reduceMotion && image == nil ? 1-progress : 1
        incoming?.alpha = 1
        backing?.alpha = image == nil ? 0 : (reduceMotion ? progress : 1)
    }
    func prepared(_ token:UUID,success:Bool) {
        guard token == preparation else { return }
        guard success else { cancel(); return }
        ready = true
        #if DEBUG
        let host = incoming?.superview as? MobileWebHost
        paintedSurface = incoming.map(ObjectIdentifier.init)
        paintedWebParent = host?.webView.superview.map(ObjectIdentifier.init)
        paintedViewport = host?.webView.bounds.size ?? .zero
        MobileTransitionMetrics.note("swipe-painted",["surface":String(describing:paintedSurface),
            "webParent":String(describing:paintedWebParent),"width":paintedViewport.width,"height":paintedViewport.height])
        #endif
        refreshPresentation()
        completeIfReady()
    }
    func finish(commit:Bool,completion:@escaping () -> Void) {
        guard isActive, animator == nil, pendingFinish == nil else { return }
        guard canRender else {
            if commit { pendingFinish = (commit,completion) }
            else { cancel(); completion() }
            return
        }
        startSpring(commit:commit,completion:completion)
    }
    private func startSpring(commit:Bool,completion:@escaping () -> Void) {
        let request = generation
        self.completion = commit ? completion : nil
        UIView.performWithoutAnimation {
            incoming?.alpha = 1
            backing?.alpha = image == nil ? 0 : (reduceMotion ? min(abs(translation)/width,1) : 1)
        }
        translation = commit ? -CGFloat(direction)*width : 0
        topChrome?.startSpring()
        let spring = reduceMotion
            ? UIViewPropertyAnimator(duration:0.18,curve:.easeInOut) { [weak self] in self?.apply() }
            : UIViewPropertyAnimator(duration:0.34,dampingRatio:1) { [weak self] in self?.apply() }
        animator = spring
        spring.addCompletion { [weak self] position in
            guard let self, request == self.generation else { return }
            self.animator = nil
            guard position == .end else { self.cancel(); return }
            if commit { self.atEndpoint = true; self.completeIfReady() }
            else { self.cancel(); completion() }
        }
        spring.startAnimation()
    }
    private func completeIfReady() {
        guard ready, atEndpoint, let completion else { return }
        self.completion = nil
        // Leave the outgoing surface offscreen until SwiftUI removes it. The
        // destination is already at identity in its original full-size host.
        #if DEBUG
        let host = incoming?.superview as? MobileWebHost
        MobileTransitionMetrics.note("swipe-handoff",[
            "sameSurface":paintedSurface == incoming.map(ObjectIdentifier.init),
            "sameWebParent":paintedWebParent == host?.webView.superview.map(ObjectIdentifier.init),
            "sameViewport":paintedViewport == host?.webView.bounds.size])
        MobileTransitionMetrics.stop()
        #endif
        outgoing?.alpha = 0
        completion()
        topChrome?.endSwipe(commit:true,pageID:destinationID)
        clear()
    }
    private func clear() {
        navigationObserver = nil
        timeout?.cancel(); timeout = nil
        generation += 1; sourceID = nil; destinationID = nil; preparation = nil; image = nil
        outgoing = nil; incoming = nil; backing = nil
        translation = 0; ready = false; atEndpoint = false; completion = nil; pendingFinish = nil
        hosts = hosts.filter { $0.value.view != nil }
    }
    func cancel() {
        animator?.stopAnimation(true); animator = nil
        topChrome?.endSwipe(commit:false)
        outgoing?.transform = .identity; outgoing?.alpha = 1
        // SwiftUI removes these on its next update. Hide them first so resetting
        // their transforms cannot put a destination snapshot over a cancelled
        // swipe's source for one composited frame.
        for view in [incoming,backing].compactMap({ $0 }) {
            view.alpha = 0; view.transform = .identity
        }
        #if DEBUG
        if isActive { MobileTransitionMetrics.note("swipe-cancel",[:]); MobileTransitionMetrics.stop() }
        #endif
        clear()
    }
    #if DEBUG
    private func frameEvidence() -> [String:Any] {
        func rectangle(_ view:UIView?) -> [Double] {
            guard let view else { return [] }
            let rect = view.layer.presentation()?.frame ?? view.frame
            return [rect.minX,rect.minY,rect.width,rect.height].map(Double.init)
        }
        return ["source":rectangle(outgoing),"destination":rectangle(incoming),"snapshot":rectangle(backing),
            "sourceOpacity":outgoing?.layer.presentation()?.opacity ?? outgoing?.layer.opacity ?? 0,
            "destinationOpacity":incoming?.layer.presentation()?.opacity ?? incoming?.layer.opacity ?? 0,
            "snapshotOpacity":backing?.layer.presentation()?.opacity ?? backing?.layer.opacity ?? 0,
            "hasSnapshot":image?.cgImage != nil,"painted":ready,"width":Double(width),"reduceMotion":reduceMotion,
            "requestedTranslation":Double(translation),"direction":direction,"canRender":canRender,
            "tracking":animator == nil && completion == nil && pendingFinish == nil]
    }
    #endif
}

@MainActor private final class MobileSwipeNavigationObserver:NSObject {
    let action:(Notification) -> Void
    init(_ action:@escaping (Notification) -> Void) {
        self.action = action; super.init()
        NotificationCenter.default.addObserver(self,selector:#selector(receive(_:)),name:BrowserTab.navigationStarted,object:nil)
    }
    @objc private func receive(_ notification:Notification) { action(notification) }
    deinit { NotificationCenter.default.removeObserver(self) }
}

/// Kept above the destination until both the spring and WebKit paint complete.
struct MobileSwipeBacking:UIViewRepresentable {
    let swipe:MobileTabSwipe
    let background:UIColor
    func makeUIView(context:Context) -> Host { Host() }
    static func dismantleUIView(_ host:Host,coordinator:()) { host.swipe?.detach(host.image) }
    func updateUIView(_ host:Host,context:Context) {
        host.image.image = swipe.image; host.image.backgroundColor = background
        host.swipe = swipe
        swipe.attachBacking(host.image)
    }
    final class Host:UIView {
        let image = UIImageView()
        weak var swipe:MobileTabSwipe?
        override init(frame:CGRect) {
            super.init(frame:frame)
            image.contentMode = .scaleToFill; image.clipsToBounds = true
            isUserInteractionEnabled = false; accessibilityElementsHidden = true
            addSubview(image)
        }
        required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            if image.bounds.size != bounds.size {
                image.bounds = CGRect(origin:.zero,size:bounds.size)
                image.center = CGPoint(x:bounds.midX,y:bounds.midY)
            }
            swipe?.attachBacking(image)
        }
    }
}

/// One persistent safe-area layer. A swipe writes it inside the very same
/// UIKit animation block as the two page transforms. Detector updates cannot
/// retarget an in-flight swipe; real subsequent changes start from displayed paint.
@MainActor @Observable final class MobileTopChrome {
    private(set) var isDark = true
    @ObservationIgnored private weak var view:UIView?
    @ObservationIgnored private var animator:UIViewPropertyAnimator?
    @ObservationIgnored private var link:CADisplayLink?
    @ObservationIgnored private lazy var driver = Driver(self)
    @ObservationIgnored private var target:ChromeColor?
    @ObservationIgnored private var targetOpacity:CGFloat = 1
    @ObservationIgnored private var pageID:UUID?
    @ObservationIgnored private var swipe:(from:ChromeColor,to:ChromeColor,fromOpacity:CGFloat,toOpacity:CGFloat)?
    @ObservationIgnored private var springing = false
    @ObservationIgnored private var styleScheduled = false
    var hasRendered:Bool { target != nil }
    static func rgb(_ color:UIColor) -> ChromeColor {
        var r:CGFloat = 0,g:CGFloat = 0,b:CGFloat = 0,a:CGFloat = 0
        color.getRed(&r,green:&g,blue:&b,alpha:&a)
        return ChromeColor(r,g,b,alpha:a)
    }
    static func blend(_ a:ChromeColor,_ b:ChromeColor,_ progress:CGFloat) -> ChromeColor {
        let p = Double(min(max(progress,0),1))
        return ChromeColor(a.red+(b.red-a.red)*p,a.green+(b.green-a.green)*p,a.blue+(b.blue-a.blue)*p)
    }
    private func paint(_ color:ChromeColor,opacity:CGFloat) {
        view?.backgroundColor = UIColor(red:color.red,green:color.green,blue:color.blue,alpha:1)
        view?.alpha = opacity
    }
    private var displayed:ChromeColor {
        if let color = view?.layer.presentation()?.backgroundColor { return Self.rgb(UIColor(cgColor:color)) }
        return view?.backgroundColor.map(Self.rgb) ?? target ?? ChromeColor(0,0,0)
    }
    private var displayedOpacity:CGFloat { CGFloat(view?.layer.presentation()?.opacity ?? Float(view?.alpha ?? 1)) }
    #if DEBUG
    var presentationColor:ChromeColor { displayed }
    #endif
    func attach(_ view:UIView) {
        guard self.view !== view else { return }
        self.view = view
        if let target { UIView.performWithoutAnimation { paint(target,opacity:targetOpacity) } }
    }
    func detach(_ view:UIView) {
        guard self.view === view else { return }
        stopFade(); link?.invalidate(); link = nil; self.view = nil
    }
    private func stopFade() {
        guard let animator else { return }
        let color = displayed, opacity = displayedOpacity
        animator.stopAnimation(true); self.animator = nil
        UIView.performWithoutAnimation { paint(color,opacity:opacity) }
    }
    func render(color:ChromeColor,opacity:CGFloat,pageID:UUID?,interactive:Bool,reduceMotion:Bool) {
        guard swipe == nil else { return }
        let samePage = self.pageID == pageID
        self.pageID = pageID
        guard target != color || targetOpacity != opacity || (reduceMotion && animator != nil) else { return }
        let initialized = target != nil
        stopFade(); target = color; targetOpacity = opacity
        if initialized && samePage && !interactive && !reduceMotion && view?.window != nil {
            let fade = UIViewPropertyAnimator(duration:0.18,curve:.easeInOut) { [weak self] in self?.paint(color,opacity:opacity) }
            animator = fade
            fade.addCompletion { [weak self,weak fade] _ in
                guard let self, self.animator === fade else { return }
                self.animator = nil; self.sampleStyle()
            }
            track(); fade.startAnimation()
        } else {
            UIView.performWithoutAnimation { paint(color,opacity:opacity) }
            // Representable updates must not publish observation recursively
            // during a SwiftUI layout. Native gesture callbacks publish directly.
            guard !styleScheduled else { return }
            styleScheduled = true
            DispatchQueue.main.async { [weak self] in self?.styleScheduled = false; self?.sampleStyle() }
        }
    }
    func beginSwipe(to:ChromeColor,opacity:CGFloat) {
        let from = displayed, fromOpacity = displayedOpacity
        stopFade()
        swipe = (from,to,fromOpacity,opacity); springing = false
    }
    func moveSwipe(_ progress:CGFloat) {
        guard let swipe else { return }
        let color = Self.blend(swipe.from,swipe.to,progress)
        let opacity = swipe.fromOpacity+(swipe.toOpacity-swipe.fromOpacity)*min(max(progress,0),1)
        paint(color,opacity:opacity)
        if !springing { sampleStyle(); track() }
    }
    func startSpring() { springing = true; track() }
    func endSwipe(commit:Bool,pageID:UUID? = nil) {
        guard let swipe else { return }
        let color = commit ? swipe.to : swipe.from, opacity = commit ? swipe.toOpacity : swipe.fromOpacity
        UIView.performWithoutAnimation { paint(color,opacity:opacity) }
        target = color; targetOpacity = opacity
        if let pageID { self.pageID = pageID }
        self.swipe = nil; springing = false; sampleStyle(color)
    }
    private func sampleStyle(_ color:ChromeColor? = nil) {
        let dark = (color ?? displayed).whiteForeground
        if isDark != dark { isDark = dark }
    }
    private func track() {
        guard link == nil else { return }
        let link = CADisplayLink(target:driver,selector:#selector(Driver.frame(_:)))
        let maximum = Float(view?.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum:min(60,maximum),maximum:maximum,preferred:maximum)
        self.link = link; link.add(to:.main,forMode:.common)
    }
    @MainActor private final class Driver:NSObject {
        weak var owner:MobileTopChrome?
        init(_ owner:MobileTopChrome) { self.owner = owner }
        @objc func frame(_ link:CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.sampleStyle()
            if !owner.springing && owner.animator == nil { link.invalidate(); owner.link = nil }
        }
    }
}

/// SwiftUI supplies its *interpolated* grid/fallback progress, rather than a
/// second timer or an independent spring. Bar swipes bypass this through UIKit.
struct MobileTopBar:View,Animatable {
    let chrome:MobileTopChrome
    let page:ChromeColor
    let canvas:ChromeColor
    let destination:ChromeColor
    let pageOpacity:CGFloat
    let destinationOpacity:CGFloat
    let pageID:UUID?
    var gridProgress:CGFloat
    var swipeProgress:CGFloat
    let interactive:Bool
    let reduceMotion:Bool
    nonisolated var animatableData:AnimatablePair<CGFloat,CGFloat> {
        get { AnimatablePair(gridProgress,swipeProgress) }
        set {
            #if DEBUG
            MobileTransitionMetrics.gridInterpolations += 1
            #endif
            gridProgress = newValue.first; swipeProgress = newValue.second
        }
    }
    var body:some View {
        let p = min(max(gridProgress,0),1), s = min(max(swipeProgress,0),1)
        let base = MobileTopChrome.blend(page,destination,s)
        let opacity = pageOpacity+(destinationOpacity-pageOpacity)*s
        Fill(chrome:chrome,color:MobileTopChrome.blend(base,canvas,p),opacity:opacity+(1-opacity)*p,
             pageID:pageID,interactive:interactive,reduceMotion:reduceMotion)
    }
    private struct Fill:UIViewRepresentable {
        let chrome:MobileTopChrome,color:ChromeColor,opacity:CGFloat,pageID:UUID?,interactive:Bool,reduceMotion:Bool
        final class Host:UIView {
            weak var chrome:MobileTopChrome?
            weak var rootView:UIView?
            let fill = UIView()
            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard let root = window?.rootViewController?.view, let container = root.superview else {
                    chrome?.detach(fill); fill.removeFromSuperview(); return
                }
                rootView = root
                if fill.superview !== container {
                    // Anchor in the existing chrome graph, but keep actual paint
                    // outside its page/grid opacity and insertion transforms.
                    // Use UIKit's common superview, never SwiftUI's managed
                    // hosting view, to preserve its controller/focus lifecycle.
                    fill.isUserInteractionEnabled = false; fill.accessibilityElementsHidden = true
                    fill.isOpaque = false; container.insertSubview(fill,aboveSubview:root)
                }
                chrome?.attach(fill); layoutFill()
            }
            override func layoutSubviews() { super.layoutSubviews(); layoutFill() }
            private func layoutFill() {
                guard let root = rootView, let container = fill.superview else { return }
                let band = CGRect(x:root.bounds.minX,y:root.bounds.minY,width:root.bounds.width,height:window?.safeAreaInsets.top ?? 0)
                fill.frame = root.convert(band,to:container)
            }
        }
        func makeUIView(context:Context) -> Host {
            let view = Host(); view.isOpaque = false; view.clipsToBounds = true
            view.isUserInteractionEnabled = false; view.accessibilityElementsHidden = true
            view.chrome = chrome; chrome.attach(view.fill); return view
        }
        func updateUIView(_ view:Host,context:Context) {
            chrome.attach(view.fill)
            chrome.render(color:color,opacity:opacity,pageID:pageID,interactive:interactive,reduceMotion:reduceMotion)
        }
        static func dismantleUIView(_ view:Host,coordinator:()) { view.chrome?.detach(view.fill); view.fill.removeFromSuperview(); view.chrome = nil }
    }
}
