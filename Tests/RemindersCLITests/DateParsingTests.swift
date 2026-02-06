// ABOUTME: Tests for date parsing helpers and due-date filtering logic.
// ABOUTME: Covers human-friendly date strings, explicit formats, edge cases, and overdue filtering.

import Foundation
import Testing

@testable import reminders
import RemindersCore

// MARK: - parseDate Tests

@Suite("parseDate")
struct ParseDateTests {

    @Test("'today' returns start of today")
    func parsesToday() {
        let result = parseDate("today")
        let expected = Calendar.current.startOfDay(for: Date())
        #expect(result == expected)
    }

    @Test("'tomorrow' returns start of tomorrow")
    func parsesTomorrow() {
        let result = parseDate("tomorrow")
        let calendar = Calendar.current
        let expected = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        #expect(result == expected)
    }

    @Test("'next week' returns 7 days from start of today")
    func parsesNextWeek() {
        let result = parseDate("next week")
        let calendar = Calendar.current
        let expected = calendar.date(byAdding: .weekOfYear, value: 1, to: calendar.startOfDay(for: Date()))
        #expect(result == expected)
    }

    @Test("keyword matching is case-insensitive")
    func keywordCaseInsensitive() {
        let today = Calendar.current.startOfDay(for: Date())
        #expect(parseDate("Today") == today)
        #expect(parseDate("TODAY") == today)
        #expect(parseDate("  today  ") == today)
    }

    @Test("'yyyy-MM-dd' format parses correctly")
    func parsesISODate() {
        let result = parseDate("2025-12-31")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let expected = formatter.date(from: "2025-12-31")
        #expect(result == expected)
    }

    @Test("'yyyy-MM-dd HH:mm' format parses correctly")
    func parsesISODateWithTime() {
        let result = parseDate("2025-12-31 14:30")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let expected = formatter.date(from: "2025-12-31 14:30")
        #expect(result == expected)
    }

    @Test("'MM/dd/yyyy' US date format parses correctly")
    func parsesUSDate() {
        let result = parseDate("12/31/2025")
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let expected = formatter.date(from: "12/31/2025")
        #expect(result == expected)
    }

    @Test("'MM/dd' format uses current year")
    func parsesMonthDay() {
        let result = parseDate("03/15")
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        var components = DateComponents()
        components.year = currentYear
        components.month = 3
        components.day = 15
        let expected = calendar.date(from: components)
        #expect(result == expected)
    }

    @Test("garbage input returns nil")
    func garbageReturnsNil() {
        #expect(parseDate("garbage") == nil)
        #expect(parseDate("not a date at all") == nil)
    }

    @Test("empty string returns nil")
    func emptyStringReturnsNil() {
        #expect(parseDate("") == nil)
    }
}

// MARK: - filterByDueDate Tests

@Suite("filterByDueDate")
struct FilterByDueDateTests {

    /// Helper to create a ReminderItem with an optional due date.
    private func makeReminder(
        id: String = "test-id",
        title: String = "Test Reminder",
        dueDate: Date? = nil
    ) -> ReminderItem {
        ReminderItem(
            id: id,
            title: title,
            isCompleted: false,
            priority: .none,
            dueDate: dueDate,
            listID: "list-1",
            listName: "Test List"
        )
    }

    @Test("nil dueDate filter returns all reminders")
    func nilDueDateReturnsAll() {
        let reminders = [
            makeReminder(id: "1", title: "A"),
            makeReminder(id: "2", title: "B"),
        ]
        let result = filterByDueDate(reminders, dueDate: nil, includeOverdue: false)
        #expect(result.count == 2)
    }

    @Test("unparseable dueDate filter returns all reminders")
    func unparseableDateReturnsAll() {
        let reminders = [
            makeReminder(id: "1", title: "A"),
            makeReminder(id: "2", title: "B"),
        ]
        let result = filterByDueDate(reminders, dueDate: "not-a-date", includeOverdue: false)
        #expect(result.count == 2)
    }

    @Test("filters out reminders without due dates")
    func filtersOutNoDueDate() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let reminders = [
            makeReminder(id: "1", title: "Has due date", dueDate: tomorrow),
            makeReminder(id: "2", title: "No due date", dueDate: nil),
        ]
        let result = filterByDueDate(reminders, dueDate: "tomorrow", includeOverdue: false)
        #expect(result.count == 1)
        #expect(result[0].id == "1")
    }

    @Test("includeOverdue includes past-due items")
    func includeOverdueIncludesPastDue() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let reminders = [
            makeReminder(id: "overdue", title: "Overdue", dueDate: yesterday),
            makeReminder(id: "upcoming", title: "Upcoming", dueDate: tomorrow),
        ]

        let withOverdue = filterByDueDate(reminders, dueDate: "tomorrow", includeOverdue: true)
        #expect(withOverdue.count == 2)

        let withoutOverdue = filterByDueDate(reminders, dueDate: "tomorrow", includeOverdue: false)
        #expect(withoutOverdue.count == 1)
        #expect(withoutOverdue[0].id == "upcoming")
    }

    @Test("filters to only reminders due on or before target date")
    func filtersByTargetDate() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let inTwoDays = calendar.date(byAdding: .day, value: 2, to: today)!
        let inTenDays = calendar.date(byAdding: .day, value: 10, to: today)!
        let reminders = [
            makeReminder(id: "soon", title: "Soon", dueDate: inTwoDays),
            makeReminder(id: "later", title: "Later", dueDate: inTenDays),
        ]
        // Filter for "next week" — should include the 2-day-out item but not the 10-day-out item
        let result = filterByDueDate(reminders, dueDate: "next week", includeOverdue: false)
        #expect(result.count == 1)
        #expect(result[0].id == "soon")
    }
}
