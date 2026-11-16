import SwiftUI

/// The installed swipe renderer receives one progress value. Finger movement
/// supplies dy/320; button, release and reverse use the same native release
/// spring as 0.12.4. Only this transparent clock animates; the page host always
/// receives unanimated samples, keeping geometry, opacity and colour in phase.
@MainActor final class MobileGridMorph {
    static let duration:TimeInterval = 0.42
    static let damping:CGFloat = 0.86
    private weak var marker:MobileGridProgressView.Host?
    private var animator:UIViewPropertyAnimator?
    private var link:UIUpdateLink?
    private var request = 0
    private var from:CGFloat = 0
    private var destination:CGFloat = 0
    private var reduced = false
    private var needsEntryLayout = false
    private var waitingForLayout = false
    private var update:((CGFloat) -> Void)?
    private var completion:(() -> Void)?
    private(set) var progress:CGFloat = 0
    private(set) var tabID:UUID?
    private(set) var isAnimating = false

    static func frame(full:CGRect,card:CGRect,progress:CGFloat) -> CGRect {
        let p = min(max(progress,0),1)
        return CGRect(x:full.minX+(card.minX-full.minX)*p,y:full.minY+(card.minY-full.minY)*p,
            width:full.width+(card.width-full.width)*p,height:full.height+(card.height-full.height)*p)
    }
    func attach(_ marker:MobileGridProgressView.Host) {
        self.marker = marker
        if isAnimating && animator == nil { start() }
    }
    func detach(_ marker:MobileGridProgressView.Host) {
        guard self.marker === marker else { return }
        pause(); self.marker = nil
    }
    func track(_ value:CGFloat,tabID:UUID?) {
        progress = min(max(value,0),1); self.tabID = tabID
    }
    func pause(at value:CGFloat? = nil) {
        let changed = value == nil ? nil : update
        request += 1; link?.isEnabled = false; link = nil
        animator?.stopAnimation(true); animator = nil
        marker?.clock.layer.removeAllAnimations()
        if let value { progress = min(max(value,0),1) }
        if let marker { UIView.performWithoutAnimation { marker.clock.transform = marker.transform(for:self.progress) } }
        update = nil; completion = nil; isAnimating = false
        waitingForLayout = false; needsEntryLayout = false
        if let changed {
            var transaction = Transaction(animation:nil); transaction.disablesAnimations = true
            withTransaction(transaction) { changed(progress) }
        }
    }
    func cancel(to value:CGFloat) { pause(); progress = value; tabID = nil }
    func animate(from:CGFloat,to:CGFloat,reduceMotion:Bool,tabID:UUID?,
                 update:@escaping (CGFloat) -> Void,completion:@escaping () -> Void) {
        pause(); progress = from; self.from = from; destination = to; reduced = reduceMotion
        self.tabID = tabID; self.update = update; self.completion = completion; isAnimating = true
        needsEntryLayout = from < 0.0001 && to > 0.9999
        if abs(from-to) < 0.0001 { finish(generation:request); return }
        start()
    }
    private func start() {
        guard animator == nil, let marker, marker.window != nil else { return }
        if waitingForLayout { return }
        if needsEntryLayout {
            // The button first makes the grid visible at p=0. Commit its actual
            // card/toolbar layout before starting the clock. A finger release
            // already has that layout and keeps its existing immediate start.
            waitingForLayout = true
            let generation = request, barrier = UIUpdateLink(view:marker)
            barrier.addAction(to:.afterCATransactionCommit) { [weak self] barrier,_ in
                barrier.isEnabled = false
                guard let self, self.request == generation, self.link === barrier else { return }
                self.link = nil; self.waitingForLayout = false; self.needsEntryLayout = false
                self.start()
            }
            barrier.requiresContinuousUpdates = true
            link = barrier; barrier.isEnabled = true; return
        }
        let generation = request, target = destination
        UIView.performWithoutAnimation { marker.clock.transform = marker.transform(for:self.from) }
        let animation = reduced ? UIViewPropertyAnimator(duration:0.2,curve:.easeInOut)
            : UIViewPropertyAnimator(duration:Self.duration,dampingRatio:Self.damping)
        animator = animation
        animation.addAnimations { marker.clock.transform = marker.transform(for:target) }
        animation.addCompletion { [weak self] position in
            guard position == .end else { return }
            self?.finish(generation:generation)
        }
        let link = UIUpdateLink(view:marker)
        var timing:CAAnimation?
        var spring:Spring?
        link.addAction(to:.afterUpdateScheduled) { [weak self] link,info in
            guard let self, self.request == generation else { link.isEnabled = false; return }
            if timing == nil, let value = marker.clock.layer.animationKeys()?.compactMap({ marker.clock.layer.animation(forKey:$0) })
                .first(where:{ value in
                    guard let value = value as? CABasicAnimation else { return false }
                    return value.keyPath == "transform" && value.beginTime > 0 && value.speed > 0
                }) {
                timing = value
                if let value = value as? CASpringAnimation {
                    spring = Spring(mass:value.mass,stiffness:value.stiffness,damping:value.damping)
                }
            }
            // Presentation readback is a frame late here. Evaluate UIKit's
            // public animation parameters at the update's model time instead.
            guard let timing else { return }
            let time = max(0,(marker.clock.layer.convertTime(info.modelTime,from:nil)-timing.beginTime)*Double(timing.speed)+timing.timeOffset)
            let fraction = spring?.value(target:1.0,initialVelocity:0.0,time:time)
                ?? Self.cubic(timing.timingFunction,time:min(time/max(0.001,timing.duration),1))
            let value = min(max(self.from+(target-self.from)*CGFloat(fraction),0),1)
            self.progress = value
            var transaction = Transaction(animation:nil); transaction.disablesAnimations = true
            withTransaction(transaction) { self.update?(value) }
        }
        let maximum = Float(marker.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum:min(80,maximum),maximum:maximum,preferred:maximum)
        link.requiresContinuousUpdates = true
        self.link = link; link.isEnabled = true; animation.startAnimation()
    }
    private static func cubic(_ timing:CAMediaTimingFunction?,time:Double) -> Double {
        guard let timing else { return time }
        var a:[Float] = [0,0], b:[Float] = [1,1]
        timing.getControlPoint(at:1,values:&a); timing.getControlPoint(at:2,values:&b)
        func value(_ t:Double,_ first:Float,_ second:Float) -> Double {
            3*(1-t)*(1-t)*t*Double(first)+3*(1-t)*t*t*Double(second)+t*t*t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let middle = (low+high)/2
            if value(middle,a[0],b[0]) < time { low = middle } else { high = middle }
        }
        return value((low+high)/2,a[1],b[1])
    }
    private func finish(generation:Int) {
        guard request == generation else { return }
        link?.isEnabled = false; link = nil; animator = nil; isAnimating = false; progress = destination
        let changed = update, finished = completion; update = nil; completion = nil
        var transaction = Transaction(animation:nil); transaction.disablesAnimations = true
        withTransaction(transaction) { changed?(destination) }
        guard request == generation else { return }
        finished?()
    }
}

private enum HostExtent { static let value:CGFloat = 1_000 }

/// Owned, clear, non-interactive clock layer; no snapshot or extra hosting graph.
struct MobileGridProgressView:UIViewRepresentable {
    let morph:MobileGridMorph
    func makeUIView(context:Context) -> Host { Host(morph:morph) }
    func updateUIView(_ view:Host,context:Context) { morph.attach(view) }
    static func dismantleUIView(_ view:Host,coordinator:()) { view.morph?.detach(view) }
    final class Host:UIView {
        weak var morph:MobileGridMorph?
        let clock = UIView(frame:CGRect(x:0,y:0,width:1,height:1))
        func transform(for progress:CGFloat) -> CGAffineTransform { CGAffineTransform(translationX:progress*HostExtent.value,y:0) }
        init(morph:MobileGridMorph) {
            self.morph = morph; super.init(frame:.zero)
            backgroundColor = .clear; isOpaque = false; isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            clock.backgroundColor = .clear; clock.isOpaque = false; clock.isUserInteractionEnabled = false
            addSubview(clock)
        }
        required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { morph?.detach(self) } else { morph?.attach(self) }
        }
    }
}
