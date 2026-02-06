// ABOUTME: Tests for RemindersCore domain model types and error descriptions.
// ABOUTME: Covers priority mapping, Codable round-trips, list equality, drafts, updates, and errors.

import Foundation
import Testing

@testable import RemindersCore

// MARK: - ReminderPriority Tests

@Suite("ReminderPriority")
struct ReminderPriorityTests {

    @Test("eventKitValue returns correct canonical values")
    func eventKitValues() {
        #expect(ReminderPriority.none.eventKitValue == 0)
        #expect(ReminderPriority.high.eventKitValue == 1)
        #expect(ReminderPriority.medium.eventKitValue == 5)
        #expect(ReminderPriority.low.eventKitValue == 9)
    }

    @Test("init from EventKit value 0 yields none")
    func initNone() {
        #expect(ReminderPriority(eventKitValue: 0) == .none)
    }

    @Test("init from EventKit values 1-4 yields high")
    func initHigh() {
        for value in 1...4 {
            #expect(ReminderPriority(eventKitValue: value) == .high)
        }
    }

    @Test("init from EventKit value 5 yields medium")
    func initMedium() {
        #expect(ReminderPriority(eventKitValue: 5) == .medium)
    }

    @Test("init from EventKit values 6-9 yields low")
    func initLow() {
        for value in 6...9 {
            #expect(ReminderPriority(eventKitValue: value) == .low)
        }
    }

    @Test("out-of-range EventKit values default to none")
    func initOutOfRange() {
        #expect(ReminderPriority(eventKitValue: -1) == .none)
        #expect(ReminderPriority(eventKitValue: 10) == .none)
        #expect(ReminderPriority(eventKitValue: 100) == .none)
        #expect(ReminderPriority(eventKitValue: -999) == .none)
    }

    @Test("round-trip through eventKitValue preserves priority for all cases")
    func roundTrip() {
        for priority in ReminderPriority.allCases {
            let roundTripped = ReminderPriority(eventKitValue: priority.eventKitValue)
            #expect(roundTripped == priority, "Round-trip failed for \(priority)")
        }
    }

    @Test("CaseIterable contains all four cases")
    func allCases() {
        #expect(ReminderPriority.allCases.count == 4)
        #expect(ReminderPriority.allCases.contains(.none))
        #expect(ReminderPriority.allCases.contains(.low))
        #expect(ReminderPriority.allCases.contains(.medium))
        #expect(ReminderPriority.allCases.contains(.high))
    }

    @Test("Codable round-trip preserves raw string values")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for priority in ReminderPriority.allCases {
            let data = try encoder.encode(priority)
            let decoded = try decoder.decode(ReminderPriority.self, from: data)
            #expect(decoded == priority)
        }
    }
}

// MARK: - ReminderList Tests

@Suite("ReminderList")
struct ReminderListTests {

    @Test("equality compares both id and title")
    func equality() {
        let a = ReminderList(id: "abc", title: "Shopping")
        let b = ReminderList(id: "abc", title: "Shopping")
        let c = ReminderList(id: "xyz", title: "Shopping")
        let d = ReminderList(id: "abc", title: "Work")

        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("Identifiable id matches stored id")
    func identifiable() {
        let list = ReminderList(id: "test-id", title: "Test")
        #expect(list.id == "test-id")
    }

    @Test("Codable round-trip preserves values")
    func codableRoundTrip() throws {
        let original = ReminderList(id: "list-1", title: "Groceries")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderList.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - ReminderItem Tests

@Suite("ReminderItem")
struct ReminderItemTests {

    @Test("Codable round-trip preserves all fields including nils")
    func codableRoundTrip() throws {
        let dueDate = Date(timeIntervalSince1970: 1_700_000_000)
        let completionDate = Date(timeIntervalSince1970: 1_700_100_000)

        let original = ReminderItem(
            id: "item-1",
            title: "Buy milk",
            notes: "From the corner store",
            isCompleted: true,
            completionDate: completionDate,
            priority: .high,
            dueDate: dueDate,
            listID: "list-1",
            listName: "Groceries"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderItem.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable round-trip preserves nil optional fields")
    func codableRoundTripWithNils() throws {
        let original = ReminderItem(
            id: "item-2",
            title: "Do laundry",
            notes: nil,
            isCompleted: false,
            completionDate: nil,
            priority: .none,
            dueDate: nil,
            listID: "list-2",
            listName: "Chores"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderItem.self, from: data)
        #expect(decoded == original)
    }

    @Test("equality distinguishes different items")
    func equality() {
        let a = ReminderItem(
            id: "1", title: "A", notes: nil, isCompleted: false,
            completionDate: nil, priority: .none, dueDate: nil,
            listID: "L", listName: "List"
        )
        let b = ReminderItem(
            id: "2", title: "A", notes: nil, isCompleted: false,
            completionDate: nil, priority: .none, dueDate: nil,
            listID: "L", listName: "List"
        )

        #expect(a != b)
    }

    @Test("Codable round-trip with every priority level")
    func codableWithEachPriority() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for priority in ReminderPriority.allCases {
            let item = ReminderItem(
                id: "id-\(priority.rawValue)",
                title: "Task",
                isCompleted: false,
                priority: priority,
                listID: "list",
                listName: "List"
            )
            let data = try encoder.encode(item)
            let decoded = try decoder.decode(ReminderItem.self, from: data)
            #expect(decoded == item)
            #expect(decoded.priority == priority)
        }
    }
}

// MARK: - ReminderDraft Tests

@Suite("ReminderDraft")
struct ReminderDraftTests {

    @Test("default values for optional fields")
    func defaults() {
        let draft = ReminderDraft(title: "Test")
        #expect(draft.title == "Test")
        #expect(draft.notes == nil)
        #expect(draft.dueDate == nil)
        #expect(draft.priority == .none)
    }

    @Test("all fields can be set")
    func allFields() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = ReminderDraft(
            title: "Meeting",
            notes: "Room 302",
            dueDate: date,
            priority: .high
        )
        #expect(draft.title == "Meeting")
        #expect(draft.notes == "Room 302")
        #expect(draft.dueDate == date)
        #expect(draft.priority == .high)
    }

    @Test("Codable round-trip preserves values")
    func codableRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let original = ReminderDraft(
            title: "Ship feature",
            notes: "Before Friday",
            dueDate: date,
            priority: .medium
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderDraft.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable round-trip preserves nil optional fields")
    func codableRoundTripWithNils() throws {
        let original = ReminderDraft(title: "Quick task")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderDraft.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - ReminderUpdate Tests

@Suite("ReminderUpdate")
struct ReminderUpdateTests {

    @Test("all-nil update has no fields set")
    func allNil() {
        let update = ReminderUpdate()
        #expect(update.title == nil)
        #expect(update.notes == nil)
        #expect(update.priority == nil)
        #expect(update.listName == nil)
        #expect(update.isCompleted == nil)
    }

    @Test("double optional dueDate: nil means don't change")
    func dueDateNilMeansNoChange() {
        let update = ReminderUpdate()
        // The outer optional is nil, meaning "don't change"
        #expect(update.dueDate == nil)
    }

    @Test("double optional dueDate: .some(nil) means clear the date")
    func dueDateSomeNilMeansClear() {
        let clearDate = ReminderUpdate(dueDate: .some(nil))
        // The outer optional is non-nil (meaning "do change"), inner is nil (meaning "clear it")
        #expect(clearDate.dueDate != nil)
        if let innerValue = clearDate.dueDate {
            #expect(innerValue == nil)
        }
    }

    @Test("double optional dueDate: .some(date) means set to date")
    func dueDateSomeDateMeansSet() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let setDate = ReminderUpdate(dueDate: .some(date))
        #expect(setDate.dueDate != nil)
        if let innerValue = setDate.dueDate {
            #expect(innerValue == date)
        }
    }

    @Test("Codable round-trip with title and priority set")
    func codableRoundTrip() throws {
        let original = ReminderUpdate(title: "Updated title", priority: .high)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderUpdate.self, from: data)
        #expect(decoded.title == original.title)
        #expect(decoded.priority == original.priority)
        #expect(decoded.notes == nil)
        #expect(decoded.dueDate == nil)
    }

    @Test("Codable round-trip with dueDate set to a date")
    func codableRoundTripWithDueDate() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let original = ReminderUpdate(dueDate: .some(date))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderUpdate.self, from: data)
        // The outer optional should be non-nil
        #expect(decoded.dueDate != nil)
        // The inner value should be the date
        if let innerValue = decoded.dueDate {
            #expect(innerValue == date)
        }
    }

    @Test("Codable round-trip with dueDate explicitly cleared")
    func codableRoundTripWithDueDateCleared() throws {
        let original = ReminderUpdate(dueDate: .some(nil))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderUpdate.self, from: data)
        // The outer optional should be non-nil (key present in JSON)
        #expect(decoded.dueDate != nil)
        // The inner value should be nil (meaning "clear")
        if let innerValue = decoded.dueDate {
            #expect(innerValue == nil)
        }
    }

    @Test("Codable round-trip with dueDate not set at all")
    func codableRoundTripWithDueDateAbsent() throws {
        let original = ReminderUpdate(title: "Something")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderUpdate.self, from: data)
        // The outer optional should be nil (key absent in JSON)
        #expect(decoded.dueDate == nil)
    }

    @Test("all fields can be set simultaneously")
    func allFieldsSet() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let update = ReminderUpdate(
            title: "New title",
            notes: "New notes",
            dueDate: .some(date),
            priority: .low,
            listName: "Work",
            isCompleted: true
        )
        #expect(update.title == "New title")
        #expect(update.notes == "New notes")
        #expect(update.priority == .low)
        #expect(update.listName == "Work")
        #expect(update.isCompleted == true)
        if let innerDate = update.dueDate {
            #expect(innerDate == date)
        }
    }
}

