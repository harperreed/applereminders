// ABOUTME: Seam between RemindersStore and EventKit for testability.
// ABOUTME: EventKitBackend forwards to a real EKEventStore; tests substitute a fake.

import EventKit
import Foundation

/// The EventKit operations RemindersStore depends on, extracted so tests can
/// substitute an in-memory fake and avoid TCC entirely.
///
/// Conformers must be safe to call from any isolation domain (`Sendable`).
/// The production conformer wraps `EKEventStore`, which Apple documents as
/// thread-safe (the store; not the calendar-item objects it vends).
public protocol EventStoreBackend: Sendable {
    /// The current Reminders authorization status for this process.
    func reminderAuthorizationStatus() -> EKAuthorizationStatus
    /// Prompts for full Reminders access. Returns `true` when granted.
    func requestReminderAccess() async throws -> Bool
    /// All reminder calendars (lists).
    func reminderCalendars() -> [EKCalendar]
    /// The default calendar for new reminders, if configured.
    func defaultReminderCalendar() -> EKCalendar?
    /// All account sources (iCloud, Local, ...).
    var allSources: [EKSource] { get }
    /// Creates an unsaved reminder calendar bound to this backend's store.
    func makeCalendar() -> EKCalendar
    /// Creates an unsaved reminder bound to this backend's store.
    func makeReminder() -> EKReminder
    /// Persists a calendar.
    func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws
    /// Persists a reminder.
    func saveReminder(_ reminder: EKReminder, commit: Bool) throws
    /// Deletes a reminder.
    func removeReminder(_ reminder: EKReminder, commit: Bool) throws
    /// Predicate matching every reminder in the given calendars (nil = all calendars).
    func remindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate
    /// Predicate matching only incomplete reminders in the given calendars.
    func incompleteRemindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate
    /// Predicate matching only completed reminders in the given calendars.
    func completedRemindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate
    /// Runs a reminder fetch. The completion may be invoked on any thread.
    func fetchReminders(
        matching predicate: NSPredicate,
        completion: @escaping @Sendable ([EKReminder]?) -> Void
    )
    /// Refreshes sources after an external change notification.
    func refreshSourcesIfNecessary()
}

/// Production backend: thin forwarding wrapper around one `EKEventStore`.
///
/// `@unchecked Sendable` is justified because the wrapper holds no mutable
/// state and `EKEventStore` itself is documented thread-safe. The calendar
/// item objects it returns are NOT thread-safe; RemindersStore confines them
/// to its actor (see `UncheckedTransfer` at the fetch continuation).
final class EventKitBackend: EventStoreBackend, @unchecked Sendable {
    private let store = EKEventStore()

    func reminderAuthorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    func requestReminderAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    func reminderCalendars() -> [EKCalendar] {
        store.calendars(for: .reminder)
    }

    func defaultReminderCalendar() -> EKCalendar? {
        store.defaultCalendarForNewReminders()
    }

    var allSources: [EKSource] {
        store.sources
    }

    func makeCalendar() -> EKCalendar {
        EKCalendar(for: .reminder, eventStore: store)
    }

    func makeReminder() -> EKReminder {
        EKReminder(eventStore: store)
    }

    func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        try store.saveCalendar(calendar, commit: commit)
    }

    func saveReminder(_ reminder: EKReminder, commit: Bool) throws {
        try store.save(reminder, commit: commit)
    }

    func removeReminder(_ reminder: EKReminder, commit: Bool) throws {
        try store.remove(reminder, commit: commit)
    }

    func remindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate {
        store.predicateForReminders(in: calendars)
    }

    func incompleteRemindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate {
        store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
    }

    func completedRemindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate {
        store.predicateForCompletedReminders(
            withCompletionDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
    }

    func fetchReminders(
        matching predicate: NSPredicate,
        completion: @escaping @Sendable ([EKReminder]?) -> Void
    ) {
        _ = store.fetchReminders(matching: predicate, completion: completion)
    }

    func refreshSourcesIfNecessary() {
        store.refreshSourcesIfNecessary()
    }
}
