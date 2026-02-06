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

    @Argument(help: "The index of the reminder to delete.")
    var index: String

    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()
            let deletedTitle = try await store.delete(
                itemAtIndex: index,
                onList: listName
            )
            print("Deleted: \(deletedTitle)")
        }
    }
}
