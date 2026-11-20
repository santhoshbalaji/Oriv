import AppKit
import BrowserCore
import Observation
import OSLog
import SwiftUI

enum ProfileSwipePreference: String, CaseIterable {
    static let key = "profileSwipePreference"
    case system = "Follow System", on = "On", off = "Off"

    func enabled(system: Bool) -> Bool {
        switch self {
        case .system: system
        case .on: true
        case .off: false
        }
    }
}

/// The snapshot bounds exclude the dots, footer, glass and titlebar controls.
struct ProfileSidebarAnchor: NSViewRepresentable {
    let switcher: ProfileSidebarSwitch
    let controller: BrowserController
    let list: SidebarListHandle
    var profileTrailingInset: CGFloat

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.switcher = switcher
        view.controller = controller
        view.list = list
        view.environment = context.environment
        view.profileTrailingInset = profileTrailingInset
        if view.window != nil { switcher.attach(view) }
    }

    final class Anchor: NSView {
        weak var switcher: ProfileSidebarSwitch?
        weak var controller: BrowserController?
        weak var list: SidebarListHandle?
        var environment = EnvironmentValues()
        var profileTrailingInset: CGFloat = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { switcher?.attach(self) }
        }
        override func layout() {
            super.layout()
            switcher?.anchorLaidOut(self)
        }
    }
}

/// Input spans the full sidebar below its titlebar, independently of the artwork.
struct ProfileSidebarSwipeRegion: NSViewRepresentable {
    enum Kind { case sidebar, editing, titlebarControl }
    let switcher: ProfileSidebarSwitch
    let controller: BrowserController
    let kind: Kind

    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) {
        view.switcher = switcher
        view.controller = controller
        view.kind = kind
        if view.window != nil { switcher.attachRegion(view) }
    }

    final class Region: NSView {
        weak var switcher: ProfileSidebarSwitch?
        weak var controller: BrowserController?
        var kind = Kind.sidebar
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { switcher?.attachRegion(self) }
        }
    }
}

/// The regular scene owns the input monitor and artwork host outside the keyed
/// BrowserWindow, so both survive the profile switch.
struct ProfileSidebarOverlayHost: NSViewRepresentable {
    let profiles: BrowserProfiles

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.profiles = profiles
        if view.window != nil { profiles.sidebarSwitch.attachHost(view) }
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.removeMonitor() }

    final class Host: NSView {
        weak var profiles: BrowserProfiles?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            profiles?.sidebarSwitch.attachHost(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                return self.routeScrollWheel(event) ? nil : event
            }
        }

        func routeScrollWheel(_ event: NSEvent) -> Bool {
            guard let window, let profiles else { return false }
            return profiles.sidebarSwitch.routeScrollWheel(event, in: window, profiles: profiles, input: .monitor)
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Keep phased events on the responder path, including those AppKit delivers
/// directly to the scroll view. Unclaimed events use native scrolling.
class ProfileSidebarScrollView: NSScrollView {
    weak var profiles: BrowserProfiles?

    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        if let window, let profiles,
           profiles.sidebarSwitch.routeScrollWheel(event, in: window, profiles: profiles, input: .scrollView) { return }
        super.scrollWheel(with: event)
    }
}

/// Owned by the profile manager so the overlay and scroll phase survive the
/// keyed BrowserWindow rebuild. Only the covering flag changes SwiftUI state.
@MainActor @Observable final class ProfileSidebarSwitch {
    enum Input: String { case monitor, scrollView }

    private(set) var isCovering = false
    @ObservationIgnored private weak var host: ProfileSidebarOverlayHost.Host?
    @ObservationIgnored private weak var anchor: ProfileSidebarAnchor.Anchor?
    @ObservationIgnored private weak var hitRegion: ProfileSidebarSwipeRegion.Region?
    @ObservationIgnored private weak var editingRegion: ProfileSidebarSwipeRegion.Region?
    @ObservationIgnored private weak var titlebarControl: ProfileSidebarSwipeRegion.Region?
    private static let diagnostics = Logger(subsystem: "Oriv", category: "ProfileSwipe")
    @ObservationIgnored private var overlay: ProfileSidebarOverlay?
    @ObservationIgnored private var swipe = ProfileSwipe()
    @ObservationIgnored private var settleToken = UUID()
    @ObservationIgnored private var settled = false
    @ObservationIgnored private var waitingForProfile: UUID?
    @ObservationIgnored private var gestureWidth: CGFloat = 0
    @ObservationIgnored private var gestureMirror: CGFloat = 1
    @ObservationIgnored private let routedEvents = NSMapTable<NSEvent, NSNumber>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    func cancel(in window: NSWindow, includingSettle: Bool = true) {
        guard overlay?.window === window, includingSettle || overlay?.isSettling == false else { return }
        settleToken = UUID()
        swipe = ProfileSwipe()
        clear()
    }

    func isPresenting(_ profileID: UUID?) -> Bool {
        profileID != nil && overlay?.destinationProfile == profileID
    }

    func attachHost(_ view: ProfileSidebarOverlayHost.Host) {
        host = view
    }

    func attach(_ view: ProfileSidebarAnchor.Anchor) {
        if let active = host?.profiles?.controller, view.controller !== active { return }
        anchor = view
        view.needsLayout = true
    }

    func attachRegion(_ view: ProfileSidebarSwipeRegion.Region) {
        if let active = host?.profiles?.controller, view.controller !== active { return }
        switch view.kind {
        case .sidebar: hitRegion = view
        case .editing: editingRegion = view
        case .titlebarControl: titlebarControl = view
        }
    }

    func anchorLaidOut(_ view: ProfileSidebarAnchor.Anchor) {
        guard view === anchor, view.bounds.width > 0, let waitingForProfile,
              view.controller?.profile?.id == waitingForProfile else { return }
        // The sibling collection view lays out in the same AppKit pass.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.anchor === view,
                  view.list?.collection?.window === view.window,
                  self.waitingForProfile == waitingForProfile,
                  view.controller?.profile?.id == waitingForProfile else { return }
            self.waitingForProfile = nil
            if self.settled { self.clear() }
        }
    }

    func select(_ target: BrowserProfile, profiles: BrowserProfiles, source: BrowserController, direction: Int?) throws {
        guard target.id != profiles.active.id else { return }
        let available = profiles.available.map(\.id)
        let forward = (available.firstIndex(of: target.id) ?? 0) > (available.firstIndex(of: profiles.active.id) ?? 0)
        let step = direction ?? (forward ? 1 : -1)
        if let anchor, anchor.controller === source, !source.sidebar.rail && !source.sidebar.peeking,
           let effect = prepare(profiles: profiles, anchor: anchor) {
            effect.setImage(render(target, profiles: profiles, anchor: anchor), step: step)
            try commit(target, step: step, profiles: profiles)
        } else {
            try profiles.select(target.id, focusLocation: false, deferSelectionSave: true)
        }
    }

    func routeScrollWheel(_ event: NSEvent, in window: NSWindow, profiles: BrowserProfiles, input: Input) -> Bool {
        guard host?.window === window, event.window == nil || event.window === window else { return false }
        // A passed event can visit both the monitor and the responder. Cache
        // by object identity for its lifetime, including across reentrant dispatch.
        if let handled = routedEvents.object(forKey: event) { return handled.boolValue }
        let point = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
        let handled = route(event, window: window, profiles: profiles, source: profiles.controller, location: point, input: input)
        routedEvents.setObject(NSNumber(value: handled), forKey: event)
        return handled
    }

    func route(_ event: NSEvent, window: NSWindow, profiles: BrowserProfiles, source: BrowserController,
               location: NSPoint? = nil, input: Input = .monitor) -> Bool {
        let phase: ProfileSwipe.Phase
        if !event.momentumPhase.isEmpty {
            phase = event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) ? .momentumEnded : .momentum
        } else {
            switch event.phase {
            case .mayBegin: phase = .mayBegin
            case .began: phase = .began
            case .changed: phase = .changed
            case .stationary: phase = .stationary
            case .ended: phase = .ended
            case .cancelled: phase = .cancelled
            default: phase = .unphased
            }
        }

        let anchor = self.anchor
        let point = location ?? event.locationInWindow
        let systemEnabled = NSEvent.isSwipeTrackingFromScrollEventsEnabled
        func blocker() -> String? {
            if !event.hasPreciseScrollingDeltas { return "non-precise" }
            if !profiles.profileSwipePreference.enabled(system: systemEnabled) { return "preference" }
            if !profiles.canSwitchProfiles(from: source) { return "profile" }
            if source.sidebar.rail || source.sidebar.peeking { return "collapsed-sidebar" }
            if source.sidebar.webpageFullscreen { return "webpage-fullscreen" }
            if source.sidebar.dragging { return "dragging" }
            if source.sidebar.menuOpen { return "menu" }
            if source.tabSearchPanel { return "tab-search" }
            if window.attachedSheet != nil { return "sheet" }
            if profiles.switchBlocker != nil { return "switch-blocker" }
            if host?.window !== window { return "missing-host" }
            if phase == .began || phase == .mayBegin {
                guard let region = hitRegion, region.window === window, region.controller === source,
                      region.convert(region.bounds, to: nil).contains(point) else { return "outside-sidebar" }
                if let editing = editingRegion, editing.window === window, editing.controller === source,
                   editing.convert(editing.bounds, to: nil).contains(point) { return "editing-field" }
                if let control = titlebarControl, control.window === window, control.controller === source,
                   control.convert(control.bounds, to: nil).contains(point) { return "titlebar-control" }
                let trafficLights: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
                if trafficLights.contains(where: { kind in
                    guard let button = window.standardWindowButton(kind), !button.isHiddenOrHasHiddenAncestor else { return false }
                    return button.convert(button.bounds, to: nil).contains(point)
                }) { return "titlebar-control" }
            }
            if anchor?.window !== window || anchor?.controller !== source ||
                (anchor?.bounds.isEmpty ?? true) { return "anchor-reattaching" }
            return nil
        }
        let reason = blocker()
        if phase == .began {
            // If the prior horizontal gesture lost its terminal event, bring
            // its artwork home even when this new gesture locks vertically.
            if swipe.axis == .horizontal, overlay?.isSettling == false { settle(step: 0) }
            gestureWidth = anchor?.bounds.width ?? 0
            gestureMirror = anchor?.environment.layoutDirection == .rightToLeft ? -1 : 1
        }
        let previous = profiles.relativeProfile(-1, wrapping: false)
        let next = profiles.relativeProfile(1, wrapping: false)
        let axisBefore = swipe.axis
        let result = swipe.update(phase, dx: event.scrollingDeltaX * gestureMirror, dy: event.scrollingDeltaY,
                                  at: event.timestamp, eligible: reason == nil, width: gestureWidth,
                                  previous: previous != nil, next: next != nil,
                                  presentationOffset: overlay?.offset(relativeTo: profiles.active.id) ?? 0)
        if UserDefaults.standard.bool(forKey: "ProfileSwipeDiagnostics") {
            Self.diagnostics.notice("source=\(input.rawValue, privacy: .public) phase=\(event.phase.rawValue) routed=\(String(describing: phase), privacy: .public) momentumPhase=\(event.momentumPhase.rawValue) dx=\(Double(event.scrollingDeltaX)) dy=\(Double(event.scrollingDeltaY)) precise=\(event.hasPreciseScrollingDeltas) system=\(systemEnabled) eligibility=\(reason ?? "eligible", privacy: .public) axis=\(String(describing: axisBefore), privacy: .public)->\(String(describing: self.swipe.axis), privacy: .public) settling=\(self.overlay?.isSettling ?? false) result=\(String(describing: result), privacy: .public)")
        }
        switch result {
        case .pass: return false
        case .swallow: return true
        case .track(let offset):
            if let anchor, let effect = prepare(profiles: profiles, anchor: anchor) {
                let step = offset < 0 ? 1 : -1
                if !effect.hasImage(step: step), let target = step > 0 ? next : previous {
                    effect.setImage(render(target, profiles: profiles, anchor: anchor), step: step)
                }
                effect.place(offset: offset)
            }
            return true
        case .settle(let step):
            if let step, let target = step > 0 ? next : previous, let anchor, let overlay {
                if !overlay.hasImage(step: step) {
                    overlay.setImage(render(target, profiles: profiles, anchor: anchor), step: step)
                }
                do { try commit(target, step: step, profiles: profiles) }
                catch { profiles.error = error.localizedDescription }
            } else { settle(step: 0) }
            return true
        }
    }

    private func prepare(profiles: BrowserProfiles, anchor: ProfileSidebarAnchor.Anchor) -> ProfileSidebarOverlay? {
        if let overlay, overlay.window === anchor.window,
           overlay.baseProfile == profiles.active.id || overlay.destinationProfile == profiles.active.id {
            if overlay.isSettling {
                settleToken = UUID()
                waitingForProfile = nil
                settled = false
                overlay.interrupt(active: profiles.active.id)
            }
            return overlay
        }
        if overlay != nil { clear() }
        guard let host, host.window === anchor.window, anchor.bounds.width > 0, anchor.bounds.height > 0 else { return nil }
        let frame = anchor.convert(anchor.bounds, to: host)
        let effect = ProfileSidebarOverlay(frame: frame, rtl: anchor.environment.layoutDirection == .rightToLeft,
                                           reduceMotion: anchor.environment.browserReduceMotion)
        effect.baseProfile = profiles.active.id
        effect.setImage(render(profiles.active, profiles: profiles, anchor: anchor, current: true), step: 0)
        host.addSubview(effect)
        overlay = effect
        isCovering = true
        return effect
    }

    private func render(_ profile: BrowserProfile, profiles: BrowserProfiles, anchor: ProfileSidebarAnchor.Anchor,
                        current: Bool = false) -> CGImage? {
        let scroll = current ? anchor.list?.collection?.enclosingScrollView : nil
        let tabListImage = scroll.flatMap { view -> NSImage? in
            let rect = view.bounds
            guard !rect.isEmpty, let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            view.cacheDisplay(in: rect, to: bitmap)
            let image = NSImage(size: rect.size)
            image.addRepresentation(bitmap)
            return image
        }
        let appearance = profiles.loadedController(profile.id)?.appearance
        var environment = anchor.environment
        if let appearance, !current {
            environment.browserTheme = appearance.theme.respecting(environment.colorSchemeContrast)
            if let scheme = appearance.colorScheme { environment.colorScheme = scheme }
        }
        let artwork = ProfileSidebarPreviewArtwork(profile: profile, preview: profiles.preview(for: profile),
                                                   size: anchor.bounds.size,
                                                   query: current ? anchor.controller?.tabSearch ?? "" : "",
                                                   tabListImage: tabListImage,
                                                   profileTrailingInset: anchor.profileTrailingInset)
        let renderer = ImageRenderer(content: artwork.environment(\.self, environment))
        renderer.scale = anchor.window?.backingScaleFactor ?? 2
        return renderer.cgImage
    }

    private func commit(_ target: BrowserProfile, step: Int, profiles: BrowserProfiles) throws {
        overlay?.destinationProfile = target.id
        waitingForProfile = target.id
        do {
            try profiles.select(target.id, focusLocation: false, deferSelectionSave: true)
        } catch {
            waitingForProfile = nil
            overlay?.destinationProfile = nil
            settle(step: 0)
            throw error
        }
        settle(step: step)
    }

    private func settle(step: Int) {
        guard let overlay else { return }
        let token = UUID()
        settleToken = token
        settled = false
        overlay.animate(step: step) { [weak self] in
            guard let self, self.settleToken == token else { return }
            self.settled = true
            if self.waitingForProfile == nil { self.clear() }
        }
        // A closed window, fullscreen transition, or rail destination may
        // never lay out an expanded sidebar.
        if waitingForProfile != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if self?.settleToken == token { self?.clear() }
            }
        }
    }

    private func clear() {
        overlay?.removeFromSuperview()
        overlay = nil
        waitingForProfile = nil
        isCovering = false
    }
}

private final class ProfileSidebarOverlay: NSView {
    private let strip = CALayer()
    private var images: [Int: CALayer] = [:]
    private let mirror: CGFloat
    private let reduceMotion: Bool
    private var offset: CGFloat = 0
    private var destinationStep = 0
    private var fadeStep = 0
    var baseProfile: UUID?
    var destinationProfile: UUID?
    private(set) var isSettling = false

    init(frame: NSRect, rtl: Bool, reduceMotion: Bool) {
        mirror = rtl ? -1 : 1
        self.reduceMotion = reduceMotion
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        strip.frame = bounds
        layer?.addSublayer(strip)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic snapshot overlay") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func hasImage(step: Int) -> Bool { images[step] != nil }

    func setImage(_ image: CGImage?, step: Int) {
        guard let image else { return }
        let piece = images[step] ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        piece.contents = image
        piece.frame = bounds.offsetBy(dx: reduceMotion ? 0 : CGFloat(step) * bounds.width * mirror, dy: 0)
        piece.opacity = step == 0 ? 1 : 0
        if images[step] == nil { strip.addSublayer(piece) }
        images[step] = piece
        CATransaction.commit()
    }

    func offset(relativeTo active: UUID) -> CGFloat {
        let current: CGFloat
        if reduceMotion, let layer = images[fadeStep], let presentation = layer.presentation() {
            current = -CGFloat(fadeStep) * CGFloat(presentation.opacity) * bounds.width
        } else { current = reduceMotion ? offset : (strip.presentation()?.transform.m41 ?? strip.transform.m41) * mirror }
        return active == destinationProfile ? current + CGFloat(destinationStep) * bounds.width : current
    }

    func interrupt(active: UUID) {
        let current = offset(relativeTo: active)
        let shift = active == destinationProfile ? destinationStep : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.removeAllAnimations()
        for piece in images.values { piece.removeAllAnimations() }
        let prior = images
        images.removeAll()
        for (step, piece) in prior {
            let rebased = step - shift
            guard abs(rebased) <= 1 else { piece.removeFromSuperlayer(); continue }
            piece.frame = bounds.offsetBy(dx: reduceMotion ? 0 : CGFloat(rebased) * bounds.width * mirror, dy: 0)
            images[rebased] = piece
        }
        CATransaction.commit()
        baseProfile = active
        destinationProfile = nil
        destinationStep = 0
        isSettling = false
        place(offset: current)
    }

    func place(offset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(offset)
        CATransaction.commit()
    }

    private func apply(_ value: CGFloat) {
        offset = value
        if reduceMotion {
            fadeStep = value < 0 ? 1 : -1
            let progress = images[fadeStep] == nil ? 0 : Float(min(1, abs(value) / bounds.width))
            for (step, piece) in images {
                piece.opacity = step == 0 ? 1 - progress : (step == fadeStep ? progress : 0)
            }
        } else {
            strip.transform = CATransform3DMakeTranslation(value * mirror, 0, 0)
            for piece in images.values { piece.opacity = 1 }
        }
    }

    func animate(step: Int, completion: @escaping @MainActor () -> Void) {
        destinationStep = step
        isSettling = true
        let end = -CGFloat(step) * bounds.width
        let outgoingFadeStep = fadeStep
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { DispatchQueue.main.async { completion() } }
        if reduceMotion {
            let old = images.mapValues { $0.presentation()?.opacity ?? $0.opacity }
            apply(end)
            if step == 0 { fadeStep = outgoingFadeStep }
            for (index, piece) in images {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.duration = 0.15
                fade.fromValue = old[index]
                fade.toValue = piece.opacity
                piece.add(fade, forKey: "settle")
            }
        } else {
            let start = strip.presentation()?.transform ?? strip.transform
            apply(end)
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1
            spring.stiffness = 320
            spring.damping = 34
            spring.duration = 0.30
            spring.fromValue = NSValue(caTransform3D: start)
            spring.toValue = NSValue(caTransform3D: strip.transform)
            strip.add(spring, forKey: "settle")
        }
        CATransaction.commit()
    }
}
