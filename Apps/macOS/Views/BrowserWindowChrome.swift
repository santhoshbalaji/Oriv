import AppKit
import SwiftUI

/// Shared geometry for the content header and the real AppKit window controls.
/// The sidebar stays on the physical left, including in right-to-left locales.
enum MacBrowserLayout {
    static let sidebarWidth: CGFloat = 296
    static let railWidth: CGFloat = 84
    static let headerHeight: CGFloat = 60
    static let sidebarInset: CGFloat = 8
    static let sidebarRowInset: CGFloat = 8
    static let sidebarTitlebarHeight: CGFloat = 32
    static let sidebarFooterGap: CGFloat = 5
    static let railItemWidth: CGFloat = 42
    static let railItemHeight: CGFloat = 36
    static let railInset = (railWidth - railItemWidth) / 2
    static let lightsWidth: CGFloat = 54
    static let lightsInset: CGFloat = 26
    static let lightsSpacing: CGFloat = 20
}

/// Weak window ownership lets the toggle inspect focus before SwiftUI removes
/// sidebar controls. A post-layout bridge runs too late to recover that focus.
@MainActor final class MacBrowserWindowContext {
    weak var window: NSWindow?
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
        return candidates.contains { $0.width > 0 && $0.minX >= 0 && $0.maxX <= MacBrowserLayout.sidebarWidth + 1 }
    }
}

/// Configures only its containing window. Standard buttons remain in AppKit's
/// hierarchy, preserving native actions, inactive appearance and tiling popovers.
struct BrowserWindowChrome: NSViewRepresentable {
    let windowContext: MacBrowserWindowContext
    var compact = false
    var initialContentFocus: NSView? = nil
    var externalPresentationRequest: Int? = nil
    var stateChanged: (Bool, Bool) -> Void
    var contentWidthChanged: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> WindowChromeView { WindowChromeView() }
    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.initialContentFocus = initialContentFocus
        view.compact = compact
        view.stateChanged = stateChanged
        view.contentWidthChanged = contentWidthChanged
        view.windowContext = windowContext
        view.externalPresentationRequest = externalPresentationRequest
        view.configure()
    }
    static func dismantleNSView(_ view: WindowChromeView, coordinator: ()) { view.detach() }

    final class WindowChromeView: NSView {
        weak var initialContentFocus: NSView?
        private var didSetInitialFocus = false
        var compact = false
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
            configure()
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
            if !didSetInitialFocus, let target = initialContentFocus, target.window === window {
                didSetInitialFocus = true
                window.initialFirstResponder = target
                DispatchQueue.main.async { [weak window, weak target] in
                    guard let window, let target, !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return }
                    window.makeFirstResponder(target)
                }
            }
            if let externalPresentationRequest { externalPresenter.request(externalPresentationRequest, in: window) }
            configuring = true
            defer { configuring = false }
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = false
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
            window.titlebarAppearsTransparent = !fullscreen
            if !fullscreen {
                for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                    guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
                    // Only position controls in this window. During fullscreen
                    // AppKit moves them to its auto-revealing titlebar host.
                    guard button.window === window else { continue }
                    let target = parent.convert(NSPoint(x: (compact ? 15 : MacBrowserLayout.lightsInset) + CGFloat(index) * MacBrowserLayout.lightsSpacing,
                        y: window.frame.height - MacBrowserLayout.sidebarTitlebarHeight / 2), from: nil)
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

/// Non-interactive geometry anchors for native regression tests and owned captures.
struct BrowserGeometryMarker: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> Marker {
        let view = Marker(); view.identifier = NSUserInterfaceItemIdentifier(name); return view
    }
    func updateNSView(_ view: Marker, context: Context) { view.identifier = NSUserInterfaceItemIdentifier(name) }
    final class Marker: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
}
