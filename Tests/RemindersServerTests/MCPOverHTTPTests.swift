// ABOUTME: End-to-end tests for the stateless MCP-over-HTTP transport at POST /mcp.
// ABOUTME: Covers initialize, tools, notifications (202), protocol errors (HTTP 200), 405s, auth.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import RemindersCore
import RemindersTestSupport
import Testing
@testable import RemindersServer

@Suite("MCP over HTTP")
struct MCPOverHTTPTests {

    @Test func initializeReturnsJSONAndNoSessionHeader() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")
                let body = String(buffer: response.body)
                #expect(body.contains("protocolVersion"))
                #expect(body.contains("\"id\":1"))
                if let sessionHeader = HTTPField.Name("Mcp-Session-Id") {
                    #expect(response.headers[sessionHeader] == nil)
                }
            }
        }
    }

    @Test func notificationGets202WithEmptyBody() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            ) { response in
                #expect(response.status == .accepted)
                #expect(response.body.readableBytes == 0)
            }
        }
    }

    @Test func parseErrorIsJSONRPCEnvelopeWithHTTP200() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: "this is not json")
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("-32700"))
            }
        }
    }

    @Test func unknownMethodIsJSONRPCEnvelopeWithHTTP200() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":9,"method":"no/such"}"#)
            ) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("-32601"))
                #expect(body.contains("\"id\":9"))
            }
        }
    }

    @Test func toolsListAndCallWorkOverHTTP() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            ) { response in
                #expect(String(buffer: response.body).contains("show_lists"))
            }
            let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"show_lists","arguments":{}}}"#
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: call)
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("Chores"))
            }
        }
    }

    @Test func getAndDeleteAre405() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(uri: "/mcp", method: .get, headers: authHeaders) { response in
                #expect(response.status == .methodNotAllowed)
            }
            try await client.execute(uri: "/mcp", method: .delete, headers: authHeaders) { response in
                #expect(response.status == .methodNotAllowed)
            }
        }
    }

    @Test func mcpWithoutTokenIs401() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(response.body.readableBytes == 0)
            }
        }
    }
}
