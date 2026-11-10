import SwiftUI
import BrowserEngine
import BrowserCore

@main struct OrivMobileApp: App {
    @State private var profiles = MobileProfiles()
    @Environment(\.scenePhase) private var phase
    #if DEBUG && targetEnvironment(simulator)
    @State private var routedSimulatorLinks = false
    #endif
    var body: some Scene {
        WindowGroup {
            MobileRootView(controller: profiles.current, profiles: profiles).id(profiles.current.profileID).browserAppearance(profiles.current.appearance, followsPage: true)
                .modifier(BrowserHandoff(continuity: profiles.continuity, session: profiles.current.session,
                    profile: profiles.profiles.first { $0.id == profiles.current.profileID } ?? .personal, open: profiles.openContinuityPage))
                .onAppear {
                    profiles.foreground()
                    #if DEBUG && targetEnvironment(simulator)
                    // Exercise the production external route without changing the Simulator's
                    // default browser. Repeat the argument to check grouped incoming links.
                    if !routedSimulatorLinks {
                        routedSimulatorLinks = true
                        if let mode = ChromeVisualFixture.mode {
                            if mode == "private" { profiles.route(URL(string: "https://docs.example.com/designing-calm-interfaces")!) }
                            let current = profiles.current.session
                            Task { @MainActor in
                                // Let the routed view attach before loading its local document.
                                try? await Task.sleep(for: .milliseconds(500))
                                for i in 0..<(mode == "private" ? 1 : 4) {
                                    let tab = i == 0 ? current.selectedTab! : current.addTab(select: false, load: false)
                                    tab.stop(); tab.dismissError()
                                    tab.webView.frame = CGRect(x: 0, y: 0, width: 440, height: 880)
                                    tab.webView.loadHTMLString(ChromeVisualFixture.html(dark: mode == "dark" || i == 2, card: i), baseURL: URL(string: "\(mode == "insecure" ? "http" : "https")://docs.example.com/designing-calm-interfaces"))
                                }
                                if mode == "gestures" {
                                    let url = URL(string: "http://127.0.0.1:8768/gestures")!
                                    current.selectedTab?.navigate(to: url)
                                    for i in 0..<12 { current.addTab(url: URL(string: "http://127.0.0.1:8768/two?tab=\(i)"), select: false, load: false) }
                                    current.addTab(url: url, isPrivate: true, select: false, load: false)
                                }
                            }
                        }
                        if let url = ChromeVisualFixture.liveURL { try? profiles.current.session.navigate(url.absoluteString) }
                        let arguments = ProcessInfo.processInfo.arguments
                        for index in arguments.indices where arguments[index] == "--oriv-external-url" && index + 1 < arguments.count {
                            if let url = URL(string: arguments[index + 1]) { profiles.route(url) }
                        }
                    }
                    #endif
                }
                .task { await BrowserUpgradeCleanup.retireOldAlerts() }
                .onOpenURL { profiles.route($0) }
                .onChange(of: phase) { _, value in value == .active ? profiles.foreground() : profiles.background() }
        }
    }
}
