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

/// The regular scene owns the input monitor and artwork host for its window.
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

/// Owns the sidebar overlay and scroll phase across profile changes.
@MainActor @Observable final class ProfileSidebarSwitch {
    enum Input: String { case monitor, scrollView }

    private(set) var isCovering = false
    @ObservationIgnored private weak var host: ProfileSidebarOverlayHost.Host?
    @ObservationIgnored private weak var anchor: ProfileSidebarAnchor.Anchor?
    @ObservationIgnored private weak var hitRegion: ProfileSidebarSwipeRegion.Region?
    @ObservationIgnored private weak var editingRegion: ProfileSidebarSwipeRegion.Region?
    @ObservationIgnored private weak var titlebarControl: ProfileSidebarSwipeRegion.Region?
    static let signposter = OSSignposter(subsystem: "Oriv", category: "ProfileSwitch")
    static var diagnosticsEnabled: Bool { UserDefaults.standard.bool(forKey: "ProfileSwipeDiagnostics") }
    private static let diagnostics = Logger(subsystem: "Oriv", category: "ProfileSwipe")
    @ObservationIgnored var springCommitted: (() -> Void)?
    @ObservationIgnored var selectTurnMeasured: ((Double) -> Void)?
    @ObservationIgnored private var selectionPending = false
    @ObservationIgnored private var transitionTarget: UUID?
    @ObservationIgnored private var transitionTime: TimeInterval = 0
    @ObservationIgnored private var gestureNeighbors: (previous: BrowserProfile?, next: BrowserProfile?) = (nil, nil)
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artworkNeedsRefresh = true
    @ObservationIgnored private var artworkGeometry: ArtworkGeometry?
    @ObservationIgnored private var artworkCache: [UUID: CachedArtwork] = [:]
    @ObservationIgnored private var nativeList: NativeListArtwork?
    @ObservationIgnored private weak var nativeScroll: SidebarTabScrollView?
    @ObservationIgnored private var lastListViewport = NSRect.zero
    @ObservationIgnored private var lastViewportChange: TimeInterval = 0

    private struct NativeListArtwork {
        let profile: UUID
        let query: String
        let geometry: ArtworkGeometry
        let viewport: NSRect
        let frame: NSRect
        let image: CGImage
    }
    @ObservationIgnored private(set) var fallbackClearCount = 0

    private struct ArtworkGeometry: Equatable {
        let size: CGSize
        let scale: CGFloat
        let inset: CGFloat
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
        let direction: LayoutDirection
        let typeSize: DynamicTypeSize
        let customTheme: Bool
        let glassLevel: SidebarGlassOpacity
        let opaqueChrome: Bool

        @MainActor init(_ anchor: ProfileSidebarAnchor.Anchor) {
            let environment = anchor.environment
            size = anchor.bounds.size
            scale = anchor.window?.backingScaleFactor ?? 2
            inset = anchor.profileTrailingInset
            scheme = environment.colorScheme
            contrast = environment.colorSchemeContrast
            direction = environment.layoutDirection
            typeSize = environment.dynamicTypeSize
            customTheme = environment.browserTheme.isT3Code
            glassLevel = environment.sidebarChromaticStyle?.level ?? .balanced
            opaqueChrome = environment.sidebarNeedsOpaqueChrome
        }
    }

    private struct CachedArtwork {
        let profile: BrowserProfile
        let preview: ProfileSidebarPreview
        let query: String
        let appearance: BrowserAppearance
        let color: SidebarColor
        let image: CGImage?
    }
    @ObservationIgnored private var mountInterval: OSSignpostIntervalState?
    @ObservationIgnored private var overlay: ProfileSidebarOverlay?
    @ObservationIgnored private var swipe = ProfileSwipe()
    @ObservationIgnored private var settleToken = UUID()
    @ObservationIgnored private var settled = false
    @ObservationIgnored private var waitingForProfile: UUID?
    @ObservationIgnored private var gestureWidth: CGFloat = 0
    @ObservationIgnored private var gestureArtworkCompatible = false
    @ObservationIgnored private var gestureMirror: CGFloat = 1
    @ObservationIgnored private let routedEvents = NSMapTable<NSEvent, NSNumber>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    func cancel(in window: NSWindow, includingSettle: Bool = true) {
        guard overlay?.window === window, includingSettle || overlay?.isSettling == false else { return }
        settleToken = UUID()
        if !selectionPending, overlay?.isSettling != true { swipe = ProfileSwipe() }
        clear()
    }

    func isPresenting(_ profileID: UUID?) -> Bool {
        profileID != nil && (overlay?.destinationProfile == profileID ||
            (transitionTarget == profileID && ProcessInfo.processInfo.systemUptime - transitionTime < 0.4))
    }

    func attachHost(_ view: ProfileSidebarOverlayHost.Host) {
        host = view
        scheduleArtwork()
    }

    func attach(_ view: ProfileSidebarAnchor.Anchor) {
        if let active = host?.profiles?.controller, view.controller !== active { return }
        anchor = view
        view.needsLayout = true
        scheduleArtwork()
    }

    func attachRegion(_ view: ProfileSidebarSwipeRegion.Region) {
        if let active = host?.profiles?.controller, view.controller !== active { return }
        switch view.kind {
        case .sidebar: hitRegion = view
        case .editing: editingRegion = view
        case .titlebarControl: titlebarControl = view
        }
    }

    func listViewportChanged(_ scroll: SidebarTabScrollView) {
        guard anchor?.list?.collection?.enclosingScrollView === scroll,
              nativeScroll !== scroll || lastListViewport != scroll.contentView.bounds else { return }
        nativeScroll = scroll
        lastListViewport = scroll.contentView.bounds
        lastViewportChange = ProcessInfo.processInfo.systemUptime
        nativeList = nil
        artworkNeedsRefresh = true
        scheduleArtwork()
    }

    func sidebarDragFinished() { scheduleArtwork() }

    func anchorLaidOut(_ view: ProfileSidebarAnchor.Anchor) {
        scheduleArtwork()
        guard view === anchor, view.bounds.width > 0, let waitingForProfile,
              view.controller?.profile?.id == waitingForProfile else { return }
        // The sibling collection view lays out in the same AppKit pass.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.anchor === view,
                  view.list?.collection?.window === view.window,
                  view.list?.collection?.sidebar?.controller === view.controller,
                  self.waitingForProfile == waitingForProfile,
                  view.controller?.profile?.id == waitingForProfile else { return }
            self.waitingForProfile = nil
            if self.settled { self.clear() }
        }
    }

    func select(_ target: BrowserProfile, profiles: BrowserProfiles, source: BrowserController, direction: Int?) throws {
        guard !selectionPending, target.id != profiles.active.id else { return }
        let available = profiles.available.map(\.id)
        let forward = (available.firstIndex(of: target.id) ?? 0) > (available.firstIndex(of: profiles.active.id) ?? 0)
        let step = direction ?? (forward ? 1 : -1)
        if host?.window == nil {
            // Model-only callers have no render transaction to wait for.
            try profiles.select(target.id, deferSelectionSave: true)
            return
        }
        if let reason = profiles.switchBlocker { throw BrowserProfileOperationError.unavailable(reason) }
        if let anchor, anchor.controller === source, !source.sidebar.rail && !source.sidebar.peeking,
           let effect = prepare(profiles: profiles, anchor: anchor) {
            effect.setImage(cachedImage(target, anchor: anchor), step: step)
        } else if overlay != nil {
            settleToken = UUID()
            clear()
        }
        requestOutgoingSnapshot(source)
        commit(target, step: step, profiles: profiles)
    }

    private func requestOutgoingSnapshot(_ controller: BrowserController) {
        DispatchQueue.main.async { [weak controller] in
            guard let controller, controller.session.isProfileActive else { return }
            controller.session.selectedTab?.captureProfileSwitchSnapshot()
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
            if selectionPending { return "selection-pending" }
            if !event.hasPreciseScrollingDeltas { return "non-precise" }
            if !profiles.profileSwipePreference.enabled(system: systemEnabled) { return "preference" }
            if source !== profiles.controller || source.profile == nil ||
                (gestureNeighbors.previous == nil && gestureNeighbors.next == nil) { return "profile" }
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
        if phase == .began {
            gestureNeighbors = profiles.swipeNeighbors(from: source)
            // If the prior horizontal gesture lost its terminal event, bring
            // its artwork home even when this new gesture locks vertically.
            if swipe.axis == .horizontal, overlay?.isSettling == false { settle(step: 0) }
            gestureArtworkCompatible = anchor.map { ArtworkGeometry($0) == artworkGeometry } ?? false
            gestureWidth = anchor?.bounds.width ?? 0
            gestureMirror = anchor?.environment.layoutDirection == .rightToLeft ? -1 : 1
        }
        let reason = blocker()
        let (previous, next) = gestureNeighbors
        let axisBefore = swipe.axis
        let result = swipe.update(phase, dx: event.scrollingDeltaX * gestureMirror, dy: event.scrollingDeltaY,
                                  at: event.timestamp, eligible: reason == nil, width: gestureWidth,
                                  previous: previous != nil, next: next != nil,
                                  presentationOffset: overlay?.offset(relativeTo: profiles.active.id) ?? 0)
        if Self.diagnosticsEnabled {
            Self.diagnostics.notice("source=\(input.rawValue, privacy: .public) phase=\(event.phase.rawValue) routed=\(String(describing: phase), privacy: .public) momentumPhase=\(event.momentumPhase.rawValue) dx=\(Double(event.scrollingDeltaX)) dy=\(Double(event.scrollingDeltaY)) precise=\(event.hasPreciseScrollingDeltas) system=\(systemEnabled) eligibility=\(reason ?? "eligible", privacy: .public) axis=\(String(describing: axisBefore), privacy: .public)->\(String(describing: self.swipe.axis), privacy: .public) settling=\(self.overlay?.isSettling ?? false) result=\(String(describing: result), privacy: .public)")
        }
        switch result {
        case .pass:
            if phase == .ended || phase == .cancelled { scheduleArtwork() }
            return false
        case .swallow: return true
        case .track(let offset):
            let drag = axisBefore == .horizontal ? nil : Self.signposter.beginInterval("DragStart")
            defer { if let drag { Self.signposter.endInterval("DragStart", drag) } }
            if axisBefore != .horizontal { requestOutgoingSnapshot(source) }
            if let anchor, let effect = prepare(profiles: profiles, anchor: anchor) {
                let step = offset < 0 ? 1 : -1
                if gestureArtworkCompatible, !effect.hasImage(step: step), let target = step > 0 ? next : previous {
                    effect.setImage(cachedNeighborImage(target), step: step)
                }
                effect.place(offset: offset)
            }
            return true
        case .settle(let step):
            if let step, let target = step > 0 ? next : previous {
                if let overlay, gestureArtworkCompatible, !overlay.hasImage(step: step) {
                    overlay.setImage(cachedNeighborImage(target), step: step)
                }
                commit(target, step: step, profiles: profiles)
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
                endMount()
                overlay.interrupt(active: profiles.active.id)
            }
            return overlay
        }
        if overlay != nil { clear() }
        guard let host, host.window === anchor.window, anchor.bounds.width > 0, anchor.bounds.height > 0 else { return nil }
        let geometry = ArtworkGeometry(anchor)
        let profile = profiles.active.id
        let query = anchor.controller?.tabSearch ?? ""
        let cached = artworkGeometry == geometry && artworkCache[profile]?.query == query ? artworkCache[profile]?.image : nil
        var native = nativeList.flatMap { image in
            image.profile == profile && image.query == query && image.geometry == geometry &&
                image.viewport == anchor.list?.collection?.enclosingScrollView?.contentView.bounds ? image : nil
        }
        // A gesture can arrive before the first idle render (for example,
        // immediately after the window mounts). Preserve the live rows then.
        if cached == nil, native == nil { native = captureNativeList(profiles: profiles, anchor: anchor, geometry: geometry) }
        guard cached != nil || native != nil else { return nil }
        let frame = anchor.convert(anchor.bounds, to: host)
        let effect = ProfileSidebarOverlay(frame: frame, rtl: anchor.environment.layoutDirection == .rightToLeft,
                                           reduceMotion: anchor.environment.browserReduceMotion)
        effect.baseProfile = profile
        effect.setImage(cached, step: 0)
        if let native { effect.setListImage(native.image, frame: native.frame) }
        host.addSubview(effect)
        overlay = effect
        isCovering = true
        return effect
    }

    private func cachedImage(_ profile: BrowserProfile, anchor: ProfileSidebarAnchor.Anchor) -> CGImage? {
        guard artworkGeometry == ArtworkGeometry(anchor) else { return nil }
        return cachedNeighborImage(profile)
    }

    private func cachedNeighborImage(_ profile: BrowserProfile) -> CGImage? {
        guard let cached = artworkCache[profile.id], cached.profile == profile, cached.query.isEmpty else { return nil }
        return cached.image
    }

    private func scheduleArtwork() {
        guard let anchor, !anchor.bounds.isEmpty, anchor.window != nil,
              anchor.controller?.sidebar.dragging != true else { return }
        let geometry = ArtworkGeometry(anchor)
        if artworkGeometry != geometry { artworkNeedsRefresh = true }
        guard artworkNeedsRefresh, artworkTask == nil, overlay == nil,
              !selectionPending, swipe.axis != .undecided else { return }
        artworkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            self.artworkTask = nil
            guard !Task.isCancelled, self.overlay == nil, !self.selectionPending, self.swipe.axis != .undecided,
                  let anchor = self.anchor, let profiles = self.host?.profiles,
                  anchor.window != nil, !anchor.bounds.isEmpty else { return }
            guard !profiles.controller.sidebar.dragging else { return }
            guard ProcessInfo.processInfo.systemUptime - self.lastViewportChange >= 0.06 else {
                self.scheduleArtwork()
                return
            }
            self.warmArtwork(profiles: profiles, anchor: anchor)
        }
    }

    private func warmArtwork(profiles: BrowserProfiles, anchor: ProfileSidebarAnchor.Anchor) {
        let geometry = ArtworkGeometry(anchor)
        let previous = artworkGeometry == geometry ? artworkCache : [:]
        artworkNeedsRefresh = false
        artworkGeometry = geometry
        artworkCache = withObservationTracking {
            let active = profiles.active
            let neighbors = profiles.swipeNeighbors(from: profiles.controller)
            let visibleProfiles = [active] + [neighbors.previous, neighbors.next].compactMap { $0 }
            return Dictionary(uniqueKeysWithValues: visibleProfiles.map { profile in
                let current = profile.id == active.id
                let controller = profiles.loadedController(profile.id)
                let preview = profiles.preview(for: profile)
                let appearance = controller?.appearance ?? .system
                let color = controller?.sidebarColor ?? .graphite
                let query = current ? controller?.tabSearch ?? "" : ""
                if let cached = previous[profile.id], cached.profile == profile,
                   cached.query == query, cached.appearance == appearance, cached.color == color,
                   cached.preview.matches(preview) {
                    return (profile.id, cached)
                }
                var environment = anchor.environment
                if !current {
                    environment.browserTheme = appearance.theme.respecting(geometry.contrast)
                    environment.colorScheme = appearance.colorScheme ?? anchor.window?.effectiveAppearance
                        .bestMatch(from: [.aqua, .darkAqua]).map { $0 == .darkAqua ? .dark : .light } ?? geometry.scheme
                }
                environment.sidebarChromaticStyle = SidebarChromaticStyle(color: color, profile: profile.color,
                    level: geometry.glassLevel, environment: environment)
                let artwork = ProfileSidebarPreviewArtwork(profile: profile, preview: preview,
                    size: geometry.size, query: query, profileTrailingInset: geometry.inset)
                let renderer = ImageRenderer(content: artwork.environment(\.self, environment))
                renderer.scale = geometry.scale
                return (profile.id, CachedArtwork(profile: profile, preview: preview, query: query,
                    appearance: appearance, color: color, image: renderer.cgImage))
            })
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.nativeList = nil
                self.artworkNeedsRefresh = true
                self.scheduleArtwork()
            }
        }

        // The native list can include scrolling and focus states absent from the
        // model preview. Capture it at rest, outside the input event.
        nativeList = captureNativeList(profiles: profiles, anchor: anchor, geometry: geometry)
    }

    private func captureNativeList(profiles: BrowserProfiles, anchor: ProfileSidebarAnchor.Anchor,
                                   geometry: ArtworkGeometry) -> NativeListArtwork? {
        guard let list = anchor.list?.collection, list.sidebar?.controller === profiles.controller,
              let scroll = list.enclosingScrollView, !scroll.bounds.isEmpty,
              let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else { return nil }
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        let frame = scroll.convert(scroll.bounds, to: anchor)
            .offsetBy(dx: -anchor.bounds.minX, dy: -anchor.bounds.minY)
        return NativeListArtwork(profile: profiles.active.id, query: profiles.controller.tabSearch,
            geometry: geometry, viewport: scroll.contentView.bounds, frame: frame, image: image)
    }

    private func commit(_ target: BrowserProfile, step: Int, profiles: BrowserProfiles) {
        let releaseStart = ProcessInfo.processInfo.systemUptime
        let release = Self.signposter.beginInterval("Commit")
        let tracing = Self.diagnosticsEnabled
        if tracing { Self.probeSettleTurns() }
        endMount()
        if overlay != nil { mountInterval = Self.signposter.beginInterval("Mount") }
        let source = profiles.controller
        overlay?.destinationProfile = target.id
        waitingForProfile = overlay == nil ? nil : target.id
        selectionPending = true
        settle(step: step)

        Self.atTurnEnd { [weak self, weak profiles] in
            Self.signposter.endInterval("Commit", release)
            if tracing {
                let elapsed = (ProcessInfo.processInfo.systemUptime - releaseStart) * 1_000
                Self.diagnostics.notice("Commit turn ms=\(elapsed)")
            }
            // The late observer gives Core Animation the rest of this turn
            // to submit the spring. Selection runs in the next dispatch turn.
            DispatchQueue.main.async {
                guard let self, let profiles else { return }
                self.selectionPending = false
                self.springCommitted?()
                guard profiles.controller === source else {
                    self.clear()
                    return
                }
                let start = ProcessInfo.processInfo.systemUptime
                let select = Self.signposter.beginInterval("Select")
                do {
                    self.transitionTarget = target.id
                    try profiles.select(target.id, deferSelectionSave: true)
                    self.transitionTime = ProcessInfo.processInfo.systemUptime
                    self.rebindSidebar(from: source, to: profiles.controller)
                } catch {
                    self.transitionTarget = nil
                    self.waitingForProfile = nil
                    self.overlay?.destinationProfile = nil
                    self.settle(step: 0)
                    profiles.error = error.localizedDescription
                }
                Self.signposter.endInterval("Select", select)
                if tracing || self.selectTurnMeasured != nil {
                    Self.atTurnEnd { [weak self] in
                        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                        self?.selectTurnMeasured?(ms)
                        if tracing { Self.diagnostics.notice("Selection turn ms=\(ms)") }
                    }
                }
            }
        }
    }

    private func rebindSidebar(from source: BrowserController, to target: BrowserController) {
        nativeList = nil
        if let width = host?.window?.contentView?.bounds.width { target.sidebar.resize(availableWidth: width) }
        if target.sidebar.rail || target.sidebar.peeking {
            waitingForProfile = nil
            if settled { finishSettle() }
        } else {
            // The next scroll phase can arrive before SwiftUI updates the
            // representables. Retain their geometry for expanded-to-expanded.
            if anchor?.controller === source { anchor?.controller = target; anchor?.needsLayout = true }
            for region in [hitRegion, editingRegion, titlebarControl] where region?.controller === source {
                region?.controller = target
            }
        }
        artworkNeedsRefresh = true
        scheduleArtwork()
    }

    static func atTurnEnd(_ work: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil,
            CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
            false, CFIndex.max) { _, _ in
                MainActor.assumeIsolated { work() }
            }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func probeSettleTurns() {
        let start = ProcessInfo.processInfo.systemUptime
        var turn = start
        var longest: Double = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue |
            CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue,
            true, CFIndex.max) { _, activity in
                MainActor.assumeIsolated {
                    let now = ProcessInfo.processInfo.systemUptime
                    if activity == .afterWaiting || activity == .entry {
                        turn = now
                    } else {
                        longest = max(longest, now - turn)
                    }
                }
            }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            CFRunLoopObserverInvalidate(observer)
            Self.diagnostics.notice("Longest settle turn ms=\(longest * 1_000)")
        }
    }

    private func settle(step: Int) {
        guard let overlay else { return }
        let token = UUID()
        settleToken = token
        settled = false
        overlay.animate(step: step) { [weak self] in
            guard let self, self.settleToken == token else { return }
            self.settled = true
            if self.waitingForProfile == nil { self.finishSettle() }
        }
        // A closed window, fullscreen transition, or rail destination may
        // never lay out an expanded sidebar.
        if waitingForProfile != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if let self, self.settleToken == token, self.overlay != nil {
                    self.fallbackClearCount += 1
                    Self.signposter.emitEvent("FallbackClear")
                    if Self.diagnosticsEnabled { Self.diagnostics.notice("FallbackClear") }
                    self.clear()
                }
            }
        }
    }

    private func finishSettle() {
        if let sidebar = host?.profiles?.controller.sidebar, sidebar.rail || sidebar.peeking, let overlay {
            let token = settleToken
            overlay.fadeOut { [weak self] in
                if self?.settleToken == token { self?.clear() }
            }
        } else { clear() }
    }

    private func endMount() {
        if let mountInterval {
            Self.signposter.endInterval("Mount", mountInterval)
            self.mountInterval = nil
        }
    }

    private func clear() {
        endMount()
        overlay?.removeFromSuperview()
        overlay = nil
        waitingForProfile = nil
        isCovering = false
        scheduleArtwork()
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
        guard let image else {
            images.removeValue(forKey: step)?.removeFromSuperlayer()
            return
        }
        let piece = images[step] ?? CALayer()
        piece.sublayers = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        piece.contents = image
        piece.frame = bounds.offsetBy(dx: reduceMotion ? 0 : CGFloat(step) * bounds.width * mirror, dy: 0)
        piece.opacity = step == 0 ? 1 : 0
        if images[step] == nil { strip.addSublayer(piece) }
        images[step] = piece
        CATransaction.commit()
    }

    func setListImage(_ image: CGImage?, frame: CGRect) {
        guard let image else { return }
        if images[0] == nil {
            let piece = CALayer()
            piece.frame = bounds
            strip.addSublayer(piece)
            images[0] = piece
        }
        guard let piece = images[0] else { return }
        if let contents = piece.contents {
            // Keep the cached header, search field and footer. Punch out the
            // synthetic rows so only the single native list capture shows.
            let chrome = CALayer()
            chrome.frame = piece.bounds
            chrome.contents = contents
            let mask = CAShapeLayer()
            let cutout = CGMutablePath()
            cutout.addRect(piece.bounds)
            cutout.addRect(frame.intersection(piece.bounds))
            mask.path = cutout
            mask.fillRule = .evenOdd
            chrome.mask = mask
            piece.contents = nil
            piece.addSublayer(chrome)
        }
        let list = CALayer()
        list.frame = frame
        list.contents = image
        piece.addSublayer(list)
    }

    func fadeOut(completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = OrivMacV3.Motion.reducedDuration
            animator().alphaValue = 0
        } completionHandler: {
            DispatchQueue.main.async { completion() }
        }
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
                fade.duration = OrivMacV3.Motion.reducedDuration
                fade.fromValue = old[index]
                fade.toValue = piece.opacity
                piece.add(fade, forKey: "settle")
            }
        } else {
            let start = strip.presentation()?.transform ?? strip.transform
            apply(end)
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = OrivMacV3.Motion.profileSettleMass
            spring.stiffness = OrivMacV3.Motion.profileSettleStiffness
            spring.damping = OrivMacV3.Motion.profileSettleDamping
            spring.duration = OrivMacV3.Motion.profileSettleDuration
            spring.fromValue = NSValue(caTransform3D: start)
            spring.toValue = NSValue(caTransform3D: strip.transform)
            strip.add(spring, forKey: "settle")
        }
        CATransaction.commit()
    }
}
