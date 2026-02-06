// ABOUTME: CLI subcommand that prints all reminder list names.
// ABOUTME: Supports plain text and JSON output formats.

import ArgumentParser
import Foundation
import RemindersCore

struct ShowListsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show-lists",
        abstract: "Print the name of each reminder list"
    )

    @Option(name: [.short, .long], help: "Output format (plain or json).")
    var format: OutputFormat = .plain

    func run() async throws {
        await withGracefulErrors {
            let store = try await makeStore()
            let allLists = await store.lists()

            switch format {
            case .plain:
                for list in allLists {
                    print(list.title)
                }
            case .json:
                Formatter.printJSON(allLists)
            }
        }
    }
}
