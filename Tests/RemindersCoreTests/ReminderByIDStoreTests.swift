// ABOUTME: Tests for RemindersStore's by-id operations used by the REST surface.
// ABOUTME: Verifies cross-list lookup, no index fallback, and mutation parity with index paths.

import EventKit
import Foundation
import RemindersTestSupport
import Testing
@testable import RemindersCore

@Suite("By-id store operations")
struct ReminderByIDStoreTests {

    private func makeSeededStore() -> (backend: FakeEventStoreBackend, store: RemindersStore) {
        let backend = FakeEventStoreBackend()
        let chores = backend.addCalendar(named: "Chores")
        let errands = backend.addCalendar(named: "Errands")
        backend.addReminder(title: "Sweep", in: chores)
        backend.addReminder(title: "Mail letter", in: errands)
        backend.addReminder(title: "Old task", in: errands, isCompleted: true)
        return (backend, RemindersStore(backend: backend))
    }

    /// Fetches the store-visible id for the reminder with the given title.
    private func id(of title: String, in store: RemindersStore) async throws -> String {
        let all = try await store.reminders(includeCompleted: true)
        let item = try #require(all.first { $0.title == title })
        return item.id
    }

    @Test func reminderByIDFindsAcrossLists() async throws {
        let (_, store) = makeSeededStore()
        let mailID = try await id(of: "Mail letter", in: store)
        let item = try await store.reminder(byID: mailID)
        #expect(item.title == "Mail letter")
        #expect(item.listName == "Errands")
    }

    @Test func reminderByIDIncludesCompleted() async throws {
        let (_, store) = makeSeededStore()
        let oldID = try await id(of: "Old task", in: store)
        let item = try await store.reminder(byID: oldID)
        #expect(item.isCompleted)
    }

    @Test func unknownIDThrowsReminderNotFound() async throws {
        let (_, store) = makeSeededStore()
        await #expect(throws: RemindersError.reminderNotFound("no-such-id")) {
            try await store.reminder(byID: "no-such-id")
        }
    }

    @Test func numericStringIsNeverAnIndex() async throws {
        // resolveReminder treats "0" as position 0; the by-id path must not.
        let (backend, store) = makeSeededStore()
        await #expect(throws: RemindersError.reminderNotFound("0")) {
            try await store.update(byID: "0", with: ReminderUpdate(title: "Hijacked"))
        }
        #expect(backend.savedReminders.isEmpty)
    }

    @Test func updateByIDChangesTitleAndSaves() async throws {
        let (backend, store) = makeSeededStore()
        let sweepID = try await id(of: "Sweep", in: store)
        let updated = try await store.update(byID: sweepID, with: ReminderUpdate(title: "Sweep porch"))
        #expect(updated.title == "Sweep porch")
        #expect(backend.savedReminders.count == 1)
    }

    @Test func updateByIDClearsDueDate() async throws {
        let (backend, store) = makeSeededStore()
        let due = DateComponents(year: 2030, month: 1, day: 15)
        let calendar = try #require(backend.currentReminders.first?.calendar)
        backend.addReminder(title: "Dated", in: calendar, dueDateComponents: due)
        let datedID = try await id(of: "Dated", in: store)
        let updated = try await store.update(byID: datedID, with: ReminderUpdate(dueDate: .some(nil)))
        #expect(updated.dueDate == nil)
    }

    @Test func setCompletedByIDRoundTrips() async throws {
        let (_, store) = makeSeededStore()
        let sweepID = try await id(of: "Sweep", in: store)
        let done = try await store.setCompleted(byID: sweepID, completed: true)
        #expect(done.isCompleted)
        #expect(done.completionDate != nil)
        let undone = try await store.setCompleted(byID: sweepID, completed: false)
        #expect(!undone.isCompleted)
        #expect(undone.completionDate == nil)
    }

    @Test func deleteByIDReturnsSnapshotAndRemoves() async throws {
        let (backend, store) = makeSeededStore()
        let mailID = try await id(of: "Mail letter", in: store)
        let deleted = try await store.delete(byID: mailID)
        #expect(deleted.title == "Mail letter")
        #expect(backend.removedReminders.count == 1)
        let remaining = try await store.reminders(includeCompleted: true)
        #expect(!remaining.contains { $0.id == mailID })
    }
}
