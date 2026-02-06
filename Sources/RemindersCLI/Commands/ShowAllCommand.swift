// ABOUTME: CLI subcommand that prints all reminders across every list.
// ABOUTME: Supports filtering by completion status, due date, and overdue items.

import ArgumentParser
import Foundation
import RemindersCore

struct ShowAllCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show-all",
        abstract: "Print all reminders across every list"
    )

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
                outputFormat: format,
                showListName: true
            )
        }
    }
}
