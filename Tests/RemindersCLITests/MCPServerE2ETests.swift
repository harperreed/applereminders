// ABOUTME: Protocol-level end-to-end tests: JSON-RPC lines in, JSON lines out.
// ABOUTME: Uses the fake backend, so no TCC grant is required.

import Foundation
import RemindersTestSupport
import Testing

@testable import reminders

@Suite("MCP server end to end")
struct MCPServerE2ETests {

    @Test("initialize and tools/list round-trip")
    func initializeAndList() async {
        let backend = FakeEventStoreBackend()
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            ],
            backend: backend
        )
        #expect(responses.count == 2)
        let initResult = responses[0]["result"] as? [String: Any]
        #expect(initResult?["protocolVersion"] as? String == "2024-11-05")
        let listResult = responses[1]["result"] as? [String: Any]
        let tools = listResult?["tools"] as? [[String: Any]]
        #expect(tools?.count == 9)
    }

    @Test("show_lists returns seeded lists as JSON text")
    func showLists() async {
        let backend = FakeEventStoreBackend()
        backend.addCalendar(named: "Groceries")
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_lists","arguments":{}}}"#
            ],
            backend: backend
        )
        #expect(responses.count == 1)
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("Groceries"))
    }

    @Test("TCC denial surfaces as an actionable tool error, not EOF")
    func authDenied() async {
        let backend = FakeEventStoreBackend()
        backend.authorizationStatus = .denied
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"show_lists","arguments":{}}}"#
            ],
            backend: backend
        )
        #expect(responses.count == 1)
        #expect(toolIsError(responses[0]) == true)
        #expect(toolText(responses[0]).contains("Grant access in System Settings"))
    }

    @Test("delete_reminder returns the deleted reminder as JSON")
    func deleteReturnsReminder() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "victim", in: cal, notes: "gone soon")
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_reminder","arguments":{"list":"Inbox","index":"0"}}}"#
            ],
            backend: backend
        )
        let text = toolText(responses[0])
        #expect(toolIsError(responses[0]) == false)
        #expect(text.contains("victim"))
        #expect(text.contains("gone soon"))
        #expect(backend.currentReminders.isEmpty)
    }

    @Test("complete_reminder accepts an integer index and counts the incomplete view")
    func completeIntegerIndexCountsIncompleteView() async {
        let backend = FakeEventStoreBackend()
        let cal = backend.addCalendar(named: "Inbox")
        backend.addReminder(title: "already done", in: cal, isCompleted: true)
        backend.addReminder(title: "first open", in: cal)
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"complete_reminder","arguments":{"list":"Inbox","index":0}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == false)
        #expect(toolText(responses[0]).contains("first open"))
    }

    @Test("malformed JSON gets a -32700 parse error with null id")
    func parseError() async {
        let backend = FakeEventStoreBackend()
        let responses = await runMCPServer(lines: ["this is not json"], backend: backend)
        #expect(responses.count == 1)
        let error = responses[0]["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32700)
        #expect(responses[0]["id"] is NSNull)
    }

    @Test("unknown method with an id gets -32601")
    func unknownMethod() async {
        let backend = FakeEventStoreBackend()
        let responses = await runMCPServer(
            lines: [#"{"jsonrpc":"2.0","id":3,"method":"bogus/method"}"#],
            backend: backend
        )
        #expect(responses.count == 1)
        let error = responses[0]["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32601)
    }

    @Test("unknown tool name returns a tool error listing tools/list")
    func unknownTool() async {
        let backend = FakeEventStoreBackend()
        let responses = await runMCPServer(
            lines: [
                #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#
            ],
            backend: backend
        )
        #expect(toolIsError(responses[0]) == true)
        #expect(toolText(responses[0]).contains("tools/list"))
    }
}
