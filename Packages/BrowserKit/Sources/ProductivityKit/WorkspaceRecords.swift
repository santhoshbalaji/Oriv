import Foundation

public enum ItemState: String, Codable, CaseIterable, Sendable {
    case reference = "Reference", active = "Active", waiting = "Waiting", finished = "Finished"
}

public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case readable = "Readable text", selection = "Selected passage", partial = "Partial capture", link = "Link only"
}

public struct PageCapture: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public var title: String
    public var text: String
    public var selection: String
    public var kind: CaptureKind
    public var explanation: String
    public let capturedAt: Date
    public init(url: URL, title: String, text: String = "", selection: String = "", kind: CaptureKind = .link,
                explanation: String = "", capturedAt: Date = .now) {
        id = UUID(); self.url = url; self.title = title; self.text = text; self.selection = selection
        self.kind = kind; self.explanation = explanation; self.capturedAt = capturedAt
    }
}

public struct SavedItem: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let url: URL?
    public let purpose: String
    public let state: ItemState
    public let createdAt: Date
    public let updatedAt: Date
    public let archivedAt: Date?
    public let deletedAt: Date?
}

public struct SourceSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let itemID: UUID
    public let url: URL
    public let title: String
    public let text: String
    public let selection: String
    public let kind: CaptureKind
    public let explanation: String
    public let capturedAt: Date
}

public struct WorkspaceNote: Identifiable, Sendable {
    public let id: UUID
    public let itemID: UUID
    public let body: String
    public let createdAt: Date
    public let supersedesID: UUID?
}

public struct WorkspaceAction: Identifiable, Sendable {
    public let id: UUID
    public let itemID: UUID
    public let title: String
    public let dueAt: Date?
    public let reminderAt: Date?
    public let timeZoneID: String
    public let completedAt: Date?
    public let createdAt: Date
    public var isComplete: Bool { completedAt != nil }
}

public struct ActivityEntry: Identifiable, Sendable {
    public let id: UUID
    public let itemID: UUID
    public let text: String
    public let createdAt: Date
}

public struct ReminderDelivery: Equatable, Sendable, Identifiable {
    public let id: String
    public let itemID: UUID
    public let actionID: UUID
    public let title: String
    public let date: Date
    public init(itemID: UUID, actionID: UUID, title: String, date: Date) {
        self.id = "oriv.action.\(actionID.uuidString)"; self.itemID = itemID
        self.actionID = actionID; self.title = title; self.date = date
    }
}

public enum WorkspaceError: LocalizedError {
    case missingRecord, invalidRecord, emptyText, invalidReminder, unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .missingRecord: "This item is no longer available."
        case .invalidRecord: "The workspace contains an unreadable record. Your existing data has been preserved."
        case .emptyText: "Enter a title or some text before saving."
        case .invalidReminder: "Choose a reminder time in the future."
        case .unavailable(let message): message
        }
    }
}
