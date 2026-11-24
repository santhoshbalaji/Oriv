import AppKit
import SwiftUI

/// Shared geometry for the content header and the real AppKit window controls.
enum MacBrowserLayout {
    static let sidebarWidth = OrivLayout.sidebarWidth
    static let sidebarWidthRange: ClosedRange<CGFloat> = 220...360
    static let railWidth = OrivLayout.railWidth
    static let headerHeight = OrivLayout.toolbarHeight
    static let sidebarResizeGripWidth = OrivSpacing.small
    static let sidebarInset = OrivSpacing.small
    static let sidebarRowInset = OrivSpacing.small
    static let sidebarTitlebarHeight = headerHeight - OrivSpacing.xs
    static let sidebarToggleSize: CGFloat = 30
    static let sidebarToggleTopInset = (headerHeight - sidebarToggleSize) / 2
    static let fullscreenProfileTrailingInset = sidebarToggleSize + sidebarInset
    static let sidebarFooterGap = OrivSpacing.xs
    static let railItemWidth = OrivTarget.macRail.width
    static let railItemHeight = OrivTarget.macRail.height
    static let railInset = (railWidth - railItemWidth) / 2
    static let lightsWidth: CGFloat = 54
    static let railLightsInset = (railWidth - lightsWidth) / 2
    static let lightsInset = OrivSpacing.medium
    static let lightsSpacing: CGFloat = 20
}

/// Window blending stays in one view across the titlebar and the body.
struct WindowBackdropMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var opacity: CGFloat = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.alphaValue = opacity
    }
}

/// Weak window ownership lets the toggle inspect focus before SwiftUI removes
/// sidebar controls. A post-layout bridge runs too late to recover that focus.
@MainActor final class MacBrowserWindowContext {
    weak var window: NSWindow?
    var layoutDirection: LayoutDirection = .leftToRight
    var sidebarWidth = MacBrowserLayout.sidebarWidth
    var sidebarContainsFocus: Bool {
        guard let window, let content = window.contentView else { return false }
        var candidates: [NSRect] = []
        if let focused = content.accessibilityFocusedUIElement as? NSAccessibilityElementProtocol {
            candidates.append(window.convertFromScreen(focused.accessibilityFrame()))
        }
        if let responder = window.firstResponder as? NSView {
            candidates.append(responder.convert(responder.bounds, to: nil))
            if let editor = responder as? NSTextView, let field = editor.delegate as? NSView {
                candidates.append(field.convert(field.bounds, to: nil))
            }
        }
        let width = content.bounds.width
        return candidates.contains { rect in
            let leading = layoutDirection == .rightToLeft ? width - rect.maxX : rect.minX
            return rect.width > 0 && leading >= 0 && leading + rect.width <= sidebarWidth + 1
        }
    }
}

/// Configures only its containing window. Standard buttons remain in AppKit's
/// hierarchy, preserving native actions, inactive appearance and tiling popovers.
struct BrowserWindowChrome: NSViewRepresentable {
    let windowContext: MacBrowserWindowContext
    var compact = false
    var sidebarWidth = MacBrowserLayout.sidebarWidth
    var backdrop: Color? = nil
    var usesWindowMaterial = false
    var initialContentFocus: NSView? = nil
    var shouldApplyProfileSwitchFocus: (() -> Bool)? = nil
    var profileEpoch: UUID? = nil
    var externalPresentationRequest: Int? = nil
    var stateChanged: (Bool, Bool) -> Void
    var contentWidthChanged: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> WindowChromeView { WindowChromeView() }
    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.initialContentFocus = initialContentFocus
        view.shouldApplyProfileSwitchFocus = shouldApplyProfileSwitchFocus
        view.compact = compact
        view.backdrop = backdrop.map { NSColor($0) }
        view.usesWindowMaterial = usesWindowMaterial
        view.stateChanged = stateChanged
        view.contentWidthChanged = contentWidthChanged
        windowContext.layoutDirection = context.environment.layoutDirection
        windowContext.sidebarWidth = sidebarWidth
        view.windowContext = windowContext
        view.profileEpoch = profileEpoch
        view.externalPresentationRequest = externalPresentationRequest
        view.configure()
    }
    static func dismantleNSView(_ view: WindowChromeView, coordinator: ()) { view.detach() }

    final class WindowChromeView: NSView {
        weak var initialContentFocus: NSView?
        var shouldApplyProfileSwitchFocus: (() -> Bool)?
        private var didSetInitialFocus = false
        var profileEpoch: UUID? {
            didSet {
                guard oldValue != profileEpoch else { return }
                didSetInitialFocus = false
                lastContentWidth = nil
            }
        }
        var compact = false
        var backdrop: NSColor?
        var usesWindowMaterial = false
        var stateChanged: ((Bool, Bool) -> Void)?
        var contentWidthChanged: ((CGFloat) -> Void)?
        private var widthTask: Task<Void, Never>?
        private var lastContentWidth: CGFloat?
        var windowContext: MacBrowserWindowContext?
        var externalPresentationRequest: Int?
        private let externalPresenter = ExternalPrivateWindowPresenter()
        private var observers: [NSObjectProtocol] = []
        private var lastState: [Bool] = []
        private var configuring = false
        private var enteringFullscreen = false
        #if DEBUG
        var simulatesFullscreenLayout = false
        #endif
        private weak var observedWindow: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            observedWindow = window
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didChangeBackingPropertiesNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification, NSWindow.willEnterFullScreenNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let entering = note.name == NSWindow.willEnterFullScreenNotification
                    let finished = note.name == NSWindow.didEnterFullScreenNotification || note.name == NSWindow.didExitFullScreenNotification
                    MainActor.assumeIsolated {
                        if entering { self?.enteringFullscreen = true }
                        if finished { self?.enteringFullscreen = false }
                        self?.configure()
                    }
                })
            }
            // Never mutate window properties inside SwiftUI's own subview insertion.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.configure()
            }
        }
        override func layout() { super.layout(); configure() }
        func detach() {
            widthTask?.cancel(); widthTask = nil; lastContentWidth = nil
            externalPresenter.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            observedWindow?.setAccessibilityChildrenInNavigationOrder(nil)
            if windowContext?.window === observedWindow { windowContext?.window = nil }
            observedWindow = nil
            lastState = []
            enteringFullscreen = false
        }
        func configure() {
            guard let window, !configuring else { return }
            windowContext?.window = window
            let target = initialContentFocus
            if !didSetInitialFocus, target?.window === window || (target == nil && shouldApplyProfileSwitchFocus != nil) {
                didSetInitialFocus = true
                if shouldApplyProfileSwitchFocus == nil { window.initialFirstResponder = target }
                let epoch = profileEpoch
                DispatchQueue.main.async { [weak self, weak window, weak target] in
                    guard let self, let window, self.window === window, self.profileEpoch == epoch,
                          self.initialContentFocus === target, target == nil || target?.window === window else { return }
                    if let shouldApplyProfileSwitchFocus = self.shouldApplyProfileSwitchFocus {
                        // A profile switch replaces the previous responder, unless
                        // a typing command has already arrived for the new profile.
                        guard shouldApplyProfileSwitchFocus() else { return }
                        window.initialFirstResponder = target
                    } else {
                        guard target != nil, !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
                              !(window.firstResponder is SidebarTabCollection) else { return }
                    }
                    window.makeFirstResponder(target)
                }
            }
            if let externalPresentationRequest { externalPresenter.request(externalPresentationRequest, in: window) }
            configuring = true
            defer { configuring = false }
            // Each setter posts KVO that NSHostingView handles synchronously. Writing
            // unchanged values while SwiftUI is adding this view crashed the
            // AttributeGraph during a profile rebuild, so only write real changes.
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            if window.isMovableByWindowBackground { window.isMovableByWindowBackground = false }
            // There is no NSToolbar to migrate into a separate fullscreen host.
            // The page-colour band and its glass controls stay in the content view
            // through menu reveal and auto-hide, so they share one backing surface.
            if window.toolbar != nil { window.toolbar = nil }
            #if DEBUG
            let fullscreen = window.styleMask.contains(.fullScreen) || enteringFullscreen || simulatesFullscreenLayout
            #else
            let fullscreen = window.styleMask.contains(.fullScreen) || enteringFullscreen
            #endif
            // Fullscreen's native reveal host paints its own titlebar over the
            // fixed content. An opaque titlebar prevents the compact profile and
            // toggle showing through the revealed lights. Never derive content
            // spacing from their visibility: revealing them must not move it.
            if let backdrop {
                let opaque = fullscreen || !usesWindowMaterial
                let backgroundColor: NSColor = opaque ? backdrop : .clear
                if window.isOpaque != opaque { window.isOpaque = opaque }
                if window.backgroundColor != backgroundColor { window.backgroundColor = backgroundColor }
            }
            if window.titlebarAppearsTransparent == fullscreen { window.titlebarAppearsTransparent = !fullscreen }
            if !fullscreen {
                for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                    guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
                    // Only position controls in this window. During fullscreen
                    // AppKit moves them to its auto-revealing titlebar host.
                    guard button.window === window else { continue }
                    let inset = (compact ? MacBrowserLayout.railLightsInset : MacBrowserLayout.lightsInset) + CGFloat(index) * MacBrowserLayout.lightsSpacing
                    let rtl = windowContext?.layoutDirection == .rightToLeft
                    let x = rtl ? window.frame.width - inset - button.frame.width : inset
                    let target = parent.convert(NSPoint(x: x,
                        y: window.frame.height - MacBrowserLayout.headerHeight / 2), from: nil)
                    button.setFrameOrigin(NSPoint(x: target.x, y: target.y - button.frame.height / 2))
                }
            }
            // Native NSWindow's default linear order puts content before its
            // buttons. Keep the same children, but lead with close/minimize/zoom.
            let children = window.accessibilityChildren() ?? []
            let elements = children.compactMap { $0 as? NSAccessibilityElementProtocol }
            let lights = [window.accessibilityCloseButton(), window.accessibilityMinimizeButton(), window.accessibilityZoomButton()]
                .compactMap { $0 as? NSAccessibilityElementProtocol }
            if !fullscreen, elements.count == children.count, lights.count == 3 {
                let rest = elements.filter { child in !lights.contains { ($0 as AnyObject) === (child as AnyObject) } }
                if rest.count + lights.count == elements.count { window.setAccessibilityChildrenInNavigationOrder(lights + rest) }
            } else { window.setAccessibilityChildrenInNavigationOrder(nil) }
            if let width = window.contentView?.bounds.width, width > 0, width != lastContentWidth {
                lastContentWidth = width; widthTask?.cancel()
                // Coalesce initial hosting/layout sizes; only the actual window's
                // settled content width participates in adaptive hysteresis.
                widthTask = Task { @MainActor [weak self, weak window] in
                    await Task.yield()
                    guard !Task.isCancelled, let self, let window, self.window === window,
                          let actualWidth = window.contentView?.bounds.width, actualWidth > 0 else { return }
                    self.contentWidthChanged?(actualWidth)
                    self.widthTask = nil
                }
            }
            let state = [fullscreen, window.isKeyWindow]
            if state != lastState {
                lastState = state
                DispatchQueue.main.async { [weak self] in self?.stateChanged?(state[0], state[1]) }
            }
        }
    }
}

/// Background only: controls above it receive their normal input. Blank header
/// regions drag the window and honor the user's titlebar double-click preference.
struct BrowserDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else { window.performDrag(with: event) }
        }
    }
}

extension View {
    /// Debug-only geometry anchors for native tests and owned captures.
    func browserGeometryMarker(_ name: @autoclosure () -> String,
                               when visible: @autoclosure () -> Bool = true) -> some View {
        #if DEBUG
        let marker = visible() ? name() : nil
        return background { if let marker { BrowserGeometryMarker(name: marker) } }
        #else
        self
        #endif
    }
}

#if DEBUG
/// Non-interactive geometry anchors for native regression tests and owned captures.
struct BrowserGeometryMarker: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> Marker {
        let view = Marker(); view.identifier = NSUserInterfaceItemIdentifier(name); return view
    }
    func updateNSView(_ view: Marker, context: Context) { view.identifier = NSUserInterfaceItemIdentifier(name) }
    final class Marker: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
}
#endif

/// Uses window-space coordinates so changing the divider frame during the
/// gesture cannot feed the new origin back into the drag.
struct SidebarResizeGrip: NSViewRepresentable {
    let width: CGFloat
    let direction: LayoutDirection
    let resize: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> Grip { Grip() }

    func updateNSView(_ view: Grip, context: Context) {
        view.width = width
        view.sign = direction == .rightToLeft ? -1 : 1
        view.resize = resize
    }

    final class Grip: NSView {
        var width = MacBrowserLayout.sidebarWidth
        var sign: CGFloat = 1
        var resize: ((CGFloat, Bool) -> Void)?
        private var start: (x: CGFloat, width: CGFloat)?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                resize?(MacBrowserLayout.sidebarWidth, false)
            } else {
                start = (event.locationInWindow.x, width)
            }
        }

        override func mouseDragged(with event: NSEvent) { updateWidth(event, dragging: true) }
        override func mouseUp(with event: NSEvent) {
            updateWidth(event, dragging: false)
            start = nil
        }

        private func updateWidth(_ event: NSEvent, dragging: Bool) {
            guard let start else { return }
            resize?(start.width + sign * (event.locationInWindow.x - start.x), dragging)
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .slider }
        override func accessibilityLabel() -> String? { "Sidebar width" }
        override func accessibilityValue() -> Any? { Int(width) }
        override func accessibilityPerformIncrement() -> Bool { adjust(OrivSpacing.large) }
        override func accessibilityPerformDecrement() -> Bool { adjust(-OrivSpacing.large) }

        private func adjust(_ offset: CGFloat) -> Bool {
            guard let resize else { return false }
            resize(width + offset, false)
            return true
        }
    }
}
