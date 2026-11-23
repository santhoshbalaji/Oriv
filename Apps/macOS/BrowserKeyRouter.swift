import AppKit
import BrowserEngine
import SwiftUI

/// Window-local routing precedes WebKit and the shared field editor. No global
/// event tap, activation, or system keyboard permission is involved.
struct BrowserKeyRouter: NSViewRepresentable {
    let session: BrowserSession
    var fillPassword: (() -> Void)? = nil
    func makeNSView(context: Context) -> RoutingView { RoutingView() }
    func updateNSView(_ view: RoutingView, context: Context) {
        view.session = session
        view.fillPassword = fillPassword
    }
    static func dismantleNSView(_ view: RoutingView, coordinator: ()) { view.detach() }

    final class RoutingView: NSView {
        weak var session: BrowserSession?
        var fillPassword: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); detach()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.route(event) == true }
                return handled ? nil : event
            }
        }
        func detach() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        func route(_ event: NSEvent) -> Bool {
            guard let window, let session, session.isProfileActive,
                  event.window === window, window.attachedSheet == nil else { return false }
            let flags = event.modifierFlags.intersection([.control, .shift, .command, .option])
            // Handled shortcuts can bypass the sidebar's window monitor.
            if !flags.intersection([.command, .control, .option]).isEmpty {
                (window.firstResponder as? SidebarTabCollection)?.updateFocusInput(for: event)
            }
            if flags == [.command, .shift, .option], event.charactersIgnoringModifiers?.lowercased() == "p",
               let fillPassword {
                if !event.isARepeat { fillPassword() }
                return true
            }
            if event.keyCode == 48 && (flags == .control || flags == [.control, .shift]) {
                session.selectRelativeTab(flags.contains(.shift) ? -1 : 1)
                return true
            }
            if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "r", session.selectedTab?.url != nil {
                session.selectedTab?.reloadFromOrigin(); return true
            }
            return false
        }
    }
}
