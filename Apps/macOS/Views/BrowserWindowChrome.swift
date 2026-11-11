import AppKit
import SwiftUI

/// Shared geometry for the content header and the real AppKit window controls.
/// The sidebar stays on the physical left, including in right-to-left locales.
enum MacBrowserLayout {
    static let sidebarWidth: CGFloat = 236
    static let headerHeight: CGFloat = 44
    static let lightsWidth: CGFloat = 54
    static let lightsInset: CGFloat = 12
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
    var stateChanged: (Bool, Bool) -> Void

    func makeNSView(context: Context) -> WindowChromeView { WindowChromeView() }
    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.stateChanged = stateChanged
        view.windowContext = windowContext
        view.configure()
    }
    static func dismantleNSView(_ view: WindowChromeView, coordinator: ()) { view.detach() }

    final class WindowChromeView: NSView {
        var stateChanged: ((Bool, Bool) -> Void)?
        var windowContext: MacBrowserWindowContext?
        private var observers: [NSObjectProtocol] = []
        private var lastState: [Bool] = []
        private var configuring = false
        #if DEBUG
        var simulatesFullscreenLayout = false
        #endif
        private weak var observedWindow: NSWindow?
        private var accessory: NSTitlebarAccessoryViewController?

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
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.configure() }
                })
            }
            configure()
        }
        override func layout() { super.layout(); configure() }
        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if let accessory, let window = observedWindow,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            observedWindow?.setAccessibilityChildrenInNavigationOrder(nil)
            if windowContext?.window === observedWindow { windowContext?.window = nil }
            accessory = nil
            observedWindow = nil
            lastState = []
        }
        func configure() {
            guard let window, !configuring else { return }
            windowContext?.window = window
            configuring = true
            defer { configuring = false }
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = false
            // There is no NSToolbar to migrate into a separate fullscreen host.
            // The page-colour band and its glass controls stay in the content view
            // through menu reveal and auto-hide, so they share one backing surface.
            if window.toolbar != nil { window.toolbar = nil }
            #if DEBUG
            let fullscreen = window.styleMask.contains(.fullScreen) || simulatesFullscreenLayout
            #else
            let fullscreen = window.styleMask.contains(.fullScreen)
            #endif
            if accessory == nil {
                let controller = NSTitlebarAccessoryViewController()
                controller.layoutAttribute = .bottom
                controller.view = BrowserGeometryMarker.Marker(frame: NSRect(x: 0, y: 0, width: 1, height: 16))
                controller.fullScreenMinHeight = 0
                window.addTitlebarAccessoryViewController(controller)
                accessory = controller
            }
            if !fullscreen {
                for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                    guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
                    let target = parent.convert(NSPoint(x: MacBrowserLayout.lightsInset + CGFloat(index) * MacBrowserLayout.lightsSpacing,
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
    func updateNSView(_ view: Marker, context: Context) {}
    final class Marker: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
}
