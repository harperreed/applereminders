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
    /// Writes one complete response line. Injectable so tests can capture output.
    typealias OutputWriter = @Sendable (String) -> Void

    private let store: RemindersStore
    private let registry: ToolRegistry
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let input: AsyncThrowingStream<String, Error>
    private let output: OutputWriter

    /// - Parameters:
    ///   - store: The reminders store to serve.
    ///   - input: Request lines to process. Defaults to stdin.
    ///   - output: Where response lines go. Defaults to stdout with an immediate flush.
    init(
        store: RemindersStore,
        input: AsyncThrowingStream<String, Error>? = nil,
        output: OutputWriter? = nil
    ) {
        self.store = store
        self.decoder = JSONDecoder()

        // Compact encoder for JSON-RPC protocol messages (single-line).
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]

        self.input = input ?? MCPServer.standardInputLines()
        self.output = output ?? { line in
            print(line)
            fflush(stdout)
        }

        self.registry = MCPServer.buildRegistry(store: store)
    }

    /// Bridges stdin into a line stream without blocking the cooperative pool.
    private static func standardInputLines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    for try await line in FileHandle.standardInput.bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    // MARK: - Main Loop

    /// Runs the server, reading lines from the injected line stream (stdin by default) until EOF.
    ///
    /// Uses an async line stream to avoid blocking the cooperative thread pool
    /// (unlike `readLine()` which is synchronous).
    func run() async {
        logStderr("reminders-mcp server starting")

        do {
            for try await line in input {
                guard !line.isEmpty else { continue }

                logStderr("recv: \(line)")

                let data = Data(line.utf8)

                do {
                    let request = try decoder.decode(JSONRPCRequest.self, from: data)
                    await handleRequest(request)
                } catch {
                    logStderr("JSON parse error: \(error)")
                    let response = makeErrorResponse(
                        id: nil,
                        code: -32700,
                        message: "Parse error: \(error.localizedDescription)"
                    )
                    writeLine(response)
                }
            }
        } catch {
            logStderr("stdin read error: \(error.localizedDescription)")
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
        let line = encodeEnvelope(
            JSONRPCResponse(id: request.id, result: ToolsListResult(tools: tools)),
            id: request.id
        )
        writeLine(line)
        logStderr("Returned \(tools.count) tool definitions")
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

        // Reminders access is requested lazily so the protocol stream stays alive even
        // when access is denied; the failure surfaces as an actionable tool error.
        do {
            try await store.requestAccess()
        } catch {
            let denied = MCPToolResult.error(
                "Reminders access is not available: \(error.localizedDescription) "
                + "Grant access in System Settings > Privacy & Security > Reminders "
                + "for the app that launched this MCP server, then call the tool again."
            )
            let line = encodeEnvelope(
                JSONRPCResponse(id: request.id, result: denied),
                id: request.id
            )
            writeLine(line)
            return
        }

        let toolResult = await registry.call(tool: toolName, params: arguments)

        let line = encodeEnvelope(
            JSONRPCResponse(id: request.id, result: toolResult),
            id: request.id
        )
        writeLine(line)
        logStderr("Tool \(toolName) completed (isError: \(toolResult.isError ?? false))")
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

    /// Encodes a JSON-RPC envelope to a single-line string via JSONEncoder.
    /// Falls back to an error response (and finally to a constant) so the server
    /// always writes valid JSON no matter what encoding throws. The fallback calls
    /// `makeErrorResponse` directly — `makeErrorResponse` has its own independent
    /// fallback and does not re-enter `encodeEnvelope`.
    private func encodeEnvelope<T: Encodable>(_ envelope: T, id: RequestID?) -> String {
        do {
            let data = try encoder.encode(envelope)
            guard let json = String(data: data, encoding: .utf8) else {
                throw MCPToolError.encodingFailed
            }
            return json
        } catch {
            logStderr("envelope encode error: \(error.localizedDescription)")
            return makeErrorResponse(id: id, code: -32603, message: "Failed to encode response")
        }
    }

    /// Builds a JSON-RPC success response string.
    private func makeSuccessResponse(id: RequestID?, result: JSONValue) -> String {
        encodeEnvelope(JSONRPCResponse(id: id, result: result), id: id)
    }

    /// Builds a JSON-RPC error response string.
    private func makeErrorResponse(id: RequestID?, code: Int, message: String) -> String {
        let envelope = JSONRPCErrorResponse(
            id: id,
            error: JSONRPCErrorBody(code: code, message: message)
        )
        do {
            let data = try encoder.encode(envelope)
            guard let json = String(data: data, encoding: .utf8) else {
                throw MCPToolError.encodingFailed
            }
            return json
        } catch {
            // Deliberately contains no interpolated data: it must always be valid JSON.
            logStderr("error envelope encode failed: \(error.localizedDescription)")
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error: failed to encode response"}}"#
        }
    }

    // MARK: - I/O

    /// Writes a single response line through the injected output.
    private func writeLine(_ line: String) {
        output(line)
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
    static func buildToolDefinitions() -> [MCPToolDefinition] {
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
                    + "Returns a JSON array of reminder objects with id, title, notes, "
                    + "isCompleted, completionDate, priority, dueDate, listID, and listName "
                    + "fields. Pass a reminder's id to complete_reminder, uncomplete_reminder, "
                    + "delete_reminder, or edit_reminder to target it reliably. "
                    + "Use due_before and/or due_after (day-granular) to filter by due date.",
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
                        "due_before": PropertySchema(
                            type: "string",
                            description: "Only include reminders due on or before this day. "
                                + "Accepts: 'today', 'tomorrow', 'next week', 'yyyy-MM-dd', "
                                + "'yyyy-MM-dd HH:mm', 'MM/dd/yyyy', or 'MM/dd'.",
                            enum: nil
                        ),
                        "due_after": PropertySchema(
                            type: "string",
                            description: "Only include reminders due on or after this day. "
                                + "Accepts the same formats as due_before.",
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
                    + "Useful for getting a full overview of all pending tasks. "
                    + "Returns the same JSON reminder objects as show_reminders; each object's "
                    + "id is a stable identifier accepted by the mutating tools. "
                    + "Use due_before and/or due_after (day-granular) to filter by due date.",
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
                        "due_before": PropertySchema(
                            type: "string",
                            description: "Only include reminders due on or before this day. "
                                + "Accepts: 'today', 'tomorrow', 'next week', 'yyyy-MM-dd', "
                                + "'yyyy-MM-dd HH:mm', 'MM/dd/yyyy', or 'MM/dd'.",
                            enum: nil
                        ),
                        "due_after": PropertySchema(
                            type: "string",
                            description: "Only include reminders due on or after this day. "
                                + "Accepts the same formats as due_before.",
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
                description: "Mark a reminder as completed. Only incomplete reminders can be "
                    + "targeted. Pass the reminder's stable id (preferred) or its zero-based "
                    + "position among the list's incomplete reminders. Returns the updated "
                    + "reminder as JSON.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The name of the reminder list (case-insensitive match).",
                            enum: nil
                        ),
                        "index": PropertySchema(
                            types: ["string", "integer"],
                            description: "The reminder's stable id from show_reminders (preferred; "
                                + "unaffected by list changes), or its zero-based position among "
                                + "the list's incomplete reminders (fragile: positions shift as "
                                + "reminders change).",
                            enum: nil
                        ),
                    ],
                    required: ["list", "index"]
                )
            ),
            MCPToolDefinition(
                name: "uncomplete_reminder",
                description: "Mark a completed reminder as incomplete (reopen it). Only completed "
                    + "reminders can be targeted. Pass the reminder's stable id (preferred) or "
                    + "its zero-based position among the COMPLETED reminders only — the view "
                    + "shown by show_reminders with only_completed=true, not the default view. "
                    + "Returns the updated reminder as JSON.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The name of the reminder list (case-insensitive match).",
                            enum: nil
                        ),
                        "index": PropertySchema(
                            types: ["string", "integer"],
                            description: "The reminder's stable id from show_reminders (preferred), "
                                + "or its zero-based position among the list's COMPLETED reminders "
                                + "(as listed by show_reminders with only_completed=true).",
                            enum: nil
                        ),
                    ],
                    required: ["list", "index"]
                )
            ),
            MCPToolDefinition(
                name: "delete_reminder",
                description: "Permanently delete a reminder from a list. This action cannot be "
                    + "undone. By default only incomplete reminders can be targeted; set "
                    + "include_completed to true to delete completed ones (the positional index "
                    + "then counts the combined view; stable ids are unaffected). Pass the "
                    + "reminder's stable id (preferred) or its zero-based position. Returns the "
                    + "deleted reminder as JSON.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The name of the reminder list (case-insensitive match).",
                            enum: nil
                        ),
                        "index": PropertySchema(
                            types: ["string", "integer"],
                            description: "The reminder's stable id from show_reminders (preferred; "
                                + "unaffected by list changes), or its zero-based position among "
                                + "the list's incomplete reminders (fragile: positions shift as "
                                + "reminders change).",
                            enum: nil
                        ),
                        "include_completed": PropertySchema(
                            type: "boolean",
                            description: "When true, completed reminders can be targeted too. "
                                + "The positional index then counts the combined view.",
                            enum: nil
                        ),
                    ],
                    required: ["list", "index"]
                )
            ),
            MCPToolDefinition(
                name: "edit_reminder",
                description: "Edit an existing reminder. Only the fields you provide change; "
                    + "omitted fields remain untouched. Can update the title, notes, due date, "
                    + "priority, and list (move_to_list). Set clear_due_date to remove the due "
                    + "date entirely. By default only incomplete reminders can be targeted; set "
                    + "include_completed to true to edit completed ones (the positional index "
                    + "then counts the combined view; stable ids are unaffected). Pass the "
                    + "reminder's stable id (preferred) or its zero-based position. Returns the "
                    + "updated reminder as JSON.",
                inputSchema: JSONSchema(
                    type: "object",
                    properties: [
                        "list": PropertySchema(
                            type: "string",
                            description: "The name of the reminder list (case-insensitive match).",
                            enum: nil
                        ),
                        "index": PropertySchema(
                            types: ["string", "integer"],
                            description: "The reminder's stable id from show_reminders (preferred; "
                                + "unaffected by list changes), or its zero-based position among "
                                + "the list's incomplete reminders (fragile: positions shift as "
                                + "reminders change).",
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
                        "due_date": PropertySchema(
                            type: "string",
                            description: "New due date. Accepts: 'today', 'tomorrow', 'next week', "
                                + "'yyyy-MM-dd', 'yyyy-MM-dd HH:mm', 'MM/dd/yyyy', or 'MM/dd'. "
                                + "Cannot be combined with clear_due_date.",
                            enum: nil
                        ),
                        "clear_due_date": PropertySchema(
                            type: "boolean",
                            description: "When true, removes the reminder's due date and alarm. "
                                + "Cannot be combined with due_date.",
                            enum: nil
                        ),
                        "priority": PropertySchema(
                            type: "string",
                            description: "New priority level.",
                            enum: ["none", "low", "medium", "high"]
                        ),
                        "move_to_list": PropertySchema(
                            type: "string",
                            description: "Name of the list to move the reminder to "
                                + "(case-insensitive match).",
                            enum: nil
                        ),
                        "include_completed": PropertySchema(
                            type: "boolean",
                            description: "When true, completed reminders can be targeted too. "
                                + "The positional index then counts the combined view.",
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

        let (dueBefore, dueBeforeError) = parseDueBound("due_before", from: params)
        if let err = dueBeforeError { return err }

        let (dueAfter, dueAfterError) = parseDueBound("due_after", from: params)
        if let err = dueAfterError { return err }

        do {
            let reminders = try await store.reminders(
                inList: listName,
                includeCompleted: includeCompleted || onlyCompleted,
                onlyCompleted: onlyCompleted
            )
            let filtered = filterByDueWindow(reminders, dueBefore: dueBefore, dueAfter: dueAfter)
            let text = prettyEncodeJSON(filtered)
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

        let (dueBefore, dueBeforeError) = parseDueBound("due_before", from: params)
        if let err = dueBeforeError { return err }

        let (dueAfter, dueAfterError) = parseDueBound("due_after", from: params)
        if let err = dueAfterError { return err }

        do {
            let reminders = try await store.reminders(
                includeCompleted: includeCompleted || onlyCompleted,
                onlyCompleted: onlyCompleted
            )
            let filtered = filterByDueWindow(reminders, dueBefore: dueBefore, dueAfter: dueAfter)
            let text = prettyEncodeJSON(filtered)
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
                    "Invalid due_date \"\(dueDateString)\". Supported formats: \(supportedDateFormats)."
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
            let updated = try await store.setComplete(
                false,
                itemAtIndex: index,
                onList: listName,
                onlyCompleted: true
            )
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

        let includeCompleted = params["include_completed"]?.boolValue() ?? false

        do {
            let deleted = try await store.delete(
                itemAtIndex: index,
                onList: listName,
                includeCompleted: includeCompleted
            )
            let text = prettyEncodeJSON(deleted)
            return .success(text)
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
        let moveToList = params["move_to_list"]?.stringValue()
        let includeCompleted = params["include_completed"]?.boolValue() ?? false
        let clearDueDate = params["clear_due_date"]?.boolValue() ?? false
        let dueDateString = params["due_date"]?.stringValue()

        if clearDueDate && dueDateString != nil {
            return .error(
                "Invalid parameters: 'due_date' and 'clear_due_date' cannot be combined. "
                + "Use due_date to set a new date, or clear_due_date to remove it."
            )
        }

        let dueDateChange: Date??
        if clearDueDate {
            dueDateChange = .some(nil)
        } else if let dueDateString {
            guard let parsed = parseDate(dueDateString) else {
                return .error(
                    "Invalid due_date \"\(dueDateString)\". Supported formats: \(supportedDateFormats)."
                )
            }
            dueDateChange = .some(parsed)
        } else {
            dueDateChange = nil
        }

        let parsedPriority: ReminderPriority?
        if let priorityString = params["priority"]?.stringValue() {
            guard let priority = ReminderPriority(rawValue: priorityString.lowercased()) else {
                return .error(
                    "Invalid priority \"\(priorityString)\". "
                    + "Must be one of: none, low, medium, high."
                )
            }
            parsedPriority = priority
        } else {
            parsedPriority = nil
        }

        do {
            let updated = try await store.update(
                itemAtIndex: index,
                onList: listName,
                with: ReminderUpdate(
                    title: newTitle,
                    notes: newNotes,
                    dueDate: dueDateChange,
                    priority: parsedPriority,
                    listName: moveToList
                ),
                includeCompleted: includeCompleted
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

    /// Parses an optional due-bound parameter (e.g. `due_before` or `due_after`) from the tool
    /// params dictionary. Returns `(nil, nil)` when the key is absent, `(date, nil)` when present
    /// and parseable, or `(nil, toolError)` when the value cannot be parsed — with an error message
    /// that names the key and the supported formats.
    private static func parseDueBound(
        _ key: String,
        from params: [String: JSONValue]
    ) -> (date: Date?, error: MCPToolResult?) {
        guard let boundString = params[key]?.stringValue() else {
            return (nil, nil)
        }
        guard let parsed = parseDate(boundString) else {
            return (nil, .error("Invalid \(key) \"\(boundString)\". Supported formats: \(supportedDateFormats)."))
        }
        return (parsed, nil)
    }

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

/// Errors specific to MCP server internals.
enum MCPToolError: LocalizedError, Sendable {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode response"
        }
    }
}
