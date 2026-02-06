// ABOUTME: Actor-based wrapper around EKEventStore for async Reminders access.
// ABOUTME: Provides a clean async/await API with no semaphores or global mutable state.

import EventKit
import Foundation

/// Wraps a non-Sendable value so it can cross isolation boundaries.
/// Safety relies on the enclosing actor ensuring exclusive access after the transfer.
private struct UncheckedTransfer<Value>: @unchecked Sendable {
    let value: Value
}

/// An actor that safely wraps Apple's `EKEventStore` for interacting with Reminders.
///
/// All mutable state is confined to this actor, ensuring thread safety without semaphores
/// or global state. Call `requestAccess()` before using any other methods.
public actor RemindersStore {

    // MARK: - Properties

    private let eventStore: EKEventStore
    private let calendar: Calendar

    // MARK: - Initialization

    /// Creates a store with the given calendar for date calculations.
    ///
    /// - Parameter calendar: The calendar used for date component conversions. Defaults to `.current`.
    public init(calendar: Calendar = .current) {
        self.eventStore = EKEventStore()
        self.calendar = calendar
    }

    // MARK: - Authorization

    /// Requests full access to the user's Reminders.
    ///
    /// Uses `requestFullAccessToReminders()` on macOS 14+. Throws a descriptive error
    /// if access is denied or insufficient.
    public func requestAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)

        switch status {
        case .authorized, .fullAccess:
            return

        case .writeOnly:
            throw RemindersError.writeOnlyAccess

        case .denied, .restricted:
            throw RemindersError.accessDenied

        case .notDetermined:
            let granted = try await eventStore.requestFullAccessToReminders()
            guard granted else {
                throw RemindersError.accessDenied
            }

        @unknown default:
            throw RemindersError.accessDenied
        }
    }

    // MARK: - Lists

    /// Returns all reminder lists (calendars of type `.reminder`).
    public func lists() -> [ReminderList] {
        eventStore.calendars(for: .reminder).map { cal in
            ReminderList(id: cal.calendarIdentifier, title: cal.title)
        }
    }

    /// Returns the title of the default reminder list, if one is configured.
    public func defaultListName() -> String? {
        eventStore.defaultCalendarForNewReminders()?.title
    }

    /// Creates a new reminder list backed by a specific source.
    ///
    /// - Parameters:
    ///   - name: The display name for the new list.
    ///   - sourceName: An optional source name (e.g., "iCloud"). If `nil`, uses the default source.
    /// - Returns: The newly created `ReminderList`.
    /// - Throws: `RemindersError.operationFailed` if the list cannot be saved.
    public func createList(name: String, sourceName: String? = nil) throws -> ReminderList {
        let newCalendar = EKCalendar(for: .reminder, eventStore: eventStore)
        newCalendar.title = name

        if let sourceName {
            guard let source = eventStore.sources.first(where: {
                $0.title.caseInsensitiveCompare(sourceName) == .orderedSame
            }) else {
                let available = eventStore.sources.map(\.title).joined(separator: ", ")
                throw RemindersError.operationFailed(
                    "No source found named \"\(sourceName)\". "
                    + "Available sources: \(available)"
                )
            }
            newCalendar.source = source
        } else if let defaultSource = eventStore.defaultCalendarForNewReminders()?.source {
            newCalendar.source = defaultSource
        } else {
            throw RemindersError.operationFailed(
                "No default source available for creating reminder lists."
            )
        }

        do {
            try eventStore.saveCalendar(newCalendar, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to save list \"\(name)\": \(error.localizedDescription)"
            )
        }

        return ReminderList(id: newCalendar.calendarIdentifier, title: newCalendar.title)
    }

    // MARK: - Fetching Reminders

    /// Fetches reminders, optionally filtering by list and completion status.
    ///
    /// - Parameters:
    ///   - listName: An optional list name to filter by. If `nil`, fetches from all lists.
    ///   - includeCompleted: Whether to include completed reminders in the results.
    ///   - onlyCompleted: If `true`, returns only completed reminders.
    /// - Returns: An array of `ReminderItem` snapshots.
    public func reminders(
        inList listName: String? = nil,
        includeCompleted: Bool = true,
        onlyCompleted: Bool = false
    ) async throws -> [ReminderItem] {
        let calendars: [EKCalendar]?
        if let listName {
            calendars = [try resolveCalendar(named: listName)]
        } else {
            calendars = nil
        }

        let options = DisplayOptions(
            includeCompleted: includeCompleted,
            onlyCompleted: onlyCompleted
        )

        return try await filteredReminders(on: calendars, displayOptions: options)
    }

    // MARK: - Creating Reminders

    /// Creates a new reminder in the specified list.
    ///
    /// - Parameters:
    ///   - draft: The `ReminderDraft` describing the new reminder.
    ///   - listName: The name of the list to add the reminder to.
    /// - Returns: The newly created `ReminderItem`.
    public func addReminder(_ draft: ReminderDraft, toList listName: String) throws -> ReminderItem {
        let targetCalendar = try resolveCalendar(named: listName)

        let ekReminder = EKReminder(eventStore: eventStore)
        ekReminder.title = draft.title
        ekReminder.notes = draft.notes
        ekReminder.calendar = targetCalendar
        ekReminder.priority = draft.priority.eventKitValue

        if let dueDate = draft.dueDate {
            ekReminder.dueDateComponents = calendarComponents(from: dueDate)

            // Add an alarm if the due date includes a meaningful time component.
            let hour = calendar.component(.hour, from: dueDate)
            let minute = calendar.component(.minute, from: dueDate)
            if hour != 0 || minute != 0 {
                ekReminder.addAlarm(EKAlarm(absoluteDate: dueDate))
            }
        }

        do {
            try eventStore.save(ekReminder, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to save reminder \"\(draft.title)\": \(error.localizedDescription)"
            )
        }

        return mapReminder(ekReminder)
    }

    // MARK: - Completing Reminders

    /// Marks a reminder as complete or incomplete.
    ///
    /// - Parameters:
    ///   - complete: `true` to mark complete, `false` to mark incomplete.
    ///   - itemAtIndex: An integer index (as a string) or an external identifier.
    ///   - listName: The name of the list containing the reminder.
    ///   - includeCompleted: Whether to include completed reminders when resolving the index.
    ///   - onlyCompleted: If `true`, only completed reminders are considered when resolving the index.
    /// - Returns: The updated `ReminderItem`.
    public func setComplete(
        _ complete: Bool,
        itemAtIndex: String,
        onList listName: String,
        includeCompleted: Bool = false,
        onlyCompleted: Bool = false
    ) async throws -> ReminderItem {
        let targetCalendar = try resolveCalendar(named: listName)
        let filtered = try await fetchFilteredEKReminders(
            on: [targetCalendar],
            includeCompleted: includeCompleted,
            onlyCompleted: onlyCompleted
        )
        let (ekReminder, _) = try resolveReminder(from: filtered, at: itemAtIndex)

        ekReminder.isCompleted = complete
        if complete {
            ekReminder.completionDate = Date()
        } else {
            ekReminder.completionDate = nil
        }

        do {
            try eventStore.save(ekReminder, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to update completion status: \(error.localizedDescription)"
            )
        }

        return mapReminder(ekReminder)
    }

    // MARK: - Editing Reminders

    /// Edits the title and/or notes of an existing reminder.
    ///
    /// - Parameters:
    ///   - itemAtIndex: An integer index (as a string) or an external identifier.
    ///   - listName: The name of the list containing the reminder.
    ///   - newText: A new title, or `nil` to leave unchanged.
    ///   - newNotes: New notes, or `nil` to leave unchanged.
    ///   - includeCompleted: Whether to include completed reminders when resolving the index.
    ///   - onlyCompleted: If `true`, only completed reminders are considered when resolving the index.
    /// - Returns: The updated `ReminderItem`.
    public func edit(
        itemAtIndex: String,
        onList listName: String,
        newText: String? = nil,
        newNotes: String? = nil,
        includeCompleted: Bool = false,
        onlyCompleted: Bool = false
    ) async throws -> ReminderItem {
        let targetCalendar = try resolveCalendar(named: listName)
        let filtered = try await fetchFilteredEKReminders(
            on: [targetCalendar],
            includeCompleted: includeCompleted,
            onlyCompleted: onlyCompleted
        )
        let (ekReminder, _) = try resolveReminder(from: filtered, at: itemAtIndex)

        if let newText {
            ekReminder.title = newText
        }
        if let newNotes {
            ekReminder.notes = newNotes
        }

        do {
            try eventStore.save(ekReminder, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to edit reminder: \(error.localizedDescription)"
            )
        }

        return mapReminder(ekReminder)
    }

    // MARK: - Deleting Reminders

    /// Deletes a reminder from a list.
    ///
    /// - Parameters:
    ///   - itemAtIndex: An integer index (as a string) or an external identifier.
    ///   - listName: The name of the list containing the reminder.
    ///   - includeCompleted: Whether to include completed reminders when resolving the index.
    ///   - onlyCompleted: If `true`, only completed reminders are considered when resolving the index.
    /// - Returns: The title of the deleted reminder.
    public func delete(
        itemAtIndex: String,
        onList listName: String,
        includeCompleted: Bool = false,
        onlyCompleted: Bool = false
    ) async throws -> String {
        let targetCalendar = try resolveCalendar(named: listName)
        let filtered = try await fetchFilteredEKReminders(
            on: [targetCalendar],
            includeCompleted: includeCompleted,
            onlyCompleted: onlyCompleted
        )
        let (ekReminder, _) = try resolveReminder(from: filtered, at: itemAtIndex)

        let deletedTitle = ekReminder.title ?? "(untitled)"

        do {
            try eventStore.remove(ekReminder, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to delete reminder \"\(deletedTitle)\": \(error.localizedDescription)"
            )
        }

        return deletedTitle
    }

    // MARK: - Private Types

    /// Options controlling which reminders to include based on completion status.
    private struct DisplayOptions {
        let includeCompleted: Bool
        let onlyCompleted: Bool
    }

    // MARK: - Private Helpers (Calendar Resolution)

    /// Resolves a calendar by name using case-insensitive matching.
    ///
    /// - Parameter name: The list name to look up.
    /// - Returns: The matching `EKCalendar`.
    /// - Throws: `RemindersError.listNotFound` with available list names for guidance.
    private func resolveCalendar(named name: String) throws -> EKCalendar {
        let allCalendars = eventStore.calendars(for: .reminder)
        guard let match = allCalendars.first(where: {
            $0.title.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            let available = allCalendars.map(\.title).joined(separator: ", ")
            throw RemindersError.listNotFound(
                "\(name) (available lists: \(available))"
            )
        }
        return match
    }

    // MARK: - Private Helpers (Reminder Resolution)

    /// Resolves a reminder by index or external identifier.
    ///
    /// First attempts to parse `indexOrID` as an integer index into the array.
    /// Falls back to matching by `calendarItemExternalIdentifier`.
    ///
    /// - Parameters:
    ///   - reminders: The array of reminders to search.
    ///   - indexOrID: A string that is either an integer index or an external ID.
    /// - Returns: A tuple of the matched `EKReminder` and its position in the array.
    /// - Throws: `RemindersError.reminderNotFound` with context about what was tried.
    private func resolveReminder(
        from reminders: [EKReminder],
        at indexOrID: String
    ) throws -> (EKReminder, Int) {
        // Try integer index first.
        if let index = Int(indexOrID) {
            guard reminders.indices.contains(index) else {
                throw RemindersError.reminderNotFound(
                    "index \(index) (list has \(reminders.count) "
                    + "reminder\(reminders.count == 1 ? "" : "s"), "
                    + "valid range: 0-\(max(0, reminders.count - 1)))"
                )
            }
            return (reminders[index], index)
        }

        // Fall back to external identifier lookup.
        guard let matchIndex = reminders.firstIndex(where: {
            $0.calendarItemExternalIdentifier == indexOrID
        }) else {
            throw RemindersError.reminderNotFound(indexOrID)
        }
        return (reminders[matchIndex], matchIndex)
    }

    // MARK: - Private Helpers (Mapping)

    /// Converts an `EKReminder` into a detached `ReminderItem` snapshot.
    private func mapReminder(_ ekReminder: EKReminder) -> ReminderItem {
        let dueDate: Date?
        if let components = ekReminder.dueDateComponents {
            dueDate = calendar.date(from: components)
        } else {
            dueDate = nil
        }

        return ReminderItem(
            id: ekReminder.calendarItemExternalIdentifier,
            title: ekReminder.title ?? "",
            notes: ekReminder.notes,
            isCompleted: ekReminder.isCompleted,
            completionDate: ekReminder.completionDate,
            priority: ReminderPriority(eventKitValue: ekReminder.priority),
            dueDate: dueDate,
            listID: ekReminder.calendar.calendarIdentifier,
            listName: ekReminder.calendar.title
        )
    }

    // MARK: - Private Helpers (Date Conversion)

    /// Converts a `Date` into `DateComponents` suitable for EventKit, preserving timezone info.
    private func calendarComponents(from date: Date) -> DateComponents {
        calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .timeZone],
            from: date
        )
    }

    // MARK: - Private Helpers (Fetching)

    /// Fetches all reminders on the given calendars.
    ///
    /// Uses `fetchReminders(matching:completion:)` wrapped in a checked continuation
    /// since EventKit does not provide a native async overload for this method.
    /// The `UncheckedTransfer` wrapper is needed because `EKReminder` is not `Sendable`,
    /// but the actor boundary guarantees exclusive access after the continuation resumes.
    private func fetchReminders(on calendars: [EKCalendar]?) async throws -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: calendars)
        let transfer = await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedTransfer<[EKReminder]>, Never>) in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: UncheckedTransfer(value: reminders ?? []))
            }
        }
        return transfer.value
    }

    /// Fetches EKReminder objects filtered by completion status.
    ///
    /// Unlike `filteredReminders(on:displayOptions:)`, this returns raw `EKReminder` objects
    /// so callers can mutate them (e.g., mark complete, edit, delete).
    ///
    /// - Parameters:
    ///   - calendars: The calendars to fetch from, or `nil` for all.
    ///   - includeCompleted: Whether to include completed reminders. Ignored when `onlyCompleted` is true.
    ///   - onlyCompleted: If `true`, returns only completed reminders.
    /// - Returns: An array of `EKReminder` matching the filter criteria.
    private func fetchFilteredEKReminders(
        on calendars: [EKCalendar]?,
        includeCompleted: Bool,
        onlyCompleted: Bool
    ) async throws -> [EKReminder] {
        let allReminders = try await fetchReminders(on: calendars)

        if onlyCompleted {
            return allReminders.filter(\.isCompleted)
        } else if !includeCompleted {
            return allReminders.filter { !$0.isCompleted }
        } else {
            return allReminders
        }
    }

    /// Fetches reminders and filters them by the given display options.
    private func filteredReminders(
        on calendars: [EKCalendar]?,
        displayOptions: DisplayOptions
    ) async throws -> [ReminderItem] {
        let filtered = try await fetchFilteredEKReminders(
            on: calendars,
            includeCompleted: displayOptions.includeCompleted,
            onlyCompleted: displayOptions.onlyCompleted
        )

        return filtered.map { mapReminder($0) }
    }
}
