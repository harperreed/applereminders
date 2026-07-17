// ABOUTME: Tests for MCPServer's per-message entry point used by HTTP transports.
// ABOUTME: Covers request/notification/parse-error/unknown-method outcomes without stdio.

import Foundation
import RemindersCore
import RemindersTestSupport
import Testing
@testable import RemindersServer

@Suite("MCP per-message entry point")
struct MCPMessageEntryPointTests {

    /// Builds a server whose stdio seams are inert: the entry point is called
    /// directly, so the input stream is pre-finished and output is discarded.
    private func makeServer() -> MCPServer {
        let backend = FakeEventStoreBackend()
        let store = RemindersStore(backend: backend)
        let input = AsyncThrowingStream<String, Error> { continuation in
            continuation.finish()
        }
        return MCPServer(store: store, input: input, output: { _ in })
    }

    @Test func initializeRequestReturnsResponseLine() async throws {
        let server = makeServer()
        let message = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        let response = await server.response(forMessageData: Data(message.utf8))
        let line = try #require(response)
        #expect(line.contains("protocolVersion"))
        #expect(line.contains("\"id\":1"))
    }

    @Test func notificationReturnsNil() async {
        let server = makeServer()
        let message = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let response = await server.response(forMessageData: Data(message.utf8))
        #expect(response == nil)
    }

    @Test func parseErrorReturnsMinus32700() async throws {
        let server = makeServer()
        let response = await server.response(forMessageData: Data("this is not json".utf8))
        let line = try #require(response)
        #expect(line.contains("-32700"))
    }

    @Test func unknownMethodWithIdReturnsMinus32601() async throws {
        let server = makeServer()
        let message = #"{"jsonrpc":"2.0","id":7,"method":"no/such/method"}"#
        let response = await server.response(forMessageData: Data(message.utf8))
        let line = try #require(response)
        #expect(line.contains("-32601"))
        #expect(line.contains("\"id\":7"))
    }

    @Test func unknownMethodWithoutIdReturnsNil() async {
        let server = makeServer()
        let message = #"{"jsonrpc":"2.0","method":"no/such/method"}"#
        let response = await server.response(forMessageData: Data(message.utf8))
        #expect(response == nil)
    }

    @Test func toolsListReturnsDefinitions() async throws {
        let server = makeServer()
        let message = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let response = await server.response(forMessageData: Data(message.utf8))
        let line = try #require(response)
        #expect(line.contains("show_lists"))
    }
}
