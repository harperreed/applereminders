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

    private let backend: any EventStoreBackend
    private let calendar: Calendar
    private var changeObserver: (any NSObjectProtocol)?

    // MARK: - Initialization

    /// Creates a store backed by the real EventKit database.
    ///
    /// - Parameter calendar: The calendar used for date component conversions. Defaults to `.current`.
    public init(calendar: Calendar = .current) {
        self.backend = EventKitBackend()
        self.calendar = calendar
    }

    /// Creates a store with an injected backend. Intended for tests, which
    /// substitute an in-memory fake to avoid TCC.
    ///
    /// - Parameters:
    ///   - backend: The EventKit seam implementation to use.
    ///   - calendar: The calendar used for date component conversions. Defaults to `.current`.
    public init(backend: any EventStoreBackend, calendar: Calendar = .current) {
        self.backend = backend
        self.calendar = calendar
    }

    // MARK: - Authorization

    /// Requests full access to the user's Reminders.
    ///
    /// Uses `requestFullAccessToReminders()` on macOS 14+. Throws a descriptive error
    /// if access is denied or insufficient.
    public func requestAccess() async throws {
        let status = backend.reminderAuthorizationStatus()

        switch status {
        case .authorized, .fullAccess:
            return

        case .writeOnly:
            throw RemindersError.writeOnlyAccess

        case .denied, .restricted:
            throw RemindersError.accessDenied

        case .notDetermined:
            let granted = try await backend.requestReminderAccess()
            guard granted else {
                throw RemindersError.accessDenied
            }

        @unknown default:
            throw RemindersError.accessDenied
        }
    }

    // MARK: - Change Observation

    /// Begins refreshing EventKit sources whenever the Calendar database changes.
    ///
    /// Long-running processes (the MCP server) otherwise risk serving stale data:
    /// once `.EKEventStoreChanged` fires, previously fetched objects are invalid and
    /// `refreshSourcesIfNecessary()` must run before new fetches see current state.
    /// Safe to call more than once; only the first call registers. The CLI path is
    /// process-per-invocation and does not need this.
    ///
    /// The closure captures only the `Sendable` backend, not `self`, so it can run
    /// off-actor without entering the actor's executor; safe here because the backend
    /// is documented thread-safe.
    ///
    /// The observer is retained for the process lifetime; no removal API is provided
    /// or needed for the MCP server use case.
    public func startObservingExternalChanges() {
        guard changeObserver == nil else { return }
        let backend = self.backend
        // `object: nil` because this process only ever has one event store.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: nil
        ) { _ in
            // EKEventStore is thread-safe; refresh directly on the posting thread.
            backend.refreshSourcesIfNecessary()
        }
    }

    // MARK: - Lists

    /// Returns all reminder lists (calendars of type `.reminder`).
    public func lists() -> [ReminderList] {
        backend.reminderCalendars().map { cal in
            ReminderList(id: cal.calendarIdentifier, title: cal.title)
        }
    }

    /// Returns the title of the default reminder list, if one is configured.
    public func defaultListName() -> String? {
        backend.defaultReminderCalendar()?.title
    }

    /// Creates a new reminder list backed by a specific source.
    ///
    /// - Parameters:
    ///   - name: The display name for the new list.
    ///   - sourceName: An optional source name (e.g., "iCloud"). If `nil`, uses the default source.
    /// - Returns: The newly created `ReminderList`.
    /// - Throws: `RemindersError.operationFailed` if the list cannot be saved.
    public func createList(name: String, sourceName: String? = nil) throws -> ReminderList {
        let newCalendar = backend.makeCalendar()
        newCalendar.title = name

        if let sourceName {
            guard let source = backend.allSources.first(where: {
                $0.title.caseInsensitiveCompare(sourceName) == .orderedSame
            }) else {
                let available = backend.allSources.map(\.title).joined(separator: ", ")
                throw RemindersError.operationFailed(
                    "No source found named \"\(sourceName)\". "
                    + "Available sources: \(available)"
                )
            }
            newCalendar.source = source
        } else if let defaultSource = backend.defaultReminderCalendar()?.source {
            newCalendar.source = defaultSource
        } else {
            throw RemindersError.operationFailed(
                "No default source available for creating reminder lists."
            )
        }

        do {
            try backend.saveCalendar(newCalendar, commit: true)
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

        let ekReminder = backend.makeReminder()
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
            try backend.saveReminder(ekReminder, commit: true)
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
        return try applyCompletion(complete, to: ekReminder)
    }

    // MARK: - Updating Reminders

    /// Applies a partial update to an existing reminder.
    ///
    /// Only the fields present in `update` change. The double-optional
    /// `update.dueDate` distinguishes "leave alone" (`nil`) from "clear"
    /// (`.some(nil)`) from "set" (`.some(date)`).
    ///
    /// - Parameters:
    ///   - itemAtIndex: An integer index (as a string) or a stable identifier.
    ///   - listName: The name of the list containing the reminder.
    ///   - update: The fields to change.
    ///   - includeCompleted: Whether completed reminders participate in index resolution.
    ///   - onlyCompleted: If `true`, only completed reminders are considered.
    /// - Returns: The updated `ReminderItem`.
    public func update(
        itemAtIndex: String,
        onList listName: String,
        with update: ReminderUpdate,
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
        return try applyAndSave(update, to: ekReminder)
    }

    // MARK: - Deleting Reminders

    /// Deletes a reminder from a list.
    ///
    /// - Parameters:
    ///   - itemAtIndex: An integer index (as a string) or an external identifier.
    ///   - listName: The name of the list containing the reminder.
    ///   - includeCompleted: Whether to include completed reminders when resolving the index.
    ///   - onlyCompleted: If `true`, only completed reminders are considered when resolving the index.
    /// - Returns: A snapshot of the deleted reminder, captured before removal.
    public func delete(
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
        return try removeAndSnapshot(ekReminder)
    }

    // MARK: - Shared Mutation Helpers

    /// Sets the completion flag (and matching completion date), saves, and maps.
    private func applyCompletion(_ complete: Bool, to ekReminder: EKReminder) throws -> ReminderItem {
        ekReminder.isCompleted = complete
        if complete {
            ekReminder.completionDate = Date()
        } else {
            ekReminder.completionDate = nil
        }

        do {
            try backend.saveReminder(ekReminder, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to update completion status: \(error.localizedDescription)"
            )
        }

        return mapReminder(ekReminder)
    }

    /// Applies the fields present in `update` to `ekReminder`, saves, and maps.
    private func applyAndSave(_ update: ReminderUpdate, to ekReminder: EKReminder) throws -> ReminderItem {
        if let title = update.title {
            ekReminder.title = title
        }
        if let notes = update.notes {
            ekReminder.notes = notes
        }
        if let priority = update.priority {
            ekReminder.priority = priority.eventKitValue
        }
        if let newListName = update.listName {
            ekReminder.calendar = try resolveCalendar(named: newListName)
        }
        if let isCompleted = update.isCompleted {
            ekReminder.isCompleted = isCompleted
            ekReminder.completionDate = isCompleted ? Date() : nil
        }
        if let dueDateChange = update.dueDate {
            // Alarms track the due date; clear stale ones on any due-date change.
            for alarm in ekReminder.alarms ?? [] {
                ekReminder.removeAlarm(alarm)
            }
            if let newDate = dueDateChange {
                ekReminder.dueDateComponents = calendarComponents(from: newDate)
                let hour = calendar.component(.hour, from: newDate)
                let minute = calendar.component(.minute, from: newDate)
                if hour != 0 || minute != 0 {
                    ekReminder.addAlarm(EKAlarm(absoluteDate: newDate))
                }
            } else {
                ekReminder.dueDateComponents = nil
            }
        }

        do {
            try backend.saveReminder(ekReminder, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to update reminder: \(error.localizedDescription)"
            )
        }

        return mapReminder(ekReminder)
    }

    /// Snapshots the reminder, removes it, and returns the snapshot.
    private func removeAndSnapshot(_ ekReminder: EKReminder) throws -> ReminderItem {
        // Snapshot before removal: EventKit invalidates the object once it is deleted.
        let deleted = mapReminder(ekReminder)

        do {
            try backend.removeReminder(ekReminder, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to delete reminder \"\(deleted.title)\": \(error.localizedDescription)"
            )
        }

        return deleted
    }

    // MARK: - By-ID Operations (REST surface)

    /// Fetches a single reminder by identifier, searching every list.
    public func reminder(byID id: String) async throws -> ReminderItem {
        let ekReminder = try await fetchEKReminder(byID: id)
        return mapReminder(ekReminder)
    }

    /// Applies a partial update to the reminder with the given identifier.
    public func update(byID id: String, with update: ReminderUpdate) async throws -> ReminderItem {
        let ekReminder = try await fetchEKReminder(byID: id)
        return try applyAndSave(update, to: ekReminder)
    }

    /// Marks the reminder with the given identifier complete or incomplete.
    public func setCompleted(byID id: String, completed: Bool) async throws -> ReminderItem {
        let ekReminder = try await fetchEKReminder(byID: id)
        return try applyCompletion(completed, to: ekReminder)
    }

    /// Deletes the reminder with the given identifier and returns its snapshot.
    public func delete(byID id: String) async throws -> ReminderItem {
        let ekReminder = try await fetchEKReminder(byID: id)
        return try removeAndSnapshot(ekReminder)
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
        let allCalendars = backend.reminderCalendars()
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

        guard let matchIndex = reminders.firstIndex(where: {
            reminderMatches($0, identifier: indexOrID)
        }) else {
            throw RemindersError.reminderNotFound(indexOrID)
        }
        return (reminders[matchIndex], matchIndex)
    }

    /// Whether `identifier` names this reminder. Accepts either identifier:
    /// mapReminder emits the external identifier when EventKit has assigned
    /// one and the item identifier otherwise, so both must round-trip back
    /// to the same reminder.
    private func reminderMatches(_ reminder: EKReminder, identifier: String) -> Bool {
        reminder.calendarItemExternalIdentifier == identifier
            || reminder.calendarItemIdentifier == identifier
    }

    /// Fetches a reminder by identifier across all lists, completed included.
    ///
    /// Identifiers only: unlike index resolution, a purely numeric string here
    /// is an identifier that matches nothing, never a position. REST ids must
    /// not alias list indexes.
    private func fetchEKReminder(byID id: String) async throws -> EKReminder {
        let all = try await fetchFilteredEKReminders(
            on: nil,
            includeCompleted: true,
            onlyCompleted: false
        )
        guard let match = all.first(where: { reminderMatches($0, identifier: id) }) else {
            throw RemindersError.reminderNotFound(id)
        }
        return match
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
            // External identifiers are only assigned once EventKit persists the
            // object; fall back to the creation-time item identifier so unsaved
            // reminders (fake backends in tests) still map without crashing.
            id: ekReminder.calendarItemExternalIdentifier ?? ekReminder.calendarItemIdentifier,
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

    /// Fetches all reminders matching the given predicate.
    ///
    /// Wraps the completion-based backend fetch in a checked continuation since
    /// EventKit has no native async overload. The `UncheckedTransfer` wrapper is
    /// needed because `EKReminder` is not `Sendable`, but the actor boundary
    /// guarantees exclusive access after the continuation resumes.
    private func fetchReminders(matching predicate: NSPredicate) async throws -> [EKReminder] {
        let backend = self.backend
        let transfer = await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedTransfer<[EKReminder]>, Never>) in
            backend.fetchReminders(matching: predicate) { reminders in
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
    /// Completion filtering is delegated to EventKit via the appropriate predicate;
    /// no in-memory filtering is performed after the fetch.
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
        let predicate: NSPredicate
        if onlyCompleted {
            predicate = backend.completedRemindersPredicate(in: calendars)
        } else if !includeCompleted {
            predicate = backend.incompleteRemindersPredicate(in: calendars)
        } else {
            predicate = backend.remindersPredicate(in: calendars)
        }
        return try await fetchReminders(matching: predicate)
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
