// ABOUTME: Date parsing and due-date filtering helpers for the CLI layer.
// ABOUTME: Supports multiple human-friendly date formats and overdue filtering.

import Foundation
import RemindersCore

/// Parses a user-supplied date string into a `Date`.
///
/// Supported formats (tried in order):
/// - `"today"` / `"tomorrow"` — midnight of the relevant day
/// - `"yyyy-MM-dd HH:mm"` — full date and time
/// - `"yyyy-MM-dd"` — date only (midnight)
/// - `"MM/dd/yyyy"` — US date format
/// - `"MM/dd"` — month and day in the current year
func parseDate(_ string: String) -> Date? {
    let trimmed = string.trimmingCharacters(in: .whitespaces).lowercased()
    let calendar = Calendar.current

    switch trimmed {
    case "today":
        return calendar.startOfDay(for: Date())
    case "tomorrow":
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
    case "next week":
        return calendar.date(byAdding: .weekOfYear, value: 1, to: calendar.startOfDay(for: Date()))
    default:
        break
    }

    let formats = [
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
        "MM/dd/yyyy",
        "MM/dd",
    ]

    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")

    for format in formats {
        dateFormatter.dateFormat = format
        if let date = dateFormatter.date(from: string) {
            // For "MM/dd" the year defaults to 2000; adjust to the current year.
            if format == "MM/dd" {
                let components = calendar.dateComponents([.month, .day], from: date)
                var adjusted = DateComponents()
                adjusted.year = calendar.component(.year, from: Date())
                adjusted.month = components.month
                adjusted.day = components.day
                return calendar.date(from: adjusted)
            }
            return date
        }
    }

    return nil
}

/// Filters reminders by an optional due-date string and/or overdue status.
///
/// - Parameters:
///   - reminders: The full array of reminders to filter.
///   - dueDate: A date string. If provided, only reminders due on or before that date are included.
///   - includeOverdue: When `true` alongside a `dueDate` filter, also includes reminders
///     whose due date is in the past (before today).
/// - Returns: The filtered array of reminders.
func filterByDueDate(
    _ reminders: [ReminderItem],
    dueDate: String?,
    includeOverdue: Bool
) -> [ReminderItem] {
    guard let dueDate else {
        return reminders
    }

    guard let targetDate = parseDate(dueDate) else {
        // If the date string is unparseable, return everything unfiltered.
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
