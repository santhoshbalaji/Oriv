import Foundation
import Observation
import UserNotifications

public enum ReminderPermission: Sendable { case unknown, allowed, denied }

@MainActor public protocol ReminderTransport: AnyObject {
    func permission(request: Bool) async throws -> ReminderPermission
    func pendingIDs() async -> Set<String>
    func deliveredIDs() async -> Set<String>
    func schedule(_ delivery: ReminderDelivery) async throws
    func cancel(_ ids: [String])
}

@MainActor public final class SystemReminderTransport: ReminderTransport {
    private let center = UNUserNotificationCenter.current()
    public init() {}
    public func permission(request: Bool) async throws -> ReminderPermission {
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined, request {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge]) ? .allowed : .denied
        }
        switch status {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .unknown
        }
    }
    public func pendingIDs() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("oriv.action.") })
    }
    public func deliveredIDs() async -> Set<String> {
        Set(await center.deliveredNotifications().map { $0.request.identifier }.filter { $0.hasPrefix("oriv.action.") })
    }
    public func schedule(_ delivery: ReminderDelivery) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Oriv reminder"; content.body = delivery.title; content.sound = .default
        content.userInfo = ["itemID": delivery.itemID.uuidString, "actionID": delivery.actionID.uuidString]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: delivery.date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: delivery.id, content: content, trigger: trigger))
    }
    public func cancel(_ ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Serial reconciliation prevents a slow permission or add callback from resurrecting a completed reminder.
@MainActor @Observable public final class WorkspaceReminders {
    public private(set) var permission: ReminderPermission = .unknown
    public private(set) var message: String?
    public private(set) var scheduledCount = 0
    public private(set) var deliveredIDs: Set<String> = []
    @ObservationIgnored private let transport: any ReminderTransport
    @ObservationIgnored private var desired: [ReminderDelivery] = []
    @ObservationIgnored private var retiringIDs: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running = false
    @ObservationIgnored private var requestPermission = false
    @ObservationIgnored private var installed: [String: ReminderDelivery] = [:]
    public init(transport: any ReminderTransport = SystemReminderTransport()) { self.transport = transport }

    public func reconcile(_ deliveries: [ReminderDelivery], retiringIDs: Set<String> = [], requestPermission: Bool = false) async {
        desired = deliveries; generation += 1
        self.retiringIDs = retiringIDs
        self.requestPermission = self.requestPermission || requestPermission
        guard !running else { return }
        running = true
        defer { running = false }
        while true {
            let current = generation
            let ask = self.requestPermission; self.requestPermission = false
            let wanted = Array(desired.sorted { $0.date < $1.date }.prefix(48))
            let retired = self.retiringIDs
            do {
                permission = try await transport.permission(request: ask)
                let pending = await transport.pendingIDs()
                let wantedIDs = Set(wanted.map(\.id))
                let obsolete = pending.union(installed.keys).subtracting(wantedIDs).union(retired)
                transport.cancel(Array(obsolete)); obsolete.forEach { installed.removeValue(forKey: $0) }
                deliveredIDs = await transport.deliveredIDs()
                guard current == generation else { continue }
                if permission == .allowed {
                    for delivery in wanted {
                        guard current == generation else { break }
                        if installed[delivery.id] != delivery || !pending.contains(delivery.id) {
                            try await transport.schedule(delivery); installed[delivery.id] = delivery
                        }
                    }
                    scheduledCount = wanted.count
                    message = desired.count > 48 ? "The next 48 reminders are scheduled. Open Oriv to schedule later reminders as they approach." : nil
                } else {
                    scheduledCount = 0
                    message = desired.isEmpty ? nil : permission == .denied
                        ? "Notifications are off. Your actions are saved; enable Oriv notifications in System Settings for alerts."
                        : "Your actions are saved. Enable notifications to receive their reminders."
                }
            } catch { message = "Your actions are saved, but alerts couldn’t be scheduled: \(error.localizedDescription)" }
            if current == generation { break }
        }
    }
}
