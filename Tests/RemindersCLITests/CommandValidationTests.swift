// ABOUTME: Tests for CLI argument validation of --due-date across show, show-all, and add.
// ABOUTME: Proves unparseable dates are rejected at parse time with the full format list.

import ArgumentParser
import Foundation
import Testing

@testable import reminders

@Suite("Command date validation")
struct CommandValidationTests {

    @Test("show rejects an unparseable --due-date")
    func showRejectsBadDate() {
        #expect(throws: (any Error).self) {
            _ = try ShowCommand.parse(["MyList", "--due-date", "definitely-not-a-date"])
        }
    }

    @Test("show accepts a valid --due-date")
    func showAcceptsGoodDate() throws {
        _ = try ShowCommand.parse(["MyList", "--due-date", "tomorrow"])
    }

    @Test("show-all rejects an unparseable --due-date")
    func showAllRejectsBadDate() {
        #expect(throws: (any Error).self) {
            _ = try ShowAllCommand.parse(["--due-date", "definitely-not-a-date"])
        }
    }

    @Test("show-all accepts a valid --due-date")
    func showAllAcceptsGoodDate() throws {
        _ = try ShowAllCommand.parse(["--due-date", "2026-12-31"])
    }

    @Test("add's rejection message lists every supported format")
    func addErrorListsAllFormats() {
        do {
            _ = try AddCommand.parse(
                ["MyList", "--due-date", "definitely-not-a-date", "Buy", "milk"]
            )
            Issue.record("expected a validation error")
        } catch {
            let message = AddCommand.message(for: error)
            #expect(message.contains("next week"))
            #expect(message.contains("yyyy-MM-dd HH:mm"))
        }
    }

    @Test("show's rejection message lists every supported format")
    func showErrorListsAllFormats() {
        do {
            _ = try ShowCommand.parse(["MyList", "--due-date", "definitely-not-a-date"])
            Issue.record("expected a validation error")
        } catch {
            let message = ShowCommand.message(for: error)
            #expect(message.contains("yyyy-MM-dd HH:mm"))
        }
    }
}
