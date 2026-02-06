// ABOUTME: CLI subcommand that marks a reminder as incomplete.
// ABOUTME: Identifies the reminder by its index within the specified list.

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

    @Argument(help: "The index of the reminder to uncomplete.")
    var index: String

    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()
            let updated = try await store.setComplete(
                false,
                itemAtIndex: index,
                onList: listName
            )
            print("Uncompleted: \(updated.title)")
        }
    }
}
