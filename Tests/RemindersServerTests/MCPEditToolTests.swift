// ABOUTME: Wire-level tests for the expanded edit_reminder and delete_reminder tools.
// ABOUTME: Exercises due date set/clear, priority, moves, and completed targeting via JSON-RPC.

import Foundation
import RemindersTestSupport
import Testing

@testable import RemindersServer

@Suite("MCP edit and delete tool surfaces")
struct MCPEditToolTests {

    @Test("edit_reminder sets a due date")
    func editSetsDueDate() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "task", in: cal)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","due_date":"2026-12-31"}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("2026-12-31"))
    }

    @Test("edit_reminder clears a due date")
    func editClearsDueDate() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(
            title: "task",
            in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 12, day: 31)
        )
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","clear_due_date":true}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("\"dueDate\" : null"))
    }

    @Test("edit_reminder rejects due_date combined with clear_due_date")
    func editRejectsConflict() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "task", in: cal)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","due_date":"today","clear_due_date":true}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == true)
        #expect(toolText(responses[0]).contains("clear_due_date"))
    }

    @Test("edit_reminder rejects an unparseable due_date, naming the formats")
    func editRejectsBadDate() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "task", in: cal)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","due_date":"someday"}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == true)
        #expect(toolText(responses[0]).contains("yyyy-MM-dd"))
    }

    @Test("edit_reminder moves a reminder and sets priority")
    func editMovesAndSetsPriority() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addCalendar(named: "Archive")
        backend.addReminder(title: "task", in: cal)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","move_to_list":"Archive","priority":"high"}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        let text = toolText(responses[0])
        #expect(text.contains("Archive"))
        #expect(text.contains("high"))
    }

    @Test("edit_reminder targets a completed reminder with include_completed")
    func editCompletedReminder() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "done", in: cal, isCompleted: true)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_reminder","arguments":{"list":"Inbox","index":"0","title":"done, renamed","include_completed":true}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("done, renamed"))
    }

    @Test("delete_reminder removes a completed reminder with include_completed")
    func deleteCompletedReminder() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "old done", in: cal, isCompleted: true)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_reminder","arguments":{"list":"Inbox","index":"0","include_completed":true}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("old done"))
        #expect(backend.currentReminders.isEmpty)
    }
}
