import BrowserCore
import BrowserEngine
import SwiftUI

@main
struct PersonalBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var profiles: BrowserProfiles
    private var controller: BrowserController { profiles.controller }
    private var appearance: BrowserAppearance { controller.appearance }

    init() {
        #if ORIV_BENCH
        precondition(Bundle.main.bundleIdentifier == "local.personalbrowser.bench", "Benchmark build requires its isolated bundle identity")
        #endif
        BackgroundUIMode.installAtLaunch()
        #if ORIV_BENCH
        let initial = BrowserProfiles(rootDirectory: SpeedometerBenchmark.profileDirectory, testing: false)
        #elseif DEBUG
        let initial = BrowserProfiles(testing: SyncTimingProbe.requested ? true : nil)
        #else
        let initial = BrowserProfiles()
        #endif
        _profiles = State(initialValue: initial)
        appDelegate.profiles = initial; appDelegate.controller = initial.controller
    }

    var body: some Scene {
        Window(AppIdentity.name, id: "browser") {
            BrowserWindow(controller: controller, profiles: profiles)
                .onChange(of: controller.sidebarDragID, initial: true) { _, _ in
                    appDelegate.controller = controller; appDelegate.profiles = profiles
                }
                .modifier(BrowserHandoff(continuity: profiles.continuity, session: controller.session, profile: profiles.active, open: profiles.openContinuityPage))
                .onChange(of: phase, initial: true) { _, value in
                    if value != .active { profiles.saveAll() }
                    profiles.continuity.setForeground(value == .active)
                }
                .onOpenURL { url in profiles.handleIncomingURL(url, sourceName: AppDelegate.externalSourceName) }
                .frame(minWidth: 760, minHeight: 520)
                .browserAppearance(appearance)
                .overlay { ProfileSidebarOverlayHost(profiles: profiles) }
        }
        .defaultLaunchBehavior(BackgroundUIMode.isEnabled ? .suppressed : .presented)
        .restorationBehavior(BackgroundUIMode.isEnabled ? .disabled : .automatic)
        .defaultSize(width: 1250, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { BrowserCommands(regularController: controller, profiles: profiles) }

        Window("Oriv — Private", id: "external-private") {
            Group {
                if let context = profiles.externalPrivate {
                    privateWindow(context, externalProfiles: profiles, dismiss: { dismissWindow(id: "external-private") }) {
                        if profiles.externalPrivate === context { profiles.endExternalPrivate() }
                    }
                }
            }
        }.defaultSize(width: 1100, height: 760).windowStyle(.hiddenTitleBar).windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)

        WindowGroup("Oriv — Private", id: "private-browser", for: UUID.self) { $id in
            if let id, let context = profiles.privateWindows[id] {
                privateWindow(context, dismiss: { dismissWindow(id: "private-browser", value: id) }) {
                    profiles.endPrivateWindow(id)
                }
            }
        }
        .defaultSize(width: 1100, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            AppearanceSettings(appearance: Binding(get: { controller.appearance }, set: { controller.appearance = $0 }), controller: controller, profiles: profiles)
                .id(profiles.active.id)
        }
    }

    private func privateWindow(_ context: BrowserController, externalProfiles: BrowserProfiles? = nil,
                               dismiss: @escaping () -> Void, endSession: @escaping () -> Void) -> some View {
        BrowserWindow(controller: context, profiles: externalProfiles)
            .frame(minWidth: 760, minHeight: 520)
            .browserAppearance(context.appearance)
            .onChange(of: context.session.tabs.isEmpty) { _, empty in
                if empty { dismiss() }
            }
            .onDisappear(perform: endSession)
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
    func applicationWillFinishLaunching(_ notification: Notification) { BackgroundUIMode.installAtLaunch() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if SyncTimingProbe.requested {
            Task {
                do {
                    try await SyncTimingProbe.run(SyncTimingProbe.Configuration()) { print($0) }
                    exit(EXIT_SUCCESS)
                } catch {
                    print(SyncTimingProbe.failure(error))
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        #endif
        #if ORIV_BENCH
        if let profiles, SpeedometerBenchmark.configured {
            Task { await SpeedometerBenchmark.run(profiles: profiles) }
            return
        }
        #endif
        profiles?.continuity.configurePushRegistration { [weak self] in
            guard !BackgroundUIMode.isEnabled else { self?.profiles?.continuity.remoteNotificationRegistration(succeeded: false); return }
            NSApplication.shared.registerForRemoteNotifications()
        }
        #if DEBUG
        if let directory = VisualSnapshots.directory { Task { await VisualSnapshots.run(into: directory) }; return }
        #endif
        Task { await BrowserUpgradeCleanup.retireOldAlerts() }
    }
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        profiles?.continuity.remoteNotificationRegistration(succeeded: true)
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        profiles?.continuity.remoteNotificationRegistration(succeeded: false)
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        profiles?.continuity.receiveRemoteNotification(userInfo)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if ORIV_BENCH
        // Speedometer edits form fields; the benchmark driver must quit unattended.
        if SpeedometerBenchmark.configured { return .terminateNow }
        #endif
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
        else { controller?.session.saveNow(); controller?.session.flushPersistence(); controller?.downloads.shutdown() }
        #if ORIV_BENCH
        try? FileManager.default.removeItem(at: SpeedometerBenchmark.profileDirectory)
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { BackgroundUIMode.showBrowserWindow(sender.windows.first(where: { $0.identifier?.rawValue == "browser" })) }
        return true
    }
}
