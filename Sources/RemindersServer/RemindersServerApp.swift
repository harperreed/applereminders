// ABOUTME: Hummingbird application builder for the network server.
// ABOUTME: Wires middleware and routes for the MCP and REST surfaces (spec R1-R4).

import Foundation
import Hummingbird
import NIOCore
import RemindersCore

/// Everything the HTTP server needs to start.
public struct ServerConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let token: String

    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }
}

/// Writes HTTP request log lines to stderr, keeping stdout clean for CLI use.
public let defaultHTTPLog: @Sendable (String) -> Void = { line in
    FileHandle.standardError.write(Data("[HTTP] \(line)\n".utf8))
}

/// Query string access with percent decoding and CLI-format date parsing.
struct RESTQuery {
    let request: Request

    /// Returns the decoded query value. Decoding twice only mangles list names
    /// containing a literal percent-escape sequence, which is acceptable; not
    /// decoding at all would break every list name containing a space.
    func value(_ key: String) -> String? {
        guard let raw = request.uri.queryParameters.get(key) else { return nil }
        let string = String(raw)
        return string.removingPercentEncoding ?? string
    }

    /// Parses a date query parameter in the CLI formats; garbage is a 400.
    func dateValue(_ key: String) throws -> Date? {
        guard let string = value(key) else { return nil }
        guard let date = parseDate(string) else {
            throw RESTError(
                status: .badRequest,
                message: "Invalid \(key) \"\(string)\". Supported formats: \(supportedDateFormats)."
            )
        }
        return date
    }
}

/// Reads the :id path parameter. Its absence is a routing bug, not client error.
func requiredID(from context: some RequestContext) throws -> String {
    guard let raw = context.parameters.get("id") else {
        throw RESTError(status: .internalServerError, message: "Route is missing its id parameter")
    }
    let id = String(raw)
    return id.removingPercentEncoding ?? id
}

/// Builds the router with both surfaces behind bearer auth.
func buildRouter(
    store: RemindersStore,
    token: String,
    log: @escaping @Sendable (String) -> Void = defaultHTTPLog
) -> Router<BasicRequestContext> {
    let router = Router()
    // Request logging is public so it covers /openapi and authenticated routes.
    router.middlewares.add(RequestLogMiddleware(log: log))

    router.get("openapi") { _, _ -> Response in
        openAPISpecResponse()
    }

    // Hummingbird middleware applies only to routes registered after this call.
    router.middlewares.add(BearerTokenMiddleware(token: token))

    let api = router.group("api")
    // Error mapping wraps the access request so a TCC denial becomes a JSON 500.
    api.add(middleware: RESTErrorMiddleware())
    api.add(middleware: RemindersAccessMiddleware(store: store))

    api.get("lists") { _, _ -> Response in
        let lists = await store.lists()
        return try jsonResponse(lists)
    }

    api.get("reminders") { request, _ -> Response in
        let query = RESTQuery(request: request)
        let completed = query.value("completed") ?? "false"
        let (includeCompleted, onlyCompleted): (Bool, Bool)
        switch completed {
        case "false":
            (includeCompleted, onlyCompleted) = (false, false)
        case "all":
            (includeCompleted, onlyCompleted) = (true, false)
        case "only":
            (includeCompleted, onlyCompleted) = (true, true)
        default:
            throw RESTError(
                status: .badRequest,
                message: "Invalid completed \"\(completed)\". Must be one of: false, all, only."
            )
        }
        let dueBefore = try query.dateValue("due_before")
        let dueAfter = try query.dateValue("due_after")
        let items = try await store.reminders(
            inList: query.value("list"),
            includeCompleted: includeCompleted,
            onlyCompleted: onlyCompleted
        )
        return try jsonResponse(filterByDueWindow(items, dueBefore: dueBefore, dueAfter: dueAfter))
    }

    api.post("reminders") { request, context -> Response in
        let body = try await decodeJSONBody(CreateReminderRequest.self, from: request, context: context)
        guard !body.title.isEmpty else {
            throw RESTError(status: .badRequest, message: "Field \"title\" must not be empty")
        }
        let draft = ReminderDraft(
            title: body.title,
            notes: body.notes,
            dueDate: try body.dueDate.map(parseDueDate),
            priority: try parsePriority(body.priority) ?? .none
        )
        let item = try await store.addReminder(draft, toList: body.list)
        return try jsonResponse(item, status: .created)
    }

    api.patch("reminders/:id") { request, context -> Response in
        let id = try requiredID(from: context)
        let body = try await decodeJSONBody(PatchReminderBody.self, from: request, context: context)
        var dueDateChange: Date?? = nil
        if let change = body.dueDate {
            dueDateChange = .some(try change.map(parseDueDate))
        }
        let update = ReminderUpdate(
            title: body.title,
            notes: body.notes,
            dueDate: dueDateChange,
            priority: try parsePriority(body.priority),
            listName: body.list
        )
        let item = try await store.update(byID: id, with: update)
        return try jsonResponse(item)
    }

    api.post("reminders/:id/complete") { _, context -> Response in
        let id = try requiredID(from: context)
        return try jsonResponse(try await store.setCompleted(byID: id, completed: true))
    }

    api.post("reminders/:id/uncomplete") { _, context -> Response in
        let id = try requiredID(from: context)
        return try jsonResponse(try await store.setCompleted(byID: id, completed: false))
    }

    api.delete("reminders/:id") { _, context -> Response in
        let id = try requiredID(from: context)
        return try jsonResponse(try await store.delete(byID: id))
    }

    // MCP over HTTP (spec "MCP over HTTP"): stateless, one message per POST.
    // Constructed with inert stdio seams; the default init would spawn a
    // stdin-reading task, which a network server must never do.
    let mcpServer = MCPServer(
        store: store,
        input: AsyncThrowingStream<String, Error> { continuation in
            continuation.finish()
        },
        output: { _ in }
    )

    router.post("mcp") { request, context -> Response in
        let buffer = try await request.body.collect(upTo: context.maxUploadSize)
        guard let line = await mcpServer.response(forMessageData: Data(buffer.readableBytesView)) else {
            // Notifications need no body; the transport answers 202 Accepted.
            return Response(status: .accepted)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: line))
        )
    }

    router.get("mcp") { _, _ -> Response in
        Response(status: .methodNotAllowed)
    }

    router.delete("mcp") { _, _ -> Response in
        Response(status: .methodNotAllowed)
    }

    return router
}

/// Builds the servable application (spec R1).
public func buildApplication(
    store: RemindersStore,
    configuration: ServerConfiguration
) -> some ApplicationProtocol {
    Application(
        router: buildRouter(store: store, token: configuration.token),
        configuration: ApplicationConfiguration(
            address: .hostname(configuration.host, port: configuration.port)
        )
    )
}
