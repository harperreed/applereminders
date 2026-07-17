// ABOUTME: CLI subcommand that deletes a reminder from a list.
// ABOUTME: Identifies the reminder by its index within the specified list.

import ArgumentParser
import Foundation
import RemindersCore

struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a reminder from a list"
    )

    @Argument(help: "The name of the reminder list.")
    var listName: String

    @Argument(help: ArgumentHelp("The reminder to delete: a zero-based index from `show`, "
        + "or a stable id from `show --format json`."))
    var index: String

    @Flag(name: .long, help: ArgumentHelp("Allow targeting completed reminders. The index then "
        + "counts the combined view shown by `show --include-completed`; stable ids are unaffected."))
    var includeCompleted = false

    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()
            let deleted = try await store.delete(
                itemAtIndex: index,
                onList: listName,
                includeCompleted: includeCompleted
            )
            print("Deleted: \(deleted.title)")
        }
    }
}
