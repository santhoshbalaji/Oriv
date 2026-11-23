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
        precondition(ProcessInfo.processInfo.environment["ORIV_BACKGROUND_UI"] == "1")
        precondition(!BackgroundUIMode.foregroundAllowed)
        let args = CommandLine.arguments
        Task { @MainActor in
            if args[1] == "--remove-store" {
                do {
                    // Initialize WebKit's main run loop in this fresh process
                    // before the data-store removal callback returns to it.
                    let configuration = WKWebViewConfiguration()
                    configuration.websiteDataStore = .nonPersistent()
                    let webKit = WKWebView(frame: .zero, configuration: configuration)
                    try await WKWebsiteDataStore.remove(forIdentifier: UUID(uuidString: args[2])!)
                    withExtendedLifetime(webKit) {}
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data(String(describing: error).utf8))
                    exit(1)
                }
            }
            let output = URL(fileURLWithPath: args[2])
            do {
                try await measure(policy: args[1], output: output, base: URL(string: args[3])!,
                                  settle: Int(args[4])!, storeID: UUID(uuidString: args[5])!)
                try Data().write(to: output.appendingPathComponent("complete"), options: .atomic)
                exit(0)
            } catch {
                try? Data(String(describing: error).utf8).write(to: output.appendingPathComponent("error.txt"))
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor static func measure(policy: String, output: URL, base: URL, settle: Int, storeID: UUID) async throws {
        BackgroundUIMode.installAtLaunch()
        let session = BrowserSession(dataStore: WKWebsiteDataStore(forIdentifier: storeID),
                                     adBlocker: AdBlocker(defaults: nil), settings: BrowserSettings(defaults: nil))
        let popupDelegate = ProbePopupDelegate(session: session)
        session.configureWebView = { view, _ in view.uiDelegate = popupDelegate }
        session.adBlocker.warmUp()
        #if TAB_RECLAMATION_PRODUCT
        // Isolate each policy from real machine pressure and the idle timer.
        // The discard case below invokes the product path with test-only aging.
        session.tabReclamationMonitor?.stopSources()
        #endif
        let window = BackgroundUIMode.Window(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        BackgroundUIMode.show(window, key: false)
        let policyOverride: WKPreferences.InactiveSchedulingPolicy? = switch policy {
        case "throttle": .throttle
        case "suspend": .suspend
        default: nil
        }
        var weakViews: [UUID: WeakObject] = [:]
        var weakControllers: [WeakObject] = []
        defer { window.contentView = nil; session.shutdown(); window.close() }
        for count in [1, 10, 20, 1] {
            let closing = count == 1 && session.tabs.count > 1
            if closing {
                for tab in Array(session.tabs.dropLast()) {
                    if tab.isInstantiated {
                        weakViews[tab.id] = WeakObject(tab.webView)
                        weakControllers.append(WeakObject(tab.webView.configuration.userContentController))
                    }
                    session.closeTab(tab.id)
                }
            } else {
                if session.selectedTab?.isInstantiated == false {
                    let tab = session.selectedTab!
                    window.contentView = tab.webView
                    tab.navigate(to: base.appendingPathComponent("timer/0"))
                    try await waitForPage(tab)
                    if let policyOverride { tab.webView.configuration.preferences.inactiveSchedulingPolicy = policyOverride }
                }
                while session.tabs.count < count {
                    let opener = session.selectedTab!
                    opener.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
                    _ = try await opener.webView.evaluateJavaScript("document.getElementById('next').click()")
                    let deadline = ProcessInfo.processInfo.systemUptime + 5
                    while session.selectedTab === opener {
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProbeError.popup }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    let tab = session.selectedTab!
                    window.contentView = tab.webView
                    try await waitForPage(tab)
                    if let policyOverride { tab.webView.configuration.preferences.inactiveSchedulingPolicy = policyOverride }
                }
            }
            window.contentView = session.selectedTab!.webView
            if policy == "discard" || policy == "pressure" {
                #if TAB_RECLAMATION_PRODUCT
                for tab in session.tabs.dropLast() where tab.isInstantiated {
                    weakViews[tab.id] = WeakObject(tab.webView)
                    tab.lastSelectedTime -= 75
                }
                _ = await session.reclaimBackgroundTabs(underMemoryPressure:policy == "pressure")
                #else
                throw ProbeError.productBuildRequired
                #endif
            }
            try await Task.sleep(for: .seconds(settle))
            let stage = closing ? "closed-1" : "\(count)"
            let payload: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "stage": stage,
                "activationProhibited": NSApp.activationPolicy() == .prohibited,
                "tabs": count, "liveViews": session.tabs.filter(\.isInstantiated).count,
                "snapshotBudgetCharge": session.tabSnapshots.cost, "snapshotCount":session.tabSnapshots.count,
                "releasedViews": weakViews.values.filter { $0.value == nil }.count, "trackedViews": weakViews.count,
                "releasedClosedControllers": weakControllers.filter { $0.value == nil }.count,
                "trackedClosedControllers": weakControllers.count,
                "audit": try JSONSerialization.jsonObject(with: JSONEncoder().encode(BackgroundUIMode.audit()))]
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: output.appendingPathComponent("ready.json"), options: .atomic)
            let ack = output.appendingPathComponent("ack-\(stage)")
            while !FileManager.default.fileExists(atPath: ack.path) {
                if FileManager.default.fileExists(atPath: output.appendingPathComponent("abort").path) { throw ProbeError.cancelled }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    @MainActor static func waitForPage(_ tab: BrowserTab) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while tab.isLoading || !tab.hasRenderedContent || tab.title != "Tab memory fixture" {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProbeError.load }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    enum ProbeError: Error { case load, popup, cancelled, productBuildRequired }
}
@MainActor private final class WeakObject {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}


@MainActor private final class ProbePopupDelegate: NSObject, WKUIDelegate {
    weak var session: BrowserSession?
    init(session: BrowserSession) { self.session = session }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let session, let opener = session.selectedTab, opener.webView === webView else { return nil }
        return session.openPopup(from: opener, url: action.request.url, configuration: configuration)
    }
}
