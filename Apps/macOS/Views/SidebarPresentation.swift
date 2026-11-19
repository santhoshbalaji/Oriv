import AppKit
import Observation
import SwiftUI

struct SidebarTransition: Equatable { let width: CGFloat; let peeking: Bool }

/// Window-local presentation. Only explicit preference/setting setters write defaults.
@MainActor @Observable final class SidebarPresentation {
    var preferredRail = false
    private(set) var automaticRail = false
    private(set) var narrowOverlay = false
    private(set) var peeking = false
    private(set) var webpageFullscreen = false
    var hoverEnabled = false { didSet { if !hoverEnabled { dismissPeek() } } }
    var voiceOver = false { didSet { if voiceOver { dismissPeek() } } }
    var pointerInside = false
    var panelInside = false { didSet { releaseIfNeeded() } }
    var focusInside = false { didSet { releaseIfNeeded() } }
    var menuOpen = false { didSet { releaseIfNeeded() } }
    var searchOpen = false { didSet { releaseIfNeeded() } }
    var dragging = false { didSet { releaseIfNeeded() } }
    @ObservationIgnored private var dwell: Task<Void, Never>?
    @ObservationIgnored private var leave: Task<Void, Never>?
    var rail: Bool { (preferredRail || automaticRail) && !narrowOverlay && !peeking }
    var reservesRail: Bool { preferredRail || automaticRail }
    var overlay: Bool { peeking || narrowOverlay }
    var reservation: CGFloat { webpageFullscreen ? 0 : (reservesRail ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth) }
    var width: CGFloat { rail ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth }
    var transition: SidebarTransition { SidebarTransition(width: width, peeking: peeking) }
    var held: Bool { pointerInside || panelInside || focusInside || menuOpen || searchOpen || dragging }

    func resize(availableWidth: CGFloat) {
        let page = availableWidth - MacBrowserLayout.sidebarWidth
        if page < 500 { automaticRail = true }
        else if page >= 540 { automaticRail = false; narrowOverlay = false }
    }
    func setPreference(_ rail: Bool) {
        preferredRail = rail
        narrowOverlay = !rail && automaticRail
        dismissPeek()
    }
    /// Returns the deliberate saved preference, including committing a peek.
    func toggle() -> Bool {
        let next = peeking ? false : !rail
        setPreference(next)
        return next
    }
    func pointer(_ inside: Bool, moved: Bool = false, drag: Bool = false) {
        pointerInside = inside
        dwell?.cancel(); dwell = nil
        if inside {
            leave?.cancel(); leave = nil
            guard rail, !webpageFullscreen, drag || (hoverEnabled && !voiceOver) else { return }
            dwell = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, !Task.isCancelled, self.pointerInside, self.rail, !self.webpageFullscreen,
                      drag || (self.hoverEnabled && !self.voiceOver) else { return }
                self.peeking = true; self.dwell = nil
            }
        } else { releaseIfNeeded() }
    }
    private func releaseIfNeeded() {
        leave?.cancel(); leave = nil
        // An explicit narrow expansion stays open until another command,
        // Escape or an outside click. Pointer exit applies only to hover peek.
        guard peeking, !held else { return }
        leave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled, self.peeking, !self.held else { return }
            self.dismissOverlay()
        }
    }
    func dismissPeek() {
        dwell?.cancel(); dwell = nil; leave?.cancel(); leave = nil; peeking = false
    }
    func dismissOverlay() { dismissPeek(); narrowOverlay = false }
    func fullscreen(_ value: Bool) {
        webpageFullscreen = value
        if value { dismissPeek() }
    }
    func cancel() { dismissPeek() }
}

@MainActor @Observable final class SidebarTooltip {
    private(set) var tabID: UUID?
    private(set) var text = ""
    private(set) var pendingID: UUID?
    @ObservationIgnored private var exitTask: Task<Void, Never>?
    @ObservationIgnored private var dwell: Task<Void, Never>?
    func hover(id: UUID, text: String) {
        dismiss(); pendingID = id
        dwell = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.text = text; self?.tabID = id; self?.pendingID = nil; self?.dwell = nil
        }
    }
    /// A short crossing allowance lets long tooltips receive their own scroll
    /// events across the eight-point gap without ever becoming a key panel.
    func exit() {
        dwell?.cancel(); dwell = nil; pendingID = nil
        exitTask?.cancel()
        guard tabID != nil else { return }
        exitTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
    func hold(_ inside: Bool) {
        exitTask?.cancel(); exitTask = nil
        if !inside { dismiss() }
    }
    func dismiss() {
        dwell?.cancel(); dwell = nil; exitTask?.cancel(); exitTask = nil
        tabID = nil; pendingID = nil; text = ""
    }
}

struct SidebarTooltipBounds: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Supplies window-space hit regions for the event monitor without intercepting input.
struct SidebarHitTarget: NSViewRepresentable {
    enum Kind: Equatable { case searchPanel, tab(UUID) }
    let kind: Kind

    func makeNSView(context: Context) -> TargetView {
        let view = TargetView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TargetView, context: Context) {
        view.kind = kind
        #if DEBUG
        switch kind {
        case .searchPanel: view.identifier = NSUserInterfaceItemIdentifier("sidebarSearchPanel")
        case .tab(let id): view.identifier = NSUserInterfaceItemIdentifier("sidebarItem-\(id)")
        }
        #endif
    }

    final class TargetView: NSView {
        var kind: Kind?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Window-scoped events; no new panel, focus request, polling, or app activation.
struct SidebarWindowEvents: NSViewRepresentable {
    let controller: BrowserController
    let input: ChromeFocusState
    var dismiss: () -> Void
    func makeNSView(context: Context) -> EventView { EventView() }
    func updateNSView(_ view: EventView, context: Context) { view.controller = controller; view.input = input; view.dismiss = dismiss; if let window = view.window { controller.sidebarWindow = window } }
    static func dismantleNSView(_ view: EventView, coordinator: ()) { view.detach() }
    final class EventView: NSView {
        weak var controller: BrowserController?
        var input: ChromeFocusState?
        var dismiss: (() -> Void)?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); detach()
            guard window != nil else { return }
            controller?.sidebarWindow = window
            controller?.sidebar.voiceOver = NSWorkspace.shared.isVoiceOverEnabled
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .otherMouseUp]) { [weak self] event in
                guard let self, event.window === self.window, let controller = self.controller else { return event }
                self.input?.receive(event)
                let tooltipVisible = controller.sidebarTooltip.tabID != nil
                controller.sidebarTooltip.dismiss()
                if event.type == .keyDown, event.keyCode == 53, tooltipVisible,
                   !controller.sidebar.overlay && !controller.tabSearchPanel { return nil }
                if event.type == .keyDown, event.keyCode == 53,
                   controller.sidebar.overlay || controller.tabSearchPanel {
                    self.dismiss?(); return nil
                }
                if event.type == .leftMouseDown {
                    if controller.tabSearchPanel, let content = self.window?.contentView {
                        let insidePanel = self.target(at: event.locationInWindow, in: content) { $0 == .searchPanel } != nil
                        if !insidePanel { self.dismiss?() }
                    } else if event.locationInWindow.x > controller.sidebar.width, controller.sidebar.overlay { self.dismiss?() }
                }
                if event.type == .otherMouseUp, event.buttonNumber == 2,
                   self.requestCloseTab(at: event.locationInWindow) { return nil }
                return event
            }
            for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.controller?.sidebar.menuOpen = open }
                })
            }
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller?.sidebar.voiceOver = NSWorkspace.shared.isVoiceOverEnabled }
            })
        }
        func requestCloseTab(at point: NSPoint) -> Bool {
            guard let controller, let content = window?.contentView else { return false }
            let hit = target(at: point, in: content) {
                if case .tab = $0 { return true }
                return false
            }
            guard case .tab(let id) = hit,
                  let tab = controller.session.tabs.first(where: { $0.id == id }), !tab.isPinned else { return false }
            controller.requestCloseTab(id)
            return true
        }

        private func target(at point: NSPoint, in view: NSView,
                            matching: (SidebarHitTarget.Kind) -> Bool) -> SidebarHitTarget.Kind? {
            if let kind = (view as? SidebarHitTarget.TargetView)?.kind, matching(kind),
               view.convert(view.bounds, to: nil).contains(point) { return kind }
            for child in view.subviews {
                if let hit = target(at: point, in: child, matching: matching) { return hit }
            }
            return nil
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        }
    }
}

/// Labels use a short opacity transition independent of the clipped chrome width.
struct SidebarLabelFade: ViewModifier {
    @Environment(\.browserReduceMotion) private var reduceMotion
    @State private var visible = false
    func body(content: Content) -> some View {
        content.opacity(visible || reduceMotion ? 1 : 0)
            .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { visible = true } }
    }
}

struct SidebarTooltipBubble: View {
    let text: String
    let width: CGFloat
    let maximumHeight: CGFloat
    @State private var textHeight: CGFloat = 40
    var body: some View {
        ScrollView {
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
        }
        .frame(width: width, height: min(textHeight, maximumHeight))
        .background(Theme.sidebar.surface, in: .rect(cornerRadius: 8)).foregroundStyle(Theme.sidebar.text)
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Theme.sidebar.separator) }
        .accessibilityHidden(true)
    }
}
