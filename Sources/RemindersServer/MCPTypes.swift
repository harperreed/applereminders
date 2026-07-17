// ABOUTME: JSON-RPC 2.0 and MCP protocol types for the stdio server.
// ABOUTME: Defines request/response envelopes, tool definitions, and a recursive JSON value type.

import Foundation

// MARK: - RequestID

/// A JSON-RPC request ID that can be either a string or an integer.
enum RequestID: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(
                RequestID.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Request ID must be a string or integer"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }
}

// MARK: - JSONValue

/// A recursive enum representing any valid JSON value.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Helper accessors

    /// Returns the underlying `String` if this is a `.string`, otherwise `nil`.
    func stringValue() -> String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Returns the underlying `Bool` if this is a `.bool`, otherwise `nil`.
    func boolValue() -> Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Returns the underlying dictionary if this is an `.object`, otherwise `nil`.
    func objectValue() -> [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Returns the underlying `Int` if this is an `.int`, otherwise `nil`.
    func intValue() -> Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    // MARK: Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Cannot decode JSON value"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - JSONRPCRequest

/// An incoming JSON-RPC 2.0 request or notification.
struct JSONRPCRequest: Decodable, Sendable {
    let jsonrpc: String
    let id: RequestID?
    let method: String
    let params: JSONValue?
}

// MARK: - JSON-RPC Responses

/// An outgoing JSON-RPC 2.0 success envelope. Encoding via JSONEncoder guarantees
/// correct escaping of IDs and results; never build these by string concatenation.
struct JSONRPCResponse<Payload: Encodable & Sendable>: Encodable, Sendable {
    let id: RequestID?
    let result: Payload

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        // JSON-RPC 2.0 requires an explicit `"id": null` when the request ID is unknown.
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
        try container.encode(result, forKey: .result)
    }
}

/// The `error` member of a JSON-RPC 2.0 error response.
struct JSONRPCErrorBody: Encodable, Sendable, Equatable {
    let code: Int
    let message: String
}

/// An outgoing JSON-RPC 2.0 error envelope.
struct JSONRPCErrorResponse: Encodable, Sendable {
    let id: RequestID?
    let error: JSONRPCErrorBody

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
        try container.encode(error, forKey: .error)
    }
}

/// The `result` payload for `tools/list`.
struct ToolsListResult: Encodable, Sendable {
    let tools: [MCPToolDefinition]
}

// MARK: - MCP Tool Definitions

/// Describes a single tool exposed by the MCP server.
struct MCPToolDefinition: Encodable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
}

/// A JSON Schema object describing tool input parameters.
struct JSONSchema: Encodable, Sendable {
    let type: String
    let properties: [String: PropertySchema]?
    let required: [String]?
}

/// Schema for a single property within a JSON Schema.
/// `types` holds one or more JSON Schema types; a single entry encodes as a bare
/// string (`"type": "string"`), multiple entries as an array (`"type": ["string", "integer"]`).
struct PropertySchema: Encodable, Sendable {
    let types: [String]
    let description: String
    let `enum`: [String]?

    init(type: String, description: String, enum enumValues: [String]?) {
        self.init(types: [type], description: description, enum: enumValues)
    }

    init(types: [String], description: String, enum enumValues: [String]?) {
        self.types = types
        self.description = description
        self.enum = enumValues
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case `enum`
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if types.count == 1 {
            try container.encode(types[0], forKey: .type)
        } else {
            try container.encode(types, forKey: .type)
        }
        try container.encode(description, forKey: .description)
        if let enumValues = self.enum {
            try container.encode(enumValues, forKey: .enum)
        }
    }
}

// MARK: - MCP Tool Results

/// A single text content block within a tool result.
struct MCPTextContent: Encodable, Sendable {
    let type: String = "text"
    let text: String
}

/// The result returned from a tool call, containing content blocks and an optional error flag.
struct MCPToolResult: Encodable, Sendable {
    let content: [MCPTextContent]
    let isError: Bool?

    init(content: [MCPTextContent], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }

    /// Convenience initializer for a successful single-text result.
    static func success(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [MCPTextContent(text: text)])
    }

    /// Convenience initializer for an error result.
    static func error(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [MCPTextContent(text: text)], isError: true)
    }
}
