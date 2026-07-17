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
