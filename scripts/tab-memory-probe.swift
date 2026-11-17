import AppKit
import BrowserCore
#if TAB_RECLAMATION_PRODUCT
@testable import BrowserEngine
#else
import BrowserEngine
#endif
import WebKit

/// Development-only executable, built by tab-memory.py. Never links into Oriv.
@main struct TabMemoryProbe {
    @MainActor static func main() {
        // Enforce this before AppKit finishes launching. Accessory apps can
        // still activate; the isolated measurement app must never do so.
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch {
                try? Data(String(describing: error).utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("error.txt"))
                exit(1)
            }
        }
        NSApplication.shared.run()
    }
    @MainActor static func run() async throws {
        precondition(ProcessInfo.processInfo.environment["ORIV_BACKGROUND_UI"] == "1")
        precondition(!BackgroundUIMode.foregroundAllowed)
        BackgroundUIMode.installAtLaunch()
        let args = CommandLine.arguments
        let policy = args[1], output = URL(fileURLWithPath: args[2])
        let base = URL(string: args[3])!
        let session = BrowserSession(dataStore: .nonPersistent(), adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        #if TAB_RECLAMATION_PRODUCT
        // Isolate each policy from real machine pressure and the idle timer.
        // The discard case below invokes the product path with test-only aging.
        session.tabReclamationMonitor?.stopSources()
        #endif
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        BackgroundUIMode.show(window, key: false)
        var dormant: [UUID: Any] = [:]
        var weakViews: [WeakView] = []
        for count in [1, 10, 20, 1] {
            let closing = count == 1 && session.tabs.count > 1
            if closing {
                for tab in Array(session.tabs.dropLast()) {
                    if tab.isInstantiated { weakViews.append(WeakView(tab.webView)) }
                    session.closeTab(tab.id)
                }
                dormant.removeAll()
            } else {
                while session.tabs.count < count { session.addTab(load: false) }
                for (index, tab) in session.tabs.enumerated() {
                    if tab.isInstantiated { continue }
                    if dormant[tab.id] != nil { continue }
                    session.selectTab(tab.id)
                    let view = tab.webView
                    view.frame = window.contentView!.bounds
                    view.configuration.preferences.inactiveSchedulingPolicy = policy == "suspend" ? .suspend : .throttle
                    tab.navigate(to: base.appendingPathComponent("timer/\(index)"))
                    let deadline = ProcessInfo.processInfo.systemUptime + 30
                    while (view.isLoading || tab.isRestoringWebView || view.title != "Tab memory fixture") && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(50)) }
                    guard view.title == "Tab memory fixture", !view.isLoading, !tab.isRestoringWebView else { throw ProbeError.load }
                }
                session.selectTab(session.tabs.last!.id)
            }
            window.contentView = session.selectedTab!.webView
            if policy == "discard" {
                #if TAB_RECLAMATION_PRODUCT
                for tab in session.tabs.dropLast() where tab.isInstantiated {
                    weakViews.append(WeakView(tab.webView))
                    tab.lastSelectedTime -= 601
                }
                _ = await session.reclaimBackgroundTabs()
                #else
                for tab in session.tabs.dropLast() where tab.isInstantiated {
                    weakViews.append(WeakView(tab.webView))
                    // Baseline experiment only: preserve public WebKit state in RAM,
                    // close the view and replace the tab. Product path is used after implementation.
                    if let state = tab.webView.interactionState {
                        dormant[tab.id] = state
                        tab.close()
                    }
                }
                #endif
            }
            try await Task.sleep(for: .seconds(12))
            let stage = closing ? "closed-1" : "\(count)"
            let payload: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "stage": stage,
                "activationProhibited": NSApp.activationPolicy() == .prohibited,
                "tabs": count, "liveViews": session.tabs.filter(\.isInstantiated).count,
                "releasedViews": weakViews.filter { $0.value == nil }.count, "trackedViews": weakViews.count,
                "audit": try JSONSerialization.jsonObject(with: JSONEncoder().encode(BackgroundUIMode.audit()))]
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: output.appendingPathComponent("ready.json"), options: .atomic)
            let ack = output.appendingPathComponent("ack-\(stage)")
            while !FileManager.default.fileExists(atPath: ack.path) {
                if FileManager.default.fileExists(atPath: output.appendingPathComponent("abort").path) { throw ProbeError.cancelled }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        window.contentView = nil
        session.shutdown()
        window.close()
    }
    enum ProbeError: Error { case load, cancelled }
}
@MainActor private final class WeakView {
    weak var value: WKWebView?
    init(_ value: WKWebView) { self.value = value }
}
