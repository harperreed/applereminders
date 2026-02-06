// ABOUTME: Tests for JSON-RPC 2.0 and MCP protocol types.
// ABOUTME: Covers RequestID, JSONValue, JSONRPCRequest, MCPToolDefinition, and MCPToolResult.

import Foundation
import Testing

@testable import reminders

// MARK: - RequestID Tests

@Suite("RequestID")
struct RequestIDTests {

    @Test("decodes integer ID")
    func decodeInt() throws {
        let json = Data("42".utf8)
        let decoded = try JSONDecoder().decode(RequestID.self, from: json)
        #expect(decoded == .int(42))
    }

    @Test("decodes string ID")
    func decodeString() throws {
        let json = Data("\"abc-123\"".utf8)
        let decoded = try JSONDecoder().decode(RequestID.self, from: json)
        #expect(decoded == .string("abc-123"))
    }

    @Test("encodes integer ID")
    func encodeInt() throws {
        let data = try JSONEncoder().encode(RequestID.int(7))
        let str = String(data: data, encoding: .utf8)
        #expect(str == "7")
    }

    @Test("encodes string ID")
    func encodeString() throws {
        let data = try JSONEncoder().encode(RequestID.string("req-1"))
        let str = String(data: data, encoding: .utf8)
        #expect(str == "\"req-1\"")
    }

    @Test("decoding an invalid type throws")
    func decodeInvalidThrows() {
        let json = Data("[1, 2, 3]".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RequestID.self, from: json)
        }
    }
}

// MARK: - JSONValue Tests

@Suite("JSONValue")
struct JSONValueTests {

    // MARK: Decode / Encode round-trips

    @Test("decodes and encodes string")
    func stringRoundTrip() throws {
        let json = Data("\"hello\"".utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        #expect(value == .string("hello"))

        let encoded = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(back == value)
    }

    @Test("decodes and encodes integer")
    func intRoundTrip() throws {
        let json = Data("99".utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        #expect(value == .int(99))

        let encoded = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(back == value)
    }

    @Test("decodes and encodes double")
    func doubleRoundTrip() throws {
        let json = Data("3.14".utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        #expect(value == .double(3.14))

        let encoded = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(back == value)
    }

    @Test("decodes and encodes bool")
    func boolRoundTrip() throws {
        let jsonTrue = Data("true".utf8)
        let valueTrue = try JSONDecoder().decode(JSONValue.self, from: jsonTrue)
        #expect(valueTrue == .bool(true))

        let jsonFalse = Data("false".utf8)
        let valueFalse = try JSONDecoder().decode(JSONValue.self, from: jsonFalse)
        #expect(valueFalse == .bool(false))
    }

    @Test("decodes and encodes null")
    func nullRoundTrip() throws {
        let json = Data("null".utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        #expect(value == .null)

        let encoded = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(back == value)
    }

    @Test("decodes and encodes array")
    func arrayRoundTrip() throws {
        let json = Data("[1, \"two\", true]".utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        #expect(value == .array([.int(1), .string("two"), .bool(true)]))

        let encoded = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(back == value)
    }

    @Test("decodes and encodes object")
    func objectRoundTrip() throws {
        let json = Data("{\"key\":\"value\"}".utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        #expect(value == .object(["key": .string("value")]))

        let encoded = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(back == value)
    }

    // MARK: Accessor tests

    @Test("stringValue returns String for .string, nil otherwise")
    func stringValueAccessor() {
        #expect(JSONValue.string("hello").stringValue() == "hello")
        #expect(JSONValue.int(42).stringValue() == nil)
        #expect(JSONValue.null.stringValue() == nil)
    }

    @Test("boolValue returns Bool for .bool, nil otherwise")
    func boolValueAccessor() {
        #expect(JSONValue.bool(true).boolValue() == true)
        #expect(JSONValue.bool(false).boolValue() == false)
        #expect(JSONValue.string("true").boolValue() == nil)
        #expect(JSONValue.int(1).boolValue() == nil)
    }

    @Test("objectValue returns dictionary for .object, nil otherwise")
    func objectValueAccessor() {
        let dict: [String: JSONValue] = ["a": .int(1)]
        #expect(JSONValue.object(dict).objectValue() == dict)
        #expect(JSONValue.string("nope").objectValue() == nil)
        #expect(JSONValue.array([]).objectValue() == nil)
    }

    @Test("intValue returns Int for .int, nil otherwise")
    func intValueAccessor() {
        #expect(JSONValue.int(42).intValue() == 42)
        #expect(JSONValue.string("42").intValue() == nil)
        #expect(JSONValue.double(42.0).intValue() == nil)
        #expect(JSONValue.bool(true).intValue() == nil)
    }
}

// MARK: - JSONRPCRequest Tests

@Suite("JSONRPCRequest")
struct JSONRPCRequestTests {

    @Test("decodes a valid request with all fields")
    func decodeFullRequest() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "list_reminders"}
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: json)
        #expect(request.jsonrpc == "2.0")
        #expect(request.id == .int(1))
        #expect(request.method == "tools/call")
        #expect(request.params != nil)
        #expect(request.params?.objectValue()?["name"] == .string("list_reminders"))
    }

    @Test("decodes a notification (no id)")
    func decodeNotification() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: json)
        #expect(request.jsonrpc == "2.0")
        #expect(request.id == nil)
        #expect(request.method == "notifications/initialized")
        #expect(request.params == nil)
    }

    @Test("decodes a request with a string id")
    func decodeStringId() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": "req-42",
            "method": "initialize"
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: json)
        #expect(request.id == .string("req-42"))
    }
}

// MARK: - MCPToolDefinition Tests

@Suite("MCPToolDefinition")
struct MCPToolDefinitionTests {

    @Test("encodes to correct JSON structure")
    func encodesCorrectly() throws {
        let tool = MCPToolDefinition(
            name: "list_reminders",
            description: "List all reminders",
            inputSchema: JSONSchema(
                type: "object",
                properties: [
                    "listName": PropertySchema(
                        type: "string",
                        description: "Name of the list",
                        enum: nil
                    )
                ],
                required: ["listName"]
            )
        )

        let data = try JSONEncoder().encode(tool)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["name"] as? String == "list_reminders")
        #expect(dict["description"] as? String == "List all reminders")

        let schema = dict["inputSchema"] as? [String: Any]
        #expect(schema?["type"] as? String == "object")

        let properties = schema?["properties"] as? [String: Any]
        let listNameProp = properties?["listName"] as? [String: Any]
        #expect(listNameProp?["type"] as? String == "string")
        #expect(listNameProp?["description"] as? String == "Name of the list")

        let required = schema?["required"] as? [String]
        #expect(required == ["listName"])
    }

    @Test("PropertySchema with enum values encodes correctly")
    func propertySchemaWithEnum() throws {
        let prop = PropertySchema(
            type: "string",
            description: "Priority level",
            enum: ["low", "medium", "high"]
        )

        let data = try JSONEncoder().encode(prop)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["type"] as? String == "string")
        #expect(dict["enum"] as? [String] == ["low", "medium", "high"])
    }

    @Test("PropertySchema without enum omits the key")
    func propertySchemaWithoutEnum() throws {
        let prop = PropertySchema(
            type: "string",
            description: "A field",
            enum: nil
        )

        let data = try JSONEncoder().encode(prop)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["enum"] == nil)
    }
}

// MARK: - MCPToolResult Tests

@Suite("MCPToolResult")
struct MCPToolResultTests {

    @Test("success factory creates result without error flag")
    func successFactory() throws {
        let result = MCPToolResult.success("All good")

        #expect(result.content.count == 1)
        #expect(result.content[0].text == "All good")
        #expect(result.content[0].type == "text")
        #expect(result.isError == nil)
    }

    @Test("error factory creates result with isError true")
    func errorFactory() throws {
        let result = MCPToolResult.error("Something went wrong")

        #expect(result.content.count == 1)
        #expect(result.content[0].text == "Something went wrong")
        #expect(result.content[0].type == "text")
        #expect(result.isError == true)
    }

    @Test("success result encodes without isError key")
    func successEncoding() throws {
        let result = MCPToolResult.success("ok")
        let data = try JSONEncoder().encode(result)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let content = dict["content"] as? [[String: Any]]
        #expect(content?.count == 1)
        #expect(content?[0]["text"] as? String == "ok")
        // isError is nil so it should not appear in the JSON
        #expect(dict["isError"] == nil)
    }

    @Test("error result encodes with isError true")
    func errorEncoding() throws {
        let result = MCPToolResult.error("fail")
        let data = try JSONEncoder().encode(result)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["isError"] as? Bool == true)
    }

    @Test("MCPTextContent type is always 'text'")
    func textContentType() throws {
        let content = MCPTextContent(text: "hello")
        let data = try JSONEncoder().encode(content)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["type"] as? String == "text")
        #expect(dict["text"] as? String == "hello")
    }
}
