// ABOUTME: Wire-level tests for due_before/due_after on the MCP show tools.
// ABOUTME: Seeds due dates through the fake backend and asserts filtered output.

import Foundation
import RemindersTestSupport
import Testing

@testable import RemindersServer

@Suite("MCP due-date filters")
struct MCPDueFilterTests {

    @Test("show_reminders honors due_before")
    func showRemindersDueBefore() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(
            title: "soon", in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 6, day: 10)
        )
        backend.addReminder(
            title: "later", in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 6, day: 20)
        )
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_reminders","arguments":{"list":"Inbox","due_before":"2026-06-15"}}}"#
            ],
            backend: backend
        )
        let text = toolText(responses[0])
        #expect(toolIsError(responses[0]) == false)
        #expect(text.contains("soon"))
        #expect(!text.contains("later"))
    }

    @Test("show_all_reminders honors due_after")
    func showAllDueAfter() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(
            title: "soon", in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 6, day: 10)
        )
        backend.addReminder(
            title: "later", in: cal,
            dueDateComponents: DateComponents(year: 2026, month: 6, day: 20)
        )
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_all_reminders","arguments":{"due_after":"2026-06-15"}}}"#
            ],
            backend: backend
        )
        let text = toolText(responses[0])
        #expect(!text.contains("soon"))
        #expect(text.contains("later"))
    }

    @Test("an unparseable bound is a tool error naming the formats")
    func badBound() async {
        let backend = FakeEventStoreBackend()
        backend.addCalendar(named: "Inbox")
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_reminders","arguments":{"list":"Inbox","due_before":"whenever"}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == true)
        #expect(toolText(responses[0]).contains("yyyy-MM-dd"))
    }
}
