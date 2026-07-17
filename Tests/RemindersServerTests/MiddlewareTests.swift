// ABOUTME: Unit tests for the HTTP middleware stack.
// ABOUTME: Exercises bearer auth, request logging, and REST error mapping on a throwaway router.

import Foundation
import Hummingbird
import HummingbirdTesting
import RemindersCore
import Testing
@testable import RemindersServer

@Suite("HTTP middleware")
struct MiddlewareTests {

    /// Thread-safe capture target for RequestLogMiddleware output.
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.withLock { _lines } }
        func append(_ line: String) { lock.withLock { _lines.append(line) } }
    }

    /// A minimal app with the production middleware order: log wraps auth
    /// (401s get logged too); the /api group carries error mapping.
    private func makeApp(log: @escaping @Sendable (String) -> Void = { _ in }) -> some ApplicationProtocol {
        let router = Router()
        router.middlewares.add(RequestLogMiddleware(log: log))
        router.middlewares.add(BearerTokenMiddleware(token: "secret"))
        router.get("ping") { _, _ in "pong" }
        let api = router.group("api")
        api.add(middleware: RESTErrorMiddleware())
        api.get("missing-list") { _, _ -> Response in
            throw RemindersError.listNotFound("Nope")
        }
        api.get("store-failure") { _, _ -> Response in
            throw RemindersError.operationFailed("Failed to update reminder: disk full")
        }
        api.get("bad-request") { _, _ -> Response in
            throw RESTError(
                status: .badRequest,
                message: "Invalid completed \"maybe\". Must be one of: false, all, only."
            )
        }
        return Application(router: router)
    }

    private let goodHeaders: HTTPFields = [.authorization: "Bearer secret"]

    @Test func missingTokenGets401WithEmptyBody() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/ping", method: .get) { response in
                #expect(response.status == .unauthorized)
                #expect(response.body.readableBytes == 0)
            }
        }
    }

    @Test func wrongTokenGets401() async throws {
        let app = makeApp()
        let headers: HTTPFields = [.authorization: "Bearer nope"]
        try await app.test(.router) { client in
            try await client.execute(uri: "/ping", method: .get, headers: headers) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func correctTokenPassesThrough() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/ping", method: .get, headers: goodHeaders) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "pong")
            }
        }
    }

    @Test func notFoundStoreErrorMapsTo404JSON() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/missing-list", method: .get, headers: goodHeaders) { response in
                #expect(response.status == .notFound)
                let body = String(buffer: response.body)
                #expect(body.contains("\"error\""))
                #expect(body.contains("No reminder list found"))
            }
        }
    }

    @Test func storeFailureMapsTo500JSON() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/store-failure", method: .get, headers: goodHeaders) { response in
                #expect(response.status == .internalServerError)
                #expect(String(buffer: response.body).contains("Failed to update reminder"))
            }
        }
    }

    @Test func restErrorCarriesItsStatusAndMessage() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/bad-request", method: .get, headers: goodHeaders) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("Must be one of: false, all, only"))
            }
        }
    }

    @Test func logLineCarriesMethodPathStatusAndNoBody() async throws {
        let box = LogBox()
        let app = makeApp(log: { box.append($0) })
        try await app.test(.router) { client in
            try await client.execute(uri: "/ping", method: .get, headers: goodHeaders) { _ in }
        }
        let line = try #require(box.lines.first)
        #expect(line.contains("GET"))
        #expect(line.contains("/ping"))
        #expect(line.contains("200"))
        #expect(!line.contains("pong"))
        #expect(!line.contains("secret"))
    }
}
