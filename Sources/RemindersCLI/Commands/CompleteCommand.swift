// ABOUTME: CLI subcommand that marks a reminder as completed.
// ABOUTME: Identifies the reminder by its index within the specified list.

import ArgumentParser
import Foundation
import RemindersCore

struct CompleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "complete",
        abstract: "Mark a reminder as completed"
    )

    @Argument(help: "The name of the reminder list.")
    var listName: String

    @Argument(help: "The index of the reminder to complete.")
    var index: String

    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()
            let updated = try await store.setComplete(
                true,
                itemAtIndex: index,
                onList: listName
            )
            print("Completed: \(updated.title)")
        }
    }
}
