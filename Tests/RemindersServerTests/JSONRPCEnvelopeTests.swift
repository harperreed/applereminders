// ABOUTME: Tests for JSON-RPC envelope types encoded via JSONEncoder.
// ABOUTME: Proves error messages and string IDs with special characters survive encoding.

import Foundation
import Testing

@testable import RemindersServer

@Suite("JSON-RPC envelopes")
struct JSONRPCEnvelopeTests {

    private struct DecodedError: Decodable {
        struct Body: Decodable {
            let code: Int
            let message: String
        }
        let jsonrpc: String
        let error: Body
    }

    @Test("error message with quotes, tabs, CR, and control chars stays valid JSON")
    func errorMessageSurvivesSpecialCharacters() throws {
        let hostile = "path \"quoted\"\twith\ttabs\r\nand control\u{01}chars\\backslash"
        let envelope = JSONRPCErrorResponse(
            id: .int(3),
            error: JSONRPCErrorBody(code: -32603, message: hostile)
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(DecodedError.self, from: data)

        #expect(decoded.jsonrpc == "2.0")
        #expect(decoded.error.code == -32603)
        #expect(decoded.error.message == hostile)
    }

    @Test("string request ID with quote and backslash round-trips")
    func stringIDSurvivesSpecialCharacters() throws {
        let envelope = JSONRPCErrorResponse(
            id: .string("req \"7\" \\ end"),
            error: JSONRPCErrorBody(code: -32700, message: "Parse error")
        )

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["id"] as? String == "req \"7\" \\ end")
    }

    @Test("missing request ID encodes as explicit null")
    func nilIDEncodesAsNull() throws {
        let envelope = JSONRPCErrorResponse(
            id: nil,
            error: JSONRPCErrorBody(code: -32700, message: "Parse error")
        )

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object != nil)
        #expect(object?.keys.contains("id") == true)
        #expect(object?["id"] is NSNull)
    }

    @Test("success envelope wraps the result under 'result'")
    func successEnvelopeShape() throws {
        let envelope = JSONRPCResponse(id: .int(1), result: MCPToolResult.success("ok"))

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["jsonrpc"] as? String == "2.0")
        #expect(object?["id"] as? Int == 1)
        let result = object?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "ok")
    }

    @Test("tools/list result nests tools under the result object")
    func toolsListResultShape() throws {
        let tool = MCPToolDefinition(
            name: "demo",
            description: "Demo tool",
            inputSchema: JSONSchema(type: "object", properties: nil, required: nil)
        )
        let envelope = JSONRPCResponse(id: .string("a"), result: ToolsListResult(tools: [tool]))

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = object?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]

        #expect(tools?.count == 1)
        #expect(tools?.first?["name"] as? String == "demo")
    }
}
