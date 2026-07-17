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
}
