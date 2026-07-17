// ABOUTME: CLI subcommand that edits the title and/or notes of a reminder.
// ABOUTME: Supports title, notes, due date set/clear, priority, list moves, and completed targeting.

import ArgumentParser
import Foundation
import RemindersCore

struct EditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit a reminder's title or notes"
    )

    @Argument(help: "The name of the reminder list.")
    var listName: String

    @Argument(help: ArgumentHelp("The reminder to edit: a zero-based index from `show`, "
        + "or a stable id from `show --format json`."))
    var index: String

    @Argument(parsing: .remaining, help: "New title text (joined with spaces). Omit to keep the current title.")
    var newText: [String] = []

    @Option(name: [.short, .long], help: "New notes for the reminder.")
    var notes: String?

    @Option(name: [.short, .long], help: "New due date (e.g. today, tomorrow, 2025-12-31, MM/dd).")
    var dueDate: String?

    @Flag(name: .long, help: "Remove the due date (and its alarm) from the reminder.")
    var clearDueDate = false

    @Option(name: [.short, .long], help: "New priority: none, low, medium, or high.")
    var priority: String?

    @Option(name: .long, help: ArgumentHelp("Move the reminder to this list."))
    var moveTo: String?

    @Flag(name: .long, help: ArgumentHelp("Allow targeting completed reminders. The index then "
        + "counts the combined view shown by `show --include-completed`; stable ids are unaffected."))
    var includeCompleted = false

    func validate() throws {
        if dueDate != nil && clearDueDate {
            throw ValidationError("Cannot use --due-date and --clear-due-date together.")
        }

        if let dueDate {
            guard parseDate(dueDate) != nil else {
                throw ValidationError(
                    "Could not parse date \"\(dueDate)\". Supported formats: \(supportedDateFormats)."
                )
            }
        }

        if let priority {
            guard ReminderPriority(rawValue: priority.lowercased()) != nil else {
                throw ValidationError(
                    "Invalid priority \"\(priority)\". "
                    + "Must be one of: none, low, medium, high."
                )
            }
        }

        let hasChange = !newText.isEmpty || notes != nil || dueDate != nil
            || clearDueDate || priority != nil || moveTo != nil
        if !hasChange {
            throw ValidationError(
                "Nothing to edit: provide new title text or at least one of "
                + "--notes, --due-date, --clear-due-date, --priority, --move-to."
            )
        }
    }

    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()

            let titleText: String? = newText.isEmpty ? nil : newText.joined(separator: " ")

            let dueDateChange: Date??
            if clearDueDate {
                dueDateChange = .some(nil)
            } else if let dueDate, let parsed = parseDate(dueDate) {
                dueDateChange = .some(parsed)
            } else {
                dueDateChange = nil
            }

            let parsedPriority = priority.flatMap { ReminderPriority(rawValue: $0.lowercased()) }

            let updated = try await store.update(
                itemAtIndex: index,
                onList: listName,
                with: ReminderUpdate(
                    title: titleText,
                    notes: notes,
                    dueDate: dueDateChange,
                    priority: parsedPriority,
                    listName: moveTo
                ),
                includeCompleted: includeCompleted
            )
            print("Edited: \(Formatter.format(updated))")
        }
    }
}
