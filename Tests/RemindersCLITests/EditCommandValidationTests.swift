// ABOUTME: Validation and parse tests for the expanded edit and delete commands.
// ABOUTME: Locks flag names, mutual exclusions, and the no-op edit rejection.

import ArgumentParser
import Foundation
import Testing

@testable import reminders

@Suite("edit and delete command validation")
struct EditCommandValidationTests {

    @Test("edit accepts a due date, priority, move, and include-completed together")
    func editParsesNewFlags() throws {
        let cmd = try EditCommand.parse([
            "Inbox", "0",
            "--due-date", "tomorrow",
            "--priority", "high",
            "--move-to", "Archive",
            "--include-completed",
        ])
        #expect(cmd.dueDate == "tomorrow")
        #expect(cmd.priority == "high")
        #expect(cmd.moveTo == "Archive")
        #expect(cmd.includeCompleted == true)
    }

    @Test("edit rejects --due-date combined with --clear-due-date")
    func editRejectsDueDateWithClear() {
        do {
            _ = try EditCommand.parse([
                "Inbox", "0", "--due-date", "today", "--clear-due-date",
            ])
            Issue.record("Expected a validation error")
        } catch {
            #expect(EditCommand.message(for: error).contains("--clear-due-date"))
        }
    }

    @Test("edit rejects an unparseable due date and names the formats")
    func editRejectsBadDate() {
        do {
            _ = try EditCommand.parse(["Inbox", "0", "--due-date", "someday"])
            Issue.record("Expected a validation error")
        } catch {
            #expect(EditCommand.message(for: error).contains("yyyy-MM-dd"))
        }
    }

    @Test("edit rejects an invalid priority")
    func editRejectsBadPriority() {
        do {
            _ = try EditCommand.parse(["Inbox", "0", "--priority", "urgent"])
            Issue.record("Expected a validation error")
        } catch {
            #expect(EditCommand.message(for: error).contains("none, low, medium, high"))
        }
    }

    @Test("edit with nothing to change is rejected")
    func editRejectsNoOp() {
        do {
            _ = try EditCommand.parse(["Inbox", "0"])
            Issue.record("Expected a validation error")
        } catch {
            #expect(EditCommand.message(for: error).contains("Nothing to edit"))
        }
    }

    @Test("edit with only new title text is accepted")
    func editTitleOnly() throws {
        let cmd = try EditCommand.parse(["Inbox", "0", "New", "title"])
        #expect(cmd.newText == ["New", "title"])
    }

    @Test("edit help documents the new flags")
    func editHelp() {
        let help = EditCommand.helpMessage(columns: 500)
        #expect(help.contains("--clear-due-date"))
        #expect(help.contains("--move-to"))
        #expect(help.contains("--include-completed"))
    }

    @Test("delete accepts and documents --include-completed")
    func deleteIncludeCompleted() throws {
        let cmd = try DeleteCommand.parse(["Inbox", "0", "--include-completed"])
        #expect(cmd.includeCompleted == true)
        #expect(DeleteCommand.helpMessage(columns: 500).contains("--include-completed"))
    }
}
