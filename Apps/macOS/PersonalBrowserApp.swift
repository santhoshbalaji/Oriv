import BrowserCore
import BrowserEngine
import SwiftUI
import UserNotifications

@main
struct PersonalBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = BrowserController()
    @AppStorage("browserAppearance") private var appearance: BrowserAppearance = .system

    var body: some Scene {
        Window("Oriv", id: "browser") {
            BrowserWindow(controller: controller)
                .modifier(NotificationRouting(controller: controller, delegate: appDelegate))
                .onOpenURL { url in controller.openExternal(url) }
                .frame(minWidth: 760, minHeight: 520)
                .tint(Theme.accent)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 1250, height: 820)
        .windowToolbarStyle(.unified)
        .commands { BrowserCommands(controller: controller) }

        Window("Oriv Workspace", id: "workspace") {
            WorkspaceView(controller: controller)
                .modifier(NotificationRouting(controller: controller, delegate: appDelegate))
                .tint(Theme.accent).preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)

        Settings {
            AppearanceSettings(appearance: $appearance, adBlocker: controller.session.adBlocker)
                .preferredColorScheme(appearance.colorScheme).tint(Theme.accent)
        }
    }
}

private struct NotificationRouting: ViewModifier {
    let controller: BrowserController
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear {
            delegate.connect(controller: controller) { openWindow(id: "workspace") }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var controller: BrowserController?
    private var pendingItemID: UUID?
    private var openWorkspace: (() -> Void)?
    func connect(controller: BrowserController, openWorkspace: @escaping () -> Void) {
        self.controller = controller
        self.openWorkspace = openWorkspace
        routePendingReminder()
    }
    func openReminder(itemID: UUID) {
        pendingItemID = itemID
        routePendingReminder()
    }
    private func routePendingReminder() {
        guard let id = pendingItemID, let controller, let openWorkspace else { return }
        pendingItemID = nil
        controller.showWorkspace(itemID: id)
        // Keep the scene action after windows close; observation in a closed view cannot route a notification.
        openWorkspace()
    }
    func applicationDidFinishLaunching(_ notification: Notification) { UNUserNotificationCenter.current().delegate = self }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["itemID"] as? String, let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            self.openReminder(itemID: id)
            NSApp.activate()
        }
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.session.saveNow() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.identifier?.rawValue == "browser" })?.makeKeyAndOrderFront(nil) }
        return true
    }
}
