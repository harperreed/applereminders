// ABOUTME: MCP server actor that speaks JSON-RPC 2.0 over stdin/stdout.
// ABOUTME: Maps MCP tool calls to RemindersStore methods and returns structured results.

import Foundation
import RemindersCore

// MARK: - ToolRegistry

/// Maps tool names to their definitions and async handler closures.
/// Provides a clean dispatch mechanism for incoming tools/call requests.
struct ToolRegistry: Sendable {
    /// A handler that takes a dictionary of JSON arguments and returns a tool result.
    typealias Handler = @Sendable ([String: JSONValue]) async -> MCPToolResult

    private let definitions: [MCPToolDefinition]
    private let handlers: [String: Handler]

    init(definitions: [MCPToolDefinition], handlers: [String: Handler]) {
        self.definitions = definitions
        self.handlers = handlers
    }

    /// All tool definitions for the `tools/list` response.
    func allDefinitions() -> [MCPToolDefinition] {
        definitions
    }

    /// Looks up and executes the handler for the given tool name.
    func call(tool name: String, params: [String: JSONValue]) async -> MCPToolResult {
        guard let handler = handlers[name] else {
            return .error("Unknown tool: \"\(name)\". Use tools/list to see available tools.")
        }
        return await handler(params)
    }
}

// MARK: - MCPServer

/// An actor-based MCP server that reads JSON-RPC requests from stdin and writes
/// responses to stdout. Each response is a single line of JSON followed by a newline.
/// Diagnostic logging goes to stderr so it does not interfere with the protocol stream.
actor MCPServer {
    private let store: RemindersStore
    private let registry: ToolRegistry
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let prettyEncoder: JSONEncoder

    init(store: RemindersStore) {
        self.store = store
        self.decoder = JSONDecoder()

        // Compact encoder for JSON-RPC protocol messages (single-line).
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]

        // Pretty encoder for tool result payloads (human-readable data inside text content).
        self.prettyEncoder = JSONEncoder()
        self.prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.prettyEncoder.dateEncodingStrategy = .iso8601

        self.registry = MCPServer.buildRegistry(store: store)
    }

    // MARK: - Main Loop

    /// Runs the server, reading lines from stdin until EOF.
    func run() async {
        logStderr("reminders-mcp server starting")

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }

            logStderr("recv: \(line)")

            guard let data = line.data(using: .utf8) else {
                logStderr("Failed to convert input line to UTF-8 data")
                continue
            }

            do {
                let request = try decoder.decode(JSONRPCRequest.self, from: data)
                await handleRequest(request)
            } catch {
                logStderr("JSON parse error: \(error)")
                // Malformed JSON-RPC: send a parse error with null id.
                let response = makeErrorResponse(
                    id: nil,
                    code: -32700,
                    message: "Parse error: \(error.localizedDescription)"
                )
                writeLine(response)
            }
        }

        logStderr("reminders-mcp server shutting down (stdin closed)")
    }

    // MARK: - Request Dispatch

    /// Routes a JSON-RPC request to the appropriate handler based on its method name.
    private func handleRequest(_ request: JSONRPCRequest) async {
        switch request.method {
        case "initialize":
            handleInitialize(request)
        case "notifications/initialized":
            // Notification: no response required.
            logStderr("Client initialized notification received")
        case "ping":
            handlePing(request)
        case "tools/list":
            handleToolsList(request)
        case "tools/call":
            await handleToolsCall(request)
        case "resources/list":
            handleResourcesList(request)
        case "prompts/list":
            handlePromptsList(request)
        default:
            logStderr("Unknown method: \(request.method)")
            if request.id != nil {
                let response = makeErrorResponse(
                    id: request.id,
                    code: -32601,
                    message: "Method not found: \(request.method)"
                )
                writeLine(response)
            }
        }
    }

    // MARK: - Protocol Methods

    /// Responds to the `initialize` method with server capabilities.
    private func handleInitialize(_ request: JSONRPCRequest) {
        let result: [String: JSONValue] = [
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "serverInfo": .object([
                "name": .string("reminders-mcp"),
                "version": .string("1.0.0"),
            ]),
        ]
        let response = makeSuccessResponse(id: request.id, result: .object(result))
        writeLine(response)
        logStderr("Initialized with protocol version 2024-11-05")
    }

    /// Responds to the `ping` method with an empty result.
    private func handlePing(_ request: JSONRPCRequest) {
        let response = makeSuccessResponse(id: request.id, result: .object([:]))
        writeLine(response)
        logStderr("Responded to ping")
    }

    /// Responds to `tools/list` with the full array of tool definitions.
    private func handleToolsList(_ request: JSONRPCRequest) {
        let tools = registry.allDefinitions()

        do {
            let toolsData = try encoder.encode(tools)
            guard let toolsJSON = String(data: toolsData, encoding: .utf8) else {
                let response = makeErrorResponse(
                    id: request.id,
                    code: -32603,
                    message: "Failed to encode tools list"
                )
                writeLine(response)
                return
            }
            // Build the response manually so we can embed the pre-encoded tools array.
            let idString = encodeID(request.id)
            let line = "{\"jsonrpc\":\"2.0\",\"id\":\(idString),\"result\":{\"tools\":\(toolsJSON)}}"
            writeLine(line)
            logStderr("Returned \(tools.count) tool definitions")
        } catch {
            let response = makeErrorResponse(
                id: request.id,
                code: -32603,
                message: "Failed to encode tools: \(error.localizedDescription)"
            )
            writeLine(response)
        }
    }

    // MARK: - Tool Call Dispatch

    /// Handles `tools/call` by extracting the tool name and arguments, then dispatching
    /// to the registry.
    private func handleToolsCall(_ request: JSONRPCRequest) async {
        guard let params = request.params?.objectValue() else {
            let response = makeErrorResponse(
                id: request.id,
                code: -32602,
                message: "Invalid params: expected an object with 'name' and optional 'arguments'"
            )
            writeLine(response)
            return
        }

        guard let toolName = params["name"]?.stringValue() else {
            let response = makeErrorResponse(
                id: request.id,
                code: -32602,
                message: "Invalid params: missing required 'name' field"
            )
            writeLine(response)
            return
        }

        let arguments = params["arguments"]?.objectValue() ?? [:]

        logStderr("Calling tool: \(toolName)")

        let toolResult = await registry.call(tool: toolName, params: arguments)

        do {
            let resultData = try encoder.encode(toolResult)
            guard let resultJSON = String(data: resultData, encoding: .utf8) else {
                throw MCPToolError.encodingFailed
            }
            let idString = encodeID(request.id)
            let line = "{\"jsonrpc\":\"2.0\",\"id\":\(idString),\"result\":\(resultJSON)}"
            writeLine(line)
            logStderr("Tool \(toolName) completed (isError: \(toolResult.isError ?? false))")
        } catch {
            let response = makeErrorResponse(
                id: request.id,
                code: -32603,
                message: "Internal error encoding tool result: \(error.localizedDescription)"
            )
            writeLine(response)
        }
    }

    /// Responds to `resources/list` with an empty array (future-proofing).
    private func handleResourcesList(_ request: JSONRPCRequest) {
        let result: [String: JSONValue] = ["resources": .array([])]
        let response = makeSuccessResponse(id: request.id, result: .object(result))
        writeLine(response)
        logStderr("Returned empty resources list")
    }

    /// Responds to `prompts/list` with an empty array (future-proofing).
    private func handlePromptsList(_ request: JSONRPCRequest) {
        let result: [String: JSONValue] = ["prompts": .array([])]
        let response = makeSuccessResponse(id: request.id, result: .object(result))
        writeLine(response)
        logStderr("Returned empty prompts list")
    }

    // MARK: - Response Builders

    /// Builds a JSON-RPC success response string.
    private func makeSuccessResponse(id: RequestID?, result: JSONValue) -> String {
        let idString = encodeID(id)
        do {
            let resultData = try encoder.encode(result)
            guard let resultJSON = String(data: resultData, encoding: .utf8) else {
                return makeErrorResponse(id: id, code: -32603, message: "Failed to encode result")
            }
            return "{\"jsonrpc\":\"2.0\",\"id\":\(idString),\"result\":\(resultJSON)}"
        } catch {
            return makeErrorResponse(id: id, code: -32603, message: "Failed to encode result")
        }
    }

    /// Builds a JSON-RPC error response string.
    private func makeErrorResponse(id: RequestID?, code: Int, message: String) -> String {
        let idString = encodeID(id)
        let escapedMessage = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "{\"jsonrpc\":\"2.0\",\"id\":\(idString),\"error\":{\"code\":\(code),\"message\":\"\(escapedMessage)\"}}"
    }

    // MARK: - Encoding Helpers

    /// Encodes a RequestID to its JSON representation for manual string building.
    private func encodeID(_ id: RequestID?) -> String {
        guard let id else { return "null" }
        switch id {
        case .string(let value):
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .int(let value):
            return "\(value)"
        }
    }

    // MARK: - I/O

    /// Writes a single line to stdout and flushes immediately.
    private nonisolated func writeLine(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// Writes a diagnostic message to stderr (never touches stdout).
    private nonisolated func logStderr(_ message: String) {
        FileHandle.standardError.write(Data("[MCP] \(message)\n".utf8))
    }

    // MARK: - Registry Construction

    /// Builds the ToolRegistry containing all 9 tool definitions and their handlers.
    private static func buildRegistry(store: RemindersStore) -> ToolRegistry {
        let definitions = buildToolDefinitions()
        let handlers = buildToolHandlers(store: store)
        return ToolRegistry(definitions: definitions, handlers: handlers)
    }

    // MARK: - Tool Definitions

    /// Builds the array of all 9 tool definitions exposed by this MCP server.
    private static func buildToolDefinitions() -> [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "show_lists",
                description: "List all reminder lists (calendars) available in macOS Reminders. "
                    + "Returns a JSON array of list objects with id and title fields. "
                    + "Use this first to discover valid list names before calling other tools.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: nil,
                    required: nil
                )
            ),
            MCPToolDefinition(
                name: "show_reminders",
                description: "Show reminders from a specific list. By default only returns "
                    + "incomplete reminders. Use include_completed to also see finished items, "
                    + "or only_completed to see exclusively completed reminders. "
                    + "Returns a JSON array of reminder objects with index, title, notes, "
                    + "due date, priority, and completion status.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The exact name of the reminder list to show (case-insensitive match).",
                            enum: nil
                        ),
                        "include_completed": PropertySchema(
                            type: "boolean",
                            description: "When true, includes completed reminders alongside incomplete ones. "
                                + "Cannot be used together with only_completed.",
                            enum: nil
                        ),
                        "only_completed": PropertySchema(
                            type: "boolean",
                            description: "When true, shows only completed reminders. "
                                + "Cannot be used together with include_completed.",
                            enum: nil
                        ),
                    ],
                    required: ["list"]
                )
            ),
            MCPToolDefinition(
                name: "show_all_reminders",
                description: "Show reminders from all lists at once. Each reminder includes its "
                    + "list name. By default only returns incomplete reminders. "
                    + "Useful for getting a full overview of all pending tasks.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "include_completed": PropertySchema(
                            type: "boolean",
                            description: "When true, includes completed reminders alongside incomplete ones. "
                                + "Cannot be used together with only_completed.",
                            enum: nil
                        ),
                        "only_completed": PropertySchema(
                            type: "boolean",
                            description: "When true, shows only completed reminders. "
                                + "Cannot be used together with include_completed.",
                            enum: nil
                        ),
                    ],
                    required: nil
                )
            ),
            MCPToolDefinition(
                name: "add_reminder",
                description: "Create a new reminder in the specified list. Returns the created "
                    + "reminder object with all fields populated. Use show_lists first if you "
                    + "need to find a valid list name.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The name of the reminder list to add to (case-insensitive match).",
                            enum: nil
                        ),
                        "title": PropertySchema(
                            type: "string",
                            description: "The title text for the new reminder.",
                            enum: nil
                        ),
                        "notes": PropertySchema(
                            type: "string",
                            description: "Optional notes or additional details to attach to the reminder.",
                            enum: nil
                        ),
                        "due_date": PropertySchema(
                            type: "string",
                            description: "Optional due date. Accepts: 'today', 'tomorrow', 'next week', "
                                + "'yyyy-MM-dd', 'yyyy-MM-dd HH:mm', 'MM/dd/yyyy', or 'MM/dd'.",
                            enum: nil
                        ),
                        "priority": PropertySchema(
                            type: "string",
                            description: "Priority level for the reminder. Defaults to 'none' if omitted.",
                            enum: ["none", "low", "medium", "high"]
                        ),
                    ],
                    required: ["list", "title"]
                )
            ),
            MCPToolDefinition(
                name: "complete_reminder",
                description: "Mark a reminder as completed. Identify the target reminder by its "
                    + "zero-based index within the list (as shown by show_reminders).",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The name of the reminder list (case-insensitive match).",
                            enum: nil
                        ),
                        "index": PropertySchema(
                            type: "string",
                            description: "The zero-based index of the reminder to complete, as a string.",
                            enum: nil
                        ),
                    ],
                    required: ["list", "index"]
                )
            ),
            MCPToolDefinition(
                name: "uncomplete_reminder",
                description: "Mark a completed reminder as incomplete (reopen it). Identify the "
                    + "target reminder by its zero-based index within the list.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The name of the reminder list (case-insensitive match).",
                            enum: nil
                        ),
                        "index": PropertySchema(
                            type: "string",
                            description: "The zero-based index of the reminder to uncomplete, as a string.",
                            enum: nil
                        ),
                    ],
                    required: ["list", "index"]
                )
            ),
            MCPToolDefinition(
                name: "delete_reminder",
                description: "Permanently delete a reminder from a list. This action cannot be "
                    + "undone. Identify the target reminder by its zero-based index.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The name of the reminder list (case-insensitive match).",
                            enum: nil
                        ),
                        "index": PropertySchema(
                            type: "string",
                            description: "The zero-based index of the reminder to delete, as a string.",
                            enum: nil
                        ),
                    ],
                    required: ["list", "index"]
                )
            ),
            MCPToolDefinition(
                name: "edit_reminder",
                description: "Edit an existing reminder's title and/or notes. Only the fields you "
                    + "provide will be changed; omitted fields remain untouched. Identify the "
                    + "target reminder by its zero-based index.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The name of the reminder list (case-insensitive match).",
                            enum: nil
                        ),
                        "index": PropertySchema(
                            type: "string",
                            description: "The zero-based index of the reminder to edit, as a string.",
                            enum: nil
                        ),
                        "title": PropertySchema(
                            type: "string",
                            description: "New title text. Omit to keep the current title.",
                            enum: nil
                        ),
                        "notes": PropertySchema(
                            type: "string",
                            description: "New notes text. Omit to keep the current notes.",
                            enum: nil
                        ),
                    ],
                    required: ["list", "index"]
                )
            ),
            MCPToolDefinition(
                name: "create_list",
                description: "Create a new reminder list in macOS Reminders. The list will be "
                    + "backed by the default source (usually iCloud). Returns the created list "
                    + "with its id and title.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "name": PropertySchema(
                            type: "string",
                            description: "The display name for the new reminder list.",
                            enum: nil
                        ),
                    ],
                    required: ["name"]
                )
            ),
        ]
    }

    // MARK: - Tool Handlers

    /// Builds a dictionary mapping each tool name to its async handler closure.
    private static func buildToolHandlers(store: RemindersStore) -> [String: ToolRegistry.Handler] {
        [
            "show_lists": { @Sendable _ in
                await handleShowLists(store: store)
            },
            "show_reminders": { @Sendable params in
                await handleShowReminders(store: store, params: params)
            },
            "show_all_reminders": { @Sendable params in
                await handleShowAllReminders(store: store, params: params)
            },
            "add_reminder": { @Sendable params in
                await handleAddReminder(store: store, params: params)
            },
            "complete_reminder": { @Sendable params in
                await handleCompleteReminder(store: store, params: params)
            },
            "uncomplete_reminder": { @Sendable params in
                await handleUncompleteReminder(store: store, params: params)
            },
            "delete_reminder": { @Sendable params in
                await handleDeleteReminder(store: store, params: params)
            },
            "edit_reminder": { @Sendable params in
                await handleEditReminder(store: store, params: params)
            },
            "create_list": { @Sendable params in
                await handleCreateList(store: store, params: params)
            },
        ]
    }

    // MARK: - Individual Tool Implementations

    private static func handleShowLists(store: RemindersStore) async -> MCPToolResult {
        let lists = await store.lists()
        let text = prettyEncodeJSON(lists)
        return .success(text)
    }

    private static func handleShowReminders(
        store: RemindersStore,
        params: [String: JSONValue]
    ) async -> MCPToolResult {
        guard let listName = params["list"]?.stringValue() else {
            return .error("Missing required parameter: 'list' (string). "
                + "Provide the name of a reminder list.")
        }

        let includeCompleted = params["include_completed"]?.boolValue() ?? false
        let onlyCompleted = params["only_completed"]?.boolValue() ?? false

        if includeCompleted && onlyCompleted {
            return .error(
                "Invalid parameters: 'include_completed' and 'only_completed' cannot both be true. "
                + "Use include_completed to see all reminders, or only_completed to see just finished ones."
            )
        }

        do {
            let reminders = try await store.reminders(
                inList: listName,
                includeCompleted: includeCompleted || onlyCompleted,
                onlyCompleted: onlyCompleted
            )
            let text = prettyEncodeJSON(reminders)
            return .success(text)
        } catch {
            return .error("Failed to fetch reminders: \(error.localizedDescription)")
        }
    }

    private static func handleShowAllReminders(
        store: RemindersStore,
        params: [String: JSONValue]
    ) async -> MCPToolResult {
        let includeCompleted = params["include_completed"]?.boolValue() ?? false
        let onlyCompleted = params["only_completed"]?.boolValue() ?? false

        if includeCompleted && onlyCompleted {
            return .error(
                "Invalid parameters: 'include_completed' and 'only_completed' cannot both be true. "
                + "Use include_completed to see all reminders, or only_completed to see just finished ones."
            )
        }

        do {
            let reminders = try await store.reminders(
                includeCompleted: includeCompleted || onlyCompleted,
                onlyCompleted: onlyCompleted
            )
            let text = prettyEncodeJSON(reminders)
            return .success(text)
        } catch {
            return .error("Failed to fetch reminders: \(error.localizedDescription)")
        }
    }

    private static func handleAddReminder(
        store: RemindersStore,
        params: [String: JSONValue]
    ) async -> MCPToolResult {
        guard let listName = params["list"]?.stringValue() else {
            return .error("Missing required parameter: 'list' (string). "
                + "Provide the name of the reminder list to add to.")
        }
        guard let title = params["title"]?.stringValue() else {
            return .error("Missing required parameter: 'title' (string). "
                + "Provide the title text for the new reminder.")
        }

        let notes = params["notes"]?.stringValue()

        let parsedDueDate: Date?
        if let dueDateString = params["due_date"]?.stringValue() {
            guard let date = parseDate(dueDateString) else {
                return .error(
                    "Invalid due_date \"\(dueDateString)\". "
                    + "Supported formats: today, tomorrow, next week, yyyy-MM-dd, "
                    + "yyyy-MM-dd HH:mm, MM/dd/yyyy, MM/dd."
                )
            }
            parsedDueDate = date
        } else {
            parsedDueDate = nil
        }

        let parsedPriority: ReminderPriority
        if let priorityString = params["priority"]?.stringValue() {
            guard let priority = ReminderPriority(rawValue: priorityString.lowercased()) else {
                return .error(
                    "Invalid priority \"\(priorityString)\". "
                    + "Must be one of: none, low, medium, high."
                )
            }
            parsedPriority = priority
        } else {
            parsedPriority = .none
        }

        let draft = ReminderDraft(
            title: title,
            notes: notes,
            dueDate: parsedDueDate,
            priority: parsedPriority
        )

        do {
            let created = try await store.addReminder(draft, toList: listName)
            let text = prettyEncodeJSON(created)
            return .success(text)
        } catch {
            return .error("Failed to add reminder: \(error.localizedDescription)")
        }
    }

    private static func handleCompleteReminder(
        store: RemindersStore,
        params: [String: JSONValue]
    ) async -> MCPToolResult {
        guard let listName = params["list"]?.stringValue() else {
            return .error("Missing required parameter: 'list' (string).")
        }
        guard let index = extractIndex(from: params) else {
            return .error("Missing required parameter: 'index' (string or integer).")
        }

        do {
            let updated = try await store.setComplete(true, itemAtIndex: index, onList: listName)
            let text = prettyEncodeJSON(updated)
            return .success(text)
        } catch {
            return .error("Failed to complete reminder: \(error.localizedDescription)")
        }
    }

    private static func handleUncompleteReminder(
        store: RemindersStore,
        params: [String: JSONValue]
    ) async -> MCPToolResult {
        guard let listName = params["list"]?.stringValue() else {
            return .error("Missing required parameter: 'list' (string).")
        }
        guard let index = extractIndex(from: params) else {
            return .error("Missing required parameter: 'index' (string or integer).")
        }

        do {
            let updated = try await store.setComplete(false, itemAtIndex: index, onList: listName)
            let text = prettyEncodeJSON(updated)
            return .success(text)
        } catch {
            return .error("Failed to uncomplete reminder: \(error.localizedDescription)")
        }
    }

    private static func handleDeleteReminder(
        store: RemindersStore,
        params: [String: JSONValue]
    ) async -> MCPToolResult {
        guard let listName = params["list"]?.stringValue() else {
            return .error("Missing required parameter: 'list' (string).")
        }
        guard let index = extractIndex(from: params) else {
            return .error("Missing required parameter: 'index' (string or integer).")
        }

        do {
            let deletedTitle = try await store.delete(itemAtIndex: index, onList: listName)
            return .success("Deleted reminder: \(deletedTitle)")
        } catch {
            return .error("Failed to delete reminder: \(error.localizedDescription)")
        }
    }

    private static func handleEditReminder(
        store: RemindersStore,
        params: [String: JSONValue]
    ) async -> MCPToolResult {
        guard let listName = params["list"]?.stringValue() else {
            return .error("Missing required parameter: 'list' (string).")
        }
        guard let index = extractIndex(from: params) else {
            return .error("Missing required parameter: 'index' (string or integer).")
        }

        let newTitle = params["title"]?.stringValue()
        let newNotes = params["notes"]?.stringValue()

        do {
            let updated = try await store.edit(
                itemAtIndex: index,
                onList: listName,
                newText: newTitle,
                newNotes: newNotes
            )
            let text = prettyEncodeJSON(updated)
            return .success(text)
        } catch {
            return .error("Failed to edit reminder: \(error.localizedDescription)")
        }
    }

    private static func handleCreateList(
        store: RemindersStore,
        params: [String: JSONValue]
    ) async -> MCPToolResult {
        guard let name = params["name"]?.stringValue() else {
            return .error("Missing required parameter: 'name' (string). "
                + "Provide a display name for the new list.")
        }

        do {
            let created = try await store.createList(name: name)
            let text = prettyEncodeJSON(created)
            return .success(text)
        } catch {
            return .error("Failed to create list: \(error.localizedDescription)")
        }
    }

    // MARK: - Argument Helpers

    /// Extracts the `index` argument as a string, accepting both integer and string JSON values.
    private static func extractIndex(from arguments: [String: JSONValue]) -> String? {
        if let intVal = arguments["index"]?.intValue() {
            return String(intVal)
        }
        return arguments["index"]?.stringValue()
    }

    // MARK: - JSON Encoding Helpers

    /// Pretty-encodes an Encodable value to a JSON string for inclusion in tool results.
    private static func prettyEncodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? "null"
        } catch {
            return "Error encoding result: \(error.localizedDescription)"
        }
    }
}

// MARK: - MCPToolError

/// Errors specific to MCP tool dispatch and argument handling.
enum MCPToolError: LocalizedError, Sendable {
    case unknownTool(String)
    case missingRequiredParam(String)
    case invalidParam(String, String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .missingRequiredParam(let param):
            return "Missing required parameter: \(param)"
        case .invalidParam(let param, let reason):
            return "Invalid parameter \"\(param)\": \(reason)"
        case .encodingFailed:
            return "Failed to encode response"
        }
    }
}
