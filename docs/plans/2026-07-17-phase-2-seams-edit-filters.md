# Phase 2: Testability Seams, Edit Surface, and Due-Date Filters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make RemindersStore and MCPServer testable without TCC grants, wire the dormant `ReminderUpdate` type into the CLI and MCP edit surfaces, add due-date window filters to the MCP show tools, and fetch with completion-status predicates instead of filtering in memory.

**Architecture:** One seam at the EventKit boundary (`EventStoreBackend` protocol; production `EventKitBackend` wraps `EKEventStore`, tests use `FakeEventStoreBackend` from a new shared `RemindersTestSupport` target) and one at the wire boundary (MCPServer takes an injectable line stream and output writer). Everything else builds on those seams: store-level unit tests, protocol-level MCP e2e tests, then the feature work (edit surface, filters, predicates) lands test-first against the fakes.

**Tech Stack:** Swift 6 (strict concurrency, actors), EventKit, swift-argument-parser, swift-testing (`@Suite`/`@Test`/`#expect`), JSON-RPC 2.0 over stdio.

## Global Constraints

- Swift 6 language mode, strict concurrency. Zero new warnings; `make check` (build + full suite) is the canonical gate and must be green at every task's end.
- Tests use swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `Issue.record`), never XCTest.
- Never write a test that only exercises the fake. The fake is the environment; every assertion must exercise production logic in `RemindersStore`, `MCPServer`, or the commands.
- `ArgumentHelp` gotcha: a string concatenation (`"a" + "b"`) is not implicitly convertible to `ArgumentHelp`. Wrap concatenated help strings in an explicit `ArgumentHelp("a" + "b")`.
- Every error message that rejects a date string must reference the shared `supportedDateFormats` constant (single source of truth, defined in `Sources/RemindersCLI/DateParsing.swift`).
- MCP invariants: every response is a single line of JSON on stdout; stderr carries only diagnostics; tool failures are returned as `MCPToolResult.error(...)` (`isError: true`), never as JSON-RPC protocol errors.
- New source files start with two `// ABOUTME:` comment lines describing the file. Public API in RemindersCore gets `///` doc comments matching the existing style.
- Conventional commits, imperative present tense.
- Documentation prose (README, help text): no em dashes (—) or en dashes (–), sentence-case headings, plain voice.
- Never run `tccutil` in any form. The freshness smoke script may prompt for TCC; that is expected on the dev machine.
- Do not add public API beyond what a task names. `EventKitBackend` stays internal; `EventStoreBackend`, the new `RemindersStore` initializer, and `RemindersStore.update` are the only new public RemindersCore API.

## File Structure

```
Sources/RemindersCore/EventStoreBackend.swift       (new: protocol + EventKitBackend)
Sources/RemindersCore/RemindersStore.swift          (rewired onto the backend; update() added; edit() removed)
Sources/RemindersCore/Models.swift                  (unchanged; ReminderUpdate already exists)
Sources/RemindersCLI/MCPServer.swift                (injectable I/O; new tool params + handlers)
Sources/RemindersCLI/DateParsing.swift              (filterByDueDate takes Date?; filterByDueWindow added)
Sources/RemindersCLI/Commands/EditCommand.swift     (new flags: due date, clear, priority, move, include-completed)
Sources/RemindersCLI/Commands/DeleteCommand.swift   (new flag: include-completed)
Sources/RemindersCLI/Commands/ShowCommand.swift     (parses due date once, passes Date?)
Sources/RemindersCLI/Commands/ShowAllCommand.swift  (same)
Sources/RemindersCLI/Main.swift                     (unchanged: MCPServer defaults preserve the call)
Package.swift                                       (new RemindersTestSupport target)
Tests/RemindersTestSupport/FakeEventStoreBackend.swift  (new: shared fake)
Tests/RemindersCoreTests/RemindersStoreTests.swift      (new: TCC-free store tests)
Tests/RemindersCoreTests/ReminderUpdateStoreTests.swift (new: update() semantics)
Tests/RemindersCLITests/MCPServerHarness.swift          (new: run server over arrays of lines)
Tests/RemindersCLITests/MCPServerE2ETests.swift         (new: wire-level tests)
Tests/RemindersCLITests/MCPEditToolTests.swift          (new: edit/delete tool params over the wire)
Tests/RemindersCLITests/MCPDueFilterTests.swift         (new: due_before/due_after over the wire)
Tests/RemindersCLITests/EditCommandValidationTests.swift (new: CLI flag validation)
Tests/RemindersCLITests/DateParsingTests.swift          (modified: filterByDueDate signature; filterByDueWindow)
Tests/RemindersCLITests/ToolDefinitionContentTests.swift (modified: new params/descriptions)
```

---

### Task 1: EventStoreBackend seam

Introduce the protocol, the production `EventKitBackend`, and rewire `RemindersStore` onto it. Pure refactor plus two deliberate robustness fixes called out below. No test target changes yet; the gate is the existing suite staying green with zero warnings.

**Files:**
- Create: `Sources/RemindersCore/EventStoreBackend.swift`
- Modify: `Sources/RemindersCore/RemindersStore.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (later tasks rely on these exact names):
  - `public protocol EventStoreBackend: Sendable` with the members listed below.
  - `public init(backend: any EventStoreBackend, calendar: Calendar = .current)` on `RemindersStore`.
  - Internal `final class EventKitBackend: EventStoreBackend`.

**Robustness fixes (required, with comments):** `mapReminder` currently passes the implicitly unwrapped `calendarItemExternalIdentifier` straight into `ReminderItem(id:)`, which crashes for unsaved reminders (the kind a fake backend returns) because the external identifier is only guaranteed after a save. Fall back to `calendarItemIdentifier`, which is set at creation. `resolveReminder` likewise only matches the external identifier; accept either identifier so ids produced by `mapReminder` always round-trip.

- [ ] **Step 1: Create the protocol and production backend**

Create `Sources/RemindersCore/EventStoreBackend.swift`:

```swift
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
```

Note: if the compiler reports that `_ = store.fetchReminders(...)` has no discardable result to discard, drop the `_ =`. Match whatever compiles warning-free.

- [ ] **Step 2: Rewire RemindersStore**

In `Sources/RemindersCore/RemindersStore.swift`:

Replace the property and initializer block:

```swift
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
```

`requestAccess()` body becomes (the `UncheckedTransfer` dance is no longer needed because the backend is `Sendable`):

```swift
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
```

`startObservingExternalChanges()` body becomes (keep the existing doc comment except its `UncheckedTransfer` sentence; reword that sentence to say the closure captures only the `Sendable` backend, not `self`):

```swift
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
```

Mechanical replacements through the rest of the file:
- `eventStore.calendars(for: .reminder)` → `backend.reminderCalendars()` (two sites: `lists()` and `resolveCalendar(named:)`)
- `eventStore.defaultCalendarForNewReminders()?.title` → `backend.defaultReminderCalendar()?.title`
- `eventStore.defaultCalendarForNewReminders()?.source` → `backend.defaultReminderCalendar()?.source`
- `EKCalendar(for: .reminder, eventStore: eventStore)` → `backend.makeCalendar()`
- `eventStore.sources` → `backend.allSources`
- `try eventStore.saveCalendar(newCalendar, commit: true)` → `try backend.saveCalendar(newCalendar, commit: true)`
- `EKReminder(eventStore: eventStore)` → `backend.makeReminder()`
- `try eventStore.save(ekReminder, commit: true)` → `try backend.saveReminder(ekReminder, commit: true)` (three sites: add, setComplete, edit)
- `try eventStore.remove(ekReminder, commit: true)` → `try backend.removeReminder(ekReminder, commit: true)`

Replace `fetchReminders(on:)` with:

```swift
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
```

and update `fetchFilteredEKReminders` to build the predicate first:

```swift
        let allReminders = try await fetchReminders(matching: backend.remindersPredicate(in: calendars))
```

(the completion-status filtering below that line stays exactly as it is; Task 10 replaces it).

In `mapReminder`, replace the `id:` argument with a commented fallback:

```swift
        return ReminderItem(
            // External identifiers are only assigned once EventKit persists the
            // object; fall back to the creation-time item identifier so unsaved
            // reminders (fake backends in tests) still map without crashing.
            id: ekReminder.calendarItemExternalIdentifier ?? ekReminder.calendarItemIdentifier,
            title: ekReminder.title ?? "",
```

In `resolveReminder(from:at:)`, replace the external-identifier match with:

```swift
        // Accept either identifier: mapReminder emits the external identifier
        // when EventKit has assigned one and the item identifier otherwise, so
        // both must round-trip back to the same reminder.
        guard let matchIndex = reminders.firstIndex(where: {
            $0.calendarItemExternalIdentifier == indexOrID
                || $0.calendarItemIdentifier == indexOrID
        }) else {
            throw RemindersError.reminderNotFound(indexOrID)
        }
```

- [ ] **Step 3: Verify the existing suite is green with zero warnings**

Run: `make check`
Expected: build succeeds with no warnings; all 101 existing tests pass. (This refactor adds no tests; Task 2 adds the ones that exercise the seam.)

- [ ] **Step 4: Commit**

```bash
git add Sources/RemindersCore/EventStoreBackend.swift Sources/RemindersCore/RemindersStore.swift
git commit -m "refactor: seam RemindersStore behind EventStoreBackend protocol"
```

---

### Task 2: RemindersTestSupport target, fake backend, and TCC-free store tests

**Files:**
- Modify: `Package.swift`
- Create: `Tests/RemindersTestSupport/FakeEventStoreBackend.swift`
- Create: `Tests/RemindersCoreTests/RemindersStoreTests.swift`

**Interfaces:**
- Consumes: `EventStoreBackend`, `RemindersStore.init(backend:calendar:)` from Task 1.
- Produces: `public final class FakeEventStoreBackend` with the seeding and inspection API below. Tasks 3-10 build every test on it.

- [ ] **Step 1: Add the shared test-support target**

In `Package.swift`, add to `targets:` (after the `reminders` executable target):

```swift
        .target(
            name: "RemindersTestSupport",
            dependencies: ["RemindersCore"],
            path: "Tests/RemindersTestSupport"
        ),
```

and add `"RemindersTestSupport"` to the dependencies of BOTH test targets:

```swift
        .testTarget(
            name: "RemindersCoreTests",
            dependencies: ["RemindersCore", "RemindersTestSupport"]
        ),
        .testTarget(
            name: "RemindersCLITests",
            dependencies: ["reminders", "RemindersTestSupport"]
        ),
```

- [ ] **Step 2: Write the fake backend**

Create `Tests/RemindersTestSupport/FakeEventStoreBackend.swift`:

```swift
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

    public func remindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate {
        lock.withLock { _lastRequestedCalendars = calendars }
        return NSPredicate(value: true)
    }

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
```

- [ ] **Step 3: Write the store tests**

These are characterization tests against the Task 1 seam, which is already built, so they should pass on the first run (no red phase in this task).

Create `Tests/RemindersCoreTests/RemindersStoreTests.swift`:

```swift
// ABOUTME: TCC-free unit tests for RemindersStore over FakeEventStoreBackend.
// ABOUTME: Covers auth, listing, adding, resolution by index and id, completion, and deletion.

import EventKit
import Foundation
import RemindersCore
import RemindersTestSupport
import Testing

@Suite("RemindersStore over a fake backend")
struct RemindersStoreTests {

    // MARK: Authorization

    @Test("requestAccess passes through when already authorized")
    func accessAlreadyAuthorized() async throws {
        let backend = FakeEventStoreBackend()
        backend.authorizationStatus = .fullAccess
        let store = RemindersStore(backend: backend)
        try await store.requestAccess()
        #expect(backend.accessRequestCount == 0)
    }

    @Test("requestAccess throws accessDenied when denied")
    func accessDenied() async {
        let backend = FakeEventStoreBackend()
        backend.authorizationStatus = .denied
        let store = RemindersStore(backend: backend)
        do {
            try await store.requestAccess()
            Issue.record("Expected accessDenied")
        } catch let error as RemindersError {
            guard case .accessDenied = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("requestAccess throws writeOnlyAccess for write-only grants")
    func accessWriteOnly() async {
        let backend = FakeEventStoreBackend()
        backend.authorizationStatus = .writeOnly
        let store = RemindersStore(backend: backend)
        do {
            try await store.requestAccess()
            Issue.record("Expected writeOnlyAccess")
        } catch let error as RemindersError {
            guard case .writeOnlyAccess = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("requestAccess prompts when not determined and honors a denial")
    func accessPromptDenied() async {
        let backend = FakeEventStoreBackend()
        backend.authorizationStatus = .notDetermined
        backend.accessRequestResult = false
        let store = RemindersStore(backend: backend)
        do {
            try await store.requestAccess()
            Issue.record("Expected accessDenied")
        } catch let error as RemindersError {
            guard case .accessDenied = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(backend.accessRequestCount == 1)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: Lists

    @Test("lists maps calendars to ReminderList")
    func listsMapping() async {
        let backend = FakeEventStoreBackend()
        backend.addCalendar(named: "Groceries")
        backend.addCalendar(named: "Work")
        let store = RemindersStore(backend: backend)
        let lists = await store.lists()
        #expect(lists.map(\.title) == ["Groceries", "Work"])
        #expect(lists.allSatisfy { !$0.id.isEmpty })
    }

    @Test("unknown list throws listNotFound naming the available lists")
    func unknownList() async {
        let backend = FakeEventStoreBackend()
        backend.addCalendar(named: "Groceries")
        let store = RemindersStore(backend: backend)
        do {
            _ = try await store.reminders(inList: "Nope")
            Issue.record("Expected listNotFound")
        } catch let error as RemindersError {
            guard case .listNotFound(let detail) = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(detail.contains("Groceries"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: Fetching

    @Test("reminders excludes completed by default")
    func remindersExcludesCompleted() async throws {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "done", in: cal, isCompleted: true)
        backend.addReminder(title: "open", in: cal)
        let store = RemindersStore(backend: backend)
        let items = try await store.reminders(inList: "Inbox", includeCompleted: false)
        #expect(items.map(\.title) == ["open"])
    }

    @Test("reminders maps fields onto ReminderItem")
    func reminderMapping() async throws {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(
            title: "call mom",
            in: cal,
            notes: "about the trip",
            priority: 1,
            dueDateComponents: DateComponents(year: 2026, month: 8, day: 1)
        )
        let store = RemindersStore(backend: backend)
        let items = try await store.reminders(inList: "Inbox")
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.title == "call mom")
        #expect(item.notes == "about the trip")
        #expect(item.priority == .high)
        #expect(item.listName == "Inbox")
        #expect(!item.id.isEmpty)
        #expect(item.dueDate != nil)
    }

    // MARK: Adding

    @Test("addReminder saves and maps the new reminder")
    func addReminder() async throws {
        let backend = FakeEventStoreBackend()
        backend.addCalendar(named: "Inbox")
        let store = RemindersStore(backend: backend)
        let draft = ReminderDraft(title: "buy milk", notes: "oat", priority: .medium)
        let created = try await store.addReminder(draft, toList: "Inbox")
        #expect(created.title == "buy milk")
        #expect(created.notes == "oat")
        #expect(created.priority == .medium)
        #expect(backend.savedReminders.count == 1)
    }

    @Test("addReminder with a timed due date attaches an alarm")
    func addReminderAlarm() async throws {
        let backend = FakeEventStoreBackend()
        backend.addCalendar(named: "Inbox")
        let store = RemindersStore(backend: backend)
        var components = DateComponents(year: 2026, month: 8, day: 1, hour: 9, minute: 30)
        components.calendar = Calendar.current
        let date = try #require(components.date)
        let draft = ReminderDraft(title: "standup", dueDate: date)
        _ = try await store.addReminder(draft, toList: "Inbox")
        let saved = try #require(backend.savedReminders.first)
        #expect(saved.alarms?.count == 1)
    }

    @Test("addReminder at midnight attaches no alarm")
    func addReminderNoAlarm() async throws {
        let backend = FakeEventStoreBackend()
        backend.addCalendar(named: "Inbox")
        let store = RemindersStore(backend: backend)
        var components = DateComponents(year: 2026, month: 8, day: 1)
        components.calendar = Calendar.current
        let date = try #require(components.date)
        let draft = ReminderDraft(title: "someday", dueDate: date)
        _ = try await store.addReminder(draft, toList: "Inbox")
        let saved = try #require(backend.savedReminders.first)
        #expect(saved.alarms == nil || saved.alarms?.isEmpty == true)
    }

    // MARK: Index and id resolution (regression for the 6bd33e3 index-mismatch fix)

    @Test("setComplete index counts the incomplete view only")
    func completeIndexCountsIncompleteView() async throws {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "already done", in: cal, isCompleted: true)
        backend.addReminder(title: "first open", in: cal)
        backend.addReminder(title: "second open", in: cal)
        let store = RemindersStore(backend: backend)
        let completed = try await store.setComplete(true, itemAtIndex: "0", onList: "Inbox")
        #expect(completed.title == "first open")
    }

    @Test("uncomplete resolves indexes against the completed view")
    func uncompleteIndexCountsCompletedView() async throws {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "open", in: cal)
        backend.addReminder(title: "done", in: cal, isCompleted: true)
        let store = RemindersStore(backend: backend)
        let reopened = try await store.setComplete(
            false, itemAtIndex: "0", onList: "Inbox", onlyCompleted: true
        )
        #expect(reopened.title == "done")
        #expect(reopened.isCompleted == false)
    }

    @Test("a mapped id round-trips back to the same reminder")
    func idRoundTrip() async throws {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "target", in: cal)
        backend.addReminder(title: "decoy", in: cal)
        let store = RemindersStore(backend: backend)
        let items = try await store.reminders(inList: "Inbox")
        let targetID = try #require(items.first(where: { $0.title == "target" })?.id)
        let completed = try await store.setComplete(true, itemAtIndex: targetID, onList: "Inbox")
        #expect(completed.title == "target")
    }

    @Test("out-of-range index names the valid range")
    func indexOutOfRange() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "only", in: cal)
        let store = RemindersStore(backend: backend)
        do {
            _ = try await store.setComplete(true, itemAtIndex: "5", onList: "Inbox")
            Issue.record("Expected reminderNotFound")
        } catch let error as RemindersError {
            guard case .reminderNotFound(let detail) = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(detail.contains("valid range"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: Deleting

    @Test("delete returns the snapshot and removes the reminder")
    func deleteReturnsSnapshot() async throws {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "victim", in: cal, notes: "so long")
        let store = RemindersStore(backend: backend)
        let deleted = try await store.delete(itemAtIndex: "0", onList: "Inbox")
        #expect(deleted.title == "victim")
        #expect(deleted.notes == "so long")
        #expect(backend.removedReminders.count == 1)
        #expect(backend.currentReminders.isEmpty)
    }
}
```

- [ ] **Step 4: Run the new suite, expect green**

Run: `swift test --filter RemindersStoreTests`
Expected: PASS. If `reminderMapping`'s `dueDate != nil` fails, the fake seeded components without a calendar; that assertion depends on `RemindersStore.mapReminder` using its own `calendar.date(from:)`, which handles plain year/month/day components. Investigate rather than weaken the assertion.

- [ ] **Step 5: Full check and commit**

Run: `make check` (zero warnings, everything green), then:

```bash
git add Package.swift Tests/RemindersTestSupport/FakeEventStoreBackend.swift Tests/RemindersCoreTests/RemindersStoreTests.swift
git commit -m "test: add RemindersTestSupport fake backend and TCC-free store tests"
```

---

### Task 3: Injectable MCPServer I/O

**Files:**
- Modify: `Sources/RemindersCLI/MCPServer.swift` (properties, init, `run()`, `writeLine`)
- Create: `Tests/RemindersCLITests/MCPServerHarness.swift`
- Create: `Tests/RemindersCLITests/MCPServerE2ETests.swift` (first test only; Task 4 fills it out)

**Interfaces:**
- Consumes: `RemindersStore.init(backend:)`, `FakeEventStoreBackend`.
- Produces:
  - `MCPServer.init(store:input:output:)` where `input: AsyncThrowingStream<String, Error>? = nil` and `output: (@Sendable (String) -> Void)? = nil` (nil = real stdin/stdout, so `Main.swift` keeps compiling unchanged).
  - Test helper `func runMCPServer(lines: [String], backend: FakeEventStoreBackend) async -> [[String: Any]]`.

- [ ] **Step 1: Add the seam to MCPServer**

In `Sources/RemindersCLI/MCPServer.swift`, replace the property block and `init`:

```swift
    /// Writes one complete response line. Injectable so tests can capture output.
    typealias OutputWriter = @Sendable (String) -> Void

    private let store: RemindersStore
    private let registry: ToolRegistry
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let input: AsyncThrowingStream<String, Error>
    private let output: OutputWriter

    /// - Parameters:
    ///   - store: The reminders store to serve.
    ///   - input: Request lines to process. Defaults to stdin.
    ///   - output: Where response lines go. Defaults to stdout with an immediate flush.
    init(
        store: RemindersStore,
        input: AsyncThrowingStream<String, Error>? = nil,
        output: OutputWriter? = nil
    ) {
        self.store = store
        self.decoder = JSONDecoder()

        // Compact encoder for JSON-RPC protocol messages (single-line).
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]

        self.input = input ?? MCPServer.standardInputLines()
        self.output = output ?? { line in
            print(line)
            fflush(stdout)
        }

        self.registry = MCPServer.buildRegistry(store: store)
    }

    /// Bridges stdin into a line stream without blocking the cooperative pool.
    private static func standardInputLines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    for try await line in FileHandle.standardInput.bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
```

In `run()`, change the loop line from `for try await line in FileHandle.standardInput.bytes.lines {` to `for try await line in input {` and update the method's doc comment to say it reads the injected line stream (stdin by default). Replace `writeLine`:

```swift
    /// Writes a single response line through the injected output.
    private func writeLine(_ line: String) {
        output(line)
    }
```

(dropping `nonisolated` is required: the method now reads actor state. Every caller is already actor-isolated.)

- [ ] **Step 2: Write the harness and a first end-to-end test**

Create `Tests/RemindersCLITests/MCPServerHarness.swift`:

```swift
// ABOUTME: Test harness that runs MCPServer over in-memory request lines.
// ABOUTME: Returns each response line parsed into a JSON dictionary for assertions.

import Foundation
import RemindersCore
import RemindersTestSupport

@testable import reminders

/// Collects output lines across threads.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []

    func append(_ line: String) {
        lock.withLock { _lines.append(line) }
    }

    var lines: [String] { lock.withLock { _lines } }
}

/// Runs a full server session over the given request lines and returns each
/// response parsed as a JSON object, in write order.
func runMCPServer(
    lines requests: [String],
    backend: FakeEventStoreBackend
) async -> [[String: Any]] {
    let store = RemindersStore(backend: backend)
    let collector = OutputCollector()
    let input = AsyncThrowingStream<String, Error> { continuation in
        for request in requests {
            continuation.yield(request)
        }
        continuation.finish()
    }
    let server = MCPServer(store: store, input: input, output: { collector.append($0) })
    await server.run()
    return collector.lines.map { line in
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ["__unparseable__": line]
        }
        return object
    }
}

/// Digs the text of the first content block out of a tools/call response.
func toolText(_ response: [String: Any]) -> String {
    let result = response["result"] as? [String: Any]
    let content = result?["content"] as? [[String: Any]]
    return content?.first?["text"] as? String ?? ""
}

/// Reads the isError flag of a tools/call response (false when absent).
func toolIsError(_ response: [String: Any]) -> Bool {
    let result = response["result"] as? [String: Any]
    return result?["isError"] as? Bool ?? false
}
```

Create `Tests/RemindersCLITests/MCPServerE2ETests.swift`:

```swift
// ABOUTME: Protocol-level end-to-end tests: JSON-RPC lines in, JSON lines out.
// ABOUTME: Uses the fake backend, so no TCC grant is required.

import Foundation
import RemindersTestSupport
import Testing

@testable import reminders

@Suite("MCP server end to end")
struct MCPServerE2ETests {

    @Test("initialize and tools/list round-trip")
    func initializeAndList() async {
        let backend = FakeEventStoreBackend()
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            ],
            backend: backend
        )
        #expect(responses.count == 2)
        let initResult = responses[0]["result"] as? [String: Any]
        #expect(initResult?["protocolVersion"] as? String == "2024-11-05")
        let listResult = responses[1]["result"] as? [String: Any]
        let tools = listResult?["tools"] as? [[String: Any]]
        #expect(tools?.count == 9)
    }
}
```

- [ ] **Step 3: Run the new test, expect green**

Run: `swift test --filter MCPServerE2ETests`
Expected: PASS (both responses arrive; the server exits when the stream finishes).

- [ ] **Step 4: Full check and commit**

Run: `make check`, then:

```bash
git add Sources/RemindersCLI/MCPServer.swift Tests/RemindersCLITests/MCPServerHarness.swift Tests/RemindersCLITests/MCPServerE2ETests.swift
git commit -m "refactor: inject MCPServer input and output streams"
```

---

### Task 4: The e2e test pack the seams were built for

**Files:**
- Modify: `Tests/RemindersCLITests/MCPServerE2ETests.swift` (append tests to the suite)

**Interfaces:**
- Consumes: `runMCPServer(lines:backend:)`, `toolText(_:)`, `toolIsError(_:)`, `FakeEventStoreBackend`.
- Produces: nothing new; locks wire behavior.

- [ ] **Step 1: Append the failing-then-green tests**

Append inside the `MCPServerE2ETests` suite:

```swift
    @Test("show_lists returns seeded lists as JSON text")
    func showLists() async {
        let backend = FakeEventStoreBackend()
        backend.addCalendar(named: "Groceries")
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_lists","arguments":{}}}"#
            ],
            backend: backend
        )
        #expect(responses.count == 1)
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("Groceries"))
    }

    @Test("TCC denial surfaces as an actionable tool error, not EOF")
    func authDenied() async {
        let backend = FakeEventStoreBackend()
        backend.authorizationStatus = .denied
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"show_lists","arguments":{}}}"#
            ],
            backend: backend
        )
        #expect(responses.count == 1)
        #expect(toolIsError(responses[0]) == true)
        #expect(toolText(responses[0]).contains("Grant access in System Settings"))
    }

    @Test("delete_reminder returns the deleted reminder as JSON")
    func deleteReturnsReminder() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "victim", in: cal, notes: "gone soon")
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_reminder","arguments":{"list":"Inbox","index":"0"}}}"#
            ],
            backend: backend
        )
        let text = toolText(responses[0])
        #expect(toolIsError(responses[0]) == false)
        #expect(text.contains("victim"))
        #expect(text.contains("gone soon"))
        #expect(backend.currentReminders.isEmpty)
    }

    @Test("complete_reminder accepts an integer index and counts the incomplete view")
    func completeIntegerIndexCountsIncompleteView() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "already done", in: cal, isCompleted: true)
        backend.addReminder(title: "first open", in: cal)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"complete_reminder","arguments":{"list":"Inbox","index":0}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("first open"))
    }

    @Test("malformed JSON gets a -32700 parse error with null id")
    func parseError() async {
        let backend = FakeEventStoreBackend()
        let responses = await runMCPServer(lines: ["this is not json"], backend: backend)
        #expect(responses.count == 1)
        let error = responses[0]["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32700)
        #expect(responses[0]["id"] is NSNull)
    }

    @Test("unknown method with an id gets -32601")
    func unknownMethod() async {
        let backend = FakeEventStoreBackend()
        let responses = await runMCPServer(
            lines: [#"{"jsonrpc":"2.0","id":3,"method":"bogus/method"}"#],
            backend: backend
        )
        #expect(responses.count == 1)
        let error = responses[0]["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32601)
    }

    @Test("unknown tool name returns a tool error listing tools/list")
    func unknownTool() async {
        let backend = FakeEventStoreBackend()
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == true)
        #expect(toolText(responses[0]).contains("tools/list"))
    }
```

- [ ] **Step 2: Run and verify**

Run: `swift test --filter MCPServerE2ETests`
Expected: PASS, 8 tests. These lock behavior that already exists; if any fail, the test found a real wire bug. Investigate the production code before touching the test.

- [ ] **Step 3: Full check and commit**

Run: `make check`, then:

```bash
git add Tests/RemindersCLITests/MCPServerE2ETests.swift
git commit -m "test: add protocol-level MCP e2e coverage for auth, delete, index, and errors"
```

---

### Task 5: `store.update(with: ReminderUpdate)` replaces `edit`

Wire the dormant `ReminderUpdate` type (Models.swift, already Codable with the double-optional `dueDate`) into the store as the single partial-update path, and delete `edit(itemAtIndex:onList:newText:newNotes:...)`. The two existing `edit` callers are migrated mechanically in this task so the build stays green; Tasks 6 and 7 grow their surfaces.

**Files:**
- Modify: `Sources/RemindersCore/RemindersStore.swift` (add `update`, delete `edit`)
- Modify: `Sources/RemindersCLI/Commands/EditCommand.swift` (call `update`)
- Modify: `Sources/RemindersCLI/MCPServer.swift` (`handleEditReminder` calls `update`)
- Create: `Tests/RemindersCoreTests/ReminderUpdateStoreTests.swift`

**Interfaces:**
- Consumes: `ReminderUpdate` (existing), fake backend.
- Produces (Tasks 6/7 rely on this exact signature):

```swift
public func update(
    itemAtIndex: String,
    onList listName: String,
    with update: ReminderUpdate,
    includeCompleted: Bool = false,
    onlyCompleted: Bool = false
) async throws -> ReminderItem
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/RemindersCoreTests/ReminderUpdateStoreTests.swift`:

```swift
// ABOUTME: Tests RemindersStore.update applying ReminderUpdate field by field.
// ABOUTME: Covers title, notes, priority, due date set/clear with alarms, list moves, and completion targeting.

import EventKit
import Foundation
import RemindersCore
import RemindersTestSupport
import Testing

@Suite("RemindersStore.update")
struct ReminderUpdateStoreTests {

    private func makeStore() -> (FakeEventStoreBackend, EKCalendar, RemindersStore) {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        return (backend, cal, RemindersStore(backend: backend))
    }

    @Test("updates title and notes, leaves omitted fields alone")
    func titleAndNotes() async throws {
        let (backend, cal, store) = makeStore()
        backend.addReminder(title: "old", in: cal, notes: "keep?", priority: 5)
        let updated = try await store.update(
            itemAtIndex: "0",
            onList: "Inbox",
            with: ReminderUpdate(title: "new title")
        )
        #expect(updated.title == "new title")
        #expect(updated.notes == "keep?")
        #expect(updated.priority == .medium)
    }

    @Test("sets priority")
    func priority() async throws {
        let (backend, cal, store) = makeStore()
        backend.addReminder(title: "task", in: cal)
        let updated = try await store.update(
            itemAtIndex: "0",
            onList: "Inbox",
            with: ReminderUpdate(priority: .high)
        )
        #expect(updated.priority == .high)
    }

    @Test("setting a timed due date attaches an alarm")
    func setTimedDueDate() async throws {
        let (backend, cal, store) = makeStore()
        backend.addReminder(title: "task", in: cal)
        var components = DateComponents(year: 2026, month: 9, day: 1, hour: 14, minute: 0)
        components.calendar = Calendar.current
        let date = try #require(components.date)
        let updated = try await store.update(
            itemAtIndex: "0",
            onList: "Inbox",
            with: ReminderUpdate(dueDate: .some(date))
        )
        #expect(updated.dueDate != nil)
        let saved = try #require(backend.savedReminders.first)
        #expect(saved.alarms?.count == 1)
    }

    @Test("clearing the due date removes it and its alarms")
    func clearDueDate() async throws {
        let (backend, cal, store) = makeStore()
        let reminder = backend.addReminder(
            title: "task",
            in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 9, day: 1, hour: 8, minute: 0)
        )
        reminder.addAlarm(EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_000_000)))
        let updated = try await store.update(
            itemAtIndex: "0",
            onList: "Inbox",
            with: ReminderUpdate(dueDate: .some(nil))
        )
        #expect(updated.dueDate == nil)
        let saved = try #require(backend.savedReminders.first)
        #expect(saved.alarms == nil || saved.alarms?.isEmpty == true)
    }

    @Test("replacing a due date replaces the alarm instead of stacking")
    func replaceDueDateReplacesAlarm() async throws {
        let (backend, cal, store) = makeStore()
        let reminder = backend.addReminder(
            title: "task",
            in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 9, day: 1, hour: 8, minute: 0)
        )
        reminder.addAlarm(EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_000_000)))
        var components = DateComponents(year: 2026, month: 9, day: 2, hour: 9, minute: 15)
        components.calendar = Calendar.current
        let date = try #require(components.date)
        _ = try await store.update(
            itemAtIndex: "0",
            onList: "Inbox",
            with: ReminderUpdate(dueDate: .some(date))
        )
        let saved = try #require(backend.savedReminders.first)
        #expect(saved.alarms?.count == 1)
    }

    @Test("moves the reminder to another list")
    func moveList() async throws {
        let (backend, cal, store) = makeStore()
        backend.addCalendar(named: "Archive")
        backend.addReminder(title: "task", in: cal)
        let updated = try await store.update(
            itemAtIndex: "0",
            onList: "Inbox",
            with: ReminderUpdate(listName: "Archive")
        )
        #expect(updated.listName == "Archive")
    }

    @Test("moving to an unknown list throws listNotFound")
    func moveUnknownList() async {
        let (backend, cal, store) = makeStore()
        backend.addReminder(title: "task", in: cal)
        do {
            _ = try await store.update(
                itemAtIndex: "0",
                onList: "Inbox",
                with: ReminderUpdate(listName: "Nowhere")
            )
            Issue.record("Expected listNotFound")
        } catch let error as RemindersError {
            guard case .listNotFound = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("includeCompleted lets update target a completed reminder")
    func updateCompletedReminder() async throws {
        let (backend, cal, store) = makeStore()
        backend.addReminder(title: "done", in: cal, isCompleted: true)
        let updated = try await store.update(
            itemAtIndex: "0",
            onList: "Inbox",
            with: ReminderUpdate(title: "done, renamed"),
            includeCompleted: true
        )
        #expect(updated.title == "done, renamed")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ReminderUpdateStoreTests`
Expected: FAIL to compile ("value of type 'RemindersStore' has no member 'update'").

- [ ] **Step 3: Implement `update` and delete `edit`**

In `Sources/RemindersCore/RemindersStore.swift`, replace the entire `// MARK: - Editing Reminders` section (the `edit` method) with:

```swift
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
```

Migrate the two callers mechanically (surface unchanged until Tasks 6/7):

`Sources/RemindersCLI/Commands/EditCommand.swift` `run()` body:

```swift
        await withGracefulErrors {
            let store = try await makeStore()

            let titleText: String? = newText.isEmpty ? nil : newText.joined(separator: " ")

            let updated = try await store.update(
                itemAtIndex: index,
                onList: listName,
                with: ReminderUpdate(title: titleText, notes: notes)
            )
            print("Edited: \(Formatter.format(updated))")
        }
```

`Sources/RemindersCLI/MCPServer.swift` `handleEditReminder`, replace the `store.edit(...)` call:

```swift
            let updated = try await store.update(
                itemAtIndex: index,
                onList: listName,
                with: ReminderUpdate(title: newTitle, notes: newNotes)
            )
```

- [ ] **Step 4: Run the suite**

Run: `swift test --filter ReminderUpdateStoreTests` (PASS, 8 tests), then `make check` (everything green, zero warnings, no lingering references to `store.edit`).

- [ ] **Step 5: Commit**

```bash
git add Sources/RemindersCore/RemindersStore.swift Sources/RemindersCLI/Commands/EditCommand.swift Sources/RemindersCLI/MCPServer.swift Tests/RemindersCoreTests/ReminderUpdateStoreTests.swift
git commit -m "feat: apply ReminderUpdate in the store and retire edit()"
```

---

### Task 6: CLI edit and delete grow their surfaces

`edit` gains `--due-date/-d`, `--clear-due-date`, `--priority/-p`, `--move-to`, `--include-completed`; `delete` gains `--include-completed`. A no-op edit (no changes requested) becomes a validation error.

**Files:**
- Modify: `Sources/RemindersCLI/Commands/EditCommand.swift`
- Modify: `Sources/RemindersCLI/Commands/DeleteCommand.swift`
- Create: `Tests/RemindersCLITests/EditCommandValidationTests.swift`

**Interfaces:**
- Consumes: `store.update(itemAtIndex:onList:with:includeCompleted:)`, `parseDate`, `supportedDateFormats`, `ReminderPriority`, `store.delete(... includeCompleted:)` (parameter already exists).
- Produces: nothing later tasks consume; Task 11 documents the flags.

- [ ] **Step 1: Write the failing validation tests**

Create `Tests/RemindersCLITests/EditCommandValidationTests.swift`:

```swift
// ABOUTME: Validation and parse tests for the expanded edit and delete commands.
// ABOUTME: Locks flag names, mutual exclusions, and the no-op edit rejection.

import ArgumentParser
import Foundation
import Testing

@testable import reminders

@Suite("edit and delete command validation")
struct EditCommandValidationTests {

    @Test("edit accepts a due date, priority, move, and include-completed together")
    func editParsesNewFlags() throws {
        let cmd = try EditCommand.parse([
            "Inbox", "0",
            "--due-date", "tomorrow",
            "--priority", "high",
            "--move-to", "Archive",
            "--include-completed",
        ])
        #expect(cmd.dueDate == "tomorrow")
        #expect(cmd.priority == "high")
        #expect(cmd.moveTo == "Archive")
        #expect(cmd.includeCompleted == true)
    }

    @Test("edit rejects --due-date combined with --clear-due-date")
    func editRejectsDueDateWithClear() {
        do {
            _ = try EditCommand.parse([
                "Inbox", "0", "--due-date", "today", "--clear-due-date",
            ])
            Issue.record("Expected a validation error")
        } catch {
            #expect(EditCommand.message(for: error).contains("--clear-due-date"))
        }
    }

    @Test("edit rejects an unparseable due date and names the formats")
    func editRejectsBadDate() {
        do {
            _ = try EditCommand.parse(["Inbox", "0", "--due-date", "someday"])
            Issue.record("Expected a validation error")
        } catch {
            #expect(EditCommand.message(for: error).contains("yyyy-MM-dd"))
        }
    }

    @Test("edit rejects an invalid priority")
    func editRejectsBadPriority() {
        do {
            _ = try EditCommand.parse(["Inbox", "0", "--priority", "urgent"])
            Issue.record("Expected a validation error")
        } catch {
            #expect(EditCommand.message(for: error).contains("none, low, medium, high"))
        }
    }

    @Test("edit with nothing to change is rejected")
    func editRejectsNoOp() {
        do {
            _ = try EditCommand.parse(["Inbox", "0"])
            Issue.record("Expected a validation error")
        } catch {
            #expect(EditCommand.message(for: error).contains("Nothing to edit"))
        }
    }

    @Test("edit with only new title text is accepted")
    func editTitleOnly() throws {
        let cmd = try EditCommand.parse(["Inbox", "0", "New", "title"])
        #expect(cmd.newText == ["New", "title"])
    }

    @Test("edit help documents the new flags")
    func editHelp() {
        let help = EditCommand.helpMessage(columns: 500)
        #expect(help.contains("--clear-due-date"))
        #expect(help.contains("--move-to"))
        #expect(help.contains("--include-completed"))
    }

    @Test("delete accepts and documents --include-completed")
    func deleteIncludeCompleted() throws {
        let cmd = try DeleteCommand.parse(["Inbox", "0", "--include-completed"])
        #expect(cmd.includeCompleted == true)
        #expect(DeleteCommand.helpMessage(columns: 500).contains("--include-completed"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter EditCommandValidationTests`
Expected: FAIL to compile (`cmd.dueDate`, `cmd.moveTo` etc. do not exist yet).

- [ ] **Step 3: Implement the new EditCommand**

Replace the property declarations and add `validate()` in `Sources/RemindersCLI/Commands/EditCommand.swift` (keep the file header, imports, `configuration`, and the `listName`/`index`/`newText` declarations as they are; `notes` also stays):

```swift
    @Option(name: [.short, .long], help: "New due date (e.g. today, tomorrow, 2025-12-31, MM/dd).")
    var dueDate: String?

    @Flag(name: .long, help: "Remove the due date (and its alarm) from the reminder.")
    var clearDueDate = false

    @Option(name: [.short, .long], help: "New priority: none, low, medium, or high.")
    var priority: String?

    @Option(name: .long, help: ArgumentHelp("Move the reminder to this list."))
    var moveTo: String?

    @Flag(name: .long, help: ArgumentHelp("Allow targeting completed reminders. The index then "
        + "counts the combined view shown by `show --include-completed`; stable ids are unaffected."))
    var includeCompleted = false

    func validate() throws {
        if dueDate != nil && clearDueDate {
            throw ValidationError("Cannot use --due-date and --clear-due-date together.")
        }

        if let dueDate {
            guard parseDate(dueDate) != nil else {
                throw ValidationError(
                    "Could not parse date \"\(dueDate)\". Supported formats: \(supportedDateFormats)."
                )
            }
        }

        if let priority {
            guard ReminderPriority(rawValue: priority.lowercased()) != nil else {
                throw ValidationError(
                    "Invalid priority \"\(priority)\". "
                    + "Must be one of: none, low, medium, high."
                )
            }
        }

        let hasChange = !newText.isEmpty || notes != nil || dueDate != nil
            || clearDueDate || priority != nil || moveTo != nil
        if !hasChange {
            throw ValidationError(
                "Nothing to edit: provide new title text or at least one of "
                + "--notes, --due-date, --clear-due-date, --priority, --move-to."
            )
        }
    }
```

and replace `run()`:

```swift
    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()

            let titleText: String? = newText.isEmpty ? nil : newText.joined(separator: " ")

            let dueDateChange: Date??
            if clearDueDate {
                dueDateChange = .some(nil)
            } else if let dueDate, let parsed = parseDate(dueDate) {
                dueDateChange = .some(parsed)
            } else {
                dueDateChange = nil
            }

            let parsedPriority = priority.flatMap { ReminderPriority(rawValue: $0.lowercased()) }

            let updated = try await store.update(
                itemAtIndex: index,
                onList: listName,
                with: ReminderUpdate(
                    title: titleText,
                    notes: notes,
                    dueDate: dueDateChange,
                    priority: parsedPriority,
                    listName: moveTo
                ),
                includeCompleted: includeCompleted
            )
            print("Edited: \(Formatter.format(updated))")
        }
    }
```

Update the second `// ABOUTME:` line of the file to: `// ABOUTME: Supports title, notes, due date set/clear, priority, list moves, and completed targeting.`

- [ ] **Step 4: Implement DeleteCommand's flag**

In `Sources/RemindersCLI/Commands/DeleteCommand.swift`, add after the `index` argument:

```swift
    @Flag(name: .long, help: ArgumentHelp("Allow targeting completed reminders. The index then "
        + "counts the combined view shown by `show --include-completed`; stable ids are unaffected."))
    var includeCompleted = false
```

and pass it through in `run()`:

```swift
            let deleted = try await store.delete(
                itemAtIndex: index,
                onList: listName,
                includeCompleted: includeCompleted
            )
```

- [ ] **Step 5: Run and commit**

Run: `swift test --filter EditCommandValidationTests` (PASS, 8 tests), then `make check`.

```bash
git add Sources/RemindersCLI/Commands/EditCommand.swift Sources/RemindersCLI/Commands/DeleteCommand.swift Tests/RemindersCLITests/EditCommandValidationTests.swift
git commit -m "feat: add due date, priority, move, and completed targeting to CLI edit and delete"
```

---

### Task 7: MCP edit_reminder and delete_reminder grow their surfaces

`edit_reminder` gains `due_date`, `clear_due_date`, `priority`, `move_to_list`, `include_completed`; `delete_reminder` gains `include_completed`. Descriptions stop claiming only incomplete reminders can be targeted.

**Files:**
- Modify: `Sources/RemindersCLI/MCPServer.swift` (`buildToolDefinitions` for the two tools; `handleEditReminder`; `handleDeleteReminder`)
- Modify: `Tests/RemindersCLITests/ToolDefinitionContentTests.swift` (extend)
- Create: `Tests/RemindersCLITests/MCPEditToolTests.swift`

**Interfaces:**
- Consumes: `store.update(...)`, `store.delete(... includeCompleted:)`, `parseDate`, `supportedDateFormats`, harness from Task 3.
- Produces: nothing later tasks consume; Task 11 documents the params.

- [ ] **Step 1: Write the failing wire tests**

Create `Tests/RemindersCLITests/MCPEditToolTests.swift`:

```swift
// ABOUTME: Wire-level tests for the expanded edit_reminder and delete_reminder tools.
// ABOUTME: Exercises due date set/clear, priority, moves, and completed targeting via JSON-RPC.

import Foundation
import RemindersTestSupport
import Testing

@testable import reminders

@Suite("MCP edit and delete tool surfaces")
struct MCPEditToolTests {

    @Test("edit_reminder sets a due date")
    func editSetsDueDate() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "task", in: cal)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","due_date":"2026-12-31"}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("2026-12-31"))
    }

    @Test("edit_reminder clears a due date")
    func editClearsDueDate() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(
            title: "task",
            in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 12, day: 31)
        )
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","clear_due_date":true}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("\"dueDate\" : null"))
    }

    @Test("edit_reminder rejects due_date combined with clear_due_date")
    func editRejectsConflict() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "task", in: cal)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","due_date":"today","clear_due_date":true}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == true)
        #expect(toolText(responses[0]).contains("clear_due_date"))
    }

    @Test("edit_reminder rejects an unparseable due_date, naming the formats")
    func editRejectsBadDate() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "task", in: cal)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","due_date":"someday"}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == true)
        #expect(toolText(responses[0]).contains("yyyy-MM-dd"))
    }

    @Test("edit_reminder moves a reminder and sets priority")
    func editMovesAndSetsPriority() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addCalendar(named: "Archive")
        backend.addReminder(title: "task", in: cal)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","move_to_list":"Archive","priority":"high"}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        let text = toolText(responses[0])
        #expect(text.contains("Archive"))
        #expect(text.contains("high"))
    }

    @Test("edit_reminder targets a completed reminder with include_completed")
    func editCompletedReminder() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "done", in: cal, isCompleted: true)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","title":"done, renamed","include_completed":true}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("done, renamed"))
    }

    @Test("delete_reminder removes a completed reminder with include_completed")
    func deleteCompletedReminder() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "old done", in: cal, isCompleted: true)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_reminder","arguments":{"list":"Inbox","index":"0","include_completed":true}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("old done"))
        #expect(backend.currentReminders.isEmpty)
    }
}
```

Append to `Tests/RemindersCLITests/ToolDefinitionContentTests.swift` (inside its existing suite, matching its existing lookup style):

```swift
    @Test("edit_reminder schema advertises the phase 2 parameters")
    func editReminderSchemaParams() throws {
        let definitions = MCPServer.buildToolDefinitions()
        let edit = try #require(definitions.first(where: { $0.name == "edit_reminder" }))
        let properties = try #require(edit.inputSchema.properties)
        #expect(properties["due_date"] != nil)
        #expect(properties["clear_due_date"] != nil)
        #expect(properties["priority"]?.enum == ["none", "low", "medium", "high"])
        #expect(properties["move_to_list"] != nil)
        #expect(properties["include_completed"] != nil)
        #expect(edit.description.contains("include_completed"))
        #expect(!edit.description.contains("Only incomplete reminders can be targeted"))
    }

    @Test("delete_reminder schema advertises include_completed")
    func deleteReminderSchemaParams() throws {
        let definitions = MCPServer.buildToolDefinitions()
        let delete = try #require(definitions.first(where: { $0.name == "delete_reminder" }))
        let properties = try #require(delete.inputSchema.properties)
        #expect(properties["include_completed"] != nil)
        #expect(!delete.description.contains("Only incomplete reminders can be targeted"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter MCPEditToolTests` and `swift test --filter ToolDefinitionContentTests`
Expected: the new tests FAIL (unknown params are ignored today, so due_date silently does nothing and the schema assertions fail).

- [ ] **Step 3: Extend the definitions**

In `buildToolDefinitions()`, replace the `edit_reminder` definition with:

```swift
            MCPToolDefinition(
                name: "edit_reminder",
                description: "Edit an existing reminder. Only the fields you provide change; "
                    + "omitted fields remain untouched. Can update the title, notes, due date, "
                    + "priority, and list (move_to_list). Set clear_due_date to remove the due "
                    + "date entirely. By default only incomplete reminders can be targeted; set "
                    + "include_completed to true to edit completed ones (the positional index "
                    + "then counts the combined view; stable ids are unaffected). Pass the "
                    + "reminder's stable id (preferred) or its zero-based position. Returns the "
                    + "updated reminder as JSON.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The name of the reminder list (case-insensitive match).",
                            enum: nil
                        ),
                        "index": PropertySchema(
                            types: ["string", "integer"],
                            description: "The reminder's stable id from show_reminders (preferred; "
                                + "unaffected by list changes), or its zero-based position among "
                                + "the list's incomplete reminders (fragile: positions shift as "
                                + "reminders change).",
                            enum: nil
                        ),
                        "title": PropertySchema(
                            type: "string",
                            description: "New title text. Omit to keep the current title.",
                            enum: nil
                        ),
                        "notes": PropertySchema(
                            type: "string",
                            description: "New notes text. Omit to keep the current notes.",
                            enum: nil
                        ),
                        "due_date": PropertySchema(
                            type: "string",
                            description: "New due date. Accepts: 'today', 'tomorrow', 'next week', "
                                + "'yyyy-MM-dd', 'yyyy-MM-dd HH:mm', 'MM/dd/yyyy', or 'MM/dd'. "
                                + "Cannot be combined with clear_due_date.",
                            enum: nil
                        ),
                        "clear_due_date": PropertySchema(
                            type: "boolean",
                            description: "When true, removes the reminder's due date and alarm. "
                                + "Cannot be combined with due_date.",
                            enum: nil
                        ),
                        "priority": PropertySchema(
                            type: "string",
                            description: "New priority level.",
                            enum: ["none", "low", "medium", "high"]
                        ),
                        "move_to_list": PropertySchema(
                            type: "string",
                            description: "Name of the list to move the reminder to "
                                + "(case-insensitive match).",
                            enum: nil
                        ),
                        "include_completed": PropertySchema(
                            type: "boolean",
                            description: "When true, completed reminders can be targeted too. "
                                + "The positional index then counts the combined view.",
                            enum: nil
                        ),
                    ],
                    required: ["list", "index"]
                )
            ),
```

and the `delete_reminder` definition with:

```swift
            MCPToolDefinition(
                name: "delete_reminder",
                description: "Permanently delete a reminder from a list. This action cannot be "
                    + "undone. By default only incomplete reminders can be targeted; set "
                    + "include_completed to true to delete completed ones (the positional index "
                    + "then counts the combined view; stable ids are unaffected). Pass the "
                    + "reminder's stable id (preferred) or its zero-based position. Returns the "
                    + "deleted reminder as JSON.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The name of the reminder list (case-insensitive match).",
                            enum: nil
                        ),
                        "index": PropertySchema(
                            types: ["string", "integer"],
                            description: "The reminder's stable id from show_reminders (preferred; "
                                + "unaffected by list changes), or its zero-based position among "
                                + "the list's incomplete reminders (fragile: positions shift as "
                                + "reminders change).",
                            enum: nil
                        ),
                        "include_completed": PropertySchema(
                            type: "boolean",
                            description: "When true, completed reminders can be targeted too. "
                                + "The positional index then counts the combined view.",
                            enum: nil
                        ),
                    ],
                    required: ["list", "index"]
                )
            ),
```

- [ ] **Step 4: Extend the handlers**

Replace `handleEditReminder` with:

```swift
    private static func handleEditReminder(
        store: RemindersStore,
        params: [String: JSONValue]
    ) async -> MCPToolResult {
        guard let listName = params["list"]?.stringValue() else {
            return .error("Missing required parameter: 'list' (string).")
        }
        guard let index = extractIndex(from: params) else {
            return .error("Missing required parameter: 'index' (string or integer).")
        }

        let newTitle = params["title"]?.stringValue()
        let newNotes = params["notes"]?.stringValue()
        let moveToList = params["move_to_list"]?.stringValue()
        let includeCompleted = params["include_completed"]?.boolValue() ?? false
        let clearDueDate = params["clear_due_date"]?.boolValue() ?? false
        let dueDateString = params["due_date"]?.stringValue()

        if clearDueDate && dueDateString != nil {
            return .error(
                "Invalid parameters: 'due_date' and 'clear_due_date' cannot be combined. "
                + "Use due_date to set a new date, or clear_due_date to remove it."
            )
        }

        let dueDateChange: Date??
        if clearDueDate {
            dueDateChange = .some(nil)
        } else if let dueDateString {
            guard let parsed = parseDate(dueDateString) else {
                return .error(
                    "Invalid due_date \"\(dueDateString)\". Supported formats: \(supportedDateFormats)."
                )
            }
            dueDateChange = .some(parsed)
        } else {
            dueDateChange = nil
        }

        let parsedPriority: ReminderPriority?
        if let priorityString = params["priority"]?.stringValue() {
            guard let priority = ReminderPriority(rawValue: priorityString.lowercased()) else {
                return .error(
                    "Invalid priority \"\(priorityString)\". "
                    + "Must be one of: none, low, medium, high."
                )
            }
            parsedPriority = priority
        } else {
            parsedPriority = nil
        }

        do {
            let updated = try await store.update(
                itemAtIndex: index,
                onList: listName,
                with: ReminderUpdate(
                    title: newTitle,
                    notes: newNotes,
                    dueDate: dueDateChange,
                    priority: parsedPriority,
                    listName: moveToList
                ),
                includeCompleted: includeCompleted
            )
            let text = prettyEncodeJSON(updated)
            return .success(text)
        } catch {
            return .error("Failed to edit reminder: \(error.localizedDescription)")
        }
    }
```

In `handleDeleteReminder`, add the flag and pass it through:

```swift
        let includeCompleted = params["include_completed"]?.boolValue() ?? false

        do {
            let deleted = try await store.delete(
                itemAtIndex: index,
                onList: listName,
                includeCompleted: includeCompleted
            )
```

- [ ] **Step 5: Run and commit**

Run: `swift test --filter MCPEditToolTests` (PASS, 7), `swift test --filter ToolDefinitionContentTests` (PASS), then `make check`.

```bash
git add Sources/RemindersCLI/MCPServer.swift Tests/RemindersCLITests/MCPEditToolTests.swift Tests/RemindersCLITests/ToolDefinitionContentTests.swift
git commit -m "feat: extend edit_reminder and delete_reminder MCP tools"
```

---

### Task 8: `filterByDueDate` takes a `Date?`

The silent unparseable-date fallback disappears structurally: parsing moves fully to the callers (which already validate), and the filter's signature stops accepting strings.

**Files:**
- Modify: `Sources/RemindersCLI/DateParsing.swift`
- Modify: `Sources/RemindersCLI/Commands/ShowCommand.swift`
- Modify: `Sources/RemindersCLI/Commands/ShowAllCommand.swift`
- Modify: `Tests/RemindersCLITests/DateParsingTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `func filterByDueDate(_ reminders: [ReminderItem], dueDate: Date?, includeOverdue: Bool) -> [ReminderItem]`.

- [ ] **Step 1: Update the tests first**

In `Tests/RemindersCLITests/DateParsingTests.swift`, suite `FilterByDueDateTests`:

1. Delete the `unparseableDateReturnsAll` test entirely. It asserts the silent-fallback behavior this task removes, and its `"not-a-date"` string argument cannot compile once the parameter becomes `Date?`.
2. Keep `nilDueDateReturnsAll` unchanged. Its `nil` literal satisfies the new `Date?` parameter as-is and already covers nil-pass-through. Do not add a duplicate nil test.
3. In the remaining three tests (`filtersOutNoDueDate`, `includeOverdueIncludesPastDue`, `filtersByTargetDate`), wrap each string argument in `parseDate(...)` — four call sites total, `includeOverdueIncludesPastDue` has two. For example:

```swift
let filtered = filterByDueDate(reminders, dueDate: "tomorrow", includeOverdue: false)
```

becomes

```swift
let filtered = filterByDueDate(reminders, dueDate: parseDate("tomorrow"), includeOverdue: false)
```

- [ ] **Step 2: Run to verify compile failure**

Run: `swift test --filter DateParsingTests`
Expected: FAIL to compile (String passed where Date? expected once the signature changes in step 3; run after step 3 if the build order gets in the way, the point is the suite goes red before green).

- [ ] **Step 3: Change the signature**

In `Sources/RemindersCLI/DateParsing.swift`, replace `filterByDueDate` with:

```swift
/// Filters reminders by an optional due date and/or overdue status.
///
/// Parsing happens at the call sites (all of which validate user input up
/// front), so this function cannot silently ignore a bad date string.
///
/// - Parameters:
///   - reminders: The full array of reminders to filter.
///   - dueDate: If provided, only reminders due on or before that date are included.
///   - includeOverdue: When `true` alongside a `dueDate` filter, also includes reminders
///     whose due date is in the past (before today).
/// - Returns: The filtered array of reminders.
func filterByDueDate(
    _ reminders: [ReminderItem],
    dueDate: Date?,
    includeOverdue: Bool
) -> [ReminderItem] {
    guard let targetDate = dueDate else {
        return reminders
    }

    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: Date())
    guard let endOfTargetDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: targetDate)) else {
        return reminders
    }

    return reminders.filter { reminder in
        guard let reminderDue = reminder.dueDate else {
            return false
        }

        // Include if due on or before the target date.
        let dueBeforeTarget = reminderDue < endOfTargetDay

        if includeOverdue {
            return dueBeforeTarget
        } else {
            // Exclude overdue items (due before today) unless they fall on the target day itself.
            let isOverdue = reminderDue < startOfToday
            return dueBeforeTarget && !isOverdue
        }
    }
}
```

In `ShowCommand.run()` and `ShowAllCommand.run()`, change the filter call to:

```swift
            reminders = filterByDueDate(
                reminders,
                dueDate: dueDate.flatMap(parseDate),
                includeOverdue: includeOverdue
            )
```

(`validate()` already rejected unparseable strings, so `flatMap(parseDate)` never silently drops a filter a user asked for.)

- [ ] **Step 4: Run and commit**

Run: `swift test --filter DateParsingTests` (PASS), then `make check`.

```bash
git add Sources/RemindersCLI/DateParsing.swift Sources/RemindersCLI/Commands/ShowCommand.swift Sources/RemindersCLI/Commands/ShowAllCommand.swift Tests/RemindersCLITests/DateParsingTests.swift
git commit -m "refactor: move due-date parsing out of filterByDueDate"
```

---

### Task 9: MCP due_before / due_after filters

`show_reminders` and `show_all_reminders` accept day-granular `due_before` and `due_after` bounds. A new pure function does the windowing; unparseable bounds are tool errors naming `supportedDateFormats`.

**Files:**
- Modify: `Sources/RemindersCLI/DateParsing.swift` (add `filterByDueWindow`)
- Modify: `Sources/RemindersCLI/MCPServer.swift` (schemas + `handleShowReminders` + `handleShowAllReminders`)
- Modify: `Tests/RemindersCLITests/DateParsingTests.swift` (unit tests for the window)
- Modify: `Tests/RemindersCLITests/ToolDefinitionContentTests.swift` (schema assertions)
- Create: `Tests/RemindersCLITests/MCPDueFilterTests.swift`

**Interfaces:**
- Consumes: `parseDate`, `supportedDateFormats`, harness.
- Produces: `func filterByDueWindow(_ reminders: [ReminderItem], dueBefore: Date?, dueAfter: Date?, calendar: Calendar = .current) -> [ReminderItem]`.

- [ ] **Step 1: Write the failing unit tests**

Append to `Tests/RemindersCLITests/DateParsingTests.swift` (a new suite at file scope, using explicit dates so no wall-clock dependency):

```swift
@Suite("filterByDueWindow")
struct FilterByDueWindowTests {

    private func item(_ title: String, due: String?) -> ReminderItem {
        ReminderItem(
            id: title,
            title: title,
            isCompleted: false,
            priority: .none,
            dueDate: due.flatMap(parseDate),
            listID: "L",
            listName: "L"
        )
    }

    @Test("no bounds returns the input unchanged")
    func noBounds() {
        let reminders = [item("a", due: nil), item("b", due: "2026-06-15")]
        #expect(filterByDueWindow(reminders, dueBefore: nil, dueAfter: nil).count == 2)
    }

    @Test("due_before keeps reminders due on or before that day")
    func before() {
        let reminders = [
            item("early", due: "2026-06-10"),
            item("on the day", due: "2026-06-15"),
            item("late", due: "2026-06-20"),
        ]
        let filtered = filterByDueWindow(
            reminders, dueBefore: parseDate("2026-06-15"), dueAfter: nil
        )
        #expect(filtered.map(\.title) == ["early", "on the day"])
    }

    @Test("due_after keeps reminders due on or after that day")
    func after() {
        let reminders = [
            item("early", due: "2026-06-10"),
            item("on the day", due: "2026-06-15"),
            item("late", due: "2026-06-20"),
        ]
        let filtered = filterByDueWindow(
            reminders, dueBefore: nil, dueAfter: parseDate("2026-06-15")
        )
        #expect(filtered.map(\.title) == ["on the day", "late"])
    }

    @Test("both bounds form a window")
    func window() {
        let reminders = [
            item("early", due: "2026-06-10"),
            item("inside", due: "2026-06-15"),
            item("late", due: "2026-06-20"),
        ]
        let filtered = filterByDueWindow(
            reminders,
            dueBefore: parseDate("2026-06-18"),
            dueAfter: parseDate("2026-06-12")
        )
        #expect(filtered.map(\.title) == ["inside"])
    }

    @Test("reminders without a due date are excluded when a bound is present")
    func noDueDateExcluded() {
        let reminders = [item("undated", due: nil), item("dated", due: "2026-06-15")]
        let filtered = filterByDueWindow(
            reminders, dueBefore: parseDate("2026-06-16"), dueAfter: nil
        )
        #expect(filtered.map(\.title) == ["dated"])
    }

    @Test("a timed reminder on the boundary day is inside the window")
    func timedBoundary() {
        let reminders = [item("evening", due: "2026-06-15 22:30")]
        let filtered = filterByDueWindow(
            reminders, dueBefore: parseDate("2026-06-15"), dueAfter: parseDate("2026-06-15")
        )
        #expect(filtered.count == 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FilterByDueWindowTests`
Expected: FAIL to compile (`filterByDueWindow` undefined).

- [ ] **Step 3: Implement the window function**

Append to `Sources/RemindersCLI/DateParsing.swift`:

```swift
/// Filters reminders to a day-granular due-date window.
///
/// `dueBefore` keeps reminders due on or before that day; `dueAfter` keeps
/// reminders due on or after that day. Both together form a window. Reminders
/// without a due date are excluded whenever a bound is present.
///
/// - Parameters:
///   - reminders: The reminders to filter.
///   - dueBefore: Upper bound (inclusive of that whole day), or `nil` for no upper bound.
///   - dueAfter: Lower bound (inclusive from the start of that day), or `nil` for no lower bound.
///   - calendar: Calendar used to resolve day boundaries. Defaults to `.current`.
/// - Returns: The filtered array of reminders.
func filterByDueWindow(
    _ reminders: [ReminderItem],
    dueBefore: Date?,
    dueAfter: Date?,
    calendar: Calendar = .current
) -> [ReminderItem] {
    guard dueBefore != nil || dueAfter != nil else {
        return reminders
    }

    let upperBound = dueBefore.flatMap {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))
    }
    let lowerBound = dueAfter.map { calendar.startOfDay(for: $0) }

    return reminders.filter { reminder in
        guard let due = reminder.dueDate else {
            return false
        }
        if let upperBound, due >= upperBound {
            return false
        }
        if let lowerBound, due < lowerBound {
            return false
        }
        return true
    }
}
```

Run: `swift test --filter FilterByDueWindowTests` (PASS, 6 tests).

- [ ] **Step 4: Write the failing wire and schema tests**

Create `Tests/RemindersCLITests/MCPDueFilterTests.swift`:

```swift
// ABOUTME: Wire-level tests for due_before/due_after on the MCP show tools.
// ABOUTME: Seeds due dates through the fake backend and asserts filtered output.

import Foundation
import RemindersTestSupport
import Testing

@testable import reminders

@Suite("MCP due-date filters")
struct MCPDueFilterTests {

    @Test("show_reminders honors due_before")
    func showRemindersDueBefore() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(
            title: "soon", in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 6, day: 10)
        )
        backend.addReminder(
            title: "later", in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 6, day: 20)
        )
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_reminders","arguments":{"list":"Inbox","due_before":"2026-06-15"}}}"#
            ],
            backend: backend
        )
        let text = toolText(responses[0])
        #expect(toolIsError(responses[0]) == false)
        #expect(text.contains("soon"))
        #expect(!text.contains("later"))
    }

    @Test("show_all_reminders honors due_after")
    func showAllDueAfter() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(
            title: "soon", in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 6, day: 10)
        )
        backend.addReminder(
            title: "later", in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 6, day: 20)
        )
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_all_reminders","arguments":{"due_after":"2026-06-15"}}}"#
            ],
            backend: backend
        )
        let text = toolText(responses[0])
        #expect(!text.contains("soon"))
        #expect(text.contains("later"))
    }

    @Test("an unparseable bound is a tool error naming the formats")
    func badBound() async {
        let backend = FakeEventStoreBackend()
        backend.addCalendar(named: "Inbox")
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_reminders","arguments":{"list":"Inbox","due_before":"whenever"}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == true)
        #expect(toolText(responses[0]).contains("yyyy-MM-dd"))
    }
}
```

Append to `Tests/RemindersCLITests/ToolDefinitionContentTests.swift`:

```swift
    @Test("show tools advertise due_before and due_after")
    func showToolsDueWindowParams() throws {
        let definitions = MCPServer.buildToolDefinitions()
        for name in ["show_reminders", "show_all_reminders"] {
            let tool = try #require(definitions.first(where: { $0.name == name }))
            let properties = try #require(tool.inputSchema.properties)
            #expect(properties["due_before"] != nil, "\(name) missing due_before")
            #expect(properties["due_after"] != nil, "\(name) missing due_after")
        }
    }
```

Run both filters; expected: FAIL (params ignored / schema missing).

- [ ] **Step 5: Extend schemas and handlers**

In `buildToolDefinitions()`, add to the `properties` dictionaries of BOTH `show_reminders` and `show_all_reminders` (alongside the completion flags):

```swift
                        "due_before": PropertySchema(
                            type: "string",
                            description: "Only include reminders due on or before this day. "
                                + "Accepts: 'today', 'tomorrow', 'next week', 'yyyy-MM-dd', "
                                + "'yyyy-MM-dd HH:mm', 'MM/dd/yyyy', or 'MM/dd'.",
                            enum: nil
                        ),
                        "due_after": PropertySchema(
                            type: "string",
                            description: "Only include reminders due on or after this day. "
                                + "Accepts the same formats as due_before.",
                            enum: nil
                        ),
```

and append one sentence to both tools' descriptions: `"Use due_before and/or due_after (day-granular) to filter by due date."`

In `handleShowReminders` and `handleShowAllReminders`, after the completion-flag conflict check, add:

```swift
        let dueBefore: Date?
        if let boundString = params["due_before"]?.stringValue() {
            guard let parsed = parseDate(boundString) else {
                return .error(
                    "Invalid due_before \"\(boundString)\". Supported formats: \(supportedDateFormats)."
                )
            }
            dueBefore = parsed
        } else {
            dueBefore = nil
        }

        let dueAfter: Date?
        if let boundString = params["due_after"]?.stringValue() {
            guard let parsed = parseDate(boundString) else {
                return .error(
                    "Invalid due_after \"\(boundString)\". Supported formats: \(supportedDateFormats)."
                )
            }
            dueAfter = parsed
        } else {
            dueAfter = nil
        }
```

and wrap the fetched result before encoding, in both handlers:

```swift
            let filtered = filterByDueWindow(reminders, dueBefore: dueBefore, dueAfter: dueAfter)
            let text = prettyEncodeJSON(filtered)
```

- [ ] **Step 6: Run and commit**

Run: `swift test --filter MCPDueFilterTests` (PASS, 3), `swift test --filter ToolDefinitionContentTests` (PASS), then `make check`.

```bash
git add Sources/RemindersCLI/DateParsing.swift Sources/RemindersCLI/MCPServer.swift Tests/RemindersCLITests/DateParsingTests.swift Tests/RemindersCLITests/ToolDefinitionContentTests.swift Tests/RemindersCLITests/MCPDueFilterTests.swift
git commit -m "feat: add due_before and due_after filters to MCP show tools"
```

---

### Task 10: Completion-status predicates instead of in-memory filtering

EventKit can filter completed/incomplete server-side. Extend the backend seam with the two specialized predicates and let the store pick one, deleting the in-memory completion filter.

**Files:**
- Modify: `Sources/RemindersCore/EventStoreBackend.swift` (protocol + EventKitBackend)
- Modify: `Sources/RemindersCore/RemindersStore.swift` (`fetchFilteredEKReminders`)
- Modify: `Tests/RemindersTestSupport/FakeEventStoreBackend.swift` (implement + record the predicate kind)
- Modify: `Tests/RemindersCoreTests/RemindersStoreTests.swift` (assert the kind used)

**Interfaces:**
- Consumes: everything above.
- Produces:
  - Protocol members `func incompleteRemindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate` and `func completedRemindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate`.
  - `FakeEventStoreBackend.FetchKind` (`.all`, `.incomplete`, `.completed`) and `public var lastFetchKind: FetchKind?`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RemindersCoreTests/RemindersStoreTests.swift` (inside the suite):

```swift
    // MARK: Predicate selection (fetch narrowing happens in EventKit, not in memory)

    @Test("default fetch asks for the incomplete predicate")
    func incompletePredicateSelected() async throws {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "open", in: cal)
        let store = RemindersStore(backend: backend)
        _ = try await store.reminders(inList: "Inbox", includeCompleted: false)
        #expect(backend.lastFetchKind == .incomplete)
    }

    @Test("onlyCompleted fetch asks for the completed predicate")
    func completedPredicateSelected() async throws {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "done", in: cal, isCompleted: true)
        let store = RemindersStore(backend: backend)
        _ = try await store.reminders(inList: "Inbox", includeCompleted: true, onlyCompleted: true)
        #expect(backend.lastFetchKind == .completed)
    }

    @Test("includeCompleted fetch asks for the general predicate")
    func allPredicateSelected() async throws {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "open", in: cal)
        let store = RemindersStore(backend: backend)
        _ = try await store.reminders(inList: "Inbox", includeCompleted: true)
        #expect(backend.lastFetchKind == .all)
    }
```

Run: `swift test --filter RemindersStoreTests`
Expected: FAIL to compile (`lastFetchKind` undefined).

- [ ] **Step 2: Extend the protocol and production backend**

In `Sources/RemindersCore/EventStoreBackend.swift`, add to the protocol after `remindersPredicate(in:)`:

```swift
    /// Predicate matching only incomplete reminders in the given calendars.
    func incompleteRemindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate
    /// Predicate matching only completed reminders in the given calendars.
    func completedRemindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate
```

and to `EventKitBackend`:

```swift
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
```

- [ ] **Step 3: Extend the fake**

In `Tests/RemindersTestSupport/FakeEventStoreBackend.swift`:

Add the kind enum and tracking (near the other private vars):

```swift
    /// Which predicate flavor the store last requested.
    public enum FetchKind: Sendable, Equatable {
        case all
        case incomplete
        case completed
    }

    private var _lastFetchKind: FetchKind?
```

Add the inspection accessor with the others:

```swift
    /// The predicate flavor of the most recent fetch.
    public var lastFetchKind: FetchKind? { lock.withLock { _lastFetchKind } }
```

Record the kind in `remindersPredicate(in:)` (add `_lastFetchKind = .all` inside its `withLock`), and add the two new conformances:

```swift
    public func incompleteRemindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate {
        lock.withLock {
            _lastRequestedCalendars = calendars
            _lastFetchKind = .incomplete
        }
        return NSPredicate(value: true)
    }

    public func completedRemindersPredicate(in calendars: [EKCalendar]?) -> NSPredicate {
        lock.withLock {
            _lastRequestedCalendars = calendars
            _lastFetchKind = .completed
        }
        return NSPredicate(value: true)
    }
```

Extend `fetchReminders(matching:completion:)` so the snapshot honors the recorded kind (the fake must behave like EventKit or every completion-dependent test above turns meaningless):

```swift
        let snapshot: [EKReminder] = lock.withLock {
            var result = _reminders
            if let scope = _lastRequestedCalendars, let calendars = scope {
                result = result.filter { reminder in
                    calendars.contains { $0 === reminder.calendar }
                }
            }
            switch _lastFetchKind {
            case .incomplete:
                result = result.filter { !$0.isCompleted }
            case .completed:
                result = result.filter { $0.isCompleted }
            case .all, nil:
                break
            }
            return result
        }
        completion(snapshot)
```

- [ ] **Step 4: Switch the store over**

In `Sources/RemindersCore/RemindersStore.swift`, replace the body of `fetchFilteredEKReminders` with:

```swift
        let predicate: NSPredicate
        if onlyCompleted {
            predicate = backend.completedRemindersPredicate(in: calendars)
        } else if !includeCompleted {
            predicate = backend.incompleteRemindersPredicate(in: calendars)
        } else {
            predicate = backend.remindersPredicate(in: calendars)
        }
        return try await fetchReminders(matching: predicate)
```

and update its doc comment: the narrowing now happens in the EventKit predicate rather than in memory (delete the sentence about filtering after the fetch if present).

- [ ] **Step 5: Run everything and commit**

Run: `make check`
Expected: all suites green, zero warnings. The behavior-parity evidence is that every completion-related test from Tasks 2 through 9 still passes with filtering now happening in the fake's predicate layer.

```bash
git add Sources/RemindersCore/EventStoreBackend.swift Sources/RemindersCore/RemindersStore.swift Tests/RemindersTestSupport/FakeEventStoreBackend.swift Tests/RemindersCoreTests/RemindersStoreTests.swift
git commit -m "perf: fetch reminders with completion-status predicates"
```

---

### Task 11: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:** none; prose only. No em dashes or en dashes anywhere; sentence-case headings; match the README's existing plain voice.

- [ ] **Step 1: README CLI usage**

In the `## CLI usage` code block, after the existing `reminders edit Groceries 1 -n "new note"` line, add:

```sh
reminders edit Groceries 1 -d tomorrow -p high  # options only: title stays
reminders edit Groceries 1 --clear-due-date
reminders edit Groceries 1 --move-to Projects
reminders delete Groceries 2 --include-completed
```

After the "Put options ... before the title words" paragraph, add:

```markdown
`edit` changes only what you pass: title words, `-n` notes, `-d` due date,
`--clear-due-date`, `-p` priority, or `--move-to LIST`. Add `--include-completed`
to `edit` or `delete` to target completed reminders; the index then counts the
combined view from `show --include-completed`, while stable ids keep working
unchanged.
```

- [ ] **Step 2: README MCP tools section**

In the `### Tools` table, update the two rows:

```markdown
| `delete_reminder` | Delete permanently; returns the deleted reminder as JSON. `include_completed` targets completed ones |
| `edit_reminder` | Change title, notes, due date (set or clear), priority, or list |
```

After the table's trailing paragraph (the one about stable ids and EventKit change notifications), add:

```markdown
`show_reminders` and `show_all_reminders` also take `due_before` and
`due_after` (day-granular, same date formats as the CLI) to narrow results
to a due-date window.
```

- [ ] **Step 3: CLAUDE.md architecture note**

In `CLAUDE.md`, extend the Architecture list with one line after the `RemindersCLI` bullet:

```markdown
- `RemindersTestSupport` — shared in-memory fake of the EventKit seam; tests run without TCC
```

(if that bullet list uses a different dash style, match it exactly.)

- [ ] **Step 4: Verify claims against the binary**

Run: `swift build && .build/debug/reminders edit --help && .build/debug/reminders delete --help`
Expected: every flag the README names appears in the help output. Fix the README, not the code, on mismatch.

Run: `grep -nE '—|–' README.md CLAUDE.md`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: document phase 2 edit surface and MCP due-date filters"
```

---

### Task 12: Final verification sweep

**Files:** none; verification only.

- [ ] **Step 1: Full canonical check**

Run: `make check`
Expected: zero warnings, every suite green (the new RemindersStoreTests, ReminderUpdateStoreTests, MCPServerE2ETests, MCPEditToolTests, MCPDueFilterTests, EditCommandValidationTests, FilterByDueWindowTests, plus all pre-existing suites).

- [ ] **Step 2: MCP wire smoke (real binary, full session)**

```bash
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"show_lists","arguments":{}}}' \
  | .build/debug/reminders --mcp 2>/dev/null
```

Expected: three JSON lines. Line 2 includes `due_before`, `due_after`, `clear_due_date`, `move_to_list`, and `include_completed` among the tool schemas. Line 3 either lists real lists (TCC granted) or is an `isError` result containing "Grant access in System Settings"; both are correct.

- [ ] **Step 3: Freshness smoke**

Run: `bash scripts/mcp-freshness-smoke.sh`
Expected: `PASS`. If the shell has no TCC grant, record SKIPPED and flag it in the final report so Harper can run it himself.

- [ ] **Step 4: Live CLI spot-check (TCC-dependent, best effort)**

If the shell has a grant: create a scratch reminder, edit its due date, clear it, and delete it:

```bash
.build/debug/reminders add "MCP Smoke Test" phase2 scratch item
.build/debug/reminders edit "MCP Smoke Test" 0 -d tomorrow
.build/debug/reminders edit "MCP Smoke Test" 0 --clear-due-date
.build/debug/reminders delete "MCP Smoke Test" 0
```

Expected: each command prints a confirmation; no residue left in the list. Skip with a note if TCC blocks.

- [ ] **Step 5: Git hygiene and report**

Run: `git status` (clean) and `git log --oneline main..HEAD` (~11 commits matching the tasks).

Report: summarize what shipped, which TCC-dependent checks ran vs. were skipped, and hand off to superpowers:finishing-a-development-branch (push + PR so CI runs).

---

## Phase 3 Backlog (unchanged from the phase 2 backlog, minus items 1-4)

Remaining ranked items from the 2026-07-17 audit, for the next plan to pull from the top:

1. **Supply chain** — SHA-pin actions in `release.yml`; pass `HOMEBREW_TAP_TOKEN` via header/credential helper instead of embedding in the clone URL; remove `Package.resolved` from `.gitignore` and commit it; ad-hoc codesign (or notarize) release binaries. Also: bump the pinned `actions/checkout` to a v5 SHA (Node 20 deprecation notice in CI).
2. **Protocol negotiation** — echo/validate the client's `protocolVersion` in `initialize` instead of hardcoding `2024-11-05`; audit the capabilities object.
3. **Upstream output compatibility** — decide whether CLI confirmation strings should byte-match keith/reminders-cli. Product call for Harper.
4. **Duplicate list names** — accept a list id anywhere a list name is accepted; document first-match behavior meanwhile.
5. Minor: tool annotations (`readOnlyHint`, `destructiveHint`), `additionalProperties: false`, pagination for large lists.
6. Minor: differentiated exit codes (usage vs. permission vs. not-found).
7. Minor: `make lint` adopts swift-format or SwiftLint.
8. Minor: date-parsing test determinism (pin timezone/clock, DST edges).
9. Minor: stderr logging redaction (`recv:` logs full request lines; gate behind a debug flag).
10. Minor: CHANGELOG.md, CONTRIBUTING.md, CI build caching.
