// ABOUTME: HTTP middleware for the network server: bearer auth, request logging,
// ABOUTME: REST error mapping, and lazy Reminders access requests.

import Foundation
import Hummingbird
import RemindersCore

/// A REST-surface failure carrying its HTTP status and message.
struct RESTError: Error {
    let status: HTTPResponse.Status
    let message: String
}

/// Rejects any request whose Authorization header does not carry the expected
/// bearer token. 401 responses have an empty body by design (spec R4); both
/// the MCP and REST surfaces sit behind this one middleware.
struct BearerTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard request.headers[.authorization] == "Bearer \(token)" else {
            return Response(status: .unauthorized)
        }
        return try await next(request, context)
    }
}

/// Logs one line per request: method, path, status, duration. Never logs
/// bodies or the Authorization header (spec R9).
struct RequestLogMiddleware<Context: RequestContext>: RouterMiddleware {
    let log: @Sendable (String) -> Void

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await next(request, context)
        let elapsed = start.duration(to: clock.now)
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        log("\(request.method) \(request.uri.path) \(response.status.code) \(String(format: "%.1f", milliseconds))ms")
        return response
    }
}

/// Maps errors thrown by REST handlers onto the spec's JSON error bodies:
/// not-found store errors to 404, other store errors to 500, RESTError to its
/// own status, anything unexpected to 500.
struct RESTErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as RESTError {
            return try errorResponse(status: error.status, message: error.message)
        } catch let error as RemindersError {
            switch error {
            case .listNotFound, .reminderNotFound:
                return try errorResponse(status: .notFound, message: error.localizedDescription)
            case .accessDenied, .writeOnlyAccess, .operationFailed:
                return try errorResponse(status: .internalServerError, message: error.localizedDescription)
            }
        } catch {
            return try errorResponse(status: .internalServerError, message: error.localizedDescription)
        }
    }
}

/// Requests Reminders access lazily per request, so the server starts without
/// TCC interaction and denial surfaces as a JSON 500 (via RESTErrorMiddleware)
/// instead of killing the process.
struct RemindersAccessMiddleware<Context: RequestContext>: RouterMiddleware {
    let store: RemindersStore

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        try await store.requestAccess()
        return try await next(request, context)
    }
}
