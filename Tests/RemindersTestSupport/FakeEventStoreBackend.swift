// ABOUTME: In-memory EventStoreBackend fake shared by both test targets.
// ABOUTME: Creates real (unsaved) EKCalendar/EKReminder objects, so no TCC is needed.

import EventKit
import Foundation
import RemindersCore

/// In-memory stand-in for EventKit. Holds a real `EKEventStore` purely as an
/// object factory: creating `EKCalendar`/`EKReminder` instances never touches
/// TCC (only fetching and saving do).
///
/// `@unchecked Sendable` is justified because every access to mutable state
/// goes through `lock`.
public final class FakeEventStoreBackend: EventStoreBackend, @unchecked Sendable {

    private let lock = NSLock()
    private let factory = EKEventStore()

    private var _calendars: [EKCalendar] = []
    private var _reminders: [EKReminder] = []
    private var _authorizationStatus: EKAuthorizationStatus = .fullAccess
    private var _accessRequestResult = true
    private var _accessRequestCount = 0
    private var _savedReminders: [EKReminder] = []
    private var _removedReminders: [EKReminder] = []
    private var _lastRequestedCalendars: [EKCalendar]??
    private var _refreshCount = 0

    public init() {}

    // MARK: - Test configuration

    /// The status `reminderAuthorizationStatus()` reports. Defaults to `.fullAccess`.
    public var authorizationStatus: EKAuthorizationStatus {
        get { lock.withLock { _authorizationStatus } }
        set { lock.withLock { _authorizationStatus = newValue } }
    }

    /// What `requestReminderAccess()` returns. Defaults to `true`.
    public var accessRequestResult: Bool {
        get { lock.withLock { _accessRequestResult } }
        set { lock.withLock { _accessRequestResult = newValue } }
    }

    // MARK: - Test inspection

    /// How many times `requestReminderAccess()` was called.
    public var accessRequestCount: Int { lock.withLock { _accessRequestCount } }
    /// Every reminder passed to `saveReminder`, in call order.
    public var savedReminders: [EKReminder] { lock.withLock { _savedReminders } }
    /// Every reminder passed to `removeReminder`, in call order.
    public var removedReminders: [EKReminder] { lock.withLock { _removedReminders } }
    /// How many times `refreshSourcesIfNecessary()` was called.
    public var refreshCount: Int { lock.withLock { _refreshCount } }
    /// All reminders currently stored (post save/remove).
    public var currentReminders: [EKReminder] { lock.withLock { _reminders } }

    // MARK: - Seeding

    /// Adds a reminder list and returns its calendar.
    @discardableResult
    public func addCalendar(named title: String) -> EKCalendar {
        let calendar = EKCalendar(for: .reminder, eventStore: factory)
        calendar.title = title
        lock.withLock { _calendars.append(calendar) }
        return calendar
    }

    /// Adds a reminder to a previously added calendar and returns it.
    @discardableResult
    public func addReminder(
        title: String,
        in calendar: EKCalendar,
        isCompleted: Bool = false,
        notes: String? = nil,
        priority: Int = 0,
        dueDateComponents: DateComponents? = nil
    ) -> EKReminder {
        let reminder = EKReminder(eventStore: factory)
        reminder.title = title
        reminder.calendar = calendar
        reminder.notes = notes
        reminder.priority = priority
        reminder.dueDateComponents = dueDateComponents
        // Setting isCompleted also sets/clears completionDate (EventKit behavior).
        reminder.isCompleted = isCompleted
        lock.withLock { _reminders.append(reminder) }
        return reminder
    }

    // MARK: - EventStoreBackend

    public func reminderAuthorizationStatus() -> EKAuthorizationStatus {
        lock.withLock { _authorizationStatus }
    }

    public func requestReminderAccess() async throws -> Bool {
        lock.withLock {
            _accessRequestCount += 1
            return _accessRequestResult
        }
    }

    public func reminderCalendars() -> [EKCalendar] {
        lock.withLock { _calendars }
    }

    public func defaultReminderCalendar() -> EKCalendar? {
        lock.withLock { _calendars.first }
    }

    public var allSources: [EKSource] { [] }

    public func makeCalendar() -> EKCalendar {
        EKCalendar(for: .reminder, eventStore: factory)
    }

    public func makeReminder() -> EKReminder {
        EKReminder(eventStore: factory)
    }

    public func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        lock.withLock { _calendars.append(calendar) }
    }

    public func saveReminder(_ reminder: EKReminder, commit: Bool) throws {
        lock.withLock {
            _savedReminders.append(reminder)
            if !_reminders.contains(where: { $0 === reminder }) {
                _reminders.append(reminder)
            }
        }
    }

    public func removeReminder(_ reminder: EKReminder, commit: Bool) throws {
        lock.withLock {
            _removedReminders.append(reminder)
            _reminders.removeAll { $0 === reminder }
        }
    }

    /// Records `calendars` in `_lastRequestedCalendars` so that the paired
    /// `fetchReminders(matching:completion:)` call knows which scope to apply,
    /// then returns an opaque `NSPredicate` placeholder.
    ///
    /// **Pairing contract:** EventKit's real predicate is opaque — its calendar
    /// scope cannot be recovered once constructed. This fake mirrors that design:
    /// calling `remindersPredicate(in:)` is the *only* way to establish the
    /// calendar scope for the next fetch. Callers **must** invoke
    /// `remindersPredicate(in:)` (or a completed/incomplete variant) immediately
    /// before each `fetchReminders` call. Calling `fetchReminders` without a
    /// prior predicate call returns all reminders (scope is treated as "all").
    public func remindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate {
        lock.withLock { _lastRequestedCalendars = calendars }
        return NSPredicate(value: true)
    }

    /// Filters the in-memory reminders by the scope recorded during the most
    /// recent `remindersPredicate(in:)` call and delivers the result to
    /// `completion`.
    ///
    /// **Pairing contract:** The `predicate` argument is ignored — it is an
    /// opaque `NSPredicate` whose calendar scope cannot be introspected. Instead,
    /// this method reads `_lastRequestedCalendars`, which is written by
    /// `remindersPredicate(in:)`. Callers **must** build a predicate via
    /// `remindersPredicate(in:)` (or a completed/incomplete variant) immediately
    /// before each fetch. If no predicate was built first, `_lastRequestedCalendars`
    /// is `nil` (outer optional absent) and this method returns all reminders.
    public func fetchReminders(
        matching predicate: NSPredicate,
        completion: @escaping @Sendable ([EKReminder]?) -> Void
    ) {
        let snapshot: [EKReminder] = lock.withLock {
            guard let scope = _lastRequestedCalendars else { return _reminders }
            guard let calendars = scope else { return _reminders }
            return _reminders.filter { reminder in
                calendars.contains { $0 === reminder.calendar }
            }
        }
        completion(snapshot)
    }

    public func refreshSourcesIfNecessary() {
        lock.withLock { _refreshCount += 1 }
    }
}
