// ABOUTME: Hummingbird application builder for the network server.
// ABOUTME: Wires middleware and routes for the MCP and REST surfaces (spec R1-R4).

import Foundation
import Hummingbird
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

/// Builds the router with both surfaces behind bearer auth.
func buildRouter(
    store: RemindersStore,
    token: String,
    log: @escaping @Sendable (String) -> Void = defaultHTTPLog
) -> Router<BasicRequestContext> {
    let router = Router()
    // Global middleware: logging wraps auth so 401s get logged too.
    router.middlewares.add(RequestLogMiddleware(log: log))
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
