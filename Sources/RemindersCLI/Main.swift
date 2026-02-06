// ABOUTME: Entry point for the reminders CLI tool.
// ABOUTME: Dispatches to CLI subcommands or MCP server mode.
import ArgumentParser
import Foundation
import RemindersCore

@main
struct RemindersTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Interact with macOS Reminders from the command line"
    )
}
