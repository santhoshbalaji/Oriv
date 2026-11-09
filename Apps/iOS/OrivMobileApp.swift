import SwiftUI
import BrowserEngine

@main struct OrivMobileApp: App {
    @State private var profiles = MobileProfiles()
    @Environment(\.scenePhase) private var phase
    #if DEBUG && targetEnvironment(simulator)
    @State private var routedSimulatorLinks = false
    #endif
    var body: some Scene {
        WindowGroup {
            MobileRootView(controller: profiles.current, profiles: profiles).id(profiles.current.profileID).browserAppearance(profiles.current.appearance)
                .modifier(BrowserHandoff(continuity: profiles.continuity, session: profiles.current.session,
                    profile: profiles.profiles.first { $0.id == profiles.current.profileID } ?? .personal, open: profiles.openContinuityPage))
                .onAppear {
                    profiles.foreground()
                    #if DEBUG && targetEnvironment(simulator)
                    // Exercise the production external route without changing the Simulator's
                    // default browser. Repeat the argument to check grouped incoming links.
                    if !routedSimulatorLinks {
                        routedSimulatorLinks = true
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
