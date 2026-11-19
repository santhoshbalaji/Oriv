import AppKit
import BrowserEngine
import SwiftUI

/// Window-local routing precedes WebKit and the shared field editor. No global
/// event tap, activation, or system keyboard permission is involved.
struct BrowserKeyRouter: NSViewRepresentable {
    let session: BrowserSession
    var overviewVisible = false
    var input: ChromeFocusState? = nil
    func makeNSView(context: Context) -> RoutingView { RoutingView() }
    func updateNSView(_ view: RoutingView, context: Context) {
        view.session = session; view.overviewVisible = overviewVisible; view.input = input
    }
    static func dismantleNSView(_ view: RoutingView, coordinator: ()) { view.detach() }

    final class RoutingView: NSView {
        weak var session: BrowserSession?
        var overviewVisible = false
        var input: ChromeFocusState?
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
                  event.window === window || (overviewVisible && event.window?.sheetParent === window),
                  window.attachedSheet == nil || overviewVisible else { return false }
            let flags = event.modifierFlags.intersection([.control, .shift, .command, .option])
            if event.keyCode == 48 && (flags == .control || flags == [.control, .shift]) {
                // A consumed shortcut may never reach SidebarWindowEvents;
                // keep modality independent of local-monitor installation order.
                input?.receive(event)
                session.selectRelativeTab(flags.contains(.shift) ? -1 : 1)
                return true
            }
            if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "r", session.selectedTab?.url != nil {
                input?.receive(event)
                session.selectedTab?.reloadFromOrigin(); return true
            }
            return false
        }
    }
}
