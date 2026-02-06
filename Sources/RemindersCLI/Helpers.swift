// ABOUTME: Shared helper functions used across CLI subcommands.
// ABOUTME: Provides store initialization and graceful error handling wrappers.

import Foundation
import RemindersCore

/// Creates a `RemindersStore` and requests access in one step.
///
/// Every subcommand needs this sequence, so it is extracted here to avoid repetition.
func makeStore() async throws -> RemindersStore {
    let store = RemindersStore()
    try await store.requestAccess()
    return store
}

/// Runs a CLI action block with graceful error handling.
///
/// Catches `RemindersError` and other errors, printing a user-friendly message
/// to stderr instead of dumping a stack trace. Exits with code 1 on failure.
func withGracefulErrors(_ body: () async throws -> Void) async {
    do {
        try await body()
    } catch let error as RemindersError {
        printError(error.localizedDescription)
        Foundation.exit(1)
    } catch {
        printError(error.localizedDescription)
        Foundation.exit(1)
    }
}

/// Prints a message to stderr.
func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}
