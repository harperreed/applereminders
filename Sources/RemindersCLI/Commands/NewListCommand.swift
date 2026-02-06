// ABOUTME: CLI subcommand that creates a new reminder list.
// ABOUTME: Optionally specifies the backing source (e.g. iCloud, Local).

import ArgumentParser
import Foundation
import RemindersCore

struct NewListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new-list",
        abstract: "Create a new reminder list"
    )

    @Argument(help: "The name for the new list.")
    var listName: String

    @Option(name: .long, help: "The source to back the list (e.g. iCloud).")
    var source: String?

    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()
            let created = try await store.createList(
                name: listName,
                sourceName: source
            )
            print("Created list: \(created.title)")
        }
    }
}
