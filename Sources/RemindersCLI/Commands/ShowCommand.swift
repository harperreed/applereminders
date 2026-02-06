// ABOUTME: CLI subcommand that prints reminders from a specific list.
// ABOUTME: Supports filtering by completion status, due date, and overdue items.

import ArgumentParser
import Foundation
import RemindersCore

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the reminders in a specific list"
    )

    @Argument(help: "The name of the reminder list.")
    var listName: String

    @Flag(name: .long, help: "Show only completed reminders.")
    var onlyCompleted = false

    @Flag(name: .long, help: "Include completed reminders in the output.")
    var includeCompleted = false

    @Flag(name: .long, help: "Include overdue reminders when filtering by due date.")
    var includeOverdue = false

    @Option(name: [.short, .long], help: "Filter reminders by due date.")
    var dueDate: String?

    @Option(name: [.short, .long], help: "Output format (plain or json).")
    var format: OutputFormat = .plain

    func validate() throws {
        if onlyCompleted && includeCompleted {
            throw ValidationError(
                "Cannot use --only-completed and --include-completed together."
            )
        }
    }

    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()
            var reminders = try await store.reminders(
                inList: listName,
                includeCompleted: onlyCompleted || includeCompleted,
                onlyCompleted: onlyCompleted
            )

            reminders = filterByDueDate(
                reminders,
                dueDate: dueDate,
                includeOverdue: includeOverdue
            )

            Formatter.printReminders(
                reminders,
                outputFormat: format
            )
        }
    }
}
