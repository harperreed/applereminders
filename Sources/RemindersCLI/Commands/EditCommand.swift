// ABOUTME: CLI subcommand that edits the title and/or notes of a reminder.
// ABOUTME: Identifies the reminder by its index within the specified list.

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

    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()

            let titleText: String? = newText.isEmpty ? nil : newText.joined(separator: " ")

            let updated = try await store.update(
                itemAtIndex: index,
                onList: listName,
                with: ReminderUpdate(title: titleText, notes: notes)
            )
            print("Edited: \(Formatter.format(updated))")
        }
    }
}
