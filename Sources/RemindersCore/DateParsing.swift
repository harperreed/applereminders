// ABOUTME: Date parsing and due-date filtering helpers shared by the CLI, MCP, and REST surfaces.
// ABOUTME: Supports multiple human-friendly date formats and due-window filtering.

import Foundation

/// Single source of truth for the date formats accepted by `parseDate`, in the order tried.
/// Every error message that rejects a date string must reference this list.
public let supportedDateFormats = "today, tomorrow, next week, yyyy-MM-dd, yyyy-MM-dd HH:mm, MM/dd/yyyy, MM/dd"

/// Parses a user-supplied date string into a `Date`.
///
/// Supported formats (tried in order):
/// - `"today"` / `"tomorrow"` — midnight of the relevant day
/// - `"yyyy-MM-dd HH:mm"` — full date and time
/// - `"yyyy-MM-dd"` — date only (midnight)
/// - `"MM/dd/yyyy"` — US date format
/// - `"MM/dd"` — month and day in the current year
public func parseDate(_ string: String) -> Date? {
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
public func filterByDueWindow(
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
public func filterByDueDate(
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
