// ABOUTME: Domain model types for the RemindersCore library.
// ABOUTME: Defines priority, list, item, draft, and update types that map to EventKit concepts.

import Foundation

// MARK: - ReminderPriority

/// Maps between a semantic priority level and EventKit's integer-based priority system.
///
/// EventKit priority ranges:
///   - 0     → none
///   - 1-4   → high
///   - 5     → medium
///   - 6-9   → low
///
/// Canonical round-trip values: none=0, high=1, medium=5, low=9
public enum ReminderPriority: String, Codable, CaseIterable, Sendable {
    case none
    case low
    case medium
    case high

    /// The canonical EventKit integer value for this priority.
    public var eventKitValue: Int {
        switch self {
        case .none: return 0
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        }
    }

    /// Creates a priority from an EventKit integer value.
    ///
    /// - Parameter eventKitValue: An integer in the range 0-9 (out-of-range defaults to `.none`).
    public init(eventKitValue: Int) {
        switch eventKitValue {
        case 0:
            self = .none
        case 1...4:
            self = .high
        case 5:
            self = .medium
        case 6...9:
            self = .low
        default:
            self = .none
        }
    }
}

// MARK: - ReminderList

/// A lightweight representation of an EventKit calendar used for reminders.
public struct ReminderList: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

// MARK: - ReminderItem

/// A snapshot of a single reminder, detached from EventKit's managed objects.
public struct ReminderItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let notes: String?
    public let isCompleted: Bool
    public let completionDate: Date?
    public let priority: ReminderPriority
    public let dueDate: Date?
    public let listID: String
    public let listName: String

    public init(
        id: String,
        title: String,
        notes: String? = nil,
        isCompleted: Bool,
        completionDate: Date? = nil,
        priority: ReminderPriority,
        dueDate: Date? = nil,
        listID: String,
        listName: String
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.priority = priority
        self.dueDate = dueDate
        self.listID = listID
        self.listName = listName
    }
}

// MARK: - ReminderDraft

/// Holds the fields needed to create a new reminder.
public struct ReminderDraft: Sendable, Codable, Equatable {
    public let title: String
    public let notes: String?
    public let dueDate: Date?
    public let priority: ReminderPriority

    public init(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        priority: ReminderPriority = .none
    ) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.priority = priority
    }
}

// MARK: - ReminderUpdate

/// Carries optional fields for partial updates to an existing reminder.
///
/// The `dueDate` field is a double-optional (`Date??`):
///   - `nil`          → do not change the due date
///   - `.some(nil)`   → clear the due date
///   - `.some(date)`  → set to a new date
public struct ReminderUpdate: Sendable, Equatable {
    public let title: String?
    public let notes: String?
    public let dueDate: Date??
    public let priority: ReminderPriority?
    public let listName: String?
    public let isCompleted: Bool?

    public init(
        title: String? = nil,
        notes: String? = nil,
        dueDate: Date?? = nil,
        priority: ReminderPriority? = nil,
        listName: String? = nil,
        isCompleted: Bool? = nil
    ) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.priority = priority
        self.listName = listName
        self.isCompleted = isCompleted
    }
}

// Custom Codable to handle the double-optional dueDate field correctly.
extension ReminderUpdate: Codable {
    private enum CodingKeys: String, CodingKey {
        case title, notes, dueDate, priority, listName, isCompleted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.priority = try container.decodeIfPresent(ReminderPriority.self, forKey: .priority)
        self.listName = try container.decodeIfPresent(String.self, forKey: .listName)
        self.isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted)

        // Double-optional: if the key is present, decode the inner optional.
        // If the key is absent, the outer optional is nil ("don't change").
        if container.contains(.dueDate) {
            self.dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        } else {
            self.dueDate = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(listName, forKey: .listName)
        try container.encodeIfPresent(isCompleted, forKey: .isCompleted)

        // Only encode dueDate key when the outer optional is non-nil.
        if let outerDueDate = dueDate {
            try container.encode(outerDueDate, forKey: .dueDate)
        }
    }
}
