import SwiftUI
import BrowserEngine

@main struct OrivMobileApp: App {
    @State private var profiles = MobileProfiles()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            MobileRootView(controller: profiles.current, profiles: profiles).id(profiles.current.profileID).browserAppearance(profiles.current.appearance)
                .modifier(BrowserHandoff(continuity: profiles.continuity, session: profiles.current.session,
                    profile: profiles.profiles.first { $0.id == profiles.current.profileID } ?? .personal, open: profiles.openContinuityPage))
                .onAppear { profiles.foreground() }
                .task { await BrowserUpgradeCleanup.retireOldAlerts() }
                .onOpenURL { profiles.route($0) }
                .onChange(of: phase) { _, value in value == .active ? profiles.foreground() : profiles.background() }
        }
    }
}
