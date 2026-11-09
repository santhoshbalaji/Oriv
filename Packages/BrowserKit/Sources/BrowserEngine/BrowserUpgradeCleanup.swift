import Foundation
import UserNotifications

/// Retire only the old app-owned alerts. No authorization request, scheduler or delegate remains.
public enum BrowserUpgradeCleanup {
    public static func retireOldAlerts() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil, environment["BROWSER_TESTING"] != "1" else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter(isRetiredAlert)
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }.filter(isRetiredAlert)
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }
    public static func isRetiredAlert(_ identifier: String) -> Bool {
        if identifier.hasPrefix("oriv.action.") { return true }
        guard identifier.hasPrefix("oriv.profile.") else { return false }
        let components = identifier.split(separator: ".")
        return components.count >= 5 && UUID(uuidString: String(components[2])) != nil && components[3] == "action"
    }
}
