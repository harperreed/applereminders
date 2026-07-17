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
