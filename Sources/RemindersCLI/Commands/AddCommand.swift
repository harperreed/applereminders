// ABOUTME: CLI subcommand that adds a new reminder to a specified list.
// ABOUTME: Supports setting due date, priority, and notes on creation.

import ArgumentParser
import Foundation
import RemindersCore

struct AddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a reminder to a list"
    )

    @Argument(help: "The name of the reminder list.")
    var listName: String

    @Argument(parsing: .remaining, help: "The reminder title (joined with spaces).")
    var reminder: [String]

    @Option(name: [.short, .long], help: "Due date (e.g. today, tomorrow, 2025-12-31, MM/dd).")
    var dueDate: String?

    @Option(name: [.short, .long], help: "Priority: none, low, medium, or high.")
    var priority: String?

    @Option(name: [.short, .long], help: "Notes to attach to the reminder.")
    var notes: String?

    @Option(name: [.short, .long], help: "Output format (plain or json).")
    var format: OutputFormat = .plain

    func validate() throws {
        if reminder.isEmpty {
            throw ValidationError("Please provide the reminder title.")
        }

        if let priority {
            guard ReminderPriority(rawValue: priority.lowercased()) != nil else {
                throw ValidationError(
                    "Invalid priority \"\(priority)\". "
                    + "Must be one of: none, low, medium, high."
                )
            }
        }

        if let dueDate {
            guard parseDate(dueDate) != nil else {
                throw ValidationError(
                    "Could not parse date \"\(dueDate)\". "
                    + "Supported formats: today, tomorrow, next week, yyyy-MM-dd, MM/dd/yyyy, MM/dd."
                )
            }
        }
    }

    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()
            let title = reminder.joined(separator: " ")

            let parsedPriority: ReminderPriority
            if let priority {
                parsedPriority = ReminderPriority(rawValue: priority.lowercased()) ?? .none
            } else {
                parsedPriority = .none
            }

            let parsedDueDate: Date?
            if let dueDate {
                parsedDueDate = parseDate(dueDate)
            } else {
                parsedDueDate = nil
            }

            let draft = ReminderDraft(
                title: title,
                notes: notes,
                dueDate: parsedDueDate,
                priority: parsedPriority
            )

            let created = try await store.addReminder(draft, toList: listName)

            switch format {
            case .plain:
                print("Added: \(Formatter.format(created))")
            case .json:
                Formatter.printJSON(created)
            }
        }
    }
}
