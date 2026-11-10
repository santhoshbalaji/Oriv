import BrowserCore
import BrowserEngine
import SwiftUI

@main
struct PersonalBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var phase
    @State private var profiles = BrowserProfiles()
    private var controller: BrowserController { profiles.controller }
    private var appearance: BrowserAppearance { controller.appearance }

    var body: some Scene {
        Window(AppIdentity.name, id: "browser") {
            BrowserWindow(controller: controller, profiles: profiles)
                .id(profiles.active.id)
                .onAppear { appDelegate.controller = controller; appDelegate.profiles = profiles }
                .modifier(BrowserHandoff(continuity: profiles.continuity, session: controller.session, profile: profiles.active, open: profiles.openContinuityPage))
                .onChange(of: phase, initial: true) { _, value in profiles.continuity.setForeground(value == .active) }
                .onOpenURL { url in profiles.handleIncomingURL(url, sourceName: AppDelegate.externalSourceName) }
                .frame(minWidth: 760, minHeight: 520)
                .browserAppearance(appearance)
        }
        .defaultSize(width: 1250, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { BrowserCommands(regularController: controller, profiles: profiles) }

        Window("Oriv — Private", id: "external-private") {
            Group {
                if let context = profiles.externalPrivate {
                    BrowserWindow(controller: context, profiles: profiles)
                        .frame(minWidth: 760, minHeight: 520).browserAppearance(context.appearance)
                        .onDisappear { profiles.endExternalPrivate() }
                }
            }
        }.defaultSize(width: 1100, height: 760).windowStyle(.hiddenTitleBar).windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)

        Settings {
            AppearanceSettings(appearance: Binding(get: { controller.appearance }, set: { controller.appearance = $0 }), controller: controller, profiles: profiles)
                .id(profiles.active.id)
                .browserAppearance(appearance)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Only attribute an active URL Apple event with a resolvable sender process.
    static var externalSourceName: String? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kInternetEventClass), event.eventID == AEEventID(kAEGetURL),
              let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)),
              let app = NSRunningApplication(processIdentifier: pid_t(sender.int32Value)),
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app.localizedName
    }
    weak var controller: BrowserController?
    weak var profiles: BrowserProfiles?
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let directory = VisualSnapshots.directory { Task { await VisualSnapshots.run(into: directory) }; return }
        #endif
        Task { await BrowserUpgradeCleanup.retireOldAlerts() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controllers = profiles?.allControllers ?? controller.map { [$0] } ?? []
        let downloads = controllers.contains { $0.downloads.hasActiveDownloads }
        let edited = controllers.contains { $0.session.tabs.contains(where: \.hasEditedFields) }
        guard downloads || edited else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Quit Oriv?"
        alert.informativeText = (downloads ? "Active downloads will stop and cannot resume after quitting. " : "") + (edited ? "Some pages have edited fields. Oriv cannot determine whether the websites saved them." : "")
        alert.addButton(withTitle: "Keep browsing"); alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let profiles { profiles.saveAll(); profiles.shutdown() }
        else { controller?.session.saveNow(); controller?.downloads.shutdown() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.identifier?.rawValue == "browser" })?.makeKeyAndOrderFront(nil) }
        return true
    }
}
