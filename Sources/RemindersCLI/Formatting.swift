// ABOUTME: Output formatting for the reminders CLI tool.
// ABOUTME: Handles plain-text and JSON rendering of reminder items and lists.

import ArgumentParser
import Foundation
import RemindersCore

// MARK: - OutputFormat

/// Controls whether output is printed as human-readable text or machine-readable JSON.
enum OutputFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
    case plain
    case json
}

// MARK: - Formatter

/// Static methods for rendering reminders and lists to stdout.
enum Formatter {

    /// Formats a single reminder as a human-readable string.
    ///
    /// Produces: `"[listName: ][index: ]title[ (notes)][ (relative due date)][ (priority: level)]"`
    static func format(
        _ reminder: ReminderItem,
        at index: Int? = nil,
        listName: String? = nil
    ) -> String {
        var parts: [String] = []

        if let listName {
            parts.append("\(listName):")
        }

        if let index {
            parts.append("\(index):")
        }

        parts.append(reminder.title)

        if let notes = reminder.notes, !notes.isEmpty {
            parts.append("(\(notes))")
        }

        if let dueDate = reminder.dueDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(for: dueDate, relativeTo: Date())
            parts.append("(\(relative))")
        }

        if reminder.priority != .none {
            parts.append("(priority: \(reminder.priority.rawValue))")
        }

        return parts.joined(separator: " ")
    }

    /// Prints an array of reminders in the chosen format.
    ///
    /// In plain mode, each reminder is printed on its own line with an index.
    /// In JSON mode, the entire array is pretty-printed.
    static func printReminders(
        _ reminders: [ReminderItem],
        outputFormat: OutputFormat,
        showListName: Bool = false
    ) {
        switch outputFormat {
        case .plain:
            for (index, reminder) in reminders.enumerated() {
                let line = format(
                    reminder,
                    at: index,
                    listName: showListName ? reminder.listName : nil
                )
                print(line)
            }
        case .json:
            printJSON(reminders)
        }
    }

    /// Pretty-prints any Encodable value as JSON with sorted keys and ISO 8601 dates.
    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(value)
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }
        } catch {
            print("Error encoding JSON: \(error.localizedDescription)")
        }
    }
}
