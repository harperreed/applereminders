// ABOUTME: Tests for the public GET /openapi endpoint and its embedded document.
// ABOUTME: Validates the embedded document's routes and bearer security without TCC.

import EventKit
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import RemindersServer

@Suite("OpenAPI endpoint")
struct OpenAPIEndpointTests {

    @Test func endpointIsPublicWithoutRemindersAccess() async throws {
        let (backend, store) = makeTestStore()
        backend.authorizationStatus = .denied
        let app = makeTestApp(store: store)

        try await app.test(.router) { client in
            try await client.execute(uri: "/openapi", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")
                #expect(String(buffer: response.body) == openAPISpecJSON)
            }

            let wrongHeaders: HTTPFields = [.authorization: "Bearer definitely-wrong"]
            try await client.execute(uri: "/openapi", method: .get, headers: wrongHeaders) { response in
                #expect(response.status == .ok)
            }
        }

        #expect(backend.accessRequestCount == 0)
    }

    @Test func documentDescribesEveryRESTOperation() throws {
        let document = try #require(
            JSONSerialization.jsonObject(with: Data(openAPISpecJSON.utf8)) as? [String: Any]
        )
        #expect(document["openapi"] as? String == "3.1.0")

        let servers = try #require(document["servers"] as? [[String: Any]])
        #expect(servers.first?["url"] as? String == "/")

        let paths = try #require(document["paths"] as? [String: Any])
        let expectedOperations: [String: Set<String>] = [
            "/api/lists": ["get"],
            "/api/reminders": ["get", "post"],
            "/api/reminders/{id}": ["patch", "delete"],
            "/api/reminders/{id}/complete": ["post"],
            "/api/reminders/{id}/uncomplete": ["post"],
        ]
        #expect(Set(paths.keys) == Set(expectedOperations.keys))
        for (path, methods) in expectedOperations {
            let item = try #require(paths[path] as? [String: Any])
            #expect(Set(item.keys) == methods)
        }

        let components = try #require(document["components"] as? [String: Any])
        let schemes = try #require(components["securitySchemes"] as? [String: Any])
        let bearer = try #require(schemes["bearerAuth"] as? [String: Any])
        #expect(bearer["type"] as? String == "http")
        #expect(bearer["scheme"] as? String == "bearer")

        let schemas = try #require(components["schemas"] as? [String: Any])
        #expect(Set(schemas.keys) == [
            "ReminderList",
            "ReminderItem",
            "CreateReminderRequest",
            "PatchReminderRequest",
            "Priority",
            "Error",
        ])

        let security = try #require(document["security"] as? [[String: Any]])
        #expect(security.first?["bearerAuth"] is [Any])
    }
}
