// ABOUTME: CLI subcommand that marks a reminder as incomplete.
// ABOUTME: Resolves the index against completed reminders only, or accepts a stable id.

import ArgumentParser
import Foundation
import RemindersCore

struct UncompleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uncomplete",
        abstract: "Mark a reminder as incomplete"
    )

    @Argument(help: "The name of the reminder list.")
    var listName: String

    @Argument(help: ArgumentHelp("The reminder to reopen: a zero-based index into the COMPLETED "
        + "reminders (see `show <list> --only-completed`), or a stable id from "
        + "`show --format json`."))
    var index: String

    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()
            let updated = try await store.setComplete(
                false,
                itemAtIndex: index,
                onList: listName,
                onlyCompleted: true
            )
            print("Uncompleted: \(updated.title)")
        }
    }
}
