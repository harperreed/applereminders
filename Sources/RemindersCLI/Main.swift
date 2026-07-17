// ABOUTME: Entry point for the reminders CLI tool.
// ABOUTME: Dispatches to CLI subcommands or MCP server mode.

import ArgumentParser
import Foundation
import RemindersCore
import RemindersServer

@main
struct RemindersTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Interact with macOS Reminders from the command line",
        subcommands: [
            ShowListsCommand.self,
            ShowCommand.self,
            ShowAllCommand.self,
            AddCommand.self,
            CompleteCommand.self,
            UncompleteCommand.self,
            DeleteCommand.self,
            EditCommand.self,
            NewListCommand.self,
            ServeCommand.self,
        ]
    )

    @Flag(help: "Run as MCP server over stdio")
    var mcp = false

    func run() async throws {
        if mcp {
            // Do not request Reminders access up front: a TCC denial here would kill
            // the process before the MCP handshake and the client would only see EOF.
            // MCPServer requests access per tools/call and reports denial as a tool error.
            let store = RemindersStore()
            await store.startObservingExternalChanges()
            let server = MCPServer(store: store)
            await server.run()
        } else {
            // No subcommand and no --mcp flag: print help.
            throw CleanExit.helpRequest(self)
        }
    }
}
